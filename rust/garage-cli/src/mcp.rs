//! `garage-mcp`: the MCP server over stdio, as an MCP client starts it
//! (`garage_rag.mcp_server.server.main`), reading the corpus through GarageService in this
//! process. `--config PATH` names the `garage.json` the service runs on, as `garage --config` does;
//! the client sees the same tools and answers as the app's `GarageMCPServerService`.

use std::io::{BufReader, Write};
use std::path::PathBuf;
use std::sync::Arc;

use garage_embed::GrpcTarget;
use garage_mcp::{Caller, GrpcCorpus, Server, Transport};
use garage_service::host::PlainHost;

use crate::backend::{Backend, load_config};

const USAGE: &str = "usage: garage-mcp [--config <garage.json>]";

/// Serves until stdin closes; returns the exit code.
pub fn main(args: &[String]) -> i32 {
    let mut config_path: Option<PathBuf> = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--config" | "-c" => match rest.next() {
                Some(path) => config_path = Some(PathBuf::from(path)),
                None => {
                    eprintln!("{USAGE}");
                    return 2;
                }
            },
            "--version" => {
                println!("garage-mcp {}", garage_service::VERSION);
                return 0;
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                return 0;
            }
            // The Python server took --stdio and ignored --http here; a client may still pass them.
            "--stdio" | "--transport" | "stdio" => {}
            other => {
                if let Some(path) = other.strip_prefix("--config=") {
                    config_path = Some(PathBuf::from(path));
                } else {
                    eprintln!("garage-mcp: unexpected argument {other}\n{USAGE}");
                    return 2;
                }
            }
        }
    }
    let config = match load_config(config_path.as_deref()) {
        Ok(config) => config,
        Err(failure) => {
            eprintln!("garage-mcp: {}", crate::out::render(&failure.message));
            return failure.code;
        }
    };
    let backend = match Backend::start(config) {
        Ok(backend) => backend,
        Err(failure) => {
            eprintln!("garage-mcp: {}", crate::out::render(&failure.message));
            return failure.code;
        }
    };
    let corpus = Arc::new(GrpcCorpus::new(GrpcTarget::Socket(backend.socket.clone()), None));
    let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(backend.handle()));
    let server = Server::new(corpus, host);
    let mut caller = Caller::new(Transport::Stdio);
    caller.registration_token = std::env::var("GARAGE_MCP_TOKEN").ok().filter(|token| !token.is_empty());
    let stdout = std::io::stdout();
    let outcome = garage_mcp::stdio::serve(&server, &caller, BufReader::new(std::io::stdin()), stdout.lock());
    let _ = std::io::stdout().flush();
    drop(backend);
    match outcome {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("garage-mcp: {error}");
            1
        }
    }
}
