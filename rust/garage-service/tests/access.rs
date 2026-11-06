//! The access hooks against a real database (`docs/plans/access-hooks.md`): a test policy that
//! hides one document from MCP callers, and every read path checked for it. Needs
//! `GARAGE_TEST_DATABASE_URL`.

mod common;

use std::path::Path;
use std::sync::Arc;

use common::*;
use garage_facade::proto;
use garage_facade::proto::garage_service_client::GarageServiceClient;
use garage_service::config::Config;
use garage_service::garage_access::{AccessError, AccessPolicy, BoxFuture, Caller, CallerKind, SqlFilter, SqlValue};
use garage_service::models::{EmbeddingModel, ModelSpec, register_model};
use garage_service::search::QueryEmbedder;
use garage_service::server::{Endpoint, serve};
use garage_service::service::{GarageService, sql_dir};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tonic::Code;
use tonic::transport::{Channel, Uri};

const DIMS: usize = 8;

/// Hides the document titled `secret` from MCP callers, and from every caller when `everyone`.
struct HideSecret {
    everyone: bool,
}

impl AccessPolicy for HideSecret {
    fn name(&self) -> &'static str {
        "hide-secret"
    }

    fn document_filter<'a>(
        &'a self,
        _client: &'a tokio_postgres::Client,
        caller: &'a Caller,
    ) -> BoxFuture<'a, Result<Option<SqlFilter>, AccessError>> {
        let restricted = self.everyone || caller.kind == CallerKind::Mcp;
        Box::pin(async move {
            Ok(restricted
                .then(|| SqlFilter::new("d.title IS DISTINCT FROM $1::text", vec![SqlValue::Text("secret".into())])))
        })
    }
}

/// Hides `secret` from MCP callers that prove no registration, and records what it was told.
#[derive(Default)]
struct RegisteredOnly {
    seen: std::sync::Mutex<Vec<Option<String>>>,
    removed: std::sync::Mutex<Vec<String>>,
}

impl AccessPolicy for RegisteredOnly {
    fn name(&self) -> &'static str {
        "registered-only"
    }

    fn document_filter<'a>(
        &'a self,
        _client: &'a tokio_postgres::Client,
        caller: &'a Caller,
    ) -> BoxFuture<'a, Result<Option<SqlFilter>, AccessError>> {
        self.seen.lock().unwrap().push(caller.registration.as_ref().map(|r| r.name.clone()));
        let anonymous = caller.kind == CallerKind::Mcp && caller.registration.is_none();
        Box::pin(async move {
            Ok(anonymous
                .then(|| SqlFilter::new("d.title IS DISTINCT FROM $1::text", vec![SqlValue::Text("secret".into())])))
        })
    }

    fn on_registration_removed<'a>(&'a self, registration_id: &'a str) -> BoxFuture<'a, ()> {
        self.removed.lock().unwrap().push(registration_id.to_owned());
        Box::pin(async {})
    }
}

/// Cannot decide.
struct Broken;

impl AccessPolicy for Broken {
    fn name(&self) -> &'static str {
        "broken"
    }

    fn document_filter<'a>(
        &'a self,
        _client: &'a tokio_postgres::Client,
        _caller: &'a Caller,
    ) -> BoxFuture<'a, Result<Option<SqlFilter>, AccessError>> {
        Box::pin(async { Err(AccessError::new("rules table missing: secret.md was in it")) })
    }
}

struct FixedEmbedder;

impl QueryEmbedder for FixedEmbedder {
    fn embed_query(&self, _: &EmbeddingModel, _: &str) -> garage_service::Result<Vec<f32>> {
        Ok(halves(DIMS, 1.0))
    }
}

type Client = GarageServiceClient<Channel>;

struct Running {
    client: Client,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}

