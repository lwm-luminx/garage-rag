#!/usr/bin/env bash
# Builds the garage_rag gem for one platform from a built garage-rag shared library.
#
#     cargo build --release -p garage-rag -p uniffi-bindgen
#     rust/garage-rag/ruby/build.sh rust/target/release/libgarage_rag.dylib arm64-darwin OUT_DIR
#
# The bindings come from the workspace's uniffi-bindgen (rust/target/release, or UNIFFI_BINDGEN),
# so they match the library's scaffolding. The gem lands in OUT_DIR.
set -euo pipefail

lib="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
platform="$2"
out="$(mkdir -p "$3" && cd "$3" && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rust="$(cd "$here/../.." && pwd)"
bindgen="${UNIFFI_BINDGEN:-$rust/target/release/uniffi-bindgen}"
[ -x "$bindgen" ] || bindgen="$bindgen.exe"

# A fresh copy of ruby/, so generated files never land in the checkout.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$here/." "$stage/"
mkdir -p "$stage/lib/garage_rag"
"$bindgen" generate --library "$lib" --language ruby --no-format \
  --config "$here/uniffi.toml" --out-dir "$stage/lib/garage_rag"
cp "$lib" "$stage/lib/garage_rag/"
# The workspace's version: the first `version = "..."` after [workspace.package].
version="$(awk '/^\[workspace\.package\]/{p=1;next} /^\[/{p=0} p && /^version *=/{gsub(/.*= *"|".*/,"");print;exit}' "$rust/Cargo.toml")"
[ -n "$version" ] || { echo "no [workspace.package] version in $rust/Cargo.toml" >&2; exit 1; }
cd "$stage"
GARAGE_RAG_VERSION="$version" GARAGE_RAG_GEM_PLATFORM="$platform" \
  gem build garage_rag.gemspec --output "$out/garage_rag-$version-$platform.gem"
