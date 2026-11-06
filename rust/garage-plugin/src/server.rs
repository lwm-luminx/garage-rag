//! The out-of-process transport: `ExtractorPlugin` served over gRPC on a Unix-domain socket.
//!
//! A plugin binary's `main` is usually one line, [`main`], which reads the command line the
//! ingester starts plugins with:
//!
//! ```text
//! <plugin> --socket <path> [--exit-with-stdin]
//! ```
//!
//! `--socket` names where to listen. The ingester picks a path in a directory only it can enter;
//! the plugin makes the socket owner-only too. There is deliberately no way to listen on TCP.
//! `--exit-with-stdin` stops the plugin when its standard input closes, which is how a plugin the
//! ingester started ends with the ingester even if the ingester is killed.

use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::io::AsyncReadExt;
use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{Request, Response, Status};

use crate::Plugin;
use crate::proto::extractor_plugin_server::{ExtractorPlugin, ExtractorPluginServer};
use crate::proto::{DescribeRequest, DescribeResponse, ExtractRequest, ExtractResponse};

/// The largest message either side accepts. A request carries a whole file, which the ingester
/// caps at `extraction.max_file_bytes` (64 MiB by default); this leaves room for raising it, and
/// matches the limit the ingester's own gRPC service sets.
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024 * 1024;

/// Serves `plugin` on the Unix-domain socket at `socket` until `shutdown` completes.
///
/// A file already at `socket` is replaced only if it is a socket (a previous run's); anything else
/// there is an error, so a mistyped path cannot delete a document.
///
/// # Errors
///
/// When the socket cannot be bound, or the server fails.
pub async fn serve<P: Plugin>(plugin: P, socket: &Path, shutdown: impl Future<Output = ()>) -> io::Result<()> {
    let listener = bind(socket)?;
    let service = ExtractorPluginServer::new(Service(Arc::new(plugin)))
        .max_decoding_message_size(MAX_MESSAGE_BYTES)
        .max_encoding_message_size(MAX_MESSAGE_BYTES);
    let result = tonic::transport::Server::builder()
        .add_service(service)
        .serve_with_incoming_shutdown(UnixListenerStream::new(listener), shutdown)
        .await;
    let _ = std::fs::remove_file(socket);
    result.map_err(io::Error::other)
}

fn bind(socket: &Path) -> io::Result<UnixListener> {
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};

    match std::fs::symlink_metadata(socket) {
        Ok(meta) if meta.file_type().is_socket() => std::fs::remove_file(socket)?,
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("{} exists and is not a socket", socket.display()),
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(socket)?;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// The command line of a plugin binary.
#[derive(Debug, PartialEq, Eq)]
pub struct Options {
    pub socket: PathBuf,
    pub exit_with_stdin: bool,
}

impl Options {
    /// Parses the arguments after the program name.
    ///
    /// # Errors
    ///
    /// A usage message when they are not `--socket <path> [--exit-with-stdin]`.
    pub fn parse(args: impl IntoIterator<Item = std::ffi::OsString>) -> Result<Self, String> {
        let mut socket = None;
        let mut exit_with_stdin = false;
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.to_str() {
                Some("--socket") => socket = Some(PathBuf::from(args.next().ok_or("--socket needs a path")?)),
                Some("--exit-with-stdin") => exit_with_stdin = true,
                _ => return Err(format!("unexpected argument {}", arg.to_string_lossy())),
            }
        }
        let socket = socket.ok_or("usage: --socket <path> [--exit-with-stdin]")?;
        Ok(Self { socket, exit_with_stdin })
    }
}

/// A plugin binary's whole `main`: parse the command line, serve until SIGINT, SIGTERM or (with
/// `--exit-with-stdin`) the end of standard input, and exit.
pub fn main<P: Plugin>(plugin: P) -> std::process::ExitCode {
    let options = match Options::parse(std::env::args_os().skip(1)) {
        Ok(options) => options,
        Err(usage) => {
            eprintln!("{usage}");
            return std::process::ExitCode::from(2);
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cannot start: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let result = runtime.block_on(serve(plugin, &options.socket, stopped(options.exit_with_stdin)));
    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{}: {error}", options.socket.display());
            std::process::ExitCode::FAILURE
        }
    }
}

async fn stopped(exit_with_stdin: bool) {
    let stdin_closed = async {
        if !exit_with_stdin {
            return std::future::pending().await;
        }
        let mut stdin = tokio::io::stdin();
        let mut sink = [0_u8; 256];
        while let Ok(n) = stdin.read(&mut sink).await {
            if n == 0 {
                break;
            }
        }
    };
    let terminated = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    };
    tokio::select! {
        () = stdin_closed => {}
        () = terminated => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}

