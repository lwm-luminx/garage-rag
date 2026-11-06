//! The operations stage over gRPC against a real database: sources (add, remove, sync, import,
//! scan, reconcile), models (register, default, drop, embed a text), settings and MCP client
//! registration, each checked for Python's messages. Needs `GARAGE_TEST_DATABASE_URL`.

#![allow(clippy::cast_possible_wrap, clippy::too_many_lines)]

mod common;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use garage_facade::proto;
use garage_facade::proto::garage_service_client::GarageServiceClient;
use garage_service::config::Config;
use garage_service::models::{EmbeddingModel, ModelSpec, register_model};
use garage_service::search::QueryEmbedder;
use garage_service::server::{Endpoint, serve};
use garage_service::service::{GarageService, sql_dir};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tonic::Code;
use tonic::transport::{Channel, Uri};

/// Answers every text with the same unit vector, so `EmbedText` has something to truncate.
struct FixedEmbedder(Vec<f32>);

impl QueryEmbedder for FixedEmbedder {
    fn embed_query(&self, _: &EmbeddingModel, _: &str) -> garage_service::Result<Vec<f32>> {
        Ok(self.0.clone())
    }
}

type Client = GarageServiceClient<Channel>;

/// A server on a Unix socket (so the config-changing methods are answered) over `database_url`,
/// running on the config file at `config_path`; stopped when dropped.
struct Running {
    client: Client,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}

impl Running {
    async fn start(database_url: &str, config_path: &Path) -> Self {
        Self::start_with_host(database_url, config_path, None).await
    }

