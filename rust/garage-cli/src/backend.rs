//! GarageService for a command: started in this process on a private Unix-domain socket, as the
//! Python CLI's functions ran in its process, and reached through `garage-facade`'s client, so a
//! command speaks the same wire the app's clients do (`ingest` persists through it, `garage-mcp`
//! reads through it). The socket is owner-only in a folder of its own and vouches for its one
//! caller, so the config-changing calls are answered.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use garage_facade::{Client, Connection, FacadeError, GrpcTarget};
use garage_service::config::Config;
use garage_service::host::{HostEmbedder, PlainHost};
use garage_service::langextract::LangExtractor;
use garage_service::server::{Endpoint, bind, serve_bound};
use garage_service::service::{GarageService, sql_dir};
use tokio::sync::oneshot;

/// Why a command stops, and its exit code: 2 for a bad parameter or configuration, 1 for work that
/// failed, as Typer's `BadParameter`/`Exit(2)` and `Exit(1)`.
#[derive(Debug)]
pub struct Failure {
    pub code: i32,
    pub message: String,
}

impl Failure {
    pub fn usage(message: impl Into<String>) -> Self {
        Self { code: 2, message: message.into() }
    }

    pub fn failed(message: impl Into<String>) -> Self {
        Self { code: 1, message: message.into() }
    }

    /// A failure whose message was already printed.
    pub fn silent(code: i32) -> Self {
        Self { code, message: String::new() }
    }

    /// The same failure with another exit code (a command Typer exited 2 from).
    #[must_use]
    pub fn with_code(mut self, code: i32) -> Self {
        self.code = code;
        self
    }
}

const NOT_FOUND: i32 = 1;

impl From<FacadeError> for Failure {
    fn from(error: FacadeError) -> Self {
        let text = error.to_string();
        let message = text.strip_prefix("GarageService: ").unwrap_or(&text).to_owned();
        let code = if matches!(error, FacadeError::NotFound(_)) { NOT_FOUND } else { 1 };
        Self { code, message }
    }
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Self::failed(message)
    }
}

impl From<garage_service::ServiceError> for Failure {
    fn from(error: garage_service::ServiceError) -> Self {
        match error {
            garage_service::ServiceError::InvalidArgument(message) => Self::usage(message),
            other => Self::failed(other.to_string()),
        }
    }
}

/// The service, serving, and a connection to it.
pub struct Backend {
    runtime: tokio::runtime::Runtime,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
    folder: PathBuf,
    /// Where the service listens, for another process or crate to reach it (`garage_ingest_run`).
    pub socket: PathBuf,
    /// The configuration the service started with.
    pub config: Config,
    connection: Connection,
}

/// Loads the configuration as the Python CLI's callback did: `--config`, else `./garage.json`,
/// then `~/.garage.json`, else the defaults.
///
/// # Errors
///
/// A file that does not load (exit code 2).
pub fn load_config(path: Option<&Path>) -> Result<Config, Failure> {
    Config::load(path).map_err(|error| Failure::usage(format!("[red]config error[/red]: {error}")))
}

impl Backend {
    /// Starts GarageService on `config` and connects to it.
    ///
    /// # Errors
    ///
    /// The configuration does not load, or the socket cannot be bound.
    pub fn start(config: Config) -> Result<Self, Failure> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_name("garage-service")
            .enable_all()
            .build()
            .map_err(|e| Failure::failed(format!("tokio runtime: {e}")))?;
        let host: Arc<dyn garage_embed::Host> = Arc::new(PlainHost::new(runtime.handle().clone()));
        let embedder = Arc::new(HostEmbedder { host: host.clone(), settings: config.embed_settings() });
        let service = GarageService::new(config.clone(), embedder, sql_dir(None), true)
            .map_err(|e| Failure::usage(format!("[red]config error[/red]: {e}")))?
            .with_extractor(Arc::new(LangExtractor::new(host.clone())))
            .with_host(host)
            .with_local_caller(garage_service::garage_access::Caller::cli());
        let folder = std::env::temp_dir().join(format!("garage-cli-{}", std::process::id()));
        let socket = folder.join("grpc");
        let endpoint = Endpoint::Unix(socket.clone());
        let bound = runtime
            .block_on(bind(&endpoint))
            .map_err(|e| Failure::failed(format!("cannot start GarageService in this process: {e}")))?;
        let (shutdown, stopped) = oneshot::channel::<()>();
        let task = runtime.spawn(async move {
            serve_bound(service, bound, None, async {
                let _ = stopped.await;
            })
            .await
        });
        let connection = Connection::connect(&GrpcTarget::Socket(socket.clone()), None)?;
        Ok(Self { runtime, shutdown: Some(shutdown), task: Some(task), folder, socket, config, connection })
    }

    /// The runtime's handle, for work beside the service.
    pub fn handle(&self) -> tokio::runtime::Handle {
        self.runtime.handle().clone()
    }

    /// Runs one call.
    ///
    /// # Errors
    ///
    /// The call's status, with the exit code it means.
    pub fn call<T, F>(&self, call: impl FnOnce(Client) -> F) -> Result<T, Failure>
    where
        F: Future<Output = Result<tonic::Response<T>, tonic::Status>>,
    {
        Ok(self.connection.call(call)?)
    }

    /// Runs a server-streaming call, handing each message to `each` until it returns false.
    ///
    /// # Errors
    ///
    /// As [`Self::call`].
    pub fn stream<T, F>(&self, call: impl FnOnce(Client) -> F, each: impl FnMut(T) -> bool) -> Result<(), Failure>
    where
        F: Future<Output = Result<tonic::Response<tonic::Streaming<T>>, tonic::Status>>,
    {
        Ok(self.connection.stream(call, each)?)
    }
}

impl Drop for Backend {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = self.runtime.block_on(async { tokio::time::timeout(Duration::from_secs(2), task).await });
        }
        let _ = std::fs::remove_dir_all(&self.folder);
    }
}