struct Service<P>(Arc<P>);

#[tonic::async_trait]
impl<P: Plugin> ExtractorPlugin for Service<P> {
    async fn describe(&self, request: Request<DescribeRequest>) -> Result<Response<DescribeResponse>, Status> {
        let plugin = Arc::clone(&self.0);
        let request = request.into_inner();
        blocking(move || plugin.describe(&request)).await.map(Response::new)
    }

    async fn extract(&self, request: Request<ExtractRequest>) -> Result<Response<ExtractResponse>, Status> {
        let plugin = Arc::clone(&self.0);
        let request = request.into_inner();
        blocking(move || plugin.extract(request)).await.map(Response::new)
    }
}

async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T, Status> {
    tokio::task::spawn_blocking(work).await.map_err(|error| {
        if error.is_panic() {
            Status::internal(format!("plugin panicked: {}", crate::ffi::panic_message(&*error.into_panic())))
        } else {
            Status::cancelled("plugin call cancelled")
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::extract_response::Outcome;
    use crate::proto::extractor_plugin_client::ExtractorPluginClient;
    use hyper_util::rt::TokioIo;
    use tonic::transport::{Endpoint, Uri};

    struct Echo;

    impl Plugin for Echo {
        fn describe(&self, _: &DescribeRequest) -> DescribeResponse {
            DescribeResponse { name: "echo".into(), contract: crate::CONTRACT.into(), ..Default::default() }
        }

        fn extract(&self, request: ExtractRequest) -> ExtractResponse {
            assert!(request.file_name != "panic.txt", "asked to panic");
            ExtractResponse::no_text(format!("{} bytes", request.content.len()))
        }
    }

    async fn client(socket: PathBuf) -> ExtractorPluginClient<tonic::transport::Channel> {
        // The URI is required by the API and ignored by the connector.
        let channel = Endpoint::try_from("http://plugin")
            .unwrap()
            .connect_with_connector(tower::service_fn(move |_: Uri| {
                let socket = socket.clone();
                async move { Ok::<_, io::Error>(TokioIo::new(tokio::net::UnixStream::connect(socket).await?)) }
            }))
            .await
            .unwrap();
        ExtractorPluginClient::new(channel)
            .max_decoding_message_size(MAX_MESSAGE_BYTES)
            .max_encoding_message_size(MAX_MESSAGE_BYTES)
    }

    #[tokio::test]
    async fn serves_on_a_unix_socket() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("plugin.sock");
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn({
            let socket = socket.clone();
            async move { serve(Echo, &socket, async { stopped.await.unwrap() }).await }
        });
        while !socket.exists() {
            tokio::task::yield_now().await;
        }
        assert_eq!(std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);

        let mut client = client(socket.clone()).await;
        let described = client.describe(DescribeRequest::default()).await.unwrap().into_inner();
        assert_eq!(described.name, "echo");

        // A 10 MiB file is well over gRPC's default 4 MiB limit.
        let content = vec![b'a'; 10 * 1024 * 1024];
        let request = ExtractRequest { file_name: "big.txt".into(), content, ..Default::default() };
        let reply = client.extract(request).await.unwrap().into_inner();
        assert!(matches!(reply.outcome, Some(Outcome::NoText(ref n)) if n.reason == "10485760 bytes"));

        let request = ExtractRequest { file_name: "panic.txt".into(), ..Default::default() };
        let status = client.extract(request).await.unwrap_err();
        assert_eq!(status.code(), tonic::Code::Internal);
        assert!(status.message().contains("asked to panic"));

        stop.send(()).unwrap();
        server.await.unwrap().unwrap();
        assert!(!socket.exists(), "the socket is removed on shutdown");
    }

    #[tokio::test]
    async fn never_replaces_a_file_that_is_not_a_socket() {
        let dir = tempfile::tempdir().unwrap();
        let document = dir.path().join("notes.md");
        std::fs::write(&document, "keep me").unwrap();
        let error = serve(Echo, &document, async {}).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read_to_string(&document).unwrap(), "keep me");
    }

    #[test]
    fn parses_the_command_line() {
        let parse = |args: &[&str]| Options::parse(args.iter().map(std::ffi::OsString::from));
        assert_eq!(
            parse(&["--socket", "/tmp/p.sock", "--exit-with-stdin"]),
            Ok(Options { socket: "/tmp/p.sock".into(), exit_with_stdin: true })
        );
        assert!(parse(&[]).is_err());
        assert!(parse(&["--socket"]).is_err());
        assert!(parse(&["--port", "80"]).is_err());
    }
}
