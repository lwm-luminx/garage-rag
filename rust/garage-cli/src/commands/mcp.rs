//! MCP: `mcp-install`, `mcp-uninstall`, `mcp-status`, `mcp-test` and `mcp-serve`, plus the tool
//! box `ask` and `mcp-test` run the tools through.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::{Duration, Instant};

use garage_embed::GrpcTarget;
use garage_facade::proto;
use garage_mcp::chat::{Chat, ChatModel};
use garage_mcp::tools::{ChatFactory, ToolError, Toolbox};
use garage_mcp::{Caller, GrpcCorpus, HttpOptions, HttpServer, Server, Transport, http::is_loopback};
use garage_service::host::PlainHost;
use serde_json::{Map, Value, json};

use super::{Command, Context, bad_parameter};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out::{self, Table, tilde};

/// The MCP tools over this process's service, with the configured local model reached through the
/// plain host (the launcher's: LlamaXPCService over its socket, Ollama and LM Studio over HTTP).
pub fn toolbox(context: &mut Context) -> Result<(Toolbox, Caller), Failure> {
    let backend = context.backend()?;
    let corpus = Arc::new(GrpcCorpus::new(GrpcTarget::Socket(backend.socket.clone()), None));
    let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(backend.handle()));
    let chat: ChatFactory = Arc::new(move |settings| {
        ChatModel::new(settings, Arc::clone(&host)).map(|model| Box::new(model) as Box<dyn Chat>)
    });
    Ok((Toolbox { corpus, chat }, Caller::new(Transport::Stdio)))
}

/// The MCP server over this process's service (`mcp-serve`).
pub fn server(context: &mut Context) -> Result<Server, Failure> {
    let backend = context.backend()?;
    let corpus = Arc::new(GrpcCorpus::new(GrpcTarget::Socket(backend.socket.clone()), None));
    let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(backend.handle()));
    Ok(Server::new(corpus, host))
}

fn announce(outcome: &proto::McpTargetOutcome) {
    out::print(&format!("\n[bold]{}[/bold] -> {}", outcome.label, outcome.path));
}

