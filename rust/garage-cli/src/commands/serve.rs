//! `garage serve`: the gRPC server as its own long-running process (`garage-service serve`).

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use garage_service::auth::{config_change_allowed, token_from_env};
use garage_service::host::{HostEmbedder, PlainHost};
use garage_service::server::{Endpoint, serve};
use garage_service::service::{GarageService, sql_dir};

use super::Command;
use crate::args::Opt;
use crate::backend::Failure;
use crate::out;

pub const SERVE: Command = Command {
    name: "serve",
    opts: &[Opt::short_value("host", 'h'), Opt::short_value("port", 'p'), Opt::value("socket")],
    help: "Start the long-running gRPC server the macOS app reads the corpus through.",
    run: |context, parsed| {
        let host = parsed.get("host").unwrap_or("127.0.0.1").to_owned();
        let port = parsed.int::<u16>("port").map_err(Failure::usage)?.unwrap_or(50051);
        let endpoint = match parsed.get("socket") {
            Some(socket) => Endpoint::Unix(PathBuf::from(socket)),
            None => {
                let ip: IpAddr = host
                    .parse()
                    .map_err(|_| Failure::usage(format!("Error: --host must be an IP address, not {host:?}")))?;
                Endpoint::Tcp(SocketAddr::new(ip, port))
            }
        };
        out::print(&format!("[bold green]Starting Garage gRPC Server[/bold green] on {endpoint}..."));
        let config = context.config()?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| Failure::failed(e.to_string()))?;
        let token = token_from_env();
        let vouched = config_change_allowed(token.is_some(), matches!(endpoint, Endpoint::Unix(_)));
        let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(runtime.handle().clone()));
        let embedder = Arc::new(HostEmbedder { host: host.clone(), settings: config.embed_settings() });
        let service = GarageService::new(config, embedder, sql_dir(None), vouched)?.with_host(host);
        println!("Garage gRPC server listening on {endpoint} (PID: {})", std::process::id());
        let result = runtime.block_on(serve(service, &endpoint, token.as_deref(), async {
            tokio::task::spawn_blocking(super::mcp::wait_for_interrupt).await.ok();
            println!("\nShutting down gRPC server...");
        }));
        println!("Garage gRPC server stopped.");
        result.map_err(|e| Failure::failed(e.to_string()))
    },
};
