//! Garage's ingest pipeline in Rust, ported from `garage_rag.ingest` one piece at a time
//! (docs/plans/rust-plugins.md). So far: the file walker ([`walk`]), with the rules it applies as
//! data ([`policy`]) and the cloud placeholder check it makes ([`placeholder`]), and the quality
//! gate that rejects machine-generated text ([`quality`]), chunking ([`chunking`], over the
//! splitters in [`splitters`]), the budgeted download of cloud placeholders ([`materialize`]), and
//! attribution ([`attribution`], with Python's sender parsing in [`parseaddr`] and git history read
//! through libgit2 in [`history`]), and the per-file decisions of the ingest loop ([`pipeline`], with
//! message handles named through [`contact_names`]), and the loop over a walked source ([`source`]),
//! with a Messages source read thread by thread ([`conversations`], over the `messages-markdown` crate),
//! persisting through GarageService ([`facade`]).
//!
//! Python's modules were the specification: each piece was held to its Python original through
//! `garage-ingest-ffi` until the Python package retired (docs/plans/python-removal.md).

pub mod attribution;
pub mod chunking;
pub mod contact_names;
pub mod conversations;
pub mod dropbox;
pub mod facade;
pub mod feed;
pub mod fnmatch;
pub mod history;
pub mod materialize;
pub mod onedrive;
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

/// Whether a source of `kind` is read through a cloud service's API rather than from disk
/// ([`dropbox`], [`onedrive`]): its root names a folder in the service, and nothing is walked.
#[must_use]
pub fn is_cloud_kind(kind: &str) -> bool {
    kind == dropbox::KIND || kind == onedrive::KIND
}
