//! Garage's MCP server without Python (`garage_rag.mcp_server`, ported).
//!
//! * [`protocol`]: MCP's JSON-RPC messages, answered as the Python server answers them.
//! * [`tools`]: the eight tools, their published schemas (`tools.json`) and argument checks
//!   ([`args`], worded as pydantic words them).
//! * [`corpus`]: the reads, through GarageService's facade (`Corpus*`), whose replies are the
//!   Python tools' own results, so search and the database stay in the backend. Each read names its
//!   [`corpus::Caller`] for the access hooks.
//! * [`chat`] and [`agent`]: rag_ask, rag_generate and rag_agent on the local model, reached through
//!   the host after the egress rules approve it (`garage_embed::egress`).
//! * [`http`]: the streamable HTTP transport GarageMCPServerService serves at `127.0.0.1:8787/mcp`;
//!   [`stdio::serve`] is the stdio one.

pub mod agent;
pub mod args;
pub mod chat;
pub mod corpus;
pub mod http;
pub mod protocol;
pub mod pyjson;
pub mod pyrepr;
pub mod stdio;
pub mod tools;

pub use corpus::{Caller, Corpus, CorpusError, GrpcCorpus, Transport};
pub use http::{HttpOptions, HttpServer};
pub use protocol::Server;
