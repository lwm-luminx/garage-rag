//! The `garage` command line and the `garage-mcp` stdio server, in Rust, over `GarageService`
//! running in the same process ([docs/plans/python-removal.md], stage 4).
//!
//! Each command is the Python CLI's (`garage_rag.cli`): the same names, options, wording and exit
//! codes, with the work done by the gRPC service the app runs, reached over `garage-facade` on a
//! private socket (`backend`), so one implementation answers the terminal, the app and the MCP
//! clients. The Swift launchers call [`garage_cli_main`] and [`garage_mcp_main`] from the static
//! library; the binaries are the same functions.
//!
//! [docs/plans/python-removal.md]: https://garagerag.app/plans/python-removal/

// The commands are long lists of prints; a `format!` pushed onto a line and `argc`/`argv` are as
// readable here as Python's were.
#![allow(
    clippy::format_push_string,
    clippy::similar_names,
    clippy::if_not_else,
    clippy::single_match_else,
    clippy::too_many_lines,
    clippy::needless_pass_by_value
)]

pub mod args;
pub mod backend;
pub mod commands;
pub mod mcp;
pub mod out;

use std::ffi::{CStr, c_char, c_int};

/// Runs `garage` with `args` (the command line without the program name) and returns its exit code.
pub fn run(args: &[String]) -> i32 {
    commands::main(args)
}

/// Runs `garage-mcp` with `args` and returns its exit code.
pub fn run_mcp(args: &[String]) -> i32 {
    mcp::main(args)
}

/// The arguments of a C `main`, from `argv[1]`, as strings (a byte sequence that is not UTF-8
/// is replaced).
///
/// # Safety
///
/// `argv` points to `argc` NUL-terminated strings.
unsafe fn arguments(argc: c_int, argv: *const *const c_char) -> Vec<String> {
    if argv.is_null() || argc <= 1 {
        return Vec::new();
    }
    (1..usize::try_from(argc).unwrap_or(0))
        .map(|i| {
            // SAFETY: the caller's contract: argv has argc entries, each a C string.
            let pointer = unsafe { *argv.add(i) };
            if pointer.is_null() {
                String::new()
            } else {
                // SAFETY: as above.
                unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned()
            }
        })
        .collect()
}

/// `garage`'s `main`: runs the command line and returns the exit code.
///
/// # Safety
///
/// `argv` points to `argc` NUL-terminated strings, as a C `main` receives them.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_cli_main(argc: c_int, argv: *const *const c_char) -> c_int {
    // SAFETY: the caller's contract.
    let args = unsafe { arguments(argc, argv) };
    std::panic::catch_unwind(|| run(&args)).unwrap_or(70)
}

/// `garage-mcp`'s `main`: serves MCP over stdin and stdout until the client closes them.
///
/// # Safety
///
/// As [`garage_cli_main`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_main(argc: c_int, argv: *const *const c_char) -> c_int {
    // SAFETY: the caller's contract.
    let args = unsafe { arguments(argc, argv) };
    std::panic::catch_unwind(|| run_mcp(&args)).unwrap_or(70)
}
