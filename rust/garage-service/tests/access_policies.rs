//! The access policies against a real database (`docs/plans/access-policies.md`), through
//! GarageService as a plain build runs it, with no policy chosen: a throwaway database migrated from
//! `data/sql`, a few documents, rules put through the store and the access calls, and reads over gRPC
//! as each kind of caller. Needs `GARAGE_TEST_DATABASE_URL` (a superuser on a server with pgvector);
//! unset, the tests pass without running.

// Test helpers that take what the calls hand them.
#![allow(clippy::needless_pass_by_value, clippy::unnecessary_wraps, clippy::too_many_lines)]

use std::path::PathBuf;
use std::sync::Arc;

use garage_access_rego::RulesPolicy;
use garage_access_rego::policy::Module;
use garage_access_rego::rules::{Effect, Rule};
use garage_access_rego::store;
use garage_facade::proto;
use garage_facade::proto::garage_service_client::GarageServiceClient;
use garage_service::config::Config;
use garage_service::db::{DatabaseUrl, pool_for};
use garage_service::migrate::apply_migrations;
use garage_service::models::EmbeddingModel;
use garage_service::search::QueryEmbedder;
use garage_service::server::{Endpoint, serve};
use garage_service::service::GarageService;
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tokio_postgres::NoTls;
use tonic::transport::{Channel, Uri};

type Client = GarageServiceClient<Channel>;

fn sql_dir() -> PathBuf {
    garage_service::service::sql_dir(None)
}

fn nonce() -> String {
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{:x}{nanos:x}{n:x}", std::process::id())
}

struct NoEmbedder;

impl QueryEmbedder for NoEmbedder {
    fn embed_query(&self, _: &EmbeddingModel, _: &str) -> garage_service::Result<Vec<f32>> {
        Err(garage_service::ServiceError::failed("keyword search only in these tests"))
    }
}

