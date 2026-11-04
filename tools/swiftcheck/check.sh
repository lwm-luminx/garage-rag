#!/usr/bin/env bash
# Syntax-check every Swift file under macapp/ without a Mac.
#
# With a Swift toolchain on PATH (the web session hook installs one under /opt/swift):
#   swiftc -parse   on every file  -> the real parser, no false positives
#   swift-format lint               -> when the toolchain ships it
# Otherwise: the tree-sitter checker (swift_syntax_check.py), which ignores the known
# grammar gaps listed in baseline.txt.
#
# Neither path type-checks: every module imports Apple-only frameworks, so that stays
# `aspect build //:macapp` on macOS.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

mapfile -t FILES < <(find macapp -name '*.swift' -not -path '*/.build/*' | sort)

if command -v swiftc >/dev/null 2>&1; then
  echo "swiftc -parse: ${#FILES[@]} file(s) with $(swiftc --version 2>&1 | head -1)"
  status=0
  for f in "${FILES[@]}"; do
    # One file per invocation so every diagnostic carries its own path and the
    # remaining files are still checked after a failure.
    swiftc -parse "$f" || status=1
  done
  if command -v swift-format >/dev/null 2>&1; then
    echo "swift-format lint"
    swift-format lint --recursive macapp || status=1
  fi
  if [ "$status" -ne 0 ]; then
    echo "swift syntax check failed"
  fi
  exit "$status"
fi

# A venv with tree-sitter and tree-sitter-swift (the web-session hook makes one at
# $GARAGE_SWIFTCHECK_VENV); otherwise whatever python3 has them.
PY="${GARAGE_SWIFTCHECK_VENV:-$REPO/.swiftcheck-venv}/bin/python"
[ -x "$PY" ] || PY="python3"
echo "no swiftc on PATH; using the tree-sitter checker"
exec "$PY" "$REPO/tools/swiftcheck/swift_syntax_check.py" "$@"
