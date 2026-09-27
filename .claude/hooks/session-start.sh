#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# The container has no Swift toolchain and no populated Python venv, so without this
# neither `pytest`/`ruff` nor any Swift checking works in a web session. It:
#   1. creates garage_python/.venv with the package and its dev extras (pytest, ruff,
#      tree-sitter for tools/swiftcheck);
#   2. installs the swift.org Linux toolchain under /opt/swift so `swiftc -parse` and
#      `swift-format lint` can syntax-check macapp/ (type checking still needs macOS:
#      every module imports Apple-only frameworks). Needs download.swift.org allowed in
#      the environment's network policy; if the download fails the hook says so and the
#      tree-sitter checker remains the fallback.
#   3. starts the image's Postgres with pgvector (built from source when the
#      distribution's package predates 0.7, which added halfvec and binary_quantize)
#      and exports GARAGE_TEST_DATABASE_URL, so garage_python/tests/test_postgres.py runs
#      instead of skipping. Needs github.com reachable for the pgvector build; if any
#      step fails the hook says so and those tests skip.
# Idempotent: every step is skipped when its result already exists, and the container
# state is cached after the hook completes.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
ENV_FILE="${CLAUDE_ENV_FILE:-/dev/null}"
cd "$REPO"

log() { printf '[session-start] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Python: uv + the package venv with dev extras
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "installing uv"
  python3 -m pip install --quiet --user uv 2>/dev/null || pip install --quiet uv
  export PATH="$HOME/.local/bin:$PATH"
fi

VENV="$REPO/garage_python/.venv"
# The venv runs the CPython release the app bundles (ext/python), not whatever 3.14 is on the
# machine: an old uv's 3.14 is a release candidate that current pydantic cannot import under.
VENV_PYTHON="$(sed -n 's/.*strip_prefix = "Python-\([0-9.]*\)".*/\1/p' "$REPO/ext/python/python.MODULE.bazel")"
VENV_PYTHON="${VENV_PYTHON:-3.14}"
# A venv left by an older hook runs another interpreter; recreate it rather than keep using it.
if [ -x "$VENV/bin/python" ] &&
  [ "$("$VENV/bin/python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)" != "$VENV_PYTHON" ]; then
  log "replacing $VENV: it is not python $VENV_PYTHON"
  rm -rf "$VENV"
fi
if [ ! -x "$VENV/bin/pytest" ] || [ ! -x "$VENV/bin/ruff" ]; then
  log "creating $VENV (python $VENV_PYTHON, package + dev extras)"
  if ! uv venv --quiet --clear --python "$VENV_PYTHON" "$VENV" 2>/dev/null; then
    # An older uv has no download for a newer CPython release.
    log "upgrading uv to find python $VENV_PYTHON"
    python3 -m pip install --quiet --user --upgrade uv 2>/dev/null || pip install --quiet --upgrade uv
    export PATH="$HOME/.local/bin:$PATH"
    uv venv --quiet --clear --python "$VENV_PYTHON" "$VENV"
  fi
fi
# uv.lock only resolves for macOS (pyproject [tool.uv].environments), so install the
# project directly instead of `uv sync`. No-op when everything is already present.
VIRTUAL_ENV="$VENV" uv pip install --quiet -e "$REPO/garage_python[dev]"
echo "export PATH=\"$VENV/bin:\$PATH\"" >> "$ENV_FILE"
log "python: $("$VENV/bin/python" --version), pytest $("$VENV/bin/pytest" --version 2>&1 | awk '{print $2}')"

# ---------------------------------------------------------------------------
# 2. Swift toolchain (syntax checking only on Linux)
# ---------------------------------------------------------------------------
SWIFT_VERSION="${GARAGE_SWIFT_VERSION:-6.1.2}"
SWIFT_HOME="${GARAGE_SWIFT_HOME:-/opt/swift}"
UBUNTU_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-24.04}")"
UBUNTU_TAG="ubuntu${UBUNTU_VERSION}"
UBUNTU_DIR="$(echo "$UBUNTU_TAG" | tr -d .)"
ARCH_SUFFIX=""
case "$(uname -m)" in
  aarch64) ARCH_SUFFIX="-aarch64" ;;
esac
TARBALL="swift-${SWIFT_VERSION}-RELEASE-${UBUNTU_TAG}${ARCH_SUFFIX}.tar.gz"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${UBUNTU_DIR}${ARCH_SUFFIX}/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"

