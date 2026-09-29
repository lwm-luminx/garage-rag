#!/usr/bin/env bash
# Smoke test for an installed garage_rag package: the one on PyPI or TestPyPI, or a wheel or
# sdist built by CI. Run by .github/workflows/ci.yaml (python-package) and publish-python.yaml.
#
#   tools/pypi/smoke_test.sh VENV_PYTHON EXPECTED_VERSION
#
# Runs from an empty directory, so nothing resolves against the checkout: the console scripts,
# the packaged data/ artifacts (SQL migrations, model catalog) and, when GARAGE_DATABASE_URL is
# set, `garage init-db` against that server, twice (the migrations are meant to be re-applied).
set -euo pipefail

python="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
expected="$2"
bin="$(dirname "$python")"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

installed="$("$python" -c 'from importlib.metadata import version; print(version("garage_rag"))')"
echo "installed garage_rag $installed"
if [[ "$installed" != "$expected" ]]; then
  echo "expected garage_rag $expected" >&2
  exit 1
fi

"$python" - <<'EOF'
import garage_rag
from garage_rag.db.catalog import manifest_path
from garage_rag.db.migrate import migration_files, sql_dir

package = sql_dir().parent
assert package.name == "_data", f"migrations resolved outside the package: {sql_dir()}"
names = [p.name for p in migration_files()]
assert names and names[0] == "001_extensions.sql", names
manifest = manifest_path()
assert manifest is not None and manifest.is_relative_to(package), manifest
print(f"{len(names)} migrations and {manifest.name} from {package}")
print(f"garage_rag.__version__ = {garage_rag.__version__}")
EOF

"$bin/garage" --help >/dev/null
"$bin/garage" version
"$bin/garage-mcp" --help >/dev/null

if [[ -n "${GARAGE_DATABASE_URL:-}" ]]; then
  "$bin/garage" init-db
  "$bin/garage" init-db
  "$bin/garage" stats
fi
echo "smoke test passed"
