//! The access extension of a plain garage-rag build: none. Every caller sees everything, as before
//! the hooks existed.
//!
//! A build with a policy replaces this crate, not its caller: Bazel's
//! `//rust/garage-access:extension` names the library linked as `garage_access_extension`, and an
//! extension's library exports the same [`register`] (`docs/plans/access-hooks.md`).

use garage_access::Registry;

/// Registers nothing.
pub fn register(_registry: &mut Registry) {}
