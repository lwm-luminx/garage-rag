#!/bin/bash
# Runs once, after the container is created: Bazel's tool PATH and a first Cargo build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '[post-create] %s\n' "$*"; }

direnv allow "$REPO" || true

# rustup reads rust/rust-toolchain.toml and installs that toolchain on first use.
log "building the Rust workspace"
(cd "$REPO/rust" && cargo build --workspace --features garage-plugin/grpc) || log "cargo build failed; see the output above"

bazel run //tools:bazel_env || log "bazel_env did not put its tools on PATH (see its output); cargo does not need them"
