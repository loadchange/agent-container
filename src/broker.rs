use std::ffi::{OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";
const SFTP_SERVER: &str = "/usr/libexec/sftp-server";
const AUTH_PREFIX: &[u8] = b"AGENT-CONTAINER-WORKSPACE/1 ";
const AUTH_TIMEOUT: Duration = Duration::from_secs(5);
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const MAX_AUTH_BYTES: usize = 100;
const RUNTIME_LIVENESS_FD: RawFd = 8;

struct BrokerLiveness {
    owner_dead: Arc<AtomicBool>,
    active_stream: Arc<Mutex<Option<TcpStream>>>,
}

impl BrokerLiveness {
    fn from_fd(fd: RawFd) -> Result<Self, String> {
        set_close_on_exec(fd).map_err(|error| {
            format!("could not protect workspace broker liveness fd {fd}: {error}")
        })?;
        // SAFETY: the private broker command accepts exactly fd 8, which the
        // runtime opens solely for this child and transfers into our ownership.
        let mut reader = unsafe { File::from_raw_fd(fd) };
        let owner_dead = Arc::new(AtomicBool::new(false));
        let active_stream = Arc::new(Mutex::new(None::<TcpStream>));
        let watcher_owner_dead = Arc::clone(&owner_dead);
        let watcher_stream = Arc::clone(&active_stream);
        thread::Builder::new()
            .name("workspace-owner-liveness".to_owned())
            .spawn(move || {
                let mut byte = [0_u8; 1];
                loop {
                    match reader.read(&mut byte) {
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        // The owner never writes data. EOF, an unexpected byte,
                        // or a pipe error all revoke this broker fail-closed.
                        Ok(_) | Err(_) => break,
                    }
                }
                watcher_owner_dead.store(true, Ordering::Release);
                if let Ok(stream) = watcher_stream.lock() {
                    if let Some(stream) = stream.as_ref() {
                        let _ = stream.shutdown(Shutdown::Both);
                    }
                }
            })
            .map_err(|error| format!("could not start workspace owner watcher: {error}"))?;
        Ok(Self {
            owner_dead,
            active_stream,
        })
    }

    fn owner_is_dead(&self) -> bool {
        self.owner_dead.load(Ordering::Acquire)
    }

    fn attach(&self, stream: &TcpStream) -> Result<(), String> {
        let shutdown_stream = stream
            .try_clone()
            .map_err(|error| format!("could not monitor workspace broker connection: {error}"))?;
        let mut active_stream = self
            .active_stream
            .lock()
            .map_err(|_| "workspace owner watcher state was poisoned".to_owned())?;
        if self.owner_is_dead() {
            let _ = shutdown_stream.shutdown(Shutdown::Both);
            return Err("workspace broker owner exited before connection setup".to_owned());
        }
        *active_stream = Some(shutdown_stream);
        Ok(())
    }
}

fn set_close_on_exec(fd: RawFd) -> io::Result<()> {
    use std::os::raw::c_int;

    const F_GETFD: c_int = 1;
    const F_SETFD: c_int = 2;
    const FD_CLOEXEC: c_int = 1;
    extern "C" {
        fn fcntl(fd: c_int, command: c_int, ...) -> c_int;
    }

    // SAFETY: fcntl is called with the portable descriptor flag operations and
    // an integer third argument required by F_SETFD.
    let flags = unsafe { fcntl(fd, F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { fcntl(fd, F_SETFD, flags | FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

const SANDBOX_PROFILE: &str = r#"(version 1)
(deny default)
(import "system.sb")
(deny network*)
; system.sb is needed to bootstrap Apple's platform SFTP binary, but it also
; grants ordinary reads of several host files.  Revoke data access using the
; same or more-specific filters while retaining executable mapping and the
; non-file process primitives required at startup.
(deny file-read-data
  (subpath "/AppleInternal")
  (subpath "/Library/Apple")
  (subpath "/Library/Filesystems/NetFSPlugins")
  (subpath "/Library/Preferences/Logging")
  (subpath "/System")
  (subpath "/private/var/db/timezone")
  (subpath "/usr/appleinternal")
  (subpath "/usr/lib")
  (subpath "/usr/share")
  (subpath "/usr/local/lib/log")
  (subpath "/dev/fd")
  (literal "/private/etc/master.passwd")
  (literal "/private/etc/passwd")
  (literal "/private/etc/protocols")
  (literal "/private/etc/services")
  (literal "/private/var/db/DarwinDirectory/local/recordStore.data")
  (literal "/private/var/db/eligibilityd/eligibility.plist")
  (literal "/usr/local/share/posix_spawn_filtering_rules"))
(allow process-exec
  (literal "/usr/libexec/sftp-server"))
(allow file-read* file-test-existence file-map-executable
  (literal "/usr/libexec/sftp-server"))
(allow file-read* file-test-existence
  (subpath (param "WORKSPACE_ROOT")))
(allow file-write*
  (subpath (param "WORKSPACE_ROOT")))
(allow file-read-metadata file-test-existence
  (path-ancestors (param "WORKSPACE_ROOT")))
"#;

pub fn run(arguments: &[OsString]) -> Result<(), String> {
    let liveness_fd = match arguments {
        [_, _] => None,
        [_, _, option, fd] if option == OsStr::new("--liveness-fd") && fd == OsStr::new("8") => {
            Some(RUNTIME_LIVENESS_FD)
        }
        _ => {
            return Err(
                "usage: agent-container __workspace-broker ROOT BIND_IP [--liveness-fd 8]"
                    .to_owned(),
            )
        }
    };

    let root = canonical_root(Path::new(&arguments[0]))?;
    let bind_ip = parse_bind_ip(&arguments[1])?;
    require_system_executable(Path::new(SANDBOX_EXEC))?;
    require_system_executable(Path::new(SFTP_SERVER))?;
    let liveness = liveness_fd.map(BrokerLiveness::from_fd).transpose()?;

    let listener = TcpListener::bind((bind_ip, 0))
        .map_err(|error| format!("could not bind workspace broker to {bind_ip}: {error}"))?;
    let local_address = listener
        .local_addr()
        .map_err(|error| format!("could not inspect workspace broker endpoint: {error}"))?;
    let token = random_token()?;

    {
        let stdout = io::stdout();
        let mut stdout = stdout.lock();
        writeln!(stdout, "{}\t{}", local_address, token)
            .and_then(|_| stdout.flush())
            .map_err(|error| format!("could not publish workspace broker endpoint: {error}"))?;
    }

    let mut stream = accept_one(listener, liveness.as_ref())?;
    if let Some(liveness) = liveness.as_ref() {
        liveness.attach(&stream)?;
    }
    stream
        .set_nodelay(true)
        .map_err(|error| format!("could not configure workspace broker connection: {error}"))?;
    authenticate(&mut stream, &token)?;
    serve_sftp(stream, &root)
}

fn canonical_root(input: &Path) -> Result<PathBuf, String> {
    let canonical = fs::canonicalize(input)
        .map_err(|error| format!("could not canonicalize workspace root {:?}: {error}", input))?;
    let metadata = fs::metadata(&canonical)
        .map_err(|error| format!("could not inspect workspace root {:?}: {error}", canonical))?;
    if !metadata.is_dir() {
        return Err(format!(
            "workspace root must resolve to a directory: {:?}",
            canonical
        ));
    }
    if canonical == Path::new("/") {
        return Err(
            "refusing to expose the filesystem root through the workspace broker".to_owned(),
        );
    }
    Ok(canonical)
}

fn accept_one(
    listener: TcpListener,
    liveness: Option<&BrokerLiveness>,
) -> Result<TcpStream, String> {
    accept_before_with_liveness(listener, Instant::now() + ACCEPT_TIMEOUT, liveness)
}

#[cfg(test)]
fn accept_before(listener: TcpListener, deadline: Instant) -> Result<TcpStream, String> {
    accept_before_with_liveness(listener, deadline, None)
}

fn accept_before_with_liveness(
    listener: TcpListener,
    deadline: Instant,
    liveness: Option<&BrokerLiveness>,
) -> Result<TcpStream, String> {
    listener
        .set_nonblocking(true)
        .map_err(|error| format!("could not configure workspace broker listener: {error}"))?;
    loop {
        if liveness.is_some_and(BrokerLiveness::owner_is_dead) {
            return Err("workspace broker owner exited before a connection arrived".to_owned());
        }
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).map_err(|error| {
                    format!("could not configure workspace broker connection: {error}")
                })?;
                return Ok(stream);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let now = Instant::now();
                if now >= deadline {
                    return Err("workspace broker timed out waiting for one connection".to_owned());
                }
                thread::sleep(ACCEPT_POLL_INTERVAL.min(deadline.saturating_duration_since(now)));
            }
            Err(error) => {
                return Err(format!(
                    "could not accept workspace broker connection: {error}"
                ))
            }
        }
    }
}

fn parse_bind_ip(input: &OsStr) -> Result<Ipv4Addr, String> {
    let text = input
        .to_str()
        .ok_or_else(|| "workspace broker BIND_IP must be UTF-8 IPv4 text".to_owned())?;
    text.parse::<Ipv4Addr>()
        .map_err(|_| format!("workspace broker BIND_IP is not an IPv4 address: {text:?}"))
}

fn require_system_executable(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        format!(
            "required system executable is unavailable at {:?}: {error}",
            path
        )
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.file_type().is_file()
        || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(format!(
            "required system executable is not a non-symlink executable file: {:?}",
            path
        ));
    }
    Ok(())
}

fn random_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .map_err(|error| {
            format!("could not read workspace broker token from /dev/urandom: {error}")
        })?;
    let mut token = String::with_capacity(64);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        token.push(HEX[(byte >> 4) as usize] as char);
        token.push(HEX[(byte & 0x0f) as usize] as char);
    }
    Ok(token)
}

