mod broker;
mod launcher;

use std::env;
use std::ffi::OsStr;
use std::process;

fn is_workspace_broker(argv0: &OsStr, args: &[std::ffi::OsString]) -> bool {
    launcher::is_generic_invocation(argv0)
        && args.first().map(OsStr::new) == Some(OsStr::new("__workspace-broker"))
}

fn run() -> Result<(), String> {
    let mut arguments = env::args_os();
    let argv0 = arguments
        .next()
        .ok_or_else(|| "the operating system did not provide argv[0]".to_owned())?;
    let arguments: Vec<_> = arguments.collect();

    if is_workspace_broker(&argv0, &arguments) {
        return broker::run(&arguments[1..]);
    }

    launcher::reject_legacy_environment()?;
    let plan = launcher::plan(&argv0, &arguments)?;
    launcher::exec_runtime(plan).map_err(|error| error.to_string())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("agent-container-launcher: {error}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{OsStr, OsString};

    #[test]
    fn broker_command_is_reserved_only_on_generic_invocations() {
        let arguments = vec![
            OsString::from("__workspace-broker"),
            OsString::from("/tmp"),
            OsString::from("127.0.0.1"),
        ];
        assert!(is_workspace_broker(
            OsStr::new("agent-container"),
            &arguments
        ));
        assert!(is_workspace_broker(
            OsStr::new("agent-container-launcher"),
            &arguments
        ));
        assert!(is_workspace_broker(
            OsStr::new("agent-container-darwin-arm64"),
            &arguments
        ));
        assert!(!is_workspace_broker(
            OsStr::new("grok-container"),
            &arguments
        ));
    }
}