install_swift() {
  # The runtime libraries swiftc needs; most are already in the image. Non-fatal so a
  # sealed apt mirror does not take the whole hook down.
  if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev libsqlite3-0 \
      libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata zlib1g-dev >/dev/null 2>&1 \
      || log "apt-get could not install the toolchain's helper packages; continuing"
  fi
  local tmp
  tmp="$(mktemp -d)"
  log "downloading $URL"
  if ! curl -fsSL --retry 3 -o "$tmp/$TARBALL" "$URL"; then
    log "download failed (is download.swift.org allowed in this environment's network policy?)"
    rm -rf "$tmp"
    return 1
  fi
  if [ -n "${GARAGE_SWIFT_SHA256:-}" ]; then
    echo "${GARAGE_SWIFT_SHA256}  $tmp/$TARBALL" | sha256sum -c - >/dev/null || {
      log "checksum mismatch for $TARBALL"; rm -rf "$tmp"; return 1; }
  fi
  mkdir -p "$SWIFT_HOME"
  tar -xzf "$tmp/$TARBALL" -C "$SWIFT_HOME" --strip-components=1
  rm -rf "$tmp"
}

if [ ! -x "$SWIFT_HOME/usr/bin/swiftc" ]; then
  if ! install_swift; then
    log "Swift toolchain unavailable; tools/swiftcheck falls back to the tree-sitter checker"
  fi
fi

if [ -x "$SWIFT_HOME/usr/bin/swiftc" ]; then
  echo "export PATH=\"$SWIFT_HOME/usr/bin:\$PATH\"" >> "$ENV_FILE"
  log "swift: $("$SWIFT_HOME/usr/bin/swiftc" --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# 3. Postgres + pgvector for the real-database tests
# ---------------------------------------------------------------------------
PGVECTOR_VERSION="${GARAGE_PGVECTOR_VERSION:-0.8.1}"
PG_TEST_URL="postgresql://garage_dev:garage_dev@localhost:5432/postgres"

pgvector_at_least_07() {
  local control="/usr/share/postgresql/$1/extension/vector.control" version
  [ -f "$control" ] || return 1
  version="$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$control")"
  [ "$(printf '%s\n0.7.0\n' "$version" | sort -V | head -1)" = "0.7.0" ]
}

PG_MAJOR=""
setup_postgres() {
  command -v pg_ctlcluster >/dev/null 2>&1 && [ "$(id -u)" = "0" ] || return 1
  local major
  major="$(ls /usr/lib/postgresql 2>/dev/null | sort -n | tail -1)"
  [ -n "$major" ] || return 1
  if ! pgvector_at_least_07 "$major"; then
    log "building pgvector $PGVECTOR_VERSION for Postgres $major"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      "postgresql-server-dev-$major" build-essential git >/dev/null 2>&1 || return 1
    local src
    src="$(mktemp -d)"
    git clone --quiet --depth 1 --branch "v$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git "$src" \
      && make -s -C "$src" PG_CONFIG="/usr/lib/postgresql/$major/bin/pg_config" OPTFLAGS="" >/dev/null 2>&1 \
      && make -s -C "$src" PG_CONFIG="/usr/lib/postgresql/$major/bin/pg_config" install >/dev/null 2>&1
    local built=$?
    rm -rf "$src"
    [ "$built" = 0 ] || return 1
  fi
  pg_ctlcluster "$major" main start >/dev/null 2>&1 || pg_ctlcluster "$major" main status >/dev/null 2>&1 || return 1
  # Superuser: pgvector is not a trusted extension, and the tests create a
  # database per run and CREATE EXTENSION vector in it.
  su postgres -c "psql -q" >/dev/null <<'SQL' || return 1
DO $$ BEGIN CREATE ROLE garage_dev; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER ROLE garage_dev WITH LOGIN SUPERUSER PASSWORD 'garage_dev';
SQL
  PG_MAJOR="$major"
}

if setup_postgres; then
  echo "export GARAGE_TEST_DATABASE_URL=\"$PG_TEST_URL\"" >> "$ENV_FILE"
  log "postgres: $PG_MAJOR with pgvector; GARAGE_TEST_DATABASE_URL set for test_postgres.py"
else
  log "no Postgres test server (needs the image's postgresql and github.com for pgvector); test_postgres.py will skip"
fi

log "done"
