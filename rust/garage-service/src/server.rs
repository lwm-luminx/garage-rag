//! Binding the service: an owner-only Unix-domain socket (`_bind_unix_socket`) or a TCP port, the
//! token layer when `GARAGE_GRPC_TOKEN` is set, and the message size `PersistDocument` needs.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::path::Path;

use garage_facade::proto::garage_service_server::GarageServiceServer;
#[cfg(unix)]
use tokio::net::UnixListener;
#[cfg(unix)]
use tokio_stream::wrappers::UnixListenerStream;

use crate::auth::TokenAuthLayer;
use crate::service::{GarageService, MAX_REQUEST_BYTES};

/// Where a server listens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Endpoint {
    /// A Unix-domain socket at an absolute path, made owner-only.
    Unix(std::path::PathBuf),
    /// A TCP address; loopback unless asked otherwise.
    Tcp(SocketAddr),
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unix(path) => write!(f, "unix:{}", path.display()),
            Self::Tcp(addr) => write!(f, "{addr}"),
        }
    }
}

fn routes(service: GarageService, token: Option<&str>) -> tonic::service::Routes {
    let service = GarageServiceServer::new(service)
        .max_decoding_message_size(MAX_REQUEST_BYTES)
        .max_encoding_message_size(MAX_REQUEST_BYTES);
    match token {
        Some(token) => {
            tonic::service::Routes::new(tower::ServiceBuilder::new().layer(TokenAuthLayer::new(token)).service(service))
        }
        None => tonic::service::Routes::new(service),
    }
}

/// A bound listener, not yet serving: binding first lets a host report a port in use before
/// its server task runs (the app's `startServer` reply), and learn the port of a `:0` bind.
pub enum Bound {
    /// The socket, and its path, removed when serving ends.
    #[cfg(unix)]
    Unix(UnixListener, std::path::PathBuf),
    Tcp(tokio::net::TcpListener),
}

impl Bound {
    /// Where the listener is: the socket path, or the address with the port the kernel chose.
    pub fn endpoint(&self) -> Endpoint {
        match self {
            #[cfg(unix)]
            Self::Unix(_, path) => Endpoint::Unix(path.clone()),
            Self::Tcp(listener) => Endpoint::Tcp(listener.local_addr().unwrap_or_else(|_| ([127, 0, 0, 1], 0).into())),
        }
    }
}

/// Binds `endpoint` on the current runtime.
///
/// # Errors
///
/// When the endpoint cannot be bound (another server answers on the socket, the path is not
/// absolute, something that is not a socket is there, the port is taken), or it is a Unix-domain
/// socket on a platform without them (Windows, where the services answer on a port).
pub async fn bind(endpoint: &Endpoint) -> io::Result<Bound> {
    match endpoint {
        #[cfg(unix)]
        Endpoint::Unix(path) => Ok(Bound::Unix(bind_unix_socket(path)?, path.clone())),
        #[cfg(not(unix))]
        Endpoint::Unix(path) => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            format!("Unix-domain sockets are not available on this platform: {}", path.display()),
        )),
        Endpoint::Tcp(addr) => Ok(Bound::Tcp(tokio::net::TcpListener::bind(addr).await?)),
    }
}

/// Serves `service` on `bound` until `shutdown` completes. With a `token`, every call but
/// `EnsureLlamaModel` must carry it (`TokenAuthInterceptor`).
///
/// # Errors
///
/// When the server fails.
pub async fn serve_bound(
    service: GarageService,
    bound: Bound,
    token: Option<&str>,
    shutdown: impl Future<Output = ()>,
) -> io::Result<()> {
    let mut builder = tonic::transport::Server::builder();
    let router = builder.add_routes(routes(service, token));
    match bound {
        #[cfg(unix)]
        Bound::Unix(listener, path) => {
            let result = router.serve_with_incoming_shutdown(UnixListenerStream::new(listener), shutdown).await;
            let _ = std::fs::remove_file(path);
            result.map_err(io::Error::other)
        }
        Bound::Tcp(listener) => router
            .serve_with_incoming_shutdown(tokio_stream::wrappers::TcpListenerStream::new(listener), shutdown)
            .await
            .map_err(io::Error::other),
    }
}

