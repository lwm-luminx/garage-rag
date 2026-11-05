//! Garage's language bindings in one library, published as `garage_rag` on PyPI and RubyGems
//! (`.github/workflows/release.yaml`).
//!
//! Each UniFFI crate of the workspace keeps its own namespace; linking them into this one cdylib
//! puts all of their scaffolding in a single shared library, and `uniffi-bindgen generate --library`
//! over it writes one module per namespace. The `garage_rag` package re-exports them:
//!
//! - `garage_embed` (`garage-embed-uniffi`): the embed worker, with the `EmbedHost` protocol.
//!
//! Add a new UniFFI crate as a dependency and a `pub use` here, then load its module in
//! `ruby/lib/garage_rag.rb`; maturin writes the Python package's `__init__.py` itself.

pub use garage_embed_uniffi;
