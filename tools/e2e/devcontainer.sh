#!/bin/bash
# Runs the Linux end-to-end tests in the devcontainer (.devcontainer/), from a Mac or any host
# with Docker and the devcontainer CLI (npm install -g @devcontainers/cli).
#
#   tools/e2e/devcontainer.sh                      # the CLI's end-to-end tests and the service's database tests
#   tools/e2e/devcontainer.sh -p garage-ingest     # anything else: cargo test arguments, from rust/
#   GARAGE_E2E_REBUILD=1 tools/e2e/devcontainer.sh # rebuild the image first (after a Dockerfile change)
#
# The first run builds the image and the workspace, which takes several minutes; later runs reuse
# the container. Postgres runs inside it; nothing on the host is touched.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "devcontainer CLI not found: npm install -g @devcontainers/cli" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running (start OrbStack or Docker Desktop)" >&2
  exit 1
fi

up_args=(--workspace-folder "$REPO")
if [ -n "${GARAGE_E2E_REBUILD:-}" ]; then
  up_args+=(--remove-existing-container --build-no-cache)
fi
devcontainer up "${up_args[@]}" >&2

if [ "$#" -eq 0 ]; then
  set -- -p garage-cli -p garage-service
fi
# printf %q keeps each argument whole through bash -c.
exec devcontainer exec --workspace-folder "$REPO" \
  bash -c "cd rust && cargo test --features garage-plugin/grpc $(printf '%q ' "$@")"
