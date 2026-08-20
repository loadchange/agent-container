use std::env;
#[cfg(target_os = "macos")]
use std::ffi::c_void;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const RUNTIME_NAME: &str = "agent-container-runtime";
type Environment = Vec<(OsString, OsString)>;

const VALUE_OPTIONS: &[(&str, &str)] = &[
    ("cpus", "AGENT_CONTAINER_CPUS"),
    ("memory", "AGENT_CONTAINER_MEMORY"),
    ("build-cpus", "AGENT_CONTAINER_BUILD_CPUS"),
    ("build-memory", "AGENT_CONTAINER_BUILD_MEMORY"),
    ("version", "AGENT_CONTAINER_VERSION"),
    ("base-image", "AGENT_CONTAINER_BASE_IMAGE"),
    ("http-proxy", "AGENT_CONTAINER_HTTP_PROXY"),
    ("https-proxy", "AGENT_CONTAINER_HTTPS_PROXY"),
    ("all-proxy", "AGENT_CONTAINER_ALL_PROXY"),
    ("no-proxy", "AGENT_CONTAINER_NO_PROXY"),
    ("extra-ca", "AGENT_CONTAINER_EXTRA_CA_CERTS"),
    ("dns1", "AGENT_CONTAINER_DNS1"),
    ("dns2", "AGENT_CONTAINER_DNS2"),
    ("timezone", "AGENT_CONTAINER_TZ"),
    ("forward-env", "AGENT_CONTAINER_FORWARD_ENV"),
    ("max-files", "AGENT_CONTAINER_MAX_FILES"),
    ("fd-stop-percent", "AGENT_CONTAINER_FD_STOP_PERCENT"),
    ("assets", "AGENT_CONTAINER_ASSET_DIR"),
    ("bin", "AGENT_CONTAINER_BIN"),
    ("host-broker", "AGENT_CONTAINER_HOST_BROKER_BIN"),
    ("host-node", "AGENT_CONTAINER_HOST_NODE_BIN"),
    ("host-gateway", "AGENT_CONTAINER_HOST_GATEWAY"),
    ("host-alias", "AGENT_CONTAINER_HOST_ALIAS"),
    ("block-host", "AGENT_CONTAINER_BLOCK_HOST"),
    ("openssl", "AGENT_CONTAINER_OPENSSL_BIN"),
    ("security", "AGENT_CONTAINER_SECURITY_BIN"),
];

const BOOLEAN_OPTIONS: &[(&str, &str)] = &[
    ("enable-experimental", "AGENT_CONTAINER_ENABLE_EXPERIMENTAL"),
    ("rebuild", "AGENT_CONTAINER_REBUILD"),
    ("skip-build", "AGENT_CONTAINER_SKIP_BUILD"),
    ("full-git-config", "AGENT_CONTAINER_FULL_GIT_CONFIG"),
    ("mount-gh", "AGENT_CONTAINER_MOUNT_GH"),
    ("forward-api-key", "AGENT_CONTAINER_FORWARD_API_KEY"),
    ("forward-ssh-agent", "AGENT_CONTAINER_FORWARD_SSH_AGENT"),
    ("mount-ssh-config", "AGENT_CONTAINER_MOUNT_SSH_CONFIG"),
    (
        "accept-virtiofs-risk",
        "AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK",
    ),
    ("allow-concurrent", "AGENT_CONTAINER_ALLOW_CONCURRENT"),
    ("disable-fd-watchdog", "AGENT_CONTAINER_DISABLE_FD_WATCHDOG"),
    ("host-tools", "AGENT_CONTAINER_HOST_TOOLS"),
];

const REMOVED_ENVIRONMENT: &[(&str, &str)] = &[
    (
        "AGENT_CONTAINER_RUNTIME",
        "runtime selection is bound to the source checkout or installed release",
    ),
    (
        "AGENT_CONTAINER_IMAGE",
        "custom image references are unsupported because images are profile-owned",
    ),
    (
        "AGENT_CONTAINER_STATE_DIR",
        "custom state roots are unsupported because uninstall must discover active sessions",
    ),
];

