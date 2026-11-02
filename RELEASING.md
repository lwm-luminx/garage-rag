# Releasing Garage

The macOS app's releases, Developer ID (notarized, Sparkle) and App Store, are cut from
[garage-enterprise](https://github.com/lwm-luminx/garage-enterprise), which carries this repository as a
submodule and holds the signing identities, the provisioning profiles and the release targets
(`docs/RELEASING.md` there). This repository builds the app ad hoc or with a local identity only; the
seam the signed builds plug into is `bazel/platforms.bzl`.

What a release still needs from here, before the cut:

- [ ] Everything meant for the release is merged into `main`, and CI is green there, including
      `.github/workflows/macos.yaml` (`aspect test //...` on macOS).
- [ ] Bump `short_version_string` in `macapp/Sources/GarageApp/BUILD.bazel`, and the Python package version if it changed.
- [ ] Regenerate `data/notices/THIRD_PARTY_NOTICES.txt` (`python3 tools/third_party_notices.py`) if dependencies or anything under `ext/` changed.
- [ ] After a Developer ID release, commit the entry garage-enterprise's appcast step wrote to `docs/appcast.xml`
      (the feed is served from this repository's site; `garage_python/tests/test_appcast.py` checks it).

## Python package on PyPI

`garage_python` is published as `garage-rag` by `.github/workflows/publish-python.yaml`, run by hand from the Actions tab. It uses Trusted Publishing, so no API token is stored in the repository or its secrets.

1. **Once per index, register the trusted publisher.** On pypi.org (and on test.pypi.org for the dry run), under **Your projects → Publishing**, add a pending publisher: PyPI project name `garage-rag`, owner `rickmark`, repository `garage-rag`, workflow `publish-python.yaml`, environment `pypi` (on TestPyPI: `testpypi`). The pending publisher reserves the name until the first upload creates the project.
2. **Protect the `pypi` environment** (optional). The first run creates the `pypi` and `testpypi` environments in the repository's settings. Adding a required reviewer to `pypi` makes every PyPI upload wait for an approval.
3. **Dry run on TestPyPI.** Run the workflow with `testpypi`. It publishes the current version with a `.dev<run number>` suffix, so it can be repeated from any branch, then installs it from TestPyPI (its dependencies from PyPI) and runs `tools/pypi/smoke_test.sh` against a pgvector Postgres.
4. **Release to PyPI.** Bump `version` in `garage_python/pyproject.toml` and `__version__` in `garage_python/src/garage_rag/__init__.py` together (the workflow refuses a mismatch), merge to `main`, then run the workflow on `main` with `pypi`. A version can be uploaded to PyPI only once. The smoke test then installs it from PyPI.

CI's `python-package` job builds the same sdist and wheel on every push and smoke-tests both, so a packaging break shows up before a release. The wheel carries `data/sql` and `data/models/models.json` as `garage_rag/_data` (`garage_python/hatch_build.py`), which is where an installed package reads them.
