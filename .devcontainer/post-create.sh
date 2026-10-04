#!/bin/bash
# Runs once, after the container is created: the Linux venv, the extensions the app's Python
# has built in, and Bazel's tool PATH.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$REPO/garage_python/.venv"
EXT="$HOME/.cache/garage-ext"

log() { printf '[post-create] %s\n' "$*"; }

direnv allow "$REPO" || true

# The venv is a volume (devcontainer.json "mounts"), created root-owned.
sudo chown "$(id -u):$(id -g)" "$VENV"

# The CPython release the app bundles, as the web-session hook picks it.
PYTHON_VERSION="$(sed -n 's/.*strip_prefix = "Python-\([0-9.]*\)".*/\1/p' "$REPO/ext/python/python.MODULE.bazel")"
if [ ! -x "$VENV/bin/python" ] ||
  [ "$("$VENV/bin/python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')" != "$PYTHON_VERSION" ]; then
  log "creating $VENV (python $PYTHON_VERSION)"
  # Empty it by hand: the directory is the volume's mount point and cannot be removed.
  find "$VENV" -mindepth 1 -delete
  uv venv --quiet --python "$PYTHON_VERSION" "$VENV"
fi
# uv.lock only resolves for macOS, so install from pyproject (as CI's Linux job does).
log "installing garage_python with the dev extras"
uv pip install --quiet --python "$VENV/bin/python" -e "$REPO/garage_python[dev]"

# _garage_git and _garage_tesseract as extension modules, as CI builds them; a .pth puts
# them on the venv's path. Optional: their tests fall back or skip without them.
mkdir -p "$EXT"
if "$REPO/tools/garage_git/build_extension.sh" "$VENV/bin/python" "$EXT/garage_git" >/dev/null 2>&1 &&
  "$REPO/tools/garage_tesseract/build_extension.sh" "$VENV/bin/python" "$EXT/garage_tesseract" >/dev/null 2>&1; then
  site="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  printf '%s\n%s\n' "$EXT/garage_git" "$EXT/garage_tesseract" > "$site/garage_devcontainer_ext.pth"
  log "built _garage_git and _garage_tesseract"
else
  log "could not build _garage_git/_garage_tesseract; their tests use the fallbacks"
fi

bazel run //tools:bazel_env || log "bazel_env did not put its tools on PATH (see its output); pytest does not need them"