/// Binds `endpoint` and serves `service` there until `shutdown` completes ([`bind`], then
/// [`serve_bound`]).
///
/// # Errors
///
/// When the endpoint cannot be bound or the server fails.
pub async fn serve(
    service: GarageService,
    endpoint: &Endpoint,
    token: Option<&str>,
    shutdown: impl Future<Output = ()>,
) -> io::Result<()> {
    let bound = bind(endpoint).await?;
    serve_bound(service, bound, token, shutdown).await
}

/// Binds `path`, owner-only, as the Python server did.
///
/// A socket file left by a server that died is removed first. A socket something still answers
/// on is another server's: unlinking it would take the path from under that server's clients, so
/// the bind fails instead. Anything else at the path is left alone and the bind fails too. The
/// probe, the unlink and the bind run under an exclusive lock on `<path>.lock`, so two servers
/// recovering the same stale socket at once take turns. The lock file is left in place: it lives
/// in the owner-only socket folder, and removing it would let a third server lock a fresh inode
/// while another still holds the old one.
///
/// # Errors
///
/// As above, or any I/O error of the folder, the lock or the bind.
#[cfg(unix)]
pub fn bind_unix_socket(path: &Path) -> io::Result<UnixListener> {
    use std::os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt};

    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("gRPC socket path must be absolute: {}", path.display()),
        ));
    }
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    let lock = socket_recovery_lock(path)?;
    let result = (|| {
        match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.file_type().is_socket() => {
                if unix_socket_is_stale(path) {
                    std::fs::remove_file(path)?;
                } else {
                    return Err(io::Error::new(
                        io::ErrorKind::AddrInUse,
                        format!(
                            "another server is listening on the gRPC socket {}; not binding over it",
                            path.display()
                        ),
                    ));
                }
            }
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "could not bind the gRPC socket {}: something that is not a socket is there",
                        path.display()
                    ),
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(listener)
    })();
    // SAFETY: `lock` is an open file descriptor this function owns; LOCK_UN only releases its lock.
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
    result
}

/// Opens `<socket>.lock` (0600) and takes an exclusive `flock` on it (`_socket_recovery_lock`).
#[cfg(unix)]
fn socket_recovery_lock(socket: &Path) -> io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut name = socket.file_name().map(std::ffi::OsString::from).unwrap_or_default();
    name.push(".lock");
    let lock_path = socket.with_file_name(name);
    let file =
        std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(lock_path)?;
    // SAFETY: `file` is an open descriptor; flock takes no other memory.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

/// True when nothing accepts connections on the socket file: a connect is refused, or the file
/// is gone (`_unix_socket_is_stale`). Any other failure means in use, or not ours to judge.
#[cfg(unix)]
pub fn unix_socket_is_stale(socket: &Path) -> bool {
    match std::os::unix::net::UnixStream::connect(socket) {
        Ok(_) => false,
        Err(error) => matches!(error.kind(), io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn stale_sockets_are_recovered_and_live_ones_kept() {
        let dir = std::env::temp_dir().join(format!("garage-service-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let socket = dir.join("grpc");
        assert!(unix_socket_is_stale(&socket));
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let _guard = runtime.enter();
        let listener = bind_unix_socket(&socket).unwrap();
        assert!(dir.join("grpc.lock").exists());
        assert!(!unix_socket_is_stale(&socket));
        let error = bind_unix_socket(&socket).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AddrInUse);
        drop(listener);
        // The socket file is left behind by a server that died: the next bind recovers it.
        assert!(socket.exists());
        assert!(unix_socket_is_stale(&socket));
        let _listener = bind_unix_socket(&socket).unwrap();
        let not_a_socket = dir.join("file");
        std::fs::write(&not_a_socket, b"x").unwrap();
        assert_eq!(bind_unix_socket(&not_a_socket).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(bind_unix_socket(Path::new("relative")).unwrap_err().kind(), io::ErrorKind::InvalidInput);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
