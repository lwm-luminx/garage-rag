//! `garage-service serve`: the backend as its own process (`garage serve`).
//!
//! ```text
//! garage-service serve [--socket <path> | --host <host> --port <port>] [--config <garage.json>] [--sql-dir <dir>]
//! ```
//!
//! `GARAGE_GRPC_SOCKET`, `GARAGE_GRPC_HOST` and `GARAGE_GRPC_PORT` are the defaults the flags
//! override, as the app passes them; `GARAGE_GRPC_TOKEN` turns the token check on and is never
//! printed.

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use garage_service::auth::{config_change_allowed, token_from_env};
use garage_service::config::Config;
use garage_service::host::{HostEmbedder, PlainHost};
use garage_service::server::{Endpoint, serve};
use garage_service::service::{GarageService, sql_dir};

#[derive(Debug, Default)]
struct Options {
    socket: Option<PathBuf>,
    host: Option<String>,
    port: Option<u16>,
    config: Option<PathBuf>,
    sql_dir: Option<PathBuf>,
}

const USAGE: &str = "usage: garage-service serve [--socket <path> | --host <host> --port <port>] [--config <garage.json>] [--sql-dir <dir>]";

fn parse(args: impl IntoIterator<Item = String>) -> Result<Options, String> {
    let mut args = args.into_iter();
    match args.next().as_deref() {
        Some("serve") => {}
        Some("--version") => return Err(format!("garage-service {}", garage_service::VERSION)),
        _ => return Err(USAGE.to_owned()),
    }
    let mut options = Options::default();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--socket" => options.socket = Some(PathBuf::from(value()?)),
            "--host" | "-h" => options.host = Some(value()?),
            "--port" | "-p" => options.port = Some(value()?.parse().map_err(|e| format!("--port: {e}"))?),
            "--config" => options.config = Some(PathBuf::from(value()?)),
            "--sql-dir" => options.sql_dir = Some(PathBuf::from(value()?)),
            _ => return Err(format!("unexpected argument {arg}\n{USAGE}")),
        }
    }
    Ok(options)
}

fn endpoint(options: &Options) -> Result<Endpoint, String> {
    let env = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
    if let Some(socket) = options.socket.clone().or_else(|| env("GARAGE_GRPC_SOCKET").map(PathBuf::from)) {
        return Ok(Endpoint::Unix(socket));
    }
    let host = options.host.clone().or_else(|| env("GARAGE_GRPC_HOST")).unwrap_or_else(|| "127.0.0.1".to_owned());
    let port = match options.port {
        Some(port) => port,
        None => {
            env("GARAGE_GRPC_PORT").map_or(Ok(50051), |p| p.parse().map_err(|e| format!("GARAGE_GRPC_PORT: {e}")))?
        }
    };
    let ip: IpAddr = host.parse().map_err(|_| format!("--host must be an IP address, not {host:?}"))?;
    Ok(Endpoint::Tcp(SocketAddr::new(ip, port)))
}

fn run() -> Result<(), String> {
    let options = parse(std::env::args().skip(1))?;
    let endpoint = endpoint(&options)?;
    let config = Config::load(options.config.as_deref()).map_err(|e| e.to_string())?;
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())?;
    let token = token_from_env();
    let vouched = config_change_allowed(token.is_some(), matches!(endpoint, Endpoint::Unix(_)));
    let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(runtime.handle().clone()));
    let embedder = Arc::new(HostEmbedder { host: host.clone(), settings: config.embed_settings() });
    let service = GarageService::new(config, embedder, sql_dir(options.sql_dir.as_deref()), vouched)
        .map_err(|e| e.to_string())?
        .with_host(host);
    println!("Garage gRPC server listening on {endpoint} (PID: {})", std::process::id());
    let result = runtime.block_on(serve(service, &endpoint, token.as_deref(), stopped()));
    println!("Garage gRPC server stopped.");
    result.map_err(|e| e.to_string())
}

/// Completes on SIGINT or SIGTERM.
async fn stopped() {
    use tokio::signal::unix::{SignalKind, signal};
    let Ok(mut term) = signal(SignalKind::terminate()) else {
        let _ = tokio::signal::ctrl_c().await;
        return;
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
    println!("\nShutting down gRPC server...");
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}