fn expected_authentication(token: &str) -> Vec<u8> {
    let mut expected = Vec::with_capacity(AUTH_PREFIX.len() + token.len() + 1);
    expected.extend_from_slice(AUTH_PREFIX);
    expected.extend_from_slice(token.as_bytes());
    expected.push(b'\n');
    expected
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        let left_byte = left.get(index).copied().unwrap_or(0);
        let right_byte = right.get(index).copied().unwrap_or(0);
        difference |= usize::from(left_byte ^ right_byte);
    }
    difference == 0
}

fn authenticate(stream: &mut TcpStream, token: &str) -> Result<(), String> {
    let deadline = Instant::now() + AUTH_TIMEOUT;
    let mut line = Vec::with_capacity(MAX_AUTH_BYTES);

    loop {
        if line.len() == MAX_AUTH_BYTES {
            return Err("workspace broker authentication exceeded 100 bytes".to_owned());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err("workspace broker authentication timed out".to_owned());
        }
        stream
            .set_read_timeout(Some(deadline.saturating_duration_since(now)))
            .map_err(|error| format!("could not set authentication timeout: {error}"))?;

        let mut byte = [0_u8; 1];
        match stream.read(&mut byte) {
            Ok(0) => {
                return Err("workspace broker connection closed before authentication".to_owned())
            }
            Ok(_) => {
                line.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Err("workspace broker authentication timed out".to_owned())
            }
            Err(error) => {
                return Err(format!(
                    "could not read workspace broker authentication: {error}"
                ))
            }
        }
    }

    stream
        .set_read_timeout(None)
        .map_err(|error| format!("could not clear authentication timeout: {error}"))?;
    if !constant_time_equal(&line, &expected_authentication(token)) {
        return Err("workspace broker authentication failed".to_owned());
    }
    Ok(())
}

