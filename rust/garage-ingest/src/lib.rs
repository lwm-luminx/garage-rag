//! Garage's ingest pipeline in Rust, ported from `garage_rag.ingest` one piece at a time
//! (docs/plans/rust-plugins.md). So far: the file walker ([`walk`]), with the rules it applies as
//! data ([`policy`]) and the cloud placeholder check it makes ([`placeholder`]), and the quality
//! gate that rejects machine-generated text ([`quality`]), chunking ([`chunking`], over the
//! splitters in [`splitters`]), the budgeted download of cloud placeholders ([`materialize`]), and
//! attribution ([`attribution`], with Python's sender parsing in [`parseaddr`] and git history read
//! through libgit2 in [`history`]), and the per-file decisions of the ingest loop ([`pipeline`], with
//! message handles named through [`contact_names`]), and the loop over a walked source ([`source`]),
//! persisting through GarageService ([`facade`]).
//!
//! Python's modules are the specification; `garage_python/tests/test_ingest_rust.py` holds each
//! piece to its Python original through `garage-ingest-ffi`.

pub mod attribution;
pub mod chunking;
pub mod contact_names;
pub mod facade;
pub mod feed;
pub mod fnmatch;
pub mod history;
pub mod materialize;
pub mod parseaddr;
pub mod pipeline;
pub mod placeholder;
pub mod policy;
pub mod quality;
pub mod scanner;
pub mod sha256;
pub mod source;
pub mod splitters;
pub mod sqlite;
pub mod walk;

pub use attribution::{Attribution, GitHistory, SelfIdentity, TrustTier};
pub use chunking::{ContentKind, TextChunk, chunk_text};
pub use history::LibGitHistory;
pub use materialize::{Budget, Materializer, Outcome};
pub use policy::WalkPolicy;
pub use quality::{Verdict, assess};
pub use scanner::{ScanOptions, ScanResult, scan_source};
pub use walk::{Candidate, WalkOptions, WalkStats, Walked, default_exclude_prefixes, root_problem, walk, walk_while};