// These names are private launcher/build/guest protocol fields.  A public
// invocation must never accept ambient values for them: the launcher and
// runtime derive every value from the selected release, host identity, or
// per-session state.
const INTERNAL_ABI_ENVIRONMENT: &[&str] = &[
    "AGENT_CONTAINER",
    "AGENT_WORKSPACE",
    "AGENT_PROFILE",
    "AGENT_VERSION",
    "AGENT_COMMAND",
    "AGENT_PROBE_ARG",
    "AGENT_CA_FINGERPRINT",
    "AGENT_INSTALLER_URL",
    "AGENT_INSTALLER_SHELL",
    "AGENT_INSTALLER_VERSION_ENV",
    "AGENT_INSTALLER_BIN_DIR_ENV",
    "AGENT_INSTALLER_HOME_ENV",
    "AGENT_INSTALLER_NONINTERACTIVE_ENV",
    "HOST_UID",
    "HOST_GID",
    "HOST_HOME",
    "XDG_RUNTIME_DIR",
    "IS_SANDBOX",
    "BASE_IMAGE",
    "DEFAULT_BASE_IMAGE",
];

const RESERVED_ENVIRONMENT_PREFIXES: &[&[u8]] = &[b"AGENT_CONTAINER_", b"AGENT_WORKSPACE_"];

// The runtime is a non-interactive Bash program which invokes network, TLS,
// Git, and native tooling.  None of those tools may acquire an undeclared
// configuration channel from the launcher's ambient environment.  Agent
// credentials and settings are deliberately absent from this list; their
// existing name-only forwarding path does not put secret values in argv.
const DANGEROUS_AMBIENT_ENVIRONMENT: &[&str] = &[
    // Bash startup and execution controls.
    "BASH_ENV",
    "ENV",
    "SHELLOPTS",
    "BASHOPTS",
    "BASH_COMPAT",
    "POSIXLY_CORRECT",
    "CDPATH",
    "GLOBIGNORE",
    "IFS",
    "PS4",
    "BASH_XTRACEFD",
    "BASH_LOADABLES_PATH",
    "PROMPT_COMMAND",
    // Proxy selection must come from --container-*-proxy.
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "FTP_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
    "ftp_proxy",
    // TLS and tool configuration must come from --container-extra-ca and the
    // verified release/runtime configuration.
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "SSLKEYLOGFILE",
    "XDG_CONFIG_HOME",
    "SSH_ASKPASS",
    "SSH_ASKPASS_REQUIRE",
];

const DANGEROUS_AMBIENT_PREFIXES: &[&[u8]] = &[
    b"BASH_FUNC_",
    b"CURL_",
    b"GIT_",
    b"OPENSSL_",
    b"LD_",
    b"DYLD_",
];

#[derive(Debug, PartialEq, Eq)]
pub struct LaunchPlan {
    pub runtime_arguments: Vec<OsString>,
    pub environment: Environment,
}

fn legacy_environment_error(environment: &Environment) -> Option<String> {
    for (environment_name, _) in environment {
        for &(option_name, legacy_name) in VALUE_OPTIONS {
            if environment_name == OsStr::new(legacy_name) {
                return Some(format!(
                    "{legacy_name} is no longer a public interface; pass --container-{option_name} VALUE as a leading launcher option"
                ));
            }
        }
        for &(option_name, legacy_name) in BOOLEAN_OPTIONS {
            if environment_name == OsStr::new(legacy_name) {
                return Some(format!(
                    "{legacy_name} is no longer a public interface; pass --container-{option_name} or --no-container-{option_name} as a leading launcher option"
                ));
            }
        }
        for &(legacy_name, replacement) in REMOVED_ENVIRONMENT {
            if environment_name == OsStr::new(legacy_name) {
                return Some(format!("{legacy_name} was removed: {replacement}"));
            }
        }
        if has_any_prefix(environment_name, RESERVED_ENVIRONMENT_PREFIXES) {
            return Some(format!(
                "{} is reserved for the private launcher/runtime protocol; pass a documented --container-* option instead",
                environment_name.to_string_lossy()
            ));
        }
        if INTERNAL_ABI_ENVIRONMENT
            .iter()
            .any(|name| environment_name == OsStr::new(name))
        {
            return Some(format!(
                "{} is reserved for the private launcher/runtime protocol and may not be supplied by the user environment",
                environment_name.to_string_lossy()
            ));
        }
    }
    None
}

fn has_any_prefix(name: &OsStr, prefixes: &[&[u8]]) -> bool {
    let bytes = name.as_bytes();
    prefixes.iter().any(|prefix| bytes.starts_with(prefix))
}

