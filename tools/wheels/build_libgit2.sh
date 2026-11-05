#!/usr/bin/env bash
# Builds the pinned libgit2 (ext/libgit2/libgit2.MODULE.bazel) as a static library for the
# garage_rag wheel and gem, with //ext/libgit2's options: local reads only, so no HTTPS or SSH
# transport and no TLS library or libssh2 to link. garage-git's build.rs links it statically from
# GARAGE_LIBGIT2_DIR, with the system's zlib (and iconv on macOS), so the shared library carries it
# and loads nothing of Homebrew's or the distribution's at run time.
#
#     tools/wheels/build_libgit2.sh PREFIX     # then: export GARAGE_LIBGIT2_DIR=PREFIX
#
# Needs cmake, a C compiler, curl and zlib's headers (no Python: the manylinux container's is 3.6).
# Windows takes vcpkg's instead (windows.yaml).
set -euo pipefail

prefix="$(mkdir -p "$1" && cd "$1" && pwd)"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The pin is a commit of libgit2's repository, as Bazel's git_repository takes it.
commit="$(sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p' "$repo/ext/libgit2/libgit2.MODULE.bazel")"
[ -n "$commit" ] || { echo "no commit in ext/libgit2/libgit2.MODULE.bazel" >&2; exit 1; }
mkdir -p "$work/src"
curl -fsSL "https://github.com/libgit2/libgit2/archive/$commit.tar.gz" | tar -xz -C "$work/src"
cmake -S "$work/src/libgit2-$commit" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DBUILD_FUZZERS=OFF -DBUILD_TESTS=OFF \
  -DUSE_BUNDLED_ZLIB=OFF -DUSE_GSSAPI=OFF -DUSE_HTTPS=OFF -DUSE_SSH=OFF -DUSE_NTLMCLIENT=OFF \
  -DUSE_HTTP_PARSER=builtin -DREGEX_BACKEND=builtin \
  -DUSE_SHA1=CollisionDetection -DUSE_SHA256=Builtin
cmake --build "$work/build" --config Release --parallel
cmake --install "$work/build" --config Release
ls -l "$prefix/lib/libgit2.a"