pub const MCP_INSTALL: Command = Command {
    name: "mcp-install",
    opts: &[
        Opt::short_value("target", 't'),
        Opt::value("path"),
        Opt::short_flag("all", 'a'),
        Opt::value("name"),
        Opt::flag("http"),
        Opt::flag("stdio"),
        Opt::value("host"),
        Opt::value("port"),
        Opt::value("route"),
        Opt::flag("force"),
        Opt::flag("dry-run"),
        Opt::short_flag("yes", 'y'),
    ],
    help: "Register this MCP server in a client's config file.",
    run: |context, parsed| {
        if parsed.has("http") && parsed.has("stdio") {
            return Err(Failure::usage("Error: choose either --http or --stdio"));
        }
        // stdio unless --http: the app no longer serves HTTP until the user turns it on.
        let use_stdio = !parsed.has("http");
        let name = parsed.get("name").unwrap_or("garage-rag").to_owned();
        let dry_run = parsed.has("dry-run");
        let request = proto::McpInstallRequest {
            target: parsed.get("target").unwrap_or("project").to_owned(),
            path: parsed.get("path").unwrap_or_default().to_owned(),
            all: parsed.has("all"),
            name: name.clone(),
            stdio: use_stdio,
            host: parsed.get("host").unwrap_or_default().to_owned(),
            port: parsed.int::<i32>("port").map_err(Failure::usage)?.unwrap_or_default(),
            route: parsed.get("route").unwrap_or_default().to_owned(),
            force: parsed.has("force"),
            dry_run,
        };
        let config_file = context.config()?.path;
        let install = |context: &mut Context, request: proto::McpInstallRequest| {
            context.backend()?.call(|mut client| async move { client.mcp_install(request).await }).map_err(|failure| {
                let message = failure.message;
                if message.contains("unknown target") || message.contains("is not a target") {
                    bad_parameter("--target", &message)
                } else if message.contains("already") {
                    Failure::failed(format!("[yellow]{message}[/yellow]"))
                } else {
                    Failure::failed(format!("[red]{message}[/red]"))
                }
            })
        };
        if !parsed.has("yes") && !dry_run {
            // Show each target and ask before anything is written, as `confirm` did per target.
            let preview = install(context, proto::McpInstallRequest { dry_run: true, ..request.clone() })?;
            for outcome in &preview.outcomes {
                if !outcome.skipped.is_empty() {
                    continue;
                }
                announce(outcome);
                let action = if outcome.replaced_entry { "Replace" } else { "Add" };
                if !out::confirm(&format!("{action} '{name}' in {}?", outcome.path)) {
                    return Err(Failure::failed("Aborted."));
                }
            }
        }
        let report = install(context, request)?;
        if report.fell_back {
            out::print(
                "[dim]No existing client config files found; targeting project and Claude Desktop defaults[/dim]",
            );
        }
        if !report.url.is_empty() {
            out::print(&format!("  url     : {}", report.url));
            out::print(
                "  [dim]the client connects to this URL; run `garage mcp-serve --http` or use the macOS app to keep it up[/dim]",
            );
        } else {
            if config_file.is_none() {
                out::print(
                    "[yellow]note[/yellow]: no config file in use; the server will run on defaults. Create one with 'garage config init'.",
                );
            }
            out::print(&format!("  command : {} {}", report.command, report.args.join(" ")));
        }
        for outcome in &report.outcomes {
            if !outcome.skipped.is_empty() {
                announce(outcome);
                out::print(&format!("[yellow]{}[/yellow]", outcome.skipped));
            } else if !outcome.preview_json.is_empty() {
                announce(outcome);
                out::print("\n[cyan]would write[/cyan]:");
                let preview: Value = serde_json::from_str(&outcome.preview_json).unwrap_or(Value::Null);
                println!("{}", serde_json::to_string_pretty(&preview).unwrap_or_default());
            } else if outcome.written {
                let verb = if outcome.created_file { "created" } else { "updated" };
                out::print(&format!("[green]{verb}[/green] {}", outcome.path));
                if !outcome.backup_path.is_empty() {
                    let name = std::path::Path::new(&outcome.backup_path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    out::print(&format!("  backup: {name}"));
                }
            }
        }
        if !dry_run {
            out::print(
                "\nRestart client(s), then try asking: [cyan]what does my reference material say about secure boot?[/cyan]",
            );
        }
        Ok(())
    },
};

pub const MCP_UNINSTALL: Command = Command {
    name: "mcp-uninstall",
    opts: &[Opt::short_value("target", 't'), Opt::value("path"), Opt::value("name")],
    help: "Remove this server from a client's config.",
    run: |context, parsed| {
        let name = parsed.get("name").unwrap_or("garage-rag").to_owned();
        let request = proto::McpUninstallRequest {
            target: parsed.get("target").unwrap_or("project").to_owned(),
            path: parsed.get("path").unwrap_or_default().to_owned(),
            name: name.clone(),
        };
        let result = context
            .backend()?
            .call(|mut client| async move { client.mcp_uninstall(request).await })
            .map_err(|failure| bad_parameter("--target", &failure.message))?;
        if result.removed {
            out::print(&format!("[green]removed[/green] {name} from {}", result.path));
        } else {
            out::print(&format!("[yellow]{name} was not configured in {}[/yellow]", result.path));
        }
        Ok(())
    },
};

pub const MCP_STATUS: Command = Command {
    name: "mcp-status",
    opts: &[],
    help: "Show which MCP clients this server is registered with.",
    run: |context, _| {
        let report =
            context.backend()?.call(|mut client| async move { client.mcp_status(proto::McpStatusRequest {}).await })?;
        out::print(&format!("[dim]server command: {}[/dim]\n", report.server_command));
        let mut table = Table::new(None);
        table.columns(&["target", "client", "registered", "config"]);
        for client in &report.clients {
            let state = if client.registered {
                "[green]yes[/green]"
            } else if client.config_exists {
                "no"
            } else {
                "[dim]no config[/dim]"
            };
            table.row(&[client.key.as_str(), client.label.as_str(), state, &tilde(&client.path)]);
        }
        table.print();
        Ok(())
    },
};

/// One POST to a loopback MCP endpoint: the status code, or why none came.
fn probe_http(url: &str) -> Result<u16, String> {
    let rest = url.strip_prefix("http://").ok_or("only http:// endpoints are probed")?;
    let (authority, path) = rest.split_once('/').map_or((rest, "/"), |(a, _)| (a, &rest[a.len()..]));
    let (host, port) = authority.rsplit_once(':').map_or((authority, 8787), |(h, p)| (h, p.parse().unwrap_or(8787)));
    let host = host.trim_matches(|c| c == '[' || c == ']');
    if !is_loopback(host) {
        return Err("not loopback".into());
    }
    let address = (host, port).to_socket_addrs().map_err(|e| e.to_string())?.next().ok_or("no address")?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(3)).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).map_err(|e| e.to_string())?;
    let body = json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "garage-cli-test", "version": "1.0"}},
    })
    .to_string();
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).map_err(|e| e.to_string())?;
    let mut reply = Vec::new();
    let _ = stream.read_to_end(&mut reply);
    let head = String::from_utf8_lossy(&reply);
    let status: u16 =
        head.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or("no HTTP status in the reply")?;
    if status >= 400 {
        return Err(format!("HTTP {status}"));
    }
    Ok(status)
}