fn should_remove_from_runtime_environment(name: &OsStr) -> bool {
    has_any_prefix(name, RESERVED_ENVIRONMENT_PREFIXES)
        || has_any_prefix(name, DANGEROUS_AMBIENT_PREFIXES)
        || INTERNAL_ABI_ENVIRONMENT
            .iter()
            .any(|candidate| name == OsStr::new(candidate))
        || DANGEROUS_AMBIENT_ENVIRONMENT
            .iter()
            .any(|candidate| name == OsStr::new(candidate))
}

fn scrub_runtime_environment(command: &mut Command, environment: &Environment) {
    for (name, _) in environment {
        if should_remove_from_runtime_environment(name) {
            command.env_remove(name);
        }
    }
}

pub fn reject_legacy_environment() -> Result<(), String> {
    let environment: Environment = env::vars_os().collect();
    match legacy_environment_error(&environment) {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Invocation {
    Generic,
    Profile(&'static str),
}

fn invocation(argv0: &OsStr) -> Result<Invocation, String> {
    let name = Path::new(argv0)
        .file_name()
        .ok_or_else(|| "argv[0] has no executable basename".to_owned())?;
    if name == OsStr::new("agent-container")
        || name == OsStr::new("agent-container-launcher")
        || name == OsStr::new("agent-container-darwin-arm64")
    {
        return Ok(Invocation::Generic);
    }
    if name == OsStr::new("claude-container") {
        return Ok(Invocation::Profile("claude"));
    }
    if name == OsStr::new("codex-container") {
        return Ok(Invocation::Profile("codex"));
    }
    if name == OsStr::new("grok-container") {
        return Ok(Invocation::Profile("grok"));
    }
    Err(format!(
        "unsupported invocation name {:?}; expected an agent-container release command",
        name
    ))
}

pub fn is_generic_invocation(argv0: &OsStr) -> bool {
    invocation(argv0) == Ok(Invocation::Generic)
}

fn option_with_value(argument: &OsStr, name: &str) -> Option<Option<OsString>> {
    let bytes = argument.as_bytes();
    let mut option = Vec::with_capacity("--container-".len() + name.len());
    option.extend_from_slice(b"--container-");
    option.extend_from_slice(name.as_bytes());

    if bytes == option {
        return Some(None);
    }
    if bytes.starts_with(&option) && bytes.get(option.len()) == Some(&b'=') {
        return Some(Some(OsString::from_vec(bytes[option.len() + 1..].to_vec())));
    }
    None
}

fn is_exact(argument: &OsStr, prefix: &[u8], name: &str) -> bool {
    let bytes = argument.as_bytes();
    bytes.len() == prefix.len() + name.len()
        && bytes.starts_with(prefix)
        && &bytes[prefix.len()..] == name.as_bytes()
}

fn parse_leading_options(
    arguments: &[OsString],
) -> Result<(Vec<OsString>, Environment, bool), String> {
    let mut environment = Vec::new();
    let mut index = 0;
    let mut delimiter_seen = false;

    while index < arguments.len() {
        let argument = arguments[index].as_os_str();
        if argument == OsStr::new("--") {
            index += 1;
            delimiter_seen = true;
            break;
        }

        let mut matched = false;
        for &(name, environment_name) in VALUE_OPTIONS {
            let Some(inline_value) = option_with_value(argument, name) else {
                continue;
            };
            let value = if let Some(value) = inline_value {
                value
            } else {
                index += 1;
                arguments
                    .get(index)
                    .cloned()
                    .ok_or_else(|| format!("--container-{name} requires a value"))?
            };
            environment.push((OsString::from(environment_name), value));
            index += 1;
            matched = true;
            break;
        }
        if matched {
            continue;
        }

        for &(name, environment_name) in BOOLEAN_OPTIONS {
            if is_exact(argument, b"--container-", name) {
                environment.push((OsString::from(environment_name), OsString::from("true")));
                index += 1;
                matched = true;
                break;
            }
            if is_exact(argument, b"--no-container-", name) {
                environment.push((OsString::from(environment_name), OsString::from("false")));
                index += 1;
                matched = true;
                break;
            }
        }
        if matched {
            continue;
        }

        if argument.as_bytes().starts_with(b"--container-")
            || argument.as_bytes().starts_with(b"--no-container-")
        {
            return Err(format!(
                "unknown launcher option {:?}; check the --container-* spelling or place Agent arguments after --",
                argument
            ));
        }

        break;
    }

    Ok((arguments[index..].to_vec(), environment, delimiter_seen))
}

pub fn plan(argv0: &OsStr, arguments: &[OsString]) -> Result<LaunchPlan, String> {
    let invocation = invocation(argv0)?;
    let (arguments, environment, delimiter_seen) = parse_leading_options(arguments)?;
    let runtime_arguments = match invocation {
        Invocation::Generic => arguments,
        Invocation::Profile(profile) => {
            let mut dispatched = Vec::with_capacity(arguments.len() + 2);
            if !delimiter_seen
                && arguments.first().map(OsString::as_os_str) == Some(OsStr::new("run"))
            {
                dispatched.push(OsString::from("run"));
                dispatched.push(OsString::from(profile));
                dispatched.extend(arguments.into_iter().skip(1));
            } else {
                dispatched.push(OsString::from(profile));
                dispatched.extend(arguments);
            }
            dispatched
        }
    };

    Ok(LaunchPlan {
        runtime_arguments,
        environment,
    })
}

fn validate_runtime(path: PathBuf) -> io::Result<PathBuf> {
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("could not inspect runtime {:?}: {error}", path),
        )
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.file_type().is_file()
        || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "runtime is not a non-symlink regular executable file: {:?}",
                path
            ),
        ));
    }
    Ok(path)
}

