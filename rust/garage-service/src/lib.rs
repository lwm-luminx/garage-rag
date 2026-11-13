//! `GarageService` in Rust (`garage_rag.service.server`): the gRPC backend the Mac app, the ingest
//! and embed workers and the MCP server read the corpus and persist through, over Postgres +
//! pgvector. [docs/plans/python-removal.md] is the plan; this crate is its first stage: the
//! database layer, the ingest and embed facades, the corpus reads, the token and socket rules.
//!
//! Each module names the Python it ports, and keeps its SQL, messages and status codes, so the
//! clients (Swift, the Rust workers, the tests) see no difference.
//!
//! [docs/plans/python-removal.md]: https://garagerag.app/plans/python-removal/

pub mod access;
pub mod auth;
pub mod backfill;
pub mod catalog;
pub mod clusters;
pub mod config;
pub mod corpus;
pub mod db;
pub mod embedding;
pub mod enrich;
pub mod error;
pub mod facts;
pub mod gateway;
pub mod graph;
pub mod host;
pub mod langextract;
pub mod mcp_install;
pub mod migrate;
pub mod models;
pub mod prompts;
pub mod registrations;
pub mod registry;
pub mod revision;
pub mod schema;
pub mod search;
pub mod server;
pub mod service;
pub mod sessions_store;
pub mod sources;

pub use error::{Result, ServiceError};
/// The access hooks' types, for the service's hosts and an extension's tests.
pub use garage_access;
pub use service::{GarageService, MAX_REQUEST_BYTES, VERSION};