fn workspace_definition(root: &Path) -> OsString {
    let mut value = OsString::from_vec(b"WORKSPACE_ROOT=".to_vec());
    value.push(root.as_os_str());
    value
}

fn serve_sftp(mut stream: TcpStream, root: &Path) -> Result<(), String> {
    let mut child = Command::new(SANDBOX_EXEC)
        .arg("-D")
        .arg(workspace_definition(root))
        .arg("-p")
        .arg(SANDBOX_PROFILE)
        .arg(SFTP_SERVER)
        .arg("-e")
        .arg("-d")
        .arg(root.as_os_str())
        .current_dir(root)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("could not start sandboxed SFTP server: {error}"))?;

    let mut child_stdin = child
        .stdin
        .take()
        .ok_or_else(|| "sandboxed SFTP server has no stdin pipe".to_owned())?;
    let mut child_stdout = child
        .stdout
        .take()
        .ok_or_else(|| "sandboxed SFTP server has no stdout pipe".to_owned())?;
    let mut upload_stream = stream
        .try_clone()
        .map_err(|error| format!("could not clone workspace broker connection: {error}"))?;

    let upload = thread::spawn(move || {
        let result = io::copy(&mut upload_stream, &mut child_stdin);
        drop(child_stdin);
        result
    });

    let download_result = io::copy(&mut child_stdout, &mut stream);
    if download_result.is_err() {
        let _ = child.kill();
    }
    let _ = stream.shutdown(Shutdown::Both);

    let upload_result = upload
        .join()
        .map_err(|_| "workspace broker upload relay panicked".to_owned())?;
    if upload_result.is_err() {
        let _ = child.kill();
    }
    let status = child
        .wait()
        .map_err(|error| format!("could not wait for sandboxed SFTP server: {error}"))?;

    if let Err(error) = download_result {
        return Err(format!("workspace broker download relay failed: {error}"));
    }
    if let Err(error) = upload_result {
        if !is_connection_shutdown(&error) {
            return Err(format!("workspace broker upload relay failed: {error}"));
        }
    }
    if !status.success() {
        return Err(format!(
            "sandboxed SFTP server exited unsuccessfully: {status}"
        ));
    }
    Ok(())
}

