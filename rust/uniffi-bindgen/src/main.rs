//! UniFFI's `uniffi-bindgen`, pinned by this workspace's Cargo.lock so the generated bindings always
//! match the scaffolding the crates were built with:
//!
//! ```sh
//! cargo build -p garage-embed-uniffi
//! cargo run -p uniffi-bindgen -- generate --library target/debug/libgarage_embed_uniffi.so \
//!     --language swift --out-dir out/
//! ```
//!
//! Built without uniffi's `cargo-metadata` feature, so it reads only the library and never runs
//! `cargo metadata`, which Bazel's sandbox has no Cargo for. Bazel runs it the same way (`//rust/garage-embed-uniffi:swift_bindings`).

fn main() {
    uniffi::uniffi_bindgen_main();
}