/// Runs `test` with a fresh migrated database's pool and URL, dropped afterwards.
fn with_db<F>(test: F)
where
    F: FnOnce(deadpool_postgres::Pool, String) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>,
{
    let Some(url) = std::env::var("GARAGE_TEST_DATABASE_URL").ok().filter(|u| !u.trim().is_empty()) else {
        eprintln!("GARAGE_TEST_DATABASE_URL is not set; the rules' database tests did not run");
        return;
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let outcome = runtime.block_on(async {
        let server = DatabaseUrl::parse(&url).unwrap();
        let admin = || async {
            let (client, connection) = server.to_config().connect(NoTls).await.unwrap();
            tokio::spawn(connection);
            client
        };
        let name = format!("garage_test_access_{}", nonce());
        admin().await.batch_execute(&format!("CREATE DATABASE \"{name}\"")).await.unwrap();
        let db_url = server.with_database(&name).to_url();
        let pool = pool_for(&db_url).unwrap();
        apply_migrations(&pool.get().await.unwrap(), &sql_dir()).await.unwrap();
        let outcome = tokio::spawn(test(pool.clone(), db_url)).await;
        pool.close();
        admin().await.batch_execute(&format!("DROP DATABASE IF EXISTS \"{name}\" WITH (FORCE)")).await.unwrap();
        outcome
    });
    if let Err(error) = outcome
        && let Ok(panic) = error.try_into_panic()
    {
        std::panic::resume_unwind(panic);
    }
}

struct Running {
    client: Client,
    stop: tokio::sync::oneshot::Sender<()>,
    task: tokio::task::JoinHandle<std::io::Result<()>>,
}

async fn start(database_url: &str) -> Running {
    let dir = std::env::temp_dir().join(format!("garage-access-rules-{}", nonce()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut config = Config::default();
    config.set_field("database_url", Value::String(database_url.to_owned()));
    // No policy chosen: a plain build holds reads to the Rego policy.
    let service = GarageService::new(config, Arc::new(NoEmbedder), sql_dir(), true).unwrap();
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
    Running { client: Client::new(channel), stop, task }
}

async fn source(db: &tokio_postgres::Client, slug: &str) -> i64 {
    db.query_one(
        "INSERT INTO sources (slug, kind, root, default_trust, config) VALUES ($1, 'filesystem', '/tmp', 'authored', '{}') RETURNING id",
        &[&slug],
    )
    .await
    .unwrap()
    .get(0)
}

/// A document of one chunk; its id.
async fn document(db: &tokio_postgres::Client, source_id: i64, title: &str, body: &str, class: &str) -> i64 {
    let digest: Vec<u8> = db.query_one("SELECT sha256($1)", &[&body.as_bytes()]).await.unwrap().get(0);
    let id: i64 = db
        .query_one(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content, content_sha256, extractor) \
             VALUES ($1, $2, CAST($3::text AS corpus_class), 'authored', $4, $5, $6, 'test') RETURNING id",
            &[&source_id, &format!("/corpus/{title}.md"), &class, &title, &body, &digest],
        )
        .await
        .unwrap()
        .get(0);
    db.execute(
        "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker) VALUES ($1, 0, $2, $3, 'test')",
        &[&id, &body, &digest],
    )
    .await
    .unwrap();
    id
}

/// Replaces a document's one chunk and its content hash, as a re-ingest does.
async fn rewrite(db: &tokio_postgres::Client, id: i64, body: &str) {
    let digest: Vec<u8> = db.query_one("SELECT sha256($1)", &[&body.as_bytes()]).await.unwrap().get(0);
    db.execute("UPDATE documents SET content = $2, content_sha256 = $3 WHERE id = $1", &[&id, &body, &digest])
        .await
        .unwrap();
    db.execute("UPDATE chunks SET text = $2, chunk_sha256 = $3 WHERE document_id = $1", &[&id, &body, &digest])
        .await
        .unwrap();
}

fn caller(token: &str) -> Option<proto::CorpusCaller> {
    Some(proto::CorpusCaller {
        kind: "mcp".into(),
        transport: "stdio".into(),
        registration_token: token.into(),
        ..Default::default()
    })
}

async fn mcp_titles(client: &mut Client, token: &str, query: &str) -> Vec<String> {
    let request = proto::CorpusSearchRequest {
        caller: caller(token),
        query: query.into(),
        mode: "fts".into(),
        limit: 20,
        ..Default::default()
    };
    let result: Value =
        serde_json::from_str(&client.corpus_search(request).await.unwrap().into_inner().result_json).unwrap();
    let mut titles: Vec<String> =
        result["hits"].as_array().unwrap().iter().map(|h| h["title"].as_str().unwrap().to_owned()).collect();
    titles.sort();
    titles
}

async fn app_titles(client: &mut Client, query: &str) -> Vec<String> {
    let request = proto::SearchRequest { query: query.into(), mode: "fts".into(), limit: 20, ..Default::default() };
    let mut titles: Vec<String> =
        client.search(request).await.unwrap().into_inner().hits.into_iter().map(|h| h.title).collect();
    titles.sort();
    titles
}

fn rule(value: Value) -> Rule {
    Rule::from_json(&value).unwrap()
}

/// Registers an MCP client in a scratch config through McpInstall; its token.
async fn register(client: &mut Client, name: &str) -> String {
    let path = std::env::temp_dir().join(format!("garage-access-client-{}.json", nonce()));
    let request = proto::McpInstallRequest {
        path: path.to_string_lossy().into_owned(),
        name: name.into(),
        stdio: true,
        ..Default::default()
    };
    client.mcp_install(request).await.unwrap();
    let written: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    written["mcpServers"][name]["env"]["GARAGE_MCP_TOKEN"].as_str().unwrap().to_owned()
}

#[test]
fn deny_rules_hide_documents_from_the_targets_they_name() {
    with_db(|pool, url| {
        Box::pin(async move {
            let db = pool.get().await.unwrap();
            let notes = source(&db, "notes").await;
            let mail = source(&db, "mail").await;
            document(&db, notes, "plan", "The project plan for the heat pump install.", "document").await;
            document(&db, notes, "keys", "heat pump controller -----BEGIN RSA PRIVATE KEY----- abc", "document").await;
            document(&db, mail, "letter", "Your heat pump invoice is attached.", "communication").await;
            let Running { mut client, stop, task } = start(&url).await;
            let everything = ["keys", "letter", "plan"];

            // No rules: every caller reads as before, and the tables appear on the first read.
            assert_eq!(mcp_titles(&mut client, "", "heat pump").await, everything);
            let claude = register(&mut client, "claude").await;
            let cursor = register(&mut client, "cursor").await;
            let claude_id: String =
                db.query_one("SELECT id FROM mcp_registrations WHERE name = 'claude'", &[]).await.unwrap().get(0);

            store::put_rule(
                &db,
                &rule(json!({"name": "no-keys", "effect": "deny", "targets": ["mcp:*"],
                "match": {"regex": "BEGIN [A-Z ]*PRIVATE KEY"}})),
            )
            .await
            .unwrap();
            store::put_rule(
                &db,
                &rule(json!({"name": "no-mail-for-claude", "effect": "deny",
                "targets": [format!("mcp:{claude_id}")], "match": {"corpus_class": "communication"}})),
            )
            .await
            .unwrap();

            assert_eq!(mcp_titles(&mut client, &claude, "heat pump").await, ["plan"]);
            assert_eq!(mcp_titles(&mut client, &cursor, "heat pump").await, ["letter", "plan"]);
            assert_eq!(mcp_titles(&mut client, "", "heat pump").await, ["letter", "plan"]);
            // The app is not an MCP target.
            assert_eq!(app_titles(&mut client, "heat pump").await, everything);

            // A document whose content changed is pending for the DENY until it is evaluated again,
            // and the next read evaluates it.
            let plan: i64 = db.query_one("SELECT id FROM documents WHERE title = 'plan'", &[]).await.unwrap().get(0);
            rewrite(&db, plan, "heat pump wiring -----BEGIN OPENSSH PRIVATE KEY----- xyz").await;
            assert_eq!(mcp_titles(&mut client, &cursor, "heat pump").await, ["letter"]);

            // Disabling a rule applies to the next read.
            let mut off = rule(json!({"name": "no-keys", "effect": "deny", "targets": ["mcp:*"],
                "match": {"regex": "BEGIN [A-Z ]*PRIVATE KEY"}}));
            off.enabled = false;
            store::put_rule(&db, &off).await.unwrap();
            assert_eq!(mcp_titles(&mut client, &cursor, "heat pump").await, everything);

            // A bad pattern is refused when it is put, not left pending forever.
            let bad = rule(json!({"name": "bad", "effect": "deny", "targets": ["*"], "match": {"regex": "(unclosed"}}));
            assert!(store::put_rule(&db, &bad).await.is_err());
            let _ = stop.send(());
            task.await.unwrap().unwrap();
        })
    });
}

#[test]
fn under_a_deny_default_a_target_sees_only_what_is_allowed() {
    with_db(|pool, url| {
        Box::pin(async move {
            let db = pool.get().await.unwrap();
            let work = source(&db, "work").await;
            let home = source(&db, "home").await;
            document(&db, work, "roadmap", "The heat pump product roadmap.", "document").await;
            document(&db, home, "falcon", "Notes on the falcon acquisition and the heat pump line.", "document").await;
            document(&db, home, "garden", "Planting the heat pump side of the garden.", "document").await;
            let Running { mut client, stop, task } = start(&url).await;
            let token = register(&mut client, "door-test").await;
            let id: String = db.query_one("SELECT id FROM mcp_registrations", &[]).await.unwrap().get(0);
            assert_eq!(mcp_titles(&mut client, &token, "heat pump").await, ["falcon", "garden", "roadmap"]);

            store::set_default(&db, "mcp:*", Some(Effect::Deny)).await.unwrap();
            assert!(mcp_titles(&mut client, &token, "heat pump").await.is_empty());
            let target = format!("mcp:{id}");
            store::put_rule(
                &db,
                &rule(json!({"name": "work", "effect": "allow", "targets": [target], "match": {"source": ["work"]}})),
            )
            .await
            .unwrap();
            store::put_rule(&db, &rule(json!({"name": "falcon", "effect": "allow", "targets": [target], "match": {"term": "falcon acquisition"}})))
                .await
                .unwrap();
            assert_eq!(mcp_titles(&mut client, &token, "heat pump").await, ["falcon", "roadmap"]);
            // A DENY wins over an ALLOW, whatever the order.
            store::put_rule(&db, &rule(json!({"name": "no-falcon", "effect": "deny", "targets": ["mcp:*"], "match": {"path": "/corpus/falcon*"}})))
                .await
                .unwrap();
            assert_eq!(mcp_titles(&mut client, &token, "heat pump").await, ["roadmap"]);
            // An unregistered caller falls under mcp:* too.
            assert!(mcp_titles(&mut client, "", "heat pump").await.is_empty());
            store::set_default(&db, "mcp:unregistered", Some(Effect::Allow)).await.unwrap();
            assert_eq!(mcp_titles(&mut client, "", "heat pump").await, ["garden", "roadmap"]);
            let _ = stop.send(());
            task.await.unwrap().unwrap();
        })
    });
}

#[test]
fn a_stored_rego_policy_decides_and_test_access_shows_it() {
    with_db(|pool, url| {
        Box::pin(async move {
            let db = pool.get().await.unwrap();
            let notes = source(&db, "notes").await;
            let mail = source(&db, "mail").await;
            document(&db, notes, "plan", "The heat pump plan.", "document").await;
            document(&db, mail, "letter", "Your heat pump invoice.", "communication").await;
            let Running { mut client, stop, task } = start(&url).await;
            assert_eq!(mcp_titles(&mut client, "", "heat pump").await, ["letter", "plan"]);
            let claude = register(&mut client, "claude").await;
            let claude_id: String =
                db.query_one("SELECT id FROM mcp_registrations WHERE name = 'claude'", &[]).await.unwrap().get(0);

            // A module that would fail every read is refused when it is put.
            let broken = Module { name: "broken".into(), rego: "package garage.access\n\ndecision := ".into() };
            assert!(store::put_policy(&db, &broken, true).await.is_err());

            // Through the command: assistants never see mail, on top of the rules.
            let rego = r#"package garage.access

decision := {"boundaries": array.concat(data.garage.access.rules.decision.boundaries, extra)}

extra := [{"default": "allow", "deny": [{"corpus_class": "communication"}]}] if {
    input.caller.kind == "mcp"
} else := []
"#;
            // Through the access calls, as the Access page and `garage access` make them.
            let put = |rego: &str, check_only: bool| proto::PutAccessPolicyRequest {
                policy: Some(proto::AccessPolicy {
                    name: "no-mail".into(),
                    rego: rego.into(),
                    enabled: true,
                    ..Default::default()
                }),
                check_only,
            };
            let error = client.put_access_policy(put(&broken.rego, true)).await.unwrap_err();
            assert_eq!(error.code(), tonic::Code::InvalidArgument, "{error:?}");
            client.put_access_policy(put(rego, true)).await.unwrap();
            assert!(
                client
                    .list_access_policies(proto::ListAccessPoliciesRequest {})
                    .await
                    .unwrap()
                    .into_inner()
                    .policies
                    .is_empty(),
                "check_only stores nothing"
            );

            // A draft is tried before it is saved: `TestAccess` decides with it and changes nothing.
            let tried = client
                .test_access(proto::TestAccessRequest {
                    caller: format!("mcp:{claude_id}"),
                    draft: put(rego, false).policy,
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(tried.policies, ["no-mail"]);
            assert!(!tried.sees_everything);
            assert_eq!(mcp_titles(&mut client, &claude, "heat pump").await, ["letter", "plan"]);

            client.put_access_policy(put(rego, false)).await.unwrap();
            let listed = client.list_access_policies(proto::ListAccessPoliciesRequest {}).await.unwrap().into_inner();
            assert!(listed.editable, "{listed:?}");
            assert_eq!(listed.engine, RulesPolicy::NAME);
            assert!(listed.builtin_rego.contains("package garage.access.rules"));
            assert_eq!(listed.policies.len(), 1);
            assert_eq!(listed.policies[0].name, "no-mail");
            assert!(
                listed
                    .callers
                    .iter()
                    .any(|c| c.caller == format!("mcp:{claude_id}") && c.label.starts_with("claude ("))
            );
            assert_eq!(listed.callers[0].caller, "app");
            assert!(listed.policies[0].enabled && !listed.policies[0].updated_at.is_empty());

            // The next read is held to it; the app is not.
            assert_eq!(mcp_titles(&mut client, &claude, "heat pump").await, ["plan"]);
            assert_eq!(app_titles(&mut client, "heat pump").await, ["letter", "plan"]);

            // `TestAccess` shows the targets, the decision and the SQL, and writes nothing.
            let tested = client
                .test_access(proto::TestAccessRequest { caller: format!("mcp:{claude_id}"), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(tested.targets, [format!("mcp:{claude_id}")]);
            assert_eq!(tested.policies, ["no-mail"]);
            assert_eq!(tested.registration_name, "claude");
            assert!(tested.filter_sql.contains("d.corpus_class::text = ANY($1::text[])"), "{tested:?}");
            assert_eq!(tested.filter_params, [r#"["communication"]"#]);
            let app = client
                .test_access(proto::TestAccessRequest { caller: "app".into(), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert!(app.sees_everything, "{app:?}");
            let error = client
                .test_access(proto::TestAccessRequest { caller: format!("door:{claude_id}"), ..Default::default() })
                .await
                .unwrap_err();
            assert!(error.message().contains(&format!("use mcp:{claude_id}")), "{error:?}");

            // Removing it returns the decision to the rules alone.
            client.remove_access_policy(proto::RemoveAccessPolicyRequest { name: "no-mail".into() }).await.unwrap();
            assert_eq!(mcp_titles(&mut client, &claude, "heat pump").await, ["letter", "plan"]);
            let error = client
                .remove_access_policy(proto::RemoveAccessPolicyRequest { name: "no-mail".into() })
                .await
                .unwrap_err();
            assert_eq!(error.code(), tonic::Code::NotFound);
            let _ = stop.send(());
            task.await.unwrap().unwrap();
        })
    });
}

#[test]
fn a_tools_policy_withholds_mcp_tools() {
    with_db(|_pool, url| {
        Box::pin(async move {
            let Running { mut client, stop, task } = start(&url).await;
            let claude = register(&mut client, "claude").await;
            let offered: Vec<String> = garage_mcp::tools::tool_names();
            let tools = |token: &str| proto::CorpusToolsRequest { caller: caller(token), tools: offered.clone() };

            // Nothing stored: every tool, for every caller.
            assert_eq!(client.corpus_tools(tools(&claude)).await.unwrap().into_inner().allowed, offered);

            // Unregistered assistants lose the model tools; a registered one keeps them.
            let rego = r#"package garage.tools

deny contains name if {
    input.caller.kind == "mcp"
    input.caller.registration == null
    some name in {"rag_ask", "rag_generate", "rag_agent"}
}
"#;
            let policy = proto::AccessPolicy {
                name: "no-models".into(),
                rego: rego.into(),
                enabled: true,
                ..Default::default()
            };
            client
                .put_access_policy(proto::PutAccessPolicyRequest { policy: Some(policy), check_only: false })
                .await
                .unwrap();
            let unregistered = client.corpus_tools(tools("")).await.unwrap().into_inner().allowed;
            assert!(unregistered.contains(&"rag_search".to_owned()));
            for withheld in ["rag_ask", "rag_generate", "rag_agent"] {
                assert!(!unregistered.contains(&withheld.to_owned()), "{unregistered:?}");
            }
            assert_eq!(client.corpus_tools(tools(&claude)).await.unwrap().into_inner().allowed, offered);

            // TestAccess shows an assistant's tools, and none for the app.
            let tested = client
                .test_access(proto::TestAccessRequest { caller: "mcp:unregistered".into(), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(tested.tools, unregistered);
            assert_eq!(tested.withheld_tools, ["rag_ask", "rag_generate", "rag_agent"]);
            let app = client
                .test_access(proto::TestAccessRequest { caller: "app".into(), ..Default::default() })
                .await
                .unwrap()
                .into_inner();
            assert!(app.tools.is_empty());

            // A tools module that takes the built-in decision is refused when it is checked.
            let taken = proto::AccessPolicy {
                name: "taken".into(),
                rego: "package garage.tools\n\ndecision := {\"allowed\": []}\n".into(),
                enabled: true,
                ..Default::default()
            };
            let error = client
                .put_access_policy(proto::PutAccessPolicyRequest { policy: Some(taken), check_only: true })
                .await
                .unwrap_err();
            assert_eq!(error.code(), tonic::Code::InvalidArgument, "{error:?}");
            let _ = stop.send(());
            task.await.unwrap().unwrap();
        })
    });
}

/// A caller as the node's end of Garage Door passes it along (garage-enterprise's `DoorContext::to_caller`).
fn door_caller(route: &str, privacy: &str) -> Option<proto::CorpusCaller> {
    Some(proto::CorpusCaller {
        kind: "mcp".into(),
        transport: "http".into(),
        attributes: [("garage-door-route", route), ("garage-door-privacy", privacy)]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect(),
        ..Default::default()
    })
}

#[test]
fn a_privacy_level_is_a_base_policy_a_stored_module_modifies() {
    with_db(|pool, url| {
        Box::pin(async move {
            let db = pool.get().await.unwrap();
            let notes = source(&db, "notes").await;
            document(&db, notes, "plan", "harbour plan", "document").await;
            document(&db, notes, "chat", "harbour chat", "communication").await;
            let Running { mut client, stop, task } = start(&url).await;
            let offered: Vec<String> = garage_mcp::tools::tool_names();
            let search = |caller: Option<proto::CorpusCaller>| proto::CorpusSearchRequest {
                caller,
                query: "harbour".into(),
                mode: "fts".into(),
                limit: 20,
                ..Default::default()
            };
            let titles = async |client: &mut Client, caller: Option<proto::CorpusCaller>| -> Vec<String> {
                let result: Value =
                    serde_json::from_str(&client.corpus_search(search(caller)).await.unwrap().into_inner().result_json)
                        .unwrap();
                let mut titles: Vec<String> = result["hits"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|h| h["title"].as_str().unwrap().to_owned())
                    .collect();
                titles.sort();
                titles
            };
            let tools =
                |caller: Option<proto::CorpusCaller>| proto::CorpusToolsRequest { caller, tools: offered.clone() };

            // Nothing stored: a hosted assistant is in at providers and shut out below it.
            assert_eq!(titles(&mut client, door_caller("web", "4")).await, ["chat", "plan"]);
            assert!(titles(&mut client, door_caller("web", "3")).await.is_empty());
            assert!(client.corpus_tools(tools(door_caller("web", "3"))).await.unwrap().into_inner().allowed.is_empty());
            assert_eq!(
                client.corpus_tools(tools(door_caller("web", "4"))).await.unwrap().into_inner().allowed,
                offered
            );
            // The node is never shut to itself.
            assert_eq!(app_titles(&mut client, "harbour").await, ["chat", "plan"]);

            // A modification: assistants a level early, without communications.
            let rego = r#"package garage.privacy

import data.garage.privacy.levels

open_routes contains "web" if levels.level >= 3

deny contains {"corpus_class": "communication"} if levels.route == "web"
"#;
            let policy = proto::AccessPolicy {
                name: "assistants-early".into(),
                rego: rego.into(),
                enabled: true,
                ..Default::default()
            };
            client
                .put_access_policy(proto::PutAccessPolicyRequest { policy: Some(policy), check_only: false })
                .await
                .unwrap();
            assert_eq!(titles(&mut client, door_caller("web", "3")).await, ["plan"]);
            assert_eq!(titles(&mut client, door_caller("web", "4")).await, ["plan"]);
            assert!(titles(&mut client, door_caller("web", "2")).await.is_empty());
            assert_eq!(app_titles(&mut client, "harbour").await, ["chat", "plan"]);

            // A modification that is not a set is refused when it is checked.
            let scalar = proto::AccessPolicy {
                name: "scalar".into(),
                rego: "package garage.privacy\n\nopen_routes := \"web\"\n".into(),
                enabled: true,
                ..Default::default()
            };
            let error = client
                .put_access_policy(proto::PutAccessPolicyRequest { policy: Some(scalar), check_only: true })
                .await
                .unwrap_err();
            assert_eq!(error.code(), tonic::Code::InvalidArgument, "{error:?}");
            let _ = stop.send(());
            task.await.unwrap().unwrap();
        })
    });
}
