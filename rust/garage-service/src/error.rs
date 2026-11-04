//! What a handler can fail with, in the gRPC status Python's `_grpc_errors` gave it.
//!
//! Python translated four exceptions (`FileExistsError`, `PermissionError`, `LookupError`,
//! `ValueError`) and its `ConfigError`; anything else stayed `UNKNOWN`, so a server fault is never
//! mistaken for a client error. The same holds here.

use std::fmt;

use tonic::{Code, Status};

/// A failed operation, in the terms the RPC status needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceError {
    /// `LookupError`: gRPC `NOT_FOUND`.
    NotFound(String),
    /// `ValueError` and `ConfigError`: gRPC `INVALID_ARGUMENT`.
    InvalidArgument(String),
    /// `PermissionError`: gRPC `PERMISSION_DENIED`.
    PermissionDenied(String),
    /// `FileExistsError`: gRPC `ALREADY_EXISTS`.
    AlreadyExists(String),
    /// A model server that did not answer or refused (`EmbeddingError`): gRPC `UNAVAILABLE`.
    Unavailable(String),
    /// A server fault (the database, the file system): gRPC `UNKNOWN`.
    Failed(String),
}

impl ServiceError {
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::NotFound(message.into())
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidArgument(message.into())
    }

    pub fn failed(message: impl Into<String>) -> Self {
        Self::Failed(message.into())
    }

    pub fn unavailable(message: impl Into<String>) -> Self {
        Self::Unavailable(message.into())
    }

    /// The message, whatever the kind.
    pub fn message(&self) -> &str {
        match self {
            Self::NotFound(m)
            | Self::InvalidArgument(m)
            | Self::PermissionDenied(m)
            | Self::AlreadyExists(m)
            | Self::Unavailable(m)
            | Self::Failed(m) => m,
        }
    }
}

impl fmt::Display for ServiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ServiceError {}

impl From<tokio_postgres::Error> for ServiceError {
    fn from(error: tokio_postgres::Error) -> Self {
        // The database error's own message (`db_error`) is the useful part; the wrapper's
        // Display is "db error: ERROR: ..." which is what Python's SQLAlchemy errors showed too.
        let detail = error.as_db_error().map_or_else(
            || std::error::Error::source(&error).map_or_else(|| error.to_string(), |s| format!("{error}: {s}")),
            |db| {
                let mut text = format!("{}: {}", db.severity(), db.message());
                if let Some(d) = db.detail() {
                    let _ = std::fmt::Write::write_fmt(&mut text, format_args!(" ({d})"));
                }
                text
            },
        );
        Self::Failed(detail)
    }
}

impl From<deadpool_postgres::PoolError> for ServiceError {
    fn from(error: deadpool_postgres::PoolError) -> Self {
        Self::Failed(format!("database: {error}"))
    }
}

impl From<serde_json::Error> for ServiceError {
    fn from(error: serde_json::Error) -> Self {
        Self::InvalidArgument(format!("invalid JSON: {error}"))
    }
}

impl From<ServiceError> for Status {
    fn from(error: ServiceError) -> Self {
        let code = match &error {
            ServiceError::NotFound(_) => Code::NotFound,
            ServiceError::InvalidArgument(_) => Code::InvalidArgument,
            ServiceError::PermissionDenied(_) => Code::PermissionDenied,
            ServiceError::AlreadyExists(_) => Code::AlreadyExists,
            ServiceError::Unavailable(_) => Code::Unavailable,
            ServiceError::Failed(_) => Code::Unknown,
        };
        Status::new(code, error.message().to_owned())
    }
}

pub type Result<T> = std::result::Result<T, ServiceError>;
