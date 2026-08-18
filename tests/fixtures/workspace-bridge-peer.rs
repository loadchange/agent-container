use std::env;
use std::error::Error;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::thread;
use std::time::Duration;

const AUTH_PREFIX: &str = "AGENT-CONTAINER-WORKSPACE/1 ";
const REQUEST: &[u8] = b"\x00SFTP-REQUEST\xff\x10\n";
const RESPONSE: &[u8] = b"\xffSFTP-RESPONSE\x00\x11\n";

fn run_peer(token: &str, read_request: bool) -> Result<(), Box<dyn Error>> {
    if token.len() != 64
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("peer token must be 64 lowercase hexadecimal characters".into());
    }

    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    println!("{}", listener.local_addr()?);
    io::stdout().flush()?;

    let (mut stream, _) = listener.accept()?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;

    let expected_frame = format!("{AUTH_PREFIX}{token}\n").into_bytes();
    if expected_frame.len() != 93 {
        return Err(format!(
            "authentication frame is {} bytes, not 93",
            expected_frame.len()
        )
        .into());
    }
    let mut received_frame = vec![0_u8; expected_frame.len()];
    stream.read_exact(&mut received_frame)?;
    if received_frame != expected_frame {
        return Err("authentication frame did not match exactly".into());
    }

    if read_request {
        let mut received_request = vec![0_u8; REQUEST.len()];
        stream.read_exact(&mut received_request)?;
        if received_request != REQUEST {
            return Err("binary client payload changed in transit".into());
        }
        let mut trailing = [0_u8; 1];
        if stream.read(&mut trailing)? != 0 {
            return Err("unexpected bytes followed the binary client payload".into());
        }
    }

    stream.write_all(RESPONSE)?;
    stream.flush()?;
    stream.shutdown(Shutdown::Write)?;
    Ok(())
}

fn run_relay(arguments: &[String]) -> Result<(), Box<dyn Error>> {
    if arguments.len() != 4
        || arguments[0] != "-t"
        || arguments[1] != "1"
        || arguments[2] != "STDIO"
    {
        return Err(
            "relay usage: workspace-bridge-peer -t 1 STDIO TCP4-CONNECT:HOST:PORT,options"
                .into(),
        );
    }
    let address = arguments[3]
        .strip_prefix("TCP4-CONNECT:")
        .and_then(|value| value.strip_suffix(",connect-timeout=5,nodelay"))
        .ok_or("relay TCP address was not canonical")?;
    let stream = TcpStream::connect(address)?;
    stream.set_nodelay(true)?;
    let mut download_stream = stream.try_clone()?;
    let mut upload_stream = stream;

    let upload = thread::spawn(move || -> io::Result<()> {
        let stdin = io::stdin();
        let mut stdin = stdin.lock();
        io::copy(&mut stdin, &mut upload_stream)?;
        upload_stream.shutdown(Shutdown::Write)
    });

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let bytes_read = download_stream.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        stdout.write_all(&buffer[..bytes_read])?;
        // std::io::Stdout is line-buffered. SFTP frames need to be forwarded
        // immediately even when a frame contains no newline.
        stdout.flush()?;
    }
    // Socat exits after its one-second half-close grace when the peer closes,
    // even if local stdin remains open. Model that behavior without allowing a
    // fixture thread blocked on stdin to retain the relay process forever.
    if upload.is_finished() {
        upload
            .join()
            .map_err(|_| "relay upload thread panicked")??;
    }
    Ok(())
}

fn run() -> Result<(), Box<dyn Error>> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    if arguments.first().map(String::as_str) == Some("--peer") {
        if arguments.len() != 2 {
            return Err("peer usage: workspace-bridge-peer --peer TOKEN".into());
        }
        run_peer(&arguments[1], true)
    } else if arguments.first().map(String::as_str) == Some("--peer-close-after-auth") {
        if arguments.len() != 2 {
            return Err(
                "peer usage: workspace-bridge-peer --peer-close-after-auth TOKEN".into(),
            );
        }
        run_peer(&arguments[1], false)
    } else {
        run_relay(&arguments)
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("workspace-bridge-peer: {error}");
        std::process::exit(1);
    }
}