impl Running {
    async fn start(database_url: &str, dir: &Path, policy: Arc<dyn AccessPolicy>) -> Self {
        let mut config = Config::default();
        config.set_field("database_url", Value::String(database_url.to_owned()));
        let service = GarageService::new(config, Arc::new(FixedEmbedder), sql_dir(None), true)
            .unwrap()
            .with_access_policy(policy);
        let socket = dir.join("grpc");
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let endpoint = Endpoint::Unix(socket.clone());
        let task = tokio::spawn(async move {
            serve(service, &endpoint, None, async {
                let _ = stopped.await;
            })
            .await
        });
        for _ in 0..200 {
            if tokio::net::UnixStream::connect(&socket).await.is_ok() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        let channel = tonic::transport::Endpoint::from_static("http://garage")
            .connect_with_connector(tower::service_fn(move |_: Uri| {
                let path = socket.clone();
                async move { Ok::<_, std::io::Error>(TokioIo::new(tokio::net::UnixStream::connect(path).await?)) }
            }))
            .await
            .unwrap();
        Self { client: Client::new(channel), stop: Some(stop), task: Some(task) }
    }

    async fn stop(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.task.take().unwrap().await.unwrap().unwrap();
    }
}

fn scratch() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("garage-service-access-{}", nonce()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Three documents about heat pumps and bread; `secret` (in a source of its own, with an author
/// of its own) matches the query as well as `heat-pumps` does. Returns `secret`'s document id.
async fn corpus(pool: &deadpool_postgres::Pool) -> i64 {
    let mut client = pool.get().await.unwrap();
    let model =
        register_model(&mut client, &ModelSpec { distance: "cosine".into(), ..ModelSpec::new("m", "m", DIMS) }, true)
            .await
            .unwrap();
    let notes = source(&client, "notes", json!({})).await;
    let vault = source(&client, "vault", json!({})).await;
    let heat = chunk(&client, notes, "heat-pumps", "Heat pumps lose efficiency in deep cold.", "document").await;
    let bread = chunk(&client, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document").await;
    let secret = chunk(&client, vault, "secret", "The heat pump contract terms are confidential.", "document").await;
    embed(&client, &model.table_name, heat, &halves(DIMS, 1.0), "vector").await;
    embed(&client, &model.table_name, bread, &halves(DIMS, -1.0), "vector").await;
    embed(&client, &model.table_name, secret, &halves(DIMS, 1.0), "vector").await;
    let secret_doc: i64 =
        client.query_one("SELECT document_id FROM chunks WHERE id = $1", &[&secret]).await.unwrap().get(0);
    let author: i64 = client
        .query_one("INSERT INTO authors (display_name) VALUES ('Mallory') RETURNING id", &[])
        .await
        .unwrap()
        .get(0);
    client
        .execute(
            "INSERT INTO document_authors (document_id, author_id, role, confidence) VALUES ($1, $2, 'author', 1.0)",
            &[&secret_doc, &author],
        )
        .await
        .unwrap();
    secret_doc
}

#[allow(clippy::unnecessary_wraps)] // the request field's type
fn mcp() -> Option<proto::CorpusCaller> {
    Some(proto::CorpusCaller { kind: "mcp".into(), transport: "stdio".into(), ..Default::default() })
}

#[allow(clippy::needless_pass_by_value)] // takes a reply as it comes
fn parse(response: proto::CorpusReadResponse) -> Value {
    serde_json::from_str(&response.result_json).unwrap()
}

fn titles(result: &Value) -> Vec<String> {
    result["hits"].as_array().unwrap().iter().map(|h| h["title"].as_str().unwrap_or_default().to_owned()).collect()
}

async fn corpus_search(client: &mut Client, mode: &str, limit: i32) -> Value {
    let request = proto::CorpusSearchRequest {
        caller: mcp(),
        query: "heat pump".into(),
        limit,
        mode: mode.into(),
        ..Default::default()
    };
    parse(client.corpus_search(request).await.unwrap().into_inner())
}

#[test]
fn a_hidden_document_appears_on_no_mcp_read_path() {
    with_db_url(|pool, url| {
        Box::pin(async move {
            let secret = corpus(&pool).await;
            let dir = scratch();
            let mut server = Running::start(&url, &dir, Arc::new(HideSecret { everyone: false })).await;
            let client = &mut server.client;

            for mode in ["hybrid", "vector", "fts"] {
                let found = titles(&corpus_search(client, mode, 10).await);
                assert!(!found.contains(&"secret".to_owned()), "{mode}: {found:?}");
                assert!(found.contains(&"heat-pumps".to_owned()), "{mode}: {found:?}");
            }
            // The filter is inside the candidate queries, so a filtered search still fills its limit.
            assert_eq!(titles(&corpus_search(client, "vector", 2).await), ["heat-pumps", "sourdough"]);

            // By id and by location, a hidden document reads as a missing one.
            let by_id = |document_id: i64| proto::CorpusDocumentRequest {
                caller: mcp(),
                document_id: Some(document_id),
                ..Default::default()
            };
            let hidden = client.corpus_document(by_id(secret)).await.unwrap_err();
            let missing = client.corpus_document(by_id(secret + 1000)).await.unwrap_err();
            assert_eq!(hidden.code(), missing.code());
            assert_eq!(hidden.message(), format!("no such document: {secret}"));
            let by_location =
                proto::CorpusDocumentRequest { caller: mcp(), location: "test://secret".into(), ..Default::default() };
            assert_eq!(
                client.corpus_document(by_location).await.unwrap_err().message(),
                "no such document: test://secret"
            );

            let sources =
                parse(client.corpus_sources(proto::CorpusSourcesRequest { caller: mcp() }).await.unwrap().into_inner());
            let slugs: Vec<&str> =
                sources["sources"].as_array().unwrap().iter().map(|s| s["slug"].as_str().unwrap()).collect();
            assert_eq!(slugs, ["notes"]);
            assert_eq!(sources["sources"][0]["documents"], 2);

            let authors = parse(
                client
                    .corpus_authors(proto::CorpusAuthorsRequest { caller: mcp(), limit: 0 })
                    .await
                    .unwrap()
                    .into_inner(),
            );
            assert_eq!(authors["count"], 0, "{authors}");

            let stats =
                parse(client.corpus_stats(proto::CorpusStatsRequest { caller: mcp() }).await.unwrap().into_inner());
            assert_eq!(
                (stats["documents"].clone(), stats["chunks"].clone(), stats["authors"].clone()),
                (json!(2), json!(2), json!(0))
            );
            assert_eq!(stats["models"][0]["vectors"], 2);
            assert_eq!(stats["by_class_and_trust"][0]["documents"], 2);

            // The app is not restricted by this policy, and sees everything.
            let request = proto::SearchRequest { query: "heat pump".into(), limit: 10, ..Default::default() };
            let hits = client.search(request).await.unwrap().into_inner().hits;
            assert!(hits.iter().any(|h| h.title == "secret"));
            let detail = client.get_document(proto::GetDocumentRequest { document_id: secret }).await.unwrap();
            assert_eq!(detail.into_inner().document.unwrap().title, "secret");
            server.stop().await;
        })
    });
}

#[test]
fn the_apps_reads_go_through_the_policy_too() {
    with_db_url(|pool, url| {
        Box::pin(async move {
            let secret = corpus(&pool).await;
            let dir = scratch();
            let mut server = Running::start(&url, &dir, Arc::new(HideSecret { everyone: true })).await;
            let client = &mut server.client;
            let request = proto::SearchRequest { query: "heat pump".into(), limit: 10, ..Default::default() };
            let hits = client.search(request).await.unwrap().into_inner().hits;
            assert!(!hits.is_empty() && hits.iter().all(|h| h.title != "secret"));
            let hidden = client.get_document(proto::GetDocumentRequest { document_id: secret }).await.unwrap_err();
            assert_eq!(hidden.code(), Code::NotFound);
            let listed = client.list_documents(proto::ListDocumentsRequest::default()).await.unwrap().into_inner();
            assert_eq!(listed.total_count, 2);
            assert!(listed.documents.iter().all(|d| d.title != "secret"));
            server.stop().await;
        })
    });
}

#[test]
fn a_policy_that_cannot_decide_fails_the_read_and_says_nothing() {
    with_db_url(|pool, url| {
        Box::pin(async move {
            corpus(&pool).await;
            let dir = scratch();
            let mut server = Running::start(&url, &dir, Arc::new(Broken)).await;
            let client = &mut server.client;
            let request = proto::CorpusSearchRequest { caller: mcp(), query: "heat pump".into(), ..Default::default() };
            let error = client.corpus_search(request).await.unwrap_err();
            assert_eq!(error.code(), Code::Unknown);
            assert!(!error.message().contains("secret"), "{}", error.message());
            let error = client.corpus_stats(proto::CorpusStatsRequest { caller: mcp() }).await.unwrap_err();
            assert_eq!(error.code(), Code::Unknown);
            server.stop().await;
        })
    });
}

#[test]
fn a_registrations_token_proves_it_until_it_is_uninstalled() {
    with_db_url(|pool, url| {
        Box::pin(async move {
            corpus(&pool).await;
            let db = pool.get().await.unwrap();
            let dir = scratch();
            let target = dir.join("client.json");
            let policy = Arc::new(RegisteredOnly::default());
            let mut server = Running::start(&url, &dir, policy.clone()).await;
            let client = &mut server.client;
            let install = |force: bool| proto::McpInstallRequest {
                path: target.to_string_lossy().into_owned(),
                stdio: true,
                force,
                ..Default::default()
            };

            // A dry run writes no token anywhere.
            let preview = client
                .mcp_install(proto::McpInstallRequest { dry_run: true, ..install(false) })
                .await
                .unwrap()
                .into_inner();
            assert!(!preview.outcomes[0].preview_json.contains("gmr_"));
            assert_eq!(count(&db, "SELECT count(*) FROM mcp_registrations").await, 0);

            client.mcp_install(install(false)).await.unwrap();
            let written: Value = serde_json::from_str(&std::fs::read_to_string(&target).unwrap()).unwrap();
            let token = written["mcpServers"]["garage-rag"]["env"]["GARAGE_MCP_TOKEN"].as_str().unwrap().to_owned();
            assert!(token.starts_with("gmr_") && !token.contains(' '));
            let row = db
                .query_one("SELECT id, name, client, transport, token_sha256 FROM mcp_registrations", &[])
                .await
                .unwrap();
            let id: String = row.get(0);
            assert_eq!(
                (row.get::<_, String>(1), row.get::<_, String>(2), row.get::<_, String>(3)),
                ("garage-rag".into(), "custom".into(), "stdio".into())
            );
            // Only the hash is kept.
            let hash: Vec<u8> = row.get(4);
            assert_eq!(hash.len(), 32);
            assert!(!format!("{row:?}").contains(&token));

            // A forced re-install keeps the token, and so the registration.
            client.mcp_install(install(true)).await.unwrap();
            let again: Value = serde_json::from_str(&std::fs::read_to_string(&target).unwrap()).unwrap();
            assert_eq!(again["mcpServers"]["garage-rag"]["env"]["GARAGE_MCP_TOKEN"], json!(token));
            assert_eq!(count(&db, "SELECT count(*) FROM mcp_registrations").await, 1);

            let search = |registration_token: &str| proto::CorpusSearchRequest {
                caller: Some(proto::CorpusCaller {
                    kind: "mcp".into(),
                    transport: "stdio".into(),
                    registration_token: registration_token.to_owned(),
                    ..Default::default()
                }),
                query: "heat pump".into(),
                mode: "fts".into(),
                ..Default::default()
            };
            let with_token = parse(client.corpus_search(search(&token)).await.unwrap().into_inner());
            assert!(titles(&with_token).contains(&"secret".to_owned()));
            let forged = parse(client.corpus_search(search("gmr_not-a-registration")).await.unwrap().into_inner());
            assert!(!titles(&forged).contains(&"secret".to_owned()));
            assert_eq!(policy.seen.lock().unwrap()[..], [Some("garage-rag".to_owned()), None]);
            assert_eq!(count(&db, "SELECT count(*) FROM mcp_registrations WHERE last_seen_at IS NOT NULL").await, 1);

            // Uninstalling deletes the registration, so the copied token stops working at once.
            let uninstall =
                proto::McpUninstallRequest { path: target.to_string_lossy().into_owned(), ..Default::default() };
            assert!(client.mcp_uninstall(uninstall).await.unwrap().into_inner().removed);
            assert_eq!(count(&db, "SELECT count(*) FROM mcp_registrations").await, 0);
            assert_eq!(policy.removed.lock().unwrap()[..], [id]);
            let revoked = parse(client.corpus_search(search(&token)).await.unwrap().into_inner());
            assert!(!titles(&revoked).contains(&"secret".to_owned()));
            server.stop().await;
        })
    });
}