fn runtime_candidate(executable: &Path) -> io::Result<PathBuf> {
    let directory = executable.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "the launcher executable has no parent directory",
        )
    })?;

    if executable.file_name() == Some(OsStr::new("agent-container-launcher")) {
        let target_directory = directory.parent().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "the source launcher is not beneath target/release",
            )
        })?;
        if directory.file_name() != Some(OsStr::new("release"))
            || target_directory.file_name() != Some(OsStr::new("target"))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the source launcher is not beneath target/release",
            ));
        }
        let source_root = target_directory.parent().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "the source launcher has no repository root",
            )
        })?;
        return Ok(source_root.join("runtime").join(RUNTIME_NAME));
    }

    Ok(directory.join(RUNTIME_NAME))
}

#[cfg(target_os = "macos")]
#[link(name = "proc")]
extern "C" {
    fn proc_pidpath(pid: i32, buffer: *mut c_void, buffersize: u32) -> i32;
}

#[cfg(target_os = "macos")]
fn loaded_executable_path() -> io::Result<PathBuf> {
    const PROC_PIDPATHINFO_MAXSIZE: usize = 4096;
    let mut buffer = vec![0_u8; PROC_PIDPATHINFO_MAXSIZE];
    let length = unsafe {
        proc_pidpath(
            std::process::id() as i32,
            buffer.as_mut_ptr().cast::<c_void>(),
            buffer.len() as u32,
        )
    };
    if length <= 0 {
        let error = io::Error::last_os_error();
        return Err(io::Error::new(
            error.kind(),
            format!("could not resolve the loaded launcher executable: {error}"),
        ));
    }
    let length = usize::try_from(length).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "proc_pidpath returned a negative launcher path length",
        )
    })?;
    if length > buffer.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "proc_pidpath returned an oversized launcher path",
        ));
    }
    let path_length = buffer[..length]
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(length);
    if path_length == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "proc_pidpath returned an empty launcher path",
        ));
    }
    let path = PathBuf::from(OsString::from_vec(buffer[..path_length].to_vec()));
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "proc_pidpath returned a non-absolute launcher path",
        ));
    }
    Ok(path)
}

#[cfg(not(target_os = "macos"))]
fn loaded_executable_path() -> io::Result<PathBuf> {
    let reported_executable = env::current_exe()?;
    fs::canonicalize(&reported_executable).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "could not resolve launcher executable {:?}: {error}",
                reported_executable
            ),
        )
    })
}

fn runtime_path() -> io::Result<PathBuf> {
    validate_runtime(runtime_candidate(&loaded_executable_path()?)?)
}

#[cfg(test)]
fn runtime_path_from_reported_executable(reported_executable: &Path) -> io::Result<PathBuf> {
    let executable = fs::canonicalize(reported_executable).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "could not resolve launcher executable {:?}: {error}",
                reported_executable
            ),
        )
    })?;
    validate_runtime(runtime_candidate(&executable)?)
}