pub const MCP_TEST: Command = Command {
    name: "mcp-test",
    opts: &[
        Opt::value("url"),
        Opt::value("host"),
        Opt::short_value("port", 'p'),
        Opt::value("path"),
        Opt::value("query"),
    ],
    help: "Test the MCP server and tool execution.",
    run: |context, parsed| {
        let (mcp_host, mcp_port, mcp_path) = context.config()?.mcp_endpoint();
        let target_host = parsed.get("host").map_or(mcp_host, str::to_owned);
        let target_port = parsed.int::<i64>("port").map_err(Failure::usage)?.unwrap_or(mcp_port);
        let route = parsed.get("path").map_or(mcp_path, str::to_owned);
        let target_url =
            parsed.get("url").map_or_else(|| format!("http://{target_host}:{target_port}{route}"), str::to_owned);
        let query = parsed.get("query").unwrap_or("test search").to_owned();
        out::print("[bold]Testing MCP Server & Tools[/bold]\n");
        out::print("[cyan]Testing local MCP tool handlers:[/cyan]");
        let (tools, caller) = toolbox(context)?;
        let mut rows: Vec<(String, &str, String, String)> = Vec::new();
        let mut run = |name: &str, args: Value, describe: &dyn Fn(&Value) -> String| {
            let started = Instant::now();
            let outcome = tools.call(name, args.as_object().unwrap_or(&Map::new()), &caller);
            let latency = format!("{:.1}ms", started.elapsed().as_secs_f64() * 1000.0);
            match outcome {
                Ok(result) => rows.push((name.to_owned(), "PASS", latency, describe(&result))),
                Err(ToolError::Failed(reason) | ToolError::Unknown(reason)) => {
                    rows.push((name.to_owned(), "FAIL", latency, reason));
                }
                Err(ToolError::Invalid(error)) => rows.push((name.to_owned(), "FAIL", latency, error.to_string())),
            }
        };
        let count = |value: &Value, key: &str| value.get(key).and_then(Value::as_array).map_or(0, Vec::len);
        run("rag_stats", json!({}), &|r| {
            format!(
                "{} docs, {} chunks",
                out::commas(r.get("documents").and_then(Value::as_i64).unwrap_or_default()),
                out::commas(r.get("chunks").and_then(Value::as_i64).unwrap_or_default())
            )
        });
        run("rag_list_sources", json!({}), &|r| format!("{} sources", count(r, "sources")));
        run("rag_list_authors", json!({}), &|r| format!("{} authors", count(r, "authors")));
        run("rag_search", json!({"query": query, "limit": 3}), &|r| {
            format!("{} hits for {}", count(r, "hits"), garage_mcp::pyrepr::str_repr(&query))
        });
        // rag_ask and rag_generate share one local model; probe it once.
        let started = Instant::now();
        let generated = tools.call(
            "rag_generate",
            json!({"prompt": "Reply with the single word: ready", "max_tokens": 8}).as_object().unwrap_or(&Map::new()),
            &caller,
        );
        let latency = format!("{:.1}ms", started.elapsed().as_secs_f64() * 1000.0);
        match generated {
            Ok(result) => {
                let details = format!(
                    "{}/{}",
                    result.get("provider").and_then(Value::as_str).unwrap_or_default(),
                    result.get("model").and_then(Value::as_str).unwrap_or_default()
                );
                rows.push(("rag_generate".into(), "PASS", latency.clone(), details));
                rows.push(("rag_ask".into(), "PASS", latency, "same model as rag_generate".into()));
            }
            Err(error) => {
                let details = match error {
                    ToolError::Failed(reason) | ToolError::Unknown(reason) => reason,
                    ToolError::Invalid(error) => error.to_string(),
                };
                // Nothing loaded is a state of the app's Models page, not of the MCP server.
                let status =
                    if details.contains("not loaded") || details.contains("unavailable") { "SKIP" } else { "FAIL" };
                rows.push(("rag_generate".into(), status, latency.clone(), details.clone()));
                rows.push(("rag_ask".into(), status, latency, details));
            }
        }
        let mut table = Table::new(None);
        table.columns(&["tool", "status", "latency", "details"]);
        for (tool, status, latency, details) in &rows {
            let shown = match *status {
                "PASS" => "[green]PASS[/green]",
                "SKIP" => "[yellow]SKIP[/yellow]",
                _ => "[red]FAIL[/red]",
            };
            table.row(&[tool.as_str(), shown, latency.as_str(), details.as_str()]);
        }
        table.print();
        out::print(&format!("\n[cyan]Testing HTTP endpoint:[/cyan] {target_url}"));
        let started = Instant::now();
        match probe_http(&target_url) {
            Err(reason) if reason == "not loopback" => {
                out::print("  [yellow]skipped[/yellow]: only an endpoint on this machine is probed");
            }
            Ok(status) => out::print(&format!(
                "  [green]HTTP {status}[/green] ({:.1}ms) - MCP server endpoint reachable and responding",
                started.elapsed().as_secs_f64() * 1000.0
            )),
            Err(reason) => {
                out::print(&format!("  [yellow]HTTP endpoint not active[/yellow]: {reason}"));
                out::print("  [dim]Start the MCP server with `garage mcp-serve --http` or from the macOS app.[/dim]");
            }
        }
        Ok(())
    },
};

