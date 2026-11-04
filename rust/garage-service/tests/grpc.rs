//! The service over gRPC, as its clients reach it: a Unix socket and a TCP port, the per-launch
//! token (`test_service_auth.py`'s rules) and the config-changing methods' guard. The calls that
//! need a database run only when `GARAGE_TEST_DATABASE_URL` is set.

mod common;

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use garage_facade::proto;
use garage_facade::proto::garage_service_client::GarageServiceClient;
use garage_service::auth::{METADATA_KEY, config_change_allowed};
use garage_service::config::Config;
use garage_service::models::EmbeddingModel;
use garage_service::search::QueryEmbedder;
use garage_service::server::{Endpoint, serve};
use garage_service::service::{GarageService, VERSION, sql_dir};
use hyper_util::rt::TokioIo;
use tonic::Code;
use tonic::metadata::MetadataValue;
use tonic::transport::{Channel, Uri};

struct NoEmbedder;

impl QueryEmbedder for NoEmbedder {
    fn embed_query(&self, _: &EmbeddingModel, _: &str) -> garage_service::Result<Vec<f32>> {
        Err(garage_service::ServiceError::failed("no model in this test"))
    }
}

/// A server on `endpoint`, stopped when dropped.
struct Running {
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}

impl Running {
    async fn start(endpoint: Endpoint, token: Option<&str>, database_url: Option<&str>) -> Self {
        let mut config = Config::default();
        if let Some(url) = database_url {
            config.set_field("database_url", serde_json::Value::String(url.to_owned()));
        }
        let vouched = config_change_allowed(token.is_some(), matches!(endpoint, Endpoint::Unix(_)));
        let service = GarageService::new(config, Arc::new(NoEmbedder), sql_dir(None), vouched).unwrap();
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let token = token.map(str::to_owned);
        let served = endpoint.clone();
        let task = tokio::spawn(async move {
            serve(service, &served, token.as_deref(), async {
                let _ = stopped.await;
            })
            .await
        });
        // Until the listener answers.
        for _ in 0..100 {
            let up = match &endpoint {
                Endpoint::Unix(path) => tokio::net::UnixStream::connect(path).await.is_ok(),
                Endpoint::Tcp(addr) => tokio::net::TcpStream::connect(addr).await.is_ok(),
            };
            if up {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        Self { stop: Some(stop), task: Some(task) }
    }

    async fn stop(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.task.take().unwrap().await.unwrap().unwrap();
    }
}

async fn unix_channel(path: &Path) -> Channel {
    let path = path.to_path_buf();
    tonic::transport::Endpoint::from_static("http://garage")
        .connect_with_connector(tower::service_fn(move |_: Uri| {
            let path = path.clone();
            async move { Ok::<_, std::io::Error>(TokioIo::new(tokio::net::UnixStream::connect(path).await?)) }
        }))
        .await
        .unwrap()
}

async fn tcp_channel(addr: std::net::SocketAddr) -> Channel {
    tonic::transport::Endpoint::from_shared(format!("http://{addr}")).unwrap().connect().await.unwrap()
}

type Client = GarageServiceClient<Channel>;

fn with_token(token: &str) -> impl Fn(tonic::Request<()>) -> Result<tonic::Request<()>, tonic::Status> + Clone {
    let value = MetadataValue::try_from(token).unwrap();
    move |mut request: tonic::Request<()>| {
        request.metadata_mut().insert(METADATA_KEY, value.clone());
        Ok(request)
    }
}

fn socket_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("garage-service-grpc-{}-{}", std::process::id(), common::nonce()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn free_port() -> std::net::SocketAddr {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap()
}

fn run(test: impl Future<Output = ()>) {
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(test);
}

#[test]
fn a_unix_socket_server_answers_without_a_token_and_vouches_for_its_callers() {
    run(async {
        let dir = socket_dir();
        let socket = dir.join("grpc");
        let server = Running::start(Endpoint::Unix(socket.clone()), None, None).await;
        let mut client = Client::new(unix_channel(&socket).await);

        let pong = client.ping(proto::PingRequest { message: String::new() }).await.unwrap().into_inner();
        assert_eq!(pong.message, "pong");
        assert!(pong.timestamp > 0);
        let echo = client.ping(proto::PingRequest { message: "hi".into() }).await.unwrap().into_inner();
        assert_eq!(echo.message, "hi");
        assert_eq!(client.get_version(proto::VersionRequest {}).await.unwrap().into_inner().version, VERSION);
        let setting =
            client.get_setting(proto::GetSettingRequest { name: "facts.provider".into() }).await.unwrap().into_inner();
        assert_eq!(setting.value_json, "\"llama_xpc\"");
        let bad = client.get_setting(proto::GetSettingRequest { name: "nope.model".into() }).await.unwrap_err();
        assert_eq!(bad.code(), Code::InvalidArgument);
        // EnsureLlamaModel is answered on the socket; outside the app no loader can load a model.
        let unnamed = client.ensure_llama_model(proto::EnsureLlamaModelRequest::default()).await.unwrap_err();
        assert_eq!((unnamed.code(), unnamed.message()), (Code::InvalidArgument, "model is required"));
        let request = proto::EnsureLlamaModelRequest { model: "gemma2-2b".into() };
        let outside = client.ensure_llama_model(request).await.unwrap_err();
        assert_eq!(outside.code(), Code::FailedPrecondition);
        assert!(
            outside
                .message()
                .starts_with("this process cannot load gemma2-2b: it is not running inside the Garage app."),
            "{}",
            outside.message()
        );
        // Backfill runs the embed worker through the process's host; this server has none.
        let no_host = client.backfill(proto::BackfillRequest::default()).await.unwrap_err();
        assert_eq!(
            (no_host.code(), no_host.message()),
            (Code::Unavailable, "this process has no way to reach a model server")
        );
        // A config change is allowed on the socket: the empty name is what is refused.
        let allowed = client.set_setting(proto::SetSettingRequest::default()).await.unwrap_err();
        assert_eq!(allowed.code(), Code::InvalidArgument);
        assert!(allowed.message().starts_with("expected SECTION.KEY"));
        // Without a database at the other end, GetStatus says so rather than failing the call.
        let status = client.get_status(proto::StatusRequest {}).await.unwrap().into_inner();
        assert!(!status.is_ready);
        assert!(status.db_status.starts_with("error"), "{}", status.db_status);
        assert_eq!(status.version, VERSION);

        server.stop().await;
        assert!(!socket.exists(), "the socket file is removed on shutdown");
        let _ = std::fs::remove_dir_all(dir);
    });
}

#[test]
fn a_tcp_server_without_a_token_refuses_config_changes() {
    run(async {
        let addr = free_port();
        let server = Running::start(Endpoint::Tcp(addr), None, None).await;
        let mut client = Client::new(tcp_channel(addr).await);
        assert_eq!(client.ping(proto::PingRequest::default()).await.unwrap().into_inner().message, "pong");
        let denied = client.init_db(proto::InitDbRequest::default()).await.unwrap_err();
        assert_eq!(denied.code(), Code::PermissionDenied);
        assert!(denied.message().contains("InitDb"), "{}", denied.message());
        let denied = client.set_setting(proto::SetSettingRequest::default()).await.unwrap_err();
        assert_eq!(denied.code(), Code::PermissionDenied);
        server.stop().await;
    });
}

#[test]
fn the_token_guards_every_call_but_ensure_llama_model() {
    run(async {
        let dir = socket_dir();
        let socket = dir.join("grpc");
        let server = Running::start(Endpoint::Unix(socket.clone()), Some("s3cret-for-this-test"), None).await;
        let channel = unix_channel(&socket).await;

        let mut bare = Client::new(channel.clone());
        let refused = bare.ping(proto::PingRequest::default()).await.unwrap_err();
        assert_eq!(refused.code(), Code::Unauthenticated);
        assert!(refused.message().contains(METADATA_KEY));
        let later = bare.ensure_llama_model(proto::EnsureLlamaModelRequest::default()).await.unwrap_err();
        assert_eq!(later.code(), Code::InvalidArgument, "EnsureLlamaModel needs no token");

        let mut wrong = GarageServiceClient::with_interceptor(channel.clone(), with_token("s3cret-for-this-tesT"));
        assert_eq!(wrong.ping(proto::PingRequest::default()).await.unwrap_err().code(), Code::Unauthenticated);

        let mut right = GarageServiceClient::with_interceptor(channel, with_token("s3cret-for-this-test"));
        assert_eq!(right.ping(proto::PingRequest::default()).await.unwrap().into_inner().message, "pong");
        // The token vouches for the caller: a config change is allowed (the empty name is refused).
        assert_eq!(
            right.set_setting(proto::SetSettingRequest::default()).await.unwrap_err().code(),
            Code::InvalidArgument
        );

        server.stop().await;
        let _ = std::fs::remove_dir_all(dir);
    });
}

#[test]
fn init_db_status_and_the_corpus_reads_answer_over_grpc() {
    common::with_db_url(|pool, url| {
        Box::pin(async move {
            let dir = socket_dir();
            let socket = dir.join("grpc");
            let server = Running::start(Endpoint::Unix(socket.clone()), None, Some(&url)).await;
            let mut client = Client::new(unix_channel(&socket).await);

            let status = client.get_status(proto::StatusRequest {}).await.unwrap().into_inner();
            assert!(status.is_ready, "{status:?}");
            assert_eq!(status.db_status, "connected");
            // The migrations are re-applied as a whole, as Python's were, and the URL is redacted.
            let init = client.init_db(proto::InitDbRequest::default()).await.unwrap().into_inner();
            assert!(init.applied.len() >= 18 && init.applied[0] == "001_extensions.sql", "{:?}", init.applied);
            assert!(
                init.message.contains("schema ready") && !init.message.contains("garage_dev:garage_dev"),
                "{}",
                init.message
            );

            let c = pool.get().await.unwrap();
            let notes = common::source(&c, "notes", serde_json::json!({})).await;
            common::chunk(&c, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document").await;
            drop(c);

            let counts = client.get_stats(proto::StatsRequest {}).await.unwrap().into_inner();
            assert_eq!((counts.documents, counts.chunks), (1, 1));
            let sources = client.list_sources(proto::ListSourcesRequest {}).await.unwrap().into_inner();
            assert_eq!(sources.sources.iter().map(|s| s.slug.as_str()).collect::<Vec<_>>(), ["notes"]);
            let found = client
                .search(proto::SearchRequest {
                    query: "wild yeast".into(),
                    mode: "fts".into(),
                    limit: 10,
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            assert_eq!(found.hits.len(), 1);
            assert_eq!(found.hits[0].title, "sourdough");
            let rag = client
                .corpus_search(proto::CorpusSearchRequest {
                    query: "wild yeast".into(),
                    mode: "fts".into(),
                    limit: 5,
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            let json: serde_json::Value = serde_json::from_str(&rag.result_json).unwrap();
            assert_eq!(json["count"], 1);
            assert_eq!(json["model"], "n/a");
            assert_eq!(json["hits"][0]["title"], "sourdough");
            let doc = client
                .corpus_document(proto::CorpusDocumentRequest {
                    location: "test://sourdough".into(),
                    ..Default::default()
                })
                .await
                .unwrap()
                .into_inner();
            let json: serde_json::Value = serde_json::from_str(&doc.result_json).unwrap();
            assert_eq!(json["chunk_count"], 1);
            let missing = client.corpus_document(proto::CorpusDocumentRequest::default()).await.unwrap_err();
            assert_eq!(missing.code(), Code::InvalidArgument);

            server.stop().await;
            let _ = std::fs::remove_dir_all(dir);
        })
    });
}