pub fn exec_runtime(plan: LaunchPlan) -> io::Result<()> {
    let runtime = runtime_path()?;
    let mut command = Command::new(&runtime);
    command.args(plan.runtime_arguments);
    let inherited_environment: Environment = env::vars_os().collect();
    scrub_runtime_environment(&mut command, &inherited_environment);
    command.envs(plan.environment);
    let error = command.exec();
    Err(io::Error::new(
        error.kind(),
        format!("could not exec runtime {:?}: {error}", runtime),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn os_values(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    fn environment_value<'a>(plan: &'a LaunchPlan, name: &str) -> Option<&'a OsStr> {
        plan.environment
            .iter()
            .rev()
            .find(|(candidate, _)| candidate == OsStr::new(name))
            .map(|(_, value)| value.as_os_str())
    }

    fn command_environment_value<'a>(
        command: &'a Command,
        name: &str,
    ) -> Option<Option<&'a OsStr>> {
        command
            .get_envs()
            .find(|(candidate, _)| *candidate == OsStr::new(name))
            .map(|(_, value)| value)
    }

    #[test]
    fn dispatches_profile_aliases_and_legacy_run_mode() {
        let claude = plan(
            OsStr::new("/usr/local/bin/claude-container"),
            &os_values(&["-p", "hello"]),
        )
        .unwrap();
        assert_eq!(
            claude.runtime_arguments,
            os_values(&["claude", "-p", "hello"])
        );

        let codex = plan(
            OsStr::new("codex-container"),
            &os_values(&["run", "--share-ro", "/tmp", "--", "ask"]),
        )
        .unwrap();
        assert_eq!(
            codex.runtime_arguments,
            os_values(&["run", "codex", "--share-ro", "/tmp", "--", "ask"])
        );

        let grok = plan(OsStr::new("grok-container"), &[]).unwrap();
        assert_eq!(grok.runtime_arguments, os_values(&["grok"]));
    }

    #[test]
    fn generic_invocation_preserves_runtime_command_shape() {
        let result = plan(
            OsStr::new("agent-container"),
            &os_values(&["singleton", "status", "grok"]),
        )
        .unwrap();
        assert_eq!(
            result.runtime_arguments,
            os_values(&["singleton", "status", "grok"])
        );

        let release_binary = plan(
            OsStr::new("agent-container-darwin-arm64"),
            &os_values(&["__workspace-broker", "/tmp/root", "127.0.0.1"]),
        )
        .unwrap();
        assert_eq!(
            release_binary.runtime_arguments,
            os_values(&["__workspace-broker", "/tmp/root", "127.0.0.1"])
        );
    }

    #[test]
    fn maps_leading_value_and_boolean_options() {
        let result = plan(
            OsStr::new("grok-container"),
            &os_values(&[
                "--container-cpus=8",
                "--container-extra-ca",
                "/tmp/root.pem",
                "--container-forward-ssh-agent",
                "--container-forward-api-key",
                "--no-container-disable-fd-watchdog",
                "question",
            ]),
        )
        .unwrap();

        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_CPUS"),
            Some(OsStr::new("8"))
        );
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_EXTRA_CA_CERTS"),
            Some(OsStr::new("/tmp/root.pem"))
        );
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_FORWARD_API_KEY"),
            Some(OsStr::new("true"))
        );
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_FORWARD_SSH_AGENT"),
            Some(OsStr::new("true"))
        );
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_DISABLE_FD_WATCHDOG"),
            Some(OsStr::new("false"))
        );
        assert_eq!(result.runtime_arguments, os_values(&["grok", "question"]));
    }

    #[test]
    fn all_value_options_have_the_expected_internal_names() {
        let expected = [
            ("cpus", "AGENT_CONTAINER_CPUS"),
            ("memory", "AGENT_CONTAINER_MEMORY"),
            ("build-cpus", "AGENT_CONTAINER_BUILD_CPUS"),
            ("build-memory", "AGENT_CONTAINER_BUILD_MEMORY"),
            ("version", "AGENT_CONTAINER_VERSION"),
            ("base-image", "AGENT_CONTAINER_BASE_IMAGE"),
            ("http-proxy", "AGENT_CONTAINER_HTTP_PROXY"),
            ("https-proxy", "AGENT_CONTAINER_HTTPS_PROXY"),
            ("all-proxy", "AGENT_CONTAINER_ALL_PROXY"),
            ("no-proxy", "AGENT_CONTAINER_NO_PROXY"),
            ("extra-ca", "AGENT_CONTAINER_EXTRA_CA_CERTS"),
            ("dns1", "AGENT_CONTAINER_DNS1"),
            ("dns2", "AGENT_CONTAINER_DNS2"),
            ("timezone", "AGENT_CONTAINER_TZ"),
            ("forward-env", "AGENT_CONTAINER_FORWARD_ENV"),
            ("max-files", "AGENT_CONTAINER_MAX_FILES"),
            ("fd-stop-percent", "AGENT_CONTAINER_FD_STOP_PERCENT"),
            ("assets", "AGENT_CONTAINER_ASSET_DIR"),
            ("bin", "AGENT_CONTAINER_BIN"),
            ("host-broker", "AGENT_CONTAINER_HOST_BROKER_BIN"),
            ("host-node", "AGENT_CONTAINER_HOST_NODE_BIN"),
            ("host-gateway", "AGENT_CONTAINER_HOST_GATEWAY"),
            ("host-alias", "AGENT_CONTAINER_HOST_ALIAS"),
            ("block-host", "AGENT_CONTAINER_BLOCK_HOST"),
            ("openssl", "AGENT_CONTAINER_OPENSSL_BIN"),
            ("security", "AGENT_CONTAINER_SECURITY_BIN"),
        ];
        assert_eq!(VALUE_OPTIONS, expected);
    }

    #[test]
    fn all_boolean_options_have_the_expected_internal_names() {
        let expected = [
            ("enable-experimental", "AGENT_CONTAINER_ENABLE_EXPERIMENTAL"),
            ("rebuild", "AGENT_CONTAINER_REBUILD"),
            ("skip-build", "AGENT_CONTAINER_SKIP_BUILD"),
            ("full-git-config", "AGENT_CONTAINER_FULL_GIT_CONFIG"),
            ("mount-gh", "AGENT_CONTAINER_MOUNT_GH"),
            ("forward-api-key", "AGENT_CONTAINER_FORWARD_API_KEY"),
            ("forward-ssh-agent", "AGENT_CONTAINER_FORWARD_SSH_AGENT"),
            ("mount-ssh-config", "AGENT_CONTAINER_MOUNT_SSH_CONFIG"),
            (
                "accept-virtiofs-risk",
                "AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK",
            ),
            ("allow-concurrent", "AGENT_CONTAINER_ALLOW_CONCURRENT"),
            ("disable-fd-watchdog", "AGENT_CONTAINER_DISABLE_FD_WATCHDOG"),
            ("host-tools", "AGENT_CONTAINER_HOST_TOOLS"),
        ];
        assert_eq!(BOOLEAN_OPTIONS, expected);
    }

    #[test]
    fn rejects_mapped_and_removed_legacy_environment() {
        let mapped = vec![(
            OsString::from("AGENT_CONTAINER_MEMORY"),
            OsString::from("8g"),
        )];
        let mapped_error = legacy_environment_error(&mapped).unwrap();
        assert!(mapped_error.contains("--container-memory VALUE"));

        let removed = vec![(
            OsString::from("AGENT_CONTAINER_IMAGE"),
            OsString::from("custom:latest"),
        )];
        let removed_error = legacy_environment_error(&removed).unwrap();
        assert!(removed_error.contains("profile-owned"));

        let runtime_override = vec![(
            OsString::from("AGENT_CONTAINER_RUNTIME"),
            OsString::from("/tmp/runtime"),
        )];
        let runtime_error = legacy_environment_error(&runtime_override).unwrap();
        assert!(runtime_error.contains("installed release"));

        let unrelated = vec![(OsString::from("ANTHROPIC_MODEL"), OsString::from("opus"))];
        assert_eq!(legacy_environment_error(&unrelated), None);
    }

    #[test]
    fn rejects_unknown_reserved_prefixes_and_every_private_abi_name() {
        for name in [
            "AGENT_CONTAINER_UNKNOWN_SETTING",
            "AGENT_CONTAINER_INSTALL_BASE_URL",
            "AGENT_WORKSPACE_UNKNOWN_FIELD",
        ] {
            let environment = vec![(OsString::from(name), OsString::new())];
            let error = legacy_environment_error(&environment).unwrap();
            assert!(
                error.contains("private launcher/runtime protocol"),
                "{name}"
            );
        }

        for name in INTERNAL_ABI_ENVIRONMENT {
            let environment = vec![(OsString::from(name), OsString::from("user-value"))];
            let error = legacy_environment_error(&environment).unwrap();
            assert!(error.contains("may not be supplied"), "{name}");
        }

        let non_utf8_reserved = vec![(
            OsString::from_vec(b"AGENT_CONTAINER_\xff".to_vec()),
            OsString::new(),
        )];
        assert!(legacy_environment_error(&non_utf8_reserved).is_some());
    }

    #[test]
    fn runtime_environment_scrub_covers_reserved_and_dangerous_names() {
        for name in DANGEROUS_AMBIENT_ENVIRONMENT {
            assert!(
                should_remove_from_runtime_environment(OsStr::new(name)),
                "dangerous exact name was retained: {name}"
            );
        }
        for name in INTERNAL_ABI_ENVIRONMENT {
            assert!(
                should_remove_from_runtime_environment(OsStr::new(name)),
                "private ABI name was retained: {name}"
            );
        }
        for name in [
            "AGENT_CONTAINER_FUTURE_OPTION",
            "AGENT_WORKSPACE_FUTURE_FIELD",
            "BASH_FUNC_injected%%",
            "CURL_CA_BUNDLE",
            "GIT_CONFIG_GLOBAL",
            "OPENSSL_CONF",
            "LD_PRELOAD",
            "DYLD_INSERT_LIBRARIES",
        ] {
            assert!(
                should_remove_from_runtime_environment(OsStr::new(name)),
                "dangerous prefixed name was retained: {name}"
            );
        }
        for name in [
            "HOME",
            "PATH",
            "TERM",
            "COLORTERM",
            "LANG",
            "SSH_AUTH_SOCK",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL",
            "OPENAI_API_KEY",
            "XAI_API_KEY",
        ] {
            assert!(
                !should_remove_from_runtime_environment(OsStr::new(name)),
                "documented host/Agent context was removed: {name}"
            );
        }
    }

    #[test]
    fn scrub_removes_inherited_values_before_cli_abi_is_injected() {
        let inherited = vec![
            (OsString::from("BASH_ENV"), OsString::from("/tmp/inject")),
            (OsString::from("GIT_DIR"), OsString::from("/tmp/repository")),
            (
                OsString::from("AGENT_CONTAINER_CPUS"),
                OsString::from("ambient"),
            ),
            (
                OsString::from("ANTHROPIC_MODEL"),
                OsString::from("host-model"),
            ),
        ];
        let mut command = Command::new("unused-runtime");
        command.envs(inherited.iter().cloned());
        scrub_runtime_environment(&mut command, &inherited);
        command.env("AGENT_CONTAINER_CPUS", "12");

        assert_eq!(command_environment_value(&command, "BASH_ENV"), Some(None));
        assert_eq!(command_environment_value(&command, "GIT_DIR"), Some(None));
        assert_eq!(
            command_environment_value(&command, "AGENT_CONTAINER_CPUS"),
            Some(Some(OsStr::new("12")))
        );
        assert_eq!(
            command_environment_value(&command, "ANTHROPIC_MODEL"),
            Some(Some(OsStr::new("host-model")))
        );
    }

    #[test]
    fn an_agent_argument_stops_launcher_option_parsing() {
        let result = plan(
            OsStr::new("claude-container"),
            &os_values(&["--verbose", "--container-cpus", "99"]),
        )
        .unwrap();
        assert!(result.environment.is_empty());
        assert_eq!(
            result.runtime_arguments,
            os_values(&["claude", "--verbose", "--container-cpus", "99"])
        );
    }

    #[test]
    fn delimiter_is_consumed_and_disables_launcher_parsing() {
        let result = plan(
            OsStr::new("codex-container"),
            &os_values(&["--container-memory", "6g", "--", "--container-cpus", "99"]),
        )
        .unwrap();
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_MEMORY"),
            Some(OsStr::new("6g"))
        );
        assert_eq!(
            result.runtime_arguments,
            os_values(&["codex", "--container-cpus", "99"])
        );
    }

    #[test]
    fn delimiter_keeps_leading_run_as_a_literal_agent_argument() {
        let result = plan(
            OsStr::new("grok-container"),
            &os_values(&["--", "run", "foo"]),
        )
        .unwrap();

        assert_eq!(result.runtime_arguments, os_values(&["grok", "run", "foo"]));
    }

    #[test]
    fn rejects_a_leading_unknown_namespaced_option() {
        let error = plan(
            OsStr::new("grok-container"),
            &os_values(&["--container-cupz", "8"]),
        )
        .unwrap_err();
        assert!(error.contains("unknown launcher option"));

        let error = plan(
            OsStr::new("grok-container"),
            &os_values(&["--no-container-cpus"]),
        )
        .unwrap_err();
        assert!(error.contains("unknown launcher option"));
    }

    #[test]
    fn rejects_a_missing_value() {
        let error = plan(
            OsStr::new("grok-container"),
            &os_values(&["--container-memory"]),
        )
        .unwrap_err();
        assert_eq!(error, "--container-memory requires a value");
    }

    #[test]
    fn last_repeated_setting_wins_at_exec_time() {
        let result = plan(
            OsStr::new("agent-container"),
            &os_values(&["--container-cpus", "4", "--container-cpus=12", "grok"]),
        )
        .unwrap();
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_CPUS"),
            Some(OsStr::new("12"))
        );
    }

    #[test]
    fn preserves_non_utf8_agent_arguments_and_option_values() {
        let value = OsString::from_vec(vec![b'/', b't', b'm', b'p', b'/', 0xff]);
        let agent_argument = OsString::from_vec(vec![b'a', 0xfe, b'b']);
        let arguments = vec![
            OsString::from("--container-assets"),
            value.clone(),
            agent_argument.clone(),
        ];
        let result = plan(OsStr::new("grok-container"), &arguments).unwrap();
        assert_eq!(
            environment_value(&result, "AGENT_CONTAINER_ASSET_DIR"),
            Some(value.as_os_str())
        );
        assert_eq!(
            result.runtime_arguments,
            vec![OsString::from("grok"), agent_argument]
        );
    }

    #[test]
    fn runtime_must_be_a_non_symlink_executable_file() {
        assert_eq!(
            validate_runtime(PathBuf::from("/bin/echo")).unwrap(),
            PathBuf::from("/bin/echo")
        );
        assert!(validate_runtime(PathBuf::from("/var")).is_err());
        assert!(validate_runtime(PathBuf::from("/definitely/missing/runtime")).is_err());
    }

    #[test]
    fn runtime_is_bound_to_the_source_checkout_or_installed_release() {
        assert_eq!(
            runtime_candidate(Path::new("/repo/target/release/agent-container-launcher")).unwrap(),
            PathBuf::from("/repo/runtime/agent-container-runtime")
        );
        assert_eq!(
            runtime_candidate(Path::new("/release/agent-container-darwin-arm64")).unwrap(),
            PathBuf::from("/release/agent-container-runtime")
        );
        assert!(runtime_candidate(Path::new("/tmp/custom/agent-container-launcher")).is_err());
    }

    #[test]
    fn installed_symlink_resolves_runtime_beside_the_physical_binary() {
        let test_root = env::temp_dir().join(format!(
            "agent-container-runtime-symlink-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let release_directory = test_root.join("release");
        let command_directory = test_root.join("bin");
        fs::create_dir(&test_root).unwrap();
        fs::create_dir(&release_directory).unwrap();
        fs::create_dir(&command_directory).unwrap();

        let physical_launcher = release_directory.join("agent-container-darwin-arm64");
        let runtime = release_directory.join(RUNTIME_NAME);
        fs::write(&physical_launcher, b"launcher\n").unwrap();
        fs::write(&runtime, b"runtime\n").unwrap();
        fs::set_permissions(&physical_launcher, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o755)).unwrap();
        let command = command_directory.join("grok-container");
        symlink(&physical_launcher, &command).unwrap();

        assert_eq!(
            runtime_path_from_reported_executable(&command).unwrap(),
            fs::canonicalize(&runtime).unwrap()
        );

        fs::remove_file(command).unwrap();
        fs::remove_file(physical_launcher).unwrap();
        fs::remove_file(runtime).unwrap();
        fs::remove_dir(command_directory).unwrap();
        fs::remove_dir(release_directory).unwrap();
        fs::remove_dir(test_root).unwrap();
    }
}
