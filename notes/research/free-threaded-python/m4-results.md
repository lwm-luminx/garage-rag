# Free-threaded 3.14t on the M4 (2026-09-27)

Branch `claude/project-thread-sh6f36`, draft PR #151 against `v1.5-beta` (rebased onto 616df51e,
where the beta already moved to 3.14 with the GIL, so the PR is only the free-threaded delta).

## Build
- `aspect build //:macapp` green. Python.framework is CPython 3.14.7 built with `--disable-gil`
  ("3.14.7 free-threading build"). Hermetic Bazel interpreter: python-build-standalone 3.14.3t, so
  site-python holds 103 `cpython-314t` extensions and no abi3 ones.
- Beyond the version and path renames it took:
  1. `cryptography<44` pin lifted; lock now 50.0.1.
  2. grpcio built from its sdist inside Bazel (no hand-built wheel). Needed `build` locked (a
     build-tools extra plus a dependency group) and a `uv.override_package` passing `DEVELOPER_DIR`
     and `SDKROOT`, because the pep517 action has none of the Apple toolchain's environment. The
     Xcode path is hard-coded to /Applications/Xcode.app.
  3. protobuf: the hub picks its cp310-abi3 wheel for cp314t, and 3.14.7t still loads `.abi3.so`,
     so `import google._upb._message` segfaults (and with it `garage_rag.service.server`).
     `google/_upb` is excluded; protobuf runs its pure-Python backend. Linux never saw this because
     pip chose the pure wheel there.

## GIL, measured in a driver linked against the bundled framework
- Stay GIL-free: protobuf (pure), psycopg, pydantic, cryptography, PIL, yaml, regex,
  `garage_rag.ingest` and `garage_rag.extract`.
- Re-enable the GIL: `grpc._cython.cygrpc`, `sqlalchemy.cyextension`, `lxml.etree`. So
  `garage_rag.service.server` and the MCP server run with the GIL on. The shim's isolated PyConfig
  ignores `PYTHON_GIL`, so the services almost certainly run with the GIL (inferred from the
  imports, not observed in a live service). Forcing it off from the shim would be
  `config.enable_gil = PyConfig_GIL_DISABLE` in GaragePythonEmbed.c, at the risk described in
  findings.md.

## Tests
- `aspect test //...`: 52 of 52 targets. Inside them pytest on 3.14t: 1535 passed, 11 skipped,
  0 failed; `test_postgres` ran against Homebrew PG 18.
- XCUITests, GarageAppUITests: 60 tests in 77 min, 48 passed, 7 skipped (Store-only), 5 failed.
  Four failures were a Secretive Touch ID prompt covering the window; all four pass on rerun. The
  fifth is the setup-assistant 3-column check that main fixed in 513826da and v1.5-beta lacks.
- GarageAppModelUITests: 3 of 3 (Embed All + search, Glean Facts, MCP Try It).
- No ingest or UI behaviour differences seen. UI runs were on the pre-rebase tree; the rebased tree
  builds green and passes 52 of 52.

## Timings (lower bounds)
CPython 3.14.7t build 147 s; grpcio sdist build 138 s at 16 jobs; full app build 532 s; test suite
938 s.

## Not covered
- Developer ID package and Store sandbox build on 3.14t.
- Windows CI still builds 3.14.7 with the GIL.
- CI venvs stay on 3.14 with the GIL, because tree-sitter-swift does not build on 3.14t
  (PR #150 adds a separate informational 3.14t job without the dev extras).