    /// A server whose long jobs reach a model server through `host`.
    async fn start_with_host(
        database_url: &str,
        config_path: &Path,
        host: Option<Arc<dyn garage_embed::Host>>,
    ) -> Self {
        let mut config = Config::default();
        config.set_field("database_url", Value::String(database_url.to_owned()));
        config.path = Some(config_path.to_path_buf());
        let mut vector = vec![0.0f32; 8];
        vector[0] = 0.6;
        vector[1] = 0.8;
        let mut service = GarageService::new(config, Arc::new(FixedEmbedder(vector)), sql_dir(None), true).unwrap();
        if let Some(host) = host {
            service = service.with_host(host);
        }
        let socket = config_path.with_file_name("grpc");
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

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("garage-service-ops-{}-{}", std::process::id(), common::nonce()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn read_json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn fixture_corpus() -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../macapp/Tests/Fixtures/corpus");
    std::fs::canonicalize(dir).unwrap()
}

#[test]
fn sources_are_added_synced_imported_and_removed() {
    common::with_db_url(|_, url| {
        Box::pin(async move {
            let dir = scratch();
            let config_path = dir.join("garage.json");
            let root = dir.join("notes");
            std::fs::create_dir_all(&root).unwrap();
            let mut server = Running::start(&url, &config_path).await;
            let client = &mut server.client;

            let add = |slug: &str, root: &Path, class: &str, trust: &str| proto::AddSourceRequest {
                slug: slug.into(),
                root: root.to_string_lossy().into_owned(),
                kind: String::new(),
                corpus_class: class.into(),
                trust: trust.into(),
            };
            let added = client.add_source(add("notes", &root, "", "")).await.unwrap().into_inner();
            assert!(added.created);
            assert_eq!(added.root, root.to_string_lossy());
            assert_eq!(added.message, format!("added source notes -> {} (document/authored)", root.display()));
            let again = client.add_source(add("notes", &root, "code", "reference")).await.unwrap().into_inner();
            assert!(!again.created);
            assert_eq!(again.message, format!("updated source notes -> {}", root.display()));
            let missing = client.add_source(add("gone", &dir.join("nope"), "", "")).await.unwrap_err();
            assert_eq!(missing.code(), Code::InvalidArgument);
            assert!(missing.message().ends_with("nope does not exist"));
            let bad = client.add_source(add("x", &root, "", "secret")).await.unwrap_err();
            assert_eq!(bad.code(), Code::InvalidArgument);
            assert!(bad.message().contains("'secret' is not a valid TrustTier"));
            let listed = client.list_sources(proto::ListSourcesRequest {}).await.unwrap().into_inner();
            assert_eq!(listed.sources.len(), 1);
            assert_eq!(
                (listed.sources[0].corpus_class.as_str(), listed.sources[0].trust_tier.as_str()),
                ("code", "reference")
            );

            // Nothing declared yet: Sync reports so, naming the file.
            let sync = client.sync_sources(proto::SyncSourcesRequest { dry_run: true }).await.unwrap().into_inner();
            assert_eq!(sync.declared, 0);
            assert_eq!(sync.message, format!("no sources declared in {}", config_path.display()));

            // Import copies the database's source into the file, with every field written.
            let imported = client
                .import_sources_to_config(proto::ImportSourcesToConfigRequest { path: String::new() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(imported.added, vec!["notes"]);
            assert_eq!(imported.message, format!("added 1 sources to {}: notes", config_path.display()));
            let document = read_json(&config_path);
            assert_eq!(document["$schema"], json!("https://garagerag.app/.data/garage.schema.json"));
            assert_eq!(
                document["sources"][0],
                json!({"slug": "notes", "root": root.to_string_lossy(), "kind": "filesystem", "class": "code",
                       "trust": "reference", "include_code": false, "enabled": true})
            );
            let unchanged = client
                .import_sources_to_config(proto::ImportSourcesToConfigRequest { path: String::new() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(unchanged.message, "config already lists every database source");

            // The file is the source of truth: a changed entry and a new one reach the database on
            // apply, and a source only the database has is reported, never deleted.
            let mut document = read_json(&config_path);
            document["sources"][0]["class"] = json!("document");
            document["sources"][0]["include_code"] = json!(true);
            document["sources"]
                .as_array_mut()
                .unwrap()
                .push(json!({"slug": "mail", "root": "~/Mail", "kind": "maildir"}));
            std::fs::write(&config_path, document.to_string()).unwrap();
            client.add_source(add("stray", &root, "", "")).await.unwrap();
            let dry = client.sync_sources(proto::SyncSourcesRequest { dry_run: true }).await.unwrap().into_inner();
            assert_eq!((dry.declared, dry.applied), (2, false));
            assert_eq!((dry.created.clone(), dry.updated.clone()), (vec!["mail".to_owned()], vec!["notes".to_owned()]));
            assert_eq!(
                dry.message,
                "would create: mail\nwould update: notes\nin the database but not declared (left untouched):\n  stray (0 documents)"
            );
            let applied = client.sync_sources(proto::SyncSourcesRequest { dry_run: false }).await.unwrap().into_inner();
            assert_eq!(applied.message.lines().next(), Some("create: mail"));
            let listed = client.list_sources(proto::ListSourcesRequest {}).await.unwrap().into_inner();
            let notes = listed.sources.iter().find(|s| s.slug == "notes").unwrap();
            assert_eq!(notes.corpus_class, "document");
            let mail = listed.sources.iter().find(|s| s.slug == "mail").unwrap();
            assert_eq!(mail.kind, "maildir");
            assert!(mail.root.ends_with("/Mail") && !mail.root.starts_with('~'));
            let settled = client.sync_sources(proto::SyncSourcesRequest { dry_run: false }).await.unwrap().into_inner();
            assert!(settled.message.starts_with("database already matches the config\n"));

            // Remove drops the source from the database and the file, so Sync cannot bring it back.
            let removed =
                client.remove_source(proto::RemoveSourceRequest { slug: "mail".into() }).await.unwrap().into_inner();
            assert_eq!(removed.deleted_documents, 0);
            assert_eq!(
                removed.message,
                format!("removed mail (0 documents) and dropped it from {}", config_path.display())
            );
            assert_eq!(read_json(&config_path)["sources"].as_array().unwrap().len(), 1);
            let stray =
                client.remove_source(proto::RemoveSourceRequest { slug: "stray".into() }).await.unwrap().into_inner();
            assert_eq!(stray.message, "removed stray (0 documents)");
            let unknown = client.remove_source(proto::RemoveSourceRequest { slug: "stray".into() }).await.unwrap_err();
            assert_eq!((unknown.code(), unknown.message()), (Code::NotFound, "no such source: stray"));

            server.stop().await;
            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn scan_streams_progress_and_records_the_count() {
    common::with_db_url(|_, url| {
        Box::pin(async move {
            let dir = scratch();
            let mut server = Running::start(&url, &dir.join("garage.json")).await;
            let client = &mut server.client;
            let corpus = fixture_corpus();
            client
                .add_source(proto::AddSourceRequest {
                    slug: "corpus".into(),
                    root: corpus.to_string_lossy().into_owned(),
                    ..Default::default()
                })
                .await
                .unwrap();
            client
                .add_source(proto::AddSourceRequest {
                    slug: "gone".into(),
                    root: dir.to_string_lossy().into_owned(),
                    ..Default::default()
                })
                .await
                .unwrap();
            // The second source's root disappears before the scan: its result carries the problem.
            let gone = dir.join("gone");
            std::fs::create_dir_all(&gone).unwrap();
            let changed = client
                .add_source(proto::AddSourceRequest {
                    slug: "gone".into(),
                    root: gone.to_string_lossy().into_owned(),
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            assert!(!changed.created);
            std::fs::remove_dir(&gone).unwrap();

            let mut stream =
                client.scan(proto::ScanRequest { source: "*".into(), include_code: true }).await.unwrap().into_inner();
            let mut events = Vec::new();
            while let Some(event) = stream.message().await.unwrap() {
                events.push(event);
            }
            assert_eq!(
                (events[0].phase.as_str(), events[0].source.as_str(), events[0].source_items),
                ("progress", "corpus", 0)
            );
            let corpus_done = events.iter().find(|e| e.phase == "source" && e.source == "corpus").unwrap();
            let result = corpus_done.result.as_ref().unwrap();
            assert_eq!((result.item_count, result.item_type.as_str(), result.error.as_str()), (6, "files", ""));
            assert_eq!(result.root, corpus.to_string_lossy());
            assert_eq!(corpus_done.source_items, 6);
            let gone_done = events.iter().find(|e| e.phase == "source" && e.source == "gone").unwrap();
            assert!(gone_done.result.as_ref().unwrap().error.contains("does not exist"));
            assert_eq!(gone_done.total_items, 6);
            let finished = events.last().unwrap();
            assert_eq!(finished.phase, "finished");
            let summary = finished.summary.as_ref().unwrap();
            assert_eq!((summary.total_items, summary.sources.len()), (6, 2));
            assert_eq!(summary.message, "Scanned 2 source(s): 6 items");

            let listed = client.list_sources(proto::ListSourcesRequest {}).await.unwrap().into_inner();
            let corpus_row = listed.sources.iter().find(|s| s.slug == "corpus").unwrap();
            assert_eq!(corpus_row.expected_elements, 6);

            let unknown =
                client.scan(proto::ScanRequest { source: "nope".into(), include_code: false }).await.unwrap_err();
            assert_eq!((unknown.code(), unknown.message()), (Code::NotFound, "no such source: nope"));

            server.stop().await;
            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn reconcile_trusts_only_a_completed_run_and_refuses_large_deletions() {
    common::with_db_url(|pool, url| {
        Box::pin(async move {
            let db = pool.get().await.unwrap();
            let source_id = common::source(&db, "notes", json!({})).await;
            let mut uris = Vec::new();
            for i in 0..8 {
                let uri = format!("/tmp/doc{i}.md");
                common::document(&db, source_id, &format!("doc{i}"), &format!("body {i}"), "document").await;
                db.execute("UPDATE documents SET uri = $1 WHERE title = $2", &[&uri, &format!("doc{i}")])
                    .await
                    .unwrap();
                uris.push(uri);
            }
            let dir = scratch();
            let mut server = Running::start(&url, &dir.join("garage.json")).await;
            let client = &mut server.client;
            let reconcile = |apply: bool, force: bool| proto::ReconcileRequest { source: "notes".into(), apply, force };

            let no_run = client.reconcile(reconcile(false, false)).await.unwrap().into_inner();
            assert!(no_run.refused);
            assert_eq!(
                no_run.message,
                "refused: no completed scan on record; run a full `garage ingest` (without --limit) before reconciling"
            );

            // An incomplete run does not count; a complete one that saw five of eight does.
            db.execute("INSERT INTO ingest_runs (source_id, completed) VALUES ($1, false)", &[&source_id])
                .await
                .unwrap();
            let run_id: i64 = db
                .query_one(
                    "INSERT INTO ingest_runs (source_id, completed) VALUES ($1, true) RETURNING id",
                    &[&source_id],
                )
                .await
                .unwrap()
                .get(0);
            for uri in &uris[..5] {
                db.execute("INSERT INTO ingest_seen (run_id, uri) VALUES ($1, $2)", &[&run_id, uri]).await.unwrap();
            }
            let too_many = client.reconcile(reconcile(true, false)).await.unwrap().into_inner();
            assert!(too_many.refused);
            assert_eq!((too_many.candidates, too_many.total_documents), (3, 8));
            assert_eq!(
                too_many.message,
                "refused: would delete 3 of 8 documents (38% > 25%); if the source really shrank that much, re-run with --force"
            );
            assert_eq!(common::count(&db, "SELECT count(*) FROM documents").await, 8);

            let dry = client.reconcile(reconcile(false, true)).await.unwrap().into_inner();
            assert!(!dry.refused && dry.deleted == 0);
            assert!((dry.fraction - 0.375).abs() < 1e-9);
            assert_eq!(dry.message, "dry run: 3 of 8 documents in notes are missing (37.5%)");
            assert_eq!(common::count(&db, "SELECT count(*) FROM documents").await, 8);

            let applied = client.reconcile(reconcile(true, true)).await.unwrap().into_inner();
            assert_eq!(applied.deleted, 3);
            assert_eq!(applied.message, "deleted 3 of 8 documents from notes");
            assert_eq!(common::count(&db, "SELECT count(*) FROM documents").await, 5);
            let nothing = client.reconcile(reconcile(true, false)).await.unwrap().into_inner();
            assert_eq!(nothing.message, "nothing to reconcile for notes");
            let unknown = client
                .reconcile(proto::ReconcileRequest { source: "x".into(), apply: false, force: false })
                .await
                .unwrap_err();
            assert_eq!(unknown.code(), Code::NotFound);

            server.stop().await;
            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn models_are_registered_from_the_catalog_or_a_width_and_embed_a_text() {
    common::with_db_url(|_, url| {
        Box::pin(async move {
            let dir = scratch();
            let mut server = Running::start(&url, &dir.join("garage.json")).await;
            let client = &mut server.client;

            let uncatalogued = client
                .register_model(proto::RegisterModelRequest { slug: "mystery".into(), ..Default::default() })
                .await
                .unwrap_err();
            assert_eq!(uncatalogued.code(), Code::InvalidArgument);
            assert_eq!(uncatalogued.message(), "model 'mystery' is not in models.json; pass --dims explicitly");

            // The repository's models.json supplies the width, distance and provider.
            let catalogued = client
                .register_model(proto::RegisterModelRequest { slug: "nomic-embed-text".into(), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            let model = catalogued.model.unwrap();
            assert_eq!((model.dims, model.provider.as_str(), model.distance.as_str()), (768, "llama_xpc", "cosine"));
            assert!(model.is_default);
            assert_eq!(
                catalogued.message,
                "registered nomic-embed-text: 768-dim -> vector(768), index=hnsw, distance=cosine, table=emb_nomic_embed_text"
            );

            let own = client
                .register_model(proto::RegisterModelRequest {
                    slug: "tiny".into(),
                    dims: 8,
                    provider: "ollama".into(),
                    distance: "l2".into(),
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            assert!(own.notes.is_empty());
            assert_eq!(own.message, "registered tiny: 8-dim -> vector(8), index=hnsw, distance=l2, table=emb_tiny");
            let wide = client
                .register_model(proto::RegisterModelRequest { slug: "wide".into(), dims: 4096, ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(wide.notes, vec!["binary-quantized index; queries re-rank on exact cosine distance"]);
            assert!(
                wide.message
                    .ends_with("table=emb_wide\nbinary-quantized index; queries re-rank on exact cosine distance")
            );

            let default = client
                .set_default_model(proto::SetDefaultModelRequest { slug: "tiny".into() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(default.message, "default model = tiny");
            let unknown =
                client.set_default_model(proto::SetDefaultModelRequest { slug: "nope".into() }).await.unwrap_err();
            assert_eq!(unknown.code(), Code::NotFound);
            let models = client.list_models(proto::ListModelsRequest {}).await.unwrap().into_inner().models;
            assert_eq!(models.iter().filter(|m| m.is_default).map(|m| m.slug.as_str()).collect::<Vec<_>>(), ["tiny"]);

            // EmbedText asks the default model's provider and truncates on request.
            let embedded = client
                .embed_text(proto::EmbedTextRequest { text: "hello".into(), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(
                (embedded.model.as_str(), embedded.provider.as_str(), embedded.native_dims),
                ("tiny", "ollama", 8)
            );
            assert_eq!(embedded.vector.len(), 8);
            let short = client
                .embed_text(proto::EmbedTextRequest { text: "hello".into(), model: "tiny".into(), dimensions: 1 })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(short.vector, vec![1.0]);
            let wrong = client
                .embed_text(proto::EmbedTextRequest { text: "hello".into(), model: String::new(), dimensions: 9 })
                .await
                .unwrap_err();
            assert_eq!(
                (wrong.code(), wrong.message()),
                (Code::InvalidArgument, "tiny gives 8 dimensions; 9 is not between 1 and 8")
            );
            let empty = client
                .embed_text(proto::EmbedTextRequest { text: "  ".into(), ..Default::default() })
                .await
                .unwrap_err();
            assert_eq!((empty.code(), empty.message()), (Code::InvalidArgument, "nothing to embed: the text is empty"));

            let dropped =
                client.drop_model(proto::DropModelRequest { slug: "wide".into() }).await.unwrap().into_inner();
            assert_eq!(dropped.message, "dropped wide");
            assert_eq!(client.list_models(proto::ListModelsRequest {}).await.unwrap().into_inner().models.len(), 2);

            server.stop().await;
            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn settings_are_written_and_reloaded_and_clients_are_registered() {
    common::with_db_url(|_, url| {
        Box::pin(async move {
            let dir = scratch();
            let config_path = dir.join("garage.json");
            let mut server = Running::start(&url, &config_path).await;
            let client = &mut server.client;

            let set = |name: &str, value: &str| proto::SetSettingRequest {
                name: name.into(),
                value: value.into(),
                path: String::new(),
            };
            let written =
                client.set_setting(set("embedding.ollama_host", "http://gpu:11434")).await.unwrap().into_inner();
            assert_eq!(
                (written.name.as_str(), written.value_json.as_str()),
                ("embedding.ollama_host", "\"http://gpu:11434\"")
            );
            assert_eq!(written.path, config_path.to_string_lossy());
            assert_eq!(read_json(&config_path)["embedding"]["ollama_host"], json!("http://gpu:11434"));
            // The process runs on the file it wrote.
            let read = client
                .get_setting(proto::GetSettingRequest { name: "embedding.ollama_host".into() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(read.value_json, "\"http://gpu:11434\"");
            let flag = client.set_setting(set("extraction.index_images", "off")).await.unwrap().into_inner();
            assert_eq!(flag.value_json, "false");
            let bad = client.set_setting(set("extraction.index_images", "maybe")).await.unwrap_err();
            assert_eq!(bad.code(), Code::InvalidArgument);
            assert!(bad.message().starts_with("index_images: expected true/false"));
            let off_box = client.set_setting(set("embedding.llama_host", "http://gpu:8790")).await.unwrap_err();
            assert_eq!(off_box.code(), Code::InvalidArgument);
            assert!(off_box.message().contains("must be a loopback URL"));
            assert_eq!(read_json(&config_path)["embedding"]["llama_host"], json!("http://127.0.0.1:8790"));
            let elsewhere = dir.join("other.json");
            let other = client
                .set_setting(proto::SetSettingRequest {
                    name: "facts.provider".into(),
                    value: "ollama".into(),
                    path: elsewhere.to_string_lossy().into_owned(),
                })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(other.path, elsewhere.to_string_lossy());
            assert_eq!(read_json(&elsewhere)["facts"]["provider"], json!("ollama"));

            // MCP registration into a named file: the HTTP URL, then the stdio command.
            let target = dir.join("mcp.json");
            let install = |stdio: bool, force: bool, dry_run: bool| proto::McpInstallRequest {
                target: String::new(),
                path: target.to_string_lossy().into_owned(),
                all: false,
                name: String::new(),
                stdio,
                host: String::new(),
                port: 0,
                route: String::new(),
                force,
                dry_run,
            };
            let preview = client.mcp_install(install(false, false, true)).await.unwrap().into_inner();
            assert_eq!(preview.url, "http://127.0.0.1:8787/mcp");
            assert_eq!(preview.outcomes.len(), 1);
            assert!(!preview.outcomes[0].written);
            assert_eq!(
                preview.outcomes[0].preview_json,
                "{\"mcpServers\": {\"garage-rag\": {\"type\": \"http\", \"url\": \"http://127.0.0.1:8787/mcp\"}}}"
            );
            assert_eq!(
                preview.message,
                format!("url: http://127.0.0.1:8787/mcp\ncustom path -> {}: would write garage-rag", target.display())
            );
            assert!(!target.exists());
            let installed = client.mcp_install(install(false, false, false)).await.unwrap().into_inner();
            assert!(installed.outcomes[0].written && installed.outcomes[0].created_file);
            assert_eq!(installed.message, format!("url: http://127.0.0.1:8787/mcp\ncreated {}", target.display()));
            assert_eq!(read_json(&target)["mcpServers"]["garage-rag"]["url"], json!("http://127.0.0.1:8787/mcp"));
            let twice = client.mcp_install(install(false, false, false)).await.unwrap_err();
            assert_eq!(twice.code(), Code::AlreadyExists);
            assert!(twice.message().starts_with("'garage-rag' is already configured in "));
            let forced = client.mcp_install(install(true, true, false)).await.unwrap().into_inner();
            assert!(!forced.command.is_empty());
            assert_eq!(forced.args[0], "--config");
            assert!(forced.outcomes[0].replaced_entry && !forced.outcomes[0].created_file);
            assert!(forced.outcomes[0].backup_path.contains(".json.bak-"));
            assert!(forced.message.starts_with("command: "));
            assert!(forced.message.ends_with(')'));
            // The file SetSetting last wrote to is the one in use, as Python's reload left it.
            let entry = &read_json(&target)["mcpServers"]["garage-rag"];
            assert!(entry["args"][1].as_str().unwrap().ends_with("other.json"), "{entry}");
            let unknown = client
                .mcp_install(proto::McpInstallRequest { target: "emacs".into(), ..Default::default() })
                .await
                .unwrap_err();
            assert_eq!(unknown.code(), Code::InvalidArgument);
            assert!(unknown.message().starts_with("unknown target 'emacs'; choose from project, "));

            let status = client.mcp_status(proto::McpStatusRequest {}).await.unwrap().into_inner();
            assert_eq!(status.clients.len(), 10);
            assert_eq!(status.clients[0].key, "project");
            assert!(status.server_command.contains("garage-mcp"));

            let uninstall = || proto::McpUninstallRequest {
                target: String::new(),
                path: target.to_string_lossy().into_owned(),
                name: String::new(),
            };
            let removed = client.mcp_uninstall(uninstall()).await.unwrap().into_inner();
            assert!(removed.removed);
            assert_eq!(removed.message, format!("removed garage-rag from {}", target.display()));
            let gone = client.mcp_uninstall(uninstall()).await.unwrap().into_inner();
            assert!(!gone.removed);
            assert_eq!(gone.message, format!("garage-rag was not configured in {}", target.display()));

            server.stop().await;
            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn facts_prompts_and_the_graph_answer_over_grpc() {
    common::with_db_url(|pool, url| {
        Box::pin(async move {
            let dir = scratch();
            let config_path = dir.join("garage.json");
            let mut server = Running::start(&url, &config_path).await;
            let client = &mut server.client;

            let prompts = client.list_fact_prompts(proto::ListFactPromptsRequest {}).await.unwrap().into_inner();
            assert_eq!(prompts.configured_json, "[]");
            assert_eq!(prompts.prompts.len(), 1);
            let default = &prompts.prompts[0];
            assert_eq!(default.name, "default");
            assert!(default.builtin && !default.customized && default.enabled);
            assert_eq!(default.sha256, "d39469abe21804eade92ad4cd1b95cb821d8b50951e2d6122bdbca98f9172b92");
            assert!(default.examples_json.starts_with("[{\"text\": \"Acme Corp was founded in 1998"));
            assert!(default.description.starts_with("Extract every standalone fact"));

            let set = |value: &str| proto::SetSettingRequest {
                name: "facts.prompts".into(),
                value: value.into(),
                path: String::new(),
            };
            let configured = concat!(
                "[{\"name\": \"default\", \"enabled\": false, \"sources\": [\"notes\"]}, ",
                "{\"name\": \"people\", \"description\": \"Find people.\", \"examples\": ",
                "[{\"text\": \"Ann met Bob.\", \"extractions\": [{\"class\": \"person\", \"text\": \"Ann\"}]}]}]"
            );
            client.set_setting(set(configured)).await.unwrap();
            let prompts = client.list_fact_prompts(proto::ListFactPromptsRequest {}).await.unwrap().into_inner();
            assert_eq!(prompts.configured_json, configured);
            assert_eq!(prompts.prompts.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["default", "people"]);
            assert!(prompts.prompts[0].customized && !prompts.prompts[0].enabled);
            assert_eq!(prompts.prompts[0].sources, ["notes"]);
            assert_eq!(prompts.prompts[0].sha256, default.sha256, "the built-in's text is kept");
            assert_eq!(
                prompts.prompts[1].examples_json,
                "[{\"text\": \"Ann met Bob.\", \"extractions\": [{\"class\": \"person\", \"text\": \"Ann\", \
                 \"attributes\": {}}]}]"
            );
            let bad = client.set_setting(set("[{\"name\": \"x\"}]")).await.unwrap_err();
            assert_eq!(bad.code(), Code::InvalidArgument);
            assert!(bad.message().contains("'x' is not a built-in prompt, so it needs description and examples"));

            let stats = client.get_fact_stats(proto::FactStatsRequest::default()).await.unwrap().into_inner();
            assert_eq!(stats.formatted_output, "0 facts across 0 documents");
            let listed = client.list_facts(proto::ListFactsRequest::default()).await.unwrap().into_inner();
            assert_eq!(listed.formatted_output, "0 of 0 facts");
            let bad = client
                .list_facts(proto::ListFactsRequest {
                    corpus_class: "mail".into(),
                    ..proto::ListFactsRequest::default()
                })
                .await
                .unwrap_err();
            assert_eq!(bad.code(), Code::InvalidArgument);
            assert!(bad.message().starts_with("unknown corpus class 'mail'"));

            // No graph has been built (and the server may have no AGE): every read says so.
            let labels = client.get_graph_labels(proto::GraphLabelsRequest {}).await.unwrap().into_inner();
            assert!(!labels.available && labels.vertex_labels.is_empty());
            let found = client
                .find_graph_vertices(proto::FindGraphVerticesRequest {
                    query: "x".into(),
                    label: String::new(),
                    limit: 0,
                })
                .await
                .unwrap()
                .into_inner();
            assert!(!found.available);
            let around =
                client.get_graph_neighborhood(proto::GraphNeighborhoodRequest::default()).await.unwrap().into_inner();
            assert!(!around.available && around.center.is_none());

            // ClusterFacts streams its progress and totals; without a model to compare under it
            // says so, and the binary's chat model is asked only when the process can reach one.
            let cluster = |model: &str, threshold: f64, no_distill: bool, no_graph: bool| proto::ClusterFactsRequest {
                model: model.into(),
                threshold,
                neighbors: 0,
                no_distill,
                no_graph,
                full: false,
            };
            let missing = client.cluster_facts(cluster("", 0.0, true, true)).await.unwrap_err();
            assert_eq!(missing.code(), Code::NotFound);
            assert!(missing.message().starts_with("no default model registered"), "{}", missing.message());
            let bad = client.cluster_facts(cluster("", 2.0, true, true)).await.unwrap_err();
            assert_eq!(bad.code(), Code::InvalidArgument);
            assert_eq!(bad.message(), "threshold must be above 0 and at most 1, not 2.0");
            let mut db = pool.get().await.unwrap();
            register_model(&mut db, &ModelSpec::new("tiny", "tiny", 8), true).await.unwrap();
            let no_host = client.cluster_facts(cluster("tiny", 0.0, false, true)).await.unwrap_err();
            assert_eq!(no_host.code(), Code::Unavailable);
            let mut stream = client.cluster_facts(cluster("tiny", 0.0, true, false)).await.unwrap().into_inner();
            let mut events = Vec::new();
            while let Some(event) = stream.message().await.unwrap() {
                events.push(event);
            }
            let finished = events.last().unwrap();
            assert_eq!((finished.phase.as_str(), finished.model.as_str(), finished.full), ("finished", "tiny", true));
            assert_eq!(
                finished.message,
                "0 potential facts distilled into 0; 0 of those group 0 restatements; regrouped the corpus"
            );
            assert!(finished.graph.is_empty() || finished.graph.starts_with("graph 'garage': "), "{}", finished.graph);
            assert!(events.iter().all(|e| e.phase == "finished" || !e.message.is_empty()));
            let params_key: String = db.query_one("SELECT params FROM fact_cluster_state", &[]).await.unwrap().get(0);
            assert_eq!(params_key, "t=0.9;s=0.95;d=0.05;g=50;r=4");
            server.stop().await;
        })
    });
}

#[test]
fn enrich_facts_streams_over_grpc() {
    common::with_db_url(|pool, url| {
        Box::pin(async move {
            let dir = scratch();
            let config_path = dir.join("garage.json");
            let mut server = Running::start(&url, &config_path).await;
            let client = &mut server.client;
            let db = pool.get().await.unwrap();
            let mail = common::source(&db, "mail", json!({})).await;
            let content = "Subject: Lunch\nFrom: ada@example.com\nTo: bob@example.com\n\nNoon?";
            let letter = common::document(&db, mail, "lunch.eml", content, "communication").await;
            db.execute(
                "UPDATE documents SET meta = '{\"email_from\": \"ada@example.com\", \"email_to\": \"bob@example.com\"}' \
                 WHERE id = $1",
                &[&letter],
            )
            .await
            .unwrap();

            let request = |source: &str, document_id: i64, model: &str, prompts: &[&str]| proto::EnrichFactsRequest {
                source: source.into(),
                document_id,
                model: model.into(),
                provider: String::new(),
                prompts: prompts.iter().map(|p| (*p).to_owned()).collect(),
                stale_only: false,
            };
            // This server has no extractor: the metadata facts are written, the prompt fails.
            let mut stream = client.enrich_facts(request("*", 0, "", &[])).await.unwrap().into_inner();
            let mut statuses = Vec::new();
            while let Some(status) = stream.message().await.unwrap() {
                statuses.push(status);
            }
            assert_eq!(
                statuses.iter().map(|s| s.phase.as_str()).collect::<Vec<_>>(),
                ["started", "document", "finished"]
            );
            assert_eq!(statuses[0].message, "enriching 1 document(s) via llama_xpc/gemma2-2b");
            assert_eq!((statuses[0].total, statuses[0].model.as_str()), (1, "gemma2-2b"));
            let doc = &statuses[1];
            assert_eq!(
                (doc.index, doc.document_id, doc.document_uri.as_str(), doc.facts),
                (1, letter, "test://lunch.eml", 3)
            );
            assert_eq!(doc.prompts, ["metadata"]);
            assert!(
                doc.error.starts_with("fact extraction with a model is not available in this build"),
                "{}",
                doc.error
            );
            assert_eq!(doc.message, format!("1/1: test://lunch.eml: {}", doc.error));
            let done = &statuses[2];
            assert_eq!((done.total, done.enriched, done.failed, done.skipped, done.facts), (1, 0, 1, 0, 3));
            assert_eq!(done.prompts, ["default"]);
            assert_eq!(done.provider, "llama_xpc");
            assert_eq!(done.message, "0/1 documents enriched, 3 facts extracted, 1 failed");
            let facts: i64 = common::scalar(&db, "SELECT count(*) FROM facts WHERE document_id = $1", &[&letter]).await;
            assert_eq!(facts, 3);

            let refused = client.enrich_facts(request("*", 0, "gpt-4o", &[])).await.unwrap_err();
            assert_eq!(refused.code(), Code::InvalidArgument);
            assert!(refused.message().starts_with("'gpt-4o' names a cloud-hosted model"), "{}", refused.message());
            let missing = client.enrich_facts(request("*", 999, "", &[])).await.unwrap_err();
            assert_eq!((missing.code(), missing.message()), (Code::NotFound, "document 999 not found"));
            let none = client.enrich_facts(request("nothing", 0, "", &[])).await.unwrap_err();
            assert_eq!((none.code(), none.message()), (Code::NotFound, "no documents to enrich"));
            let unknown = client.enrich_facts(request("*", 0, "", &["nope"])).await.unwrap_err();
            assert_eq!(
                (unknown.code(), unknown.message()),
                (Code::NotFound, "unknown fact prompt(s) nope; known: default")
            );
            server.stop().await;
        })
    });
}

/// An Ollama that answers `/api/embed` with one 8-wide vector per input.
struct FakeOllama {
    calls: std::sync::Mutex<Vec<Value>>,
}

impl garage_embed::Host for FakeOllama {
    fn http(&self, request: &garage_embed::HttpRequest) -> Result<garage_embed::HttpResponse, String> {
        assert_eq!(request.url, "http://localhost:11434/api/embed");
        let body: Value = serde_json::from_slice(&request.body).unwrap();
        let inputs = match &body["input"] {
            Value::Array(items) => items.len(),
            Value::String(_) => 1,
            other => panic!("unexpected input {other}"),
        };
        self.calls.lock().unwrap().push(body);
        let embeddings: Vec<Vec<f32>> =
            (0..inputs).map(|i| (0..8).map(|d| if d == i % 8 { 1.0 } else { 0.0 }).collect()).collect();
        let reply = json!({"embeddings": embeddings});
        Ok(garage_embed::HttpResponse { status: 200, body: reply.to_string().into_bytes() })
    }
}

/// Every status the stream carries.
async fn collect(client: &mut Client, request: proto::BackfillRequest) -> Vec<proto::BackfillStatus> {
    let mut stream = client.backfill(request).await.unwrap().into_inner();
    let mut statuses = Vec::new();
    while let Some(status) = stream.message().await.unwrap() {
        statuses.push(status);
    }
    statuses
}

#[test]
fn backfill_runs_the_embed_worker_in_process_and_streams_its_progress() {
    common::with_db_url(|pool, url| {
        Box::pin(async move {
            let dir = scratch();
            let config_path = dir.join("garage.json");
            let ollama = Arc::new(FakeOllama { calls: std::sync::Mutex::new(Vec::new()) });
            let mut server = Running::start_with_host(&url, &config_path, Some(ollama.clone())).await;
            let client = &mut server.client;
            let mut db = pool.get().await.unwrap();
            let spec = ModelSpec { provider: "ollama".into(), ..ModelSpec::new("tiny", "tiny-embed", 8) };
            register_model(&mut db, &spec, true).await.unwrap();
            let notes = common::source(&db, "notes", json!({})).await;
            let first = common::chunk(&db, notes, "a.md", "alpha", "document").await;
            common::chunk(&db, notes, "b.md", "beta", "document").await;
            common::chunk(&db, notes, "c.eml", "a message", "communication").await;

            let statuses = collect(
                client,
                proto::BackfillRequest { model: "tiny".into(), batch_size: 2, limit: 0, skip_verify: false },
            )
            .await;
            let phases: Vec<&str> = statuses.iter().map(|s| s.phase.as_str()).collect();
            assert_eq!(phases, ["started", "progress", "progress", "finished"], "{statuses:?}");
            assert_eq!(statuses[0].message, "tiny: embedding 3 chunks");
            let done = statuses.last().unwrap();
            assert_eq!((done.total, done.embedded, done.failed, done.remaining, done.batches), (3, 3, 0, 0, 2));
            assert_eq!(done.message, "tiny: embedded 3");
            let stored: i64 = common::scalar(&db, "SELECT count(*) FROM emb_tiny", &[]).await;
            assert_eq!(stored, 3);
            let vector: Vec<f32> = {
                let text: String =
                    common::scalar(&db, "SELECT embedding::text FROM emb_tiny WHERE chunk_id = $1", &[&first]).await;
                text.trim_matches(|c| c == '[' || c == ']').split(',').map(|v| v.parse().unwrap()).collect()
            };
            assert!((vector[0] - 1.0).abs() < 1e-6, "{vector:?}");
            // The probe, then two batches of two and one.
            assert_eq!(ollama.calls.lock().unwrap().len(), 3);

            let again = collect(client, proto::BackfillRequest { model: String::new(), ..Default::default() }).await;
            assert_eq!(
                again.iter().map(|s| (s.phase.as_str(), s.message.as_str())).collect::<Vec<_>>(),
                [("complete", "tiny: already complete")]
            );

            let missing = client.backfill(proto::BackfillRequest { model: "nope".into(), ..Default::default() }).await;
            let missing = match missing {
                Ok(stream) => stream.into_inner().message().await.unwrap_err(),
                Err(status) => status,
            };
            assert_eq!(missing.code(), Code::NotFound, "{missing:?}");
            server.stop().await;
        })
    });
}
