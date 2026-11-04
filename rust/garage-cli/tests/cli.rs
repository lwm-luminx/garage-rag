//! The `garage` and `garage-mcp` binaries over a throwaway database, as `test_e2e_cli.py` ran the
//! Python ones: a config written by `config init`, the database named through `config set`,
//! `init-db`, a source over the UI tests' fixture corpus, `scan`, `ingest` with the Rust readers,
//! `search --mode fts` (no model server) and `stats`, then `garage-mcp` answering `initialize` and
//! `rag_stats` over stdio. Needs `GARAGE_TEST_DATABASE_URL`; unset, it passes without running.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use garage_service::db::DatabaseUrl;
use tokio_postgres::NoTls;

const TEST_URL_ENV: &str = "GARAGE_TEST_DATABASE_URL";

fn fixture_corpus() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../macapp/Tests/Fixtures/corpus").canonicalize().unwrap()
}

struct Scratch {
    dir: PathBuf,
    config: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("garage-cli-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self { config: dir.join("garage.json"), dir }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Runs `garage` on the scratch config, with no terminal, and returns its output.
fn garage(scratch: &Scratch, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_garage"))
        .arg("--config")
        .arg(&scratch.config)
        .args(args)
        .env_remove("GARAGE_DATABASE_URL")
        .env_remove("GARAGE_GRPC_SOCKET")
        .env_remove("GARAGE_LLAMA_SOCKET")
        .output()
        .expect("run garage")
}

fn text(output: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr))
}

fn ok(output: &Output, what: &str) -> String {
    let shown = text(output);
    assert!(output.status.success(), "{what} failed ({}):\n{shown}", output.status);
    shown
}

async fn admin(url: &DatabaseUrl) -> tokio_postgres::Client {
    let (client, connection) = url.to_config().connect(NoTls).await.expect("connect to the test server");
    tokio::spawn(connection);
    client
}

