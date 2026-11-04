//! `garage-mcp`: the MCP server over stdio (`garage_rag.mcp_server.server.main`).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(garage_cli::run_mcp(&args));
}