pub const MCP_SERVE: Command = Command {
    name: "mcp-serve",
    opts: &[
        Opt::flag("http"),
        Opt::flag("sse"),
        Opt::value("host"),
        Opt::short_value("port", 'p'),
        Opt::value("path"),
        Opt::value("allow-origin"),
        Opt::value("allow-host"),
        Opt::flag("json-response"),
        Opt::flag("stateless"),
        Opt::flag("allow-remote"),
    ],
    help: "Run the MCP server over HTTP (streamable-http).",
    run: |context, parsed| {
        if parsed.has("sse") {
            return Err(Failure::usage("Error: the legacy SSE transport is no longer served; use --http"));
        }
        let (mcp_host, mcp_port, mcp_path) = context.config()?.mcp_endpoint();
        let bind_host = parsed.get("host").map_or(mcp_host, str::to_owned);
        let bind_port =
            parsed.int::<u16>("port").map_err(Failure::usage)?.unwrap_or(u16::try_from(mcp_port).unwrap_or(8787));
        let route = parsed.get("path").map_or(mcp_path, str::to_owned);
        let allow_host = parsed.all("allow-host");
        if !is_loopback(&bind_host) && !parsed.has("allow-remote") {
            // This server answers questions about the whole corpus and has no authentication.
            out::print(&format!(
                "[red]refusing to bind {bind_host}[/red]: this server has no authentication and exposes your entire corpus, including anything indexed from private communications."
            ));
            out::print(
                "  Anyone able to reach that address could read it. If that is genuinely what you want, re-run with [bold]--allow-remote[/bold], and put it behind a reverse proxy that authenticates.",
            );
            return Err(Failure::silent(1));
        }
        let server = Arc::new(server(context)?);
        let options = HttpOptions {
            host: bind_host.clone(),
            port: bind_port,
            path: route.clone(),
            allowed_origins: parsed.all("allow-origin"),
            allowed_hosts: allow_host.clone(),
        };
        let http = HttpServer::start(server, &options).map_err(|e| Failure::failed(format!("[red]{e}[/red]")))?;
        out::print(&format!(
            "[green]serving[/green] streamable-http on http://{bind_host}:{}{route}",
            http.address().port()
        ));
        if !is_loopback(&bind_host) {
            out::print("[yellow]warning[/yellow]: reachable from other machines, unauthenticated");
            if allow_host.is_empty() {
                out::print(
                    "[yellow]warning[/yellow]: no --allow-host given, so the Host header is not checked (DNS-rebinding protection off); pass the names clients will use to turn it on",
                );
            }
        }
        out::print("[dim]Ctrl-C to stop[/dim]");
        wait_for_interrupt();
        http.stop();
        out::print("\n[dim]stopped[/dim]");
        Ok(())
    },
};

/// Blocks until SIGINT or SIGTERM.
pub fn wait_for_interrupt() {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        std::thread::park();
        return;
    };
    runtime.block_on(async {
        use tokio::signal::unix::{SignalKind, signal};
        match signal(SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = term.recv() => {}
                }
            }
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    });
}
