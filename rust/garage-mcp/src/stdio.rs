//! MCP over stdio: one JSON-RPC message per line in, one per line out. Nothing else is written to
//! the output, which is the protocol stream.

use std::io::{BufRead, Write};

use serde_json::Value;

use crate::corpus::Caller;
use crate::protocol::Handler;

/// Answers messages from `input` on `output` until `input` ends. A line that is not JSON is
/// skipped, as the Python server skips it.
///
/// # Errors
///
/// An error writing to `output`.
pub fn serve(
    server: &dyn Handler,
    caller: &Caller,
    input: impl BufRead,
    mut output: impl Write,
) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            eprintln!("garage-mcp: ignoring a line that is not JSON");
            continue;
        };
        if let Some(reply) = server.handle(&message, caller) {
            writeln!(output, "{reply}")?;
            output.flush()?;
        }
    }
    Ok(())
}
