//! Garage's ingest pipeline in Rust, ported from `garage_rag.ingest` one piece at a time
//! (docs/plans/rust-plugins.md). So far: the file walker ([`walk`]), with the rules it applies as
//! data ([`policy`]) and the cloud placeholder check it makes ([`placeholder`]), and the quality
//! gate that rejects machine-generated text ([`quality`]), and chunking ([`chunking`], over the
//! splitters in [`splitters`]).
//!
//! Python's modules are the specification; `garage_python/tests/test_ingest_rust.py` holds each
//! piece to its Python original through `garage-ingest-ffi`.

pub mod chunking;
pub mod fnmatch;
pub mod placeholder;
pub mod policy;
pub mod quality;
pub mod splitters;
pub mod walk;

pub use chunking::{ContentKind, TextChunk, chunk_text};
pub use policy::WalkPolicy;
pub use quality::{Verdict, assess};
pub use walk::{Candidate, WalkOptions, WalkStats, Walked, default_exclude_prefixes, root_problem, walk};
