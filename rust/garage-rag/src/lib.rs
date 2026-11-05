//! Garage's language bindings in one library, published as `garage_rag` on PyPI and RubyGems
//! (`.github/workflows/release.yaml`).
//!
//! Each UniFFI crate of the workspace keeps its own namespace; linking them into this one cdylib
//! puts all of their scaffolding in a single shared library, and `uniffi-bindgen generate --library`
//! over it writes one module per namespace:
//!
//! - `garage_cli` (`garage-cli-uniffi`): the `garage` command line and the `garage-mcp` stdio
//!   server, arguments in and exit code out, behind the package's console scripts.
//! - `garage_embed` (`garage-embed-uniffi`): the embed worker, with the `EmbedHost` protocol.
//!
//! The Python package (`python/garage_rag`) is hand-written around the generated modules: it keeps
//! the 1.5.0 pure-Python package's names (docs/plans/python-package-parity.md) and translates to
//! these calls. Add a new UniFFI crate as a dependency and a `pub use` here, then load its module in
//! `ruby/lib/garage_rag.rb`.

pub use garage_cli_uniffi;
pub use garage_embed_uniffi;

#[cfg(test)]
mod tests {
    /// The packages' version (this crate's) is the app's release version, which `garage --version`
    /// prints: they move together.
    #[test]
    fn the_packages_version_is_the_apps() {
        assert_eq!(env!("CARGO_PKG_VERSION"), garage_cli_uniffi::version());
    }
}
