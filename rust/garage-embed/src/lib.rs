//! The embed worker: embeds the chunks a model has no vectors for.
//!
//! The Rust port of `garage_rag.ops.backfill` as the app's embed service runs it: chunks come from
//! the GarageService database facade (`GetEmbeddingBatches`) and vectors go back through it
//! (`UpdateEmbeddings`, then `BackfillDistilled`), so the worker holds no database connection
//! ([`facade`]). The model servers are reached through the process that hosts the worker
//! ([`host`]), after the same destination rules as Python's egress guard ([`egress`]): the worker
//! decides where a request may go, and the host only carries it.
//!
//! [`worker::backfill`] is the entry point; `garage-embed-ffi` exports it to Swift and .NET.

pub mod egress;
pub mod facade;
pub mod host;
pub mod provider;
pub mod settings;
pub mod worker;

/// GarageService's messages and client (`proto/garage.proto`), from `garage-facade`.
pub use garage_facade::proto;

pub use facade::{Facade, FacadeError, GrpcFacade, GrpcTarget};
pub use host::{Host, HttpRequest, HttpResponse};
pub use provider::{EmbedError, Embedder};
pub use settings::Settings;
pub use worker::{BackfillError, BackfillEvent, BackfillOptions, Phase, backfill};
