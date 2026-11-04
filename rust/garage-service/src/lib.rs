//! `GarageService` in Rust (`garage_rag.service.server`): the gRPC backend the Mac app, the ingest
//! and embed workers and the MCP server read the corpus and persist through, over Postgres +
//! pgvector. [docs/plans/python-removal.md] is the plan; this crate is its first stage: the
//! database layer, the ingest and embed facades, the corpus reads, the token and socket rules.
//!
//! Each module names the Python it ports, and keeps its SQL, messages and status codes, so the
//! clients (Swift, the Rust workers, the tests) see no difference.
//!
//! [docs/plans/python-removal.md]: https://garagerag.app/plans/python-removal/

pub mod auth;
pub mod catalog;
pub mod config;
pub mod corpus;
pub mod db;
pub mod embedding;
pub mod error;
pub mod gateway;
pub mod host;
pub mod mcp_install;
pub mod migrate;
pub mod models;
pub mod registry;
pub mod revision;
pub mod search;
pub mod server;
pub mod service;
pub mod sources;

pub use error::{Result, ServiceError};
pub use service::{GarageService, MAX_REQUEST_BYTES, VERSION};