#[test]
fn the_binaries_index_and_search_the_fixture_corpus() {
    let Some(server_url) = std::env::var(TEST_URL_ENV).ok().filter(|url| !url.trim().is_empty()) else {
        eprintln!("{TEST_URL_ENV} is not set; see 'Testing against Postgres' in CLAUDE.md");
        return;
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let server = DatabaseUrl::parse(&server_url).expect("a database URL");
    let name = format!("garage_cli_test_{}", std::process::id());
    runtime.block_on(async {
        let client = admin(&server).await;
        client.batch_execute(&format!("DROP DATABASE IF EXISTS \"{name}\" WITH (FORCE)")).await.unwrap();
        client.batch_execute(&format!("CREATE DATABASE \"{name}\"")).await.expect("create database");
    });
    let database_url = server.with_database(&name).to_url();

    let outcome = std::panic::catch_unwind(|| exercise(&database_url));

    runtime.block_on(async {
        admin(&server)
            .await
            .batch_execute(&format!("DROP DATABASE IF EXISTS \"{name}\" WITH (FORCE)"))
            .await
            .expect("drop database");
    });
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
}

fn exercise(database_url: &str) {
    let scratch = Scratch::new();
    let corpus = fixture_corpus();

    let shown = ok(&garage(&scratch, &["version"]), "version");
    assert!(shown.contains(&format!("garage v{}", garage_service::VERSION)), "{shown}");

    let shown = ok(&garage(&scratch, &["config", "init", "--path", scratch.config.to_str().unwrap()]), "config init");
    assert!(shown.contains("wrote"), "{shown}");
    assert!(scratch.config.is_file());

    let output = garage(&scratch, &["config", "set", "database.url", database_url]);
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    assert!(output.status.success(), "config set failed:\n{}", text(&output));
    assert!(stdout.trim_end().starts_with("database.url = "), "stdout is the assignment: {stdout}");
    let written: serde_json::Value = serde_json::from_slice(&std::fs::read(&scratch.config).unwrap()).unwrap();
    // Stored in SQLAlchemy's spelling, as the Python `config set` wrote it.
    let stored = written["database"]["url"].as_str().unwrap_or_default();
    assert_eq!(
        stored.trim_start_matches("postgresql+psycopg"),
        database_url.trim_start_matches("postgresql"),
        "{stored}"
    );

    let shown = ok(&garage(&scratch, &["config", "get", "database.url"]), "config get");
    assert!(shown.contains(stored), "{shown}");

    let shown = ok(&garage(&scratch, &["init-db"]), "init-db");
    assert!(shown.contains("schema ready"), "{shown}");
    assert!(!shown.contains("garage_dev:garage_dev@"), "the password is redacted: {shown}");

    let shown = ok(
        &garage(
            &scratch,
            &["add-source", "fixtures", corpus.to_str().unwrap(), "--class", "document", "--trust", "reference"],
        ),
        "add-source",
    );
    assert!(shown.contains("added source fixtures"), "{shown}");

    let shown = ok(&garage(&scratch, &["list-sources"]), "list-sources");
    assert!(shown.contains("fixtures"), "{shown}");

    let shown = ok(&garage(&scratch, &["scan", "--source", "fixtures", "--json"]), "scan --json");
    let scan: serde_json::Value = serde_json::from_str(shown.trim()).unwrap_or_else(|e| panic!("{e}: {shown}"));
    let scanned = scan.as_array().and_then(|list| list.first()).cloned().unwrap_or(scan.clone());
    assert!(scanned["item_count"].as_u64().unwrap_or(0) >= 5, "{scan}");

    let shown = ok(&garage(&scratch, &["ingest", "--source", "fixtures"]), "ingest");
    assert!(shown.contains("ingest: fixtures"), "{shown}");
    assert!(shown.contains("indexed"), "{shown}");

    // Ingested twice, the second pass changes nothing.
    let shown = ok(&garage(&scratch, &["ingest", "--source", "fixtures"]), "ingest again");
    assert!(shown.contains("skipped (unchanged)"), "{shown}");

    // A word only one fixture holds ranks that file first on the keyword side.
    let shown = ok(&garage(&scratch, &["search", "lighthouse", "--mode", "fts", "--limit", "3"]), "search");
    assert!(shown.contains("marrowgate-lighthouse"), "{shown}");
    assert!(shown.contains("1."), "{shown}");

    let shown = ok(&garage(&scratch, &["stats"]), "stats");
    assert!(shown.contains("documents"), "{shown}");
    assert!(shown.contains("sources"), "{shown}");

    let output = garage(&scratch, &["no-such-command"]);
    assert_eq!(output.status.code(), Some(2), "{}", text(&output));
    assert!(text(&output).contains("No such command"), "{}", text(&output));

    mcp_over_stdio(&scratch);
}

/// `garage-mcp` answers `initialize`, lists its tools and runs `rag_stats` over stdio.
fn mcp_over_stdio(scratch: &Scratch) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_garage-mcp"))
        .arg("--config")
        .arg(&scratch.config)
        .env_remove("GARAGE_DATABASE_URL")
        .env_remove("GARAGE_GRPC_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run garage-mcp");
    {
        let mut stdin = child.stdin.take().unwrap();
        for line in [
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rag_stats","arguments":{}}}"#,
        ] {
            writeln!(stdin, "{line}").unwrap();
        }
    }
    let output = child.wait_with_output().expect("garage-mcp exits when stdin closes");
    let shown = text(&output);
    assert!(output.status.success(), "garage-mcp failed ({}):\n{shown}", output.status);
    let replies: Vec<serde_json::Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line}")))
        .collect();
    assert_eq!(replies.len(), 3, "{shown}");
    assert_eq!(replies[0]["id"], 1);
    assert!(replies[0]["result"]["serverInfo"]["name"].is_string(), "{}", replies[0]);
    let tools: Vec<&str> =
        replies[1]["result"]["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(tools.contains(&"rag_search") && tools.contains(&"rag_stats"), "{tools:?}");
    assert_eq!(replies[2]["id"], 3);
    let stats = &replies[2]["result"]["structuredContent"];
    assert!(stats["documents"].as_u64().unwrap_or(0) >= 5, "{}", replies[2]);
}