fn is_connection_shutdown(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotConnected
            | io::ErrorKind::UnexpectedEof
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddrV4;
    use std::os::unix::io::IntoRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn token_is_256_bit_lowercase_hex() {
        let first = random_token().unwrap();
        let second = random_token().unwrap();
        assert_eq!(first.len(), 64);
        assert!(first
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)));
        assert_ne!(first, second);
    }

    #[test]
    fn authentication_frame_has_the_fixed_protocol_shape() {
        let token = "a".repeat(64);
        let frame = expected_authentication(&token);
        assert_eq!(
            frame,
            format!("AGENT-CONTAINER-WORKSPACE/1 {token}\n").as_bytes()
        );
        assert!(frame.len() <= MAX_AUTH_BYTES);
    }

    #[test]
    fn authentication_does_not_consume_the_first_sftp_byte() {
        let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let token = "b".repeat(64);
        let client_token = token.clone();
        let client = thread::spawn(move || {
            let mut stream = TcpStream::connect(address).unwrap();
            stream
                .write_all(&expected_authentication(&client_token))
                .unwrap();
            stream.write_all(&[0x42]).unwrap();
        });

        let (mut stream, _) = listener.accept().unwrap();
        authenticate(&mut stream, &token).unwrap();
        let mut first_sftp_byte = [0_u8; 1];
        stream.read_exact(&mut first_sftp_byte).unwrap();
        assert_eq!(first_sftp_byte, [0x42]);
        client.join().unwrap();
    }

    #[test]
    fn authentication_rejects_wrong_and_oversized_frames() {
        for frame in [
            b"AGENT-CONTAINER-WORKSPACE/1 wrong\n".to_vec(),
            vec![b'x'; MAX_AUTH_BYTES + 1],
        ] {
            let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).unwrap();
            let address = listener.local_addr().unwrap();
            let client = thread::spawn(move || {
                let mut stream = TcpStream::connect(address).unwrap();
                stream.write_all(&frame).unwrap();
            });
            let (mut stream, _) = listener.accept().unwrap();
            assert!(authenticate(&mut stream, &"c".repeat(64)).is_err());
            client.join().unwrap();
        }
    }

    #[test]
    fn sandbox_profile_is_default_deny_and_workspace_parameterized() {
        assert!(SANDBOX_PROFILE.contains("(deny default)"));
        assert!(SANDBOX_PROFILE.contains("(deny network*)"));
        assert!(SANDBOX_PROFILE.contains("(subpath (param \"WORKSPACE_ROOT\"))"));
        assert!(!SANDBOX_PROFILE.contains("(allow network"));
        assert!(!SANDBOX_PROFILE.contains("(allow process*)"));
        assert!(SANDBOX_PROFILE.contains("(deny file-read-data"));
        assert!(SANDBOX_PROFILE.contains("(literal \"/private/etc/passwd\")"));
    }

    #[test]
    fn workspace_definition_preserves_non_utf8_paths() {
        use std::os::unix::ffi::OsStrExt;

        let path = Path::new(OsStr::from_bytes(b"/tmp/workspace-\xff"));
        assert_eq!(
            workspace_definition(path).as_bytes(),
            b"WORKSPACE_ROOT=/tmp/workspace-\xff"
        );
    }

    #[test]
    fn bind_address_requires_ipv4() {
        assert_eq!(
            parse_bind_ip(OsStr::new("127.0.0.1")).unwrap(),
            Ipv4Addr::LOCALHOST
        );
        assert!(parse_bind_ip(OsStr::new("::1")).is_err());
        assert!(parse_bind_ip(OsStr::new("hostname.local")).is_err());
    }

    #[test]
    fn canonical_root_rejects_the_filesystem_root() {
        assert!(canonical_root(Path::new("/")).is_err());
        assert!(canonical_root(Path::new(".")).is_ok());
    }

    #[test]
    fn accept_has_a_total_deadline() {
        let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).unwrap();
        let started = Instant::now();
        let result = accept_before(listener, started + Duration::from_millis(10));
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn owner_eof_revokes_an_attached_connection() {
        let (owner_reader, owner_writer) = UnixStream::pair().unwrap();
        let liveness = BrokerLiveness::from_fd(owner_reader.into_raw_fd()).unwrap();
        let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        liveness.attach(&server).unwrap();

        drop(owner_writer);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !liveness.owner_is_dead() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(liveness.owner_is_dead());

        client
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut byte = [0_u8; 1];
        match client.read(&mut byte) {
            Ok(0) => {}
            Err(error) if is_connection_shutdown(&error) => {}
            result => panic!("liveness did not close the attached stream: {result:?}"),
        }
    }
}
