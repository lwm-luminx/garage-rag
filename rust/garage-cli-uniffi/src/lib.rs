//! The `garage` command line and the `garage-mcp` stdio server through UniFFI, for the console
//! scripts of the `garage_rag` package (docs/plans/python-package-parity.md).
//!
//! The surface is kept small and generic on purpose: the arguments in, the exit code out, and the
//! version. The 1.5.0 names (`garage_rag.cli:main_cli`, `garage_rag.mcp_server.server:main`) and
//! the environment they set up live in the package's hand-written Python, not here. Each call runs
//! GarageService in the calling process, as the binaries and the Mac app's launchers do
//! (`garage_cli::run`, `garage_cli::run_mcp`), and blocks until the command ends.

// UniFFI hands exported functions owned values.
#![allow(clippy::needless_pass_by_value)]

uniffi::setup_scaffolding!("garage_cli");

/// Runs `garage` with `args` (the command line without the program name) and returns its exit
/// code. A panic is exit code 70, as in `garage_cli_main`.
#[uniffi::export]
pub fn run_garage(args: Vec<String>) -> i32 {
    finish(std::panic::catch_unwind(|| garage_cli::run(&args)).unwrap_or(70))
}

/// Runs `garage-mcp` with `args`: serves MCP over stdin and stdout until the client closes them,
/// then returns the exit code.
#[uniffi::export]
pub fn run_garage_mcp(args: Vec<String>) -> i32 {
    finish(std::panic::catch_unwind(|| garage_cli::run_mcp(&args)).unwrap_or(70))
}

/// Flushes what the command printed: in a library no Rust `main` flushes stdout on the way out, and
/// the caller writes to the same descriptors next.
fn finish(code: i32) -> i32 {
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    code
}

/// The version `garage --version` reports: GarageService's, which is the app's release version.
#[uniffi::export]
pub fn version() -> String {
    garage_service::VERSION.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_the_services() {
        assert_eq!(version(), garage_service::VERSION);
    }

    #[test]
    fn a_usage_error_is_an_exit_code_not_an_exit() {
        // An unknown command is Typer's usage error, exit code 2, returned to the caller rather than
        // ending the process (the binaries' `main` is what calls `process::exit`).
        assert_eq!(run_garage(vec!["no-such-command".to_owned()]), 2);
    }

    #[test]
    fn version_and_help_need_no_database() {
        assert_eq!(run_garage(vec!["--version".to_owned()]), 0);
        assert_eq!(run_garage(vec!["--help".to_owned()]), 0);
        assert_eq!(run_garage_mcp(vec!["--version".to_owned()]), 0);
    }
}
