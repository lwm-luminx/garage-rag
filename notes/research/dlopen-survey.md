# Runtime loading and fork/exec in Garage (main @ 2b8d0e2, 2026-09-29)

Goal (Rick, 2026-09-29): minimize dyld runtime loading/binding and fork/exec; prefer static
linking / early binding. PR #216 (`_garage_git`, libgit2 static in Python.framework) is the
template for most of the Python items below: a C module added to `Modules/Setup.local` under
`*static*`, linked into Python.framework's own binary.

Surveyed by grep over `macapp/`, `garage_python/src/`, `ext/`, `bazel/` and `uv.lock`. Nothing
was built or traced here (no Mac in this session), so counts of loaded images are inferred from
build files; `tools/macos/trace_loaded_images.sh` on the M4 would confirm them.

## 1. Swift / C / ObjC

| Where | What | Runtime load? | Make static? |
|---|---|---|---|
| PythonKit (`ext/pythonkit`, `PythonLibrary.swift`, patched only to drop Homebrew paths) | `dlopen("Python.framework/Versions/3.14/Python")`, then `dlsym` for **every** CPython C-API function PythonKit calls | dlopen returns the already-loaded framework (PythonXPCService links `-framework Python`), but every Py* call PythonKit makes is bound by `dlsym`, lazily | **Yes, worthwhile.** Patch `PythonLibrary` to resolve symbols directly (declare them via a C module / `@_silgen_name`, or `dlsym(RTLD_DEFAULT)` once at start). The embed shim `CPythonEmbed/GaragePythonEmbed.c` already links the C API directly, so the link is there. Biggest remaining dlsym surface in the app. |
| `PythonXPCService/GaragePythonRuntime.swift:227` | `dlsym(RTLD_DEFAULT, "PQlibVersion")` + `dladdr` to find libpq's path | Lookup only, loads nothing | Goes away if libpq stops being a ctypes target (see 2). |
| `PythonXPCService/GarageXPCCrashHandler.swift:103` | `dlerror()` in the crash handler | Diagnostic only | Leave. |
| `ext/llama_cpp` | llama.cpp/ggml `BUILD_SHARED_LIBS=OFF`, `GGML_METAL_EMBED_LIBRARY=ON`, no `GGML_BACKEND_DL` | None (static) | Already done. |
| Sparkle (`//ext/sparkle`, Developer ID only) | Sparkle.framework linked by load command; its own Updater.app / XPC helpers run as processes | Load-time, not dlopen | Leave (Sparkle's design; not in store builds). |

No `dlopen`, `NSBundle.load`, `CFBundleLoadExecutable` or weak-linked frameworks anywhere in
`macapp/Sources`.

## 2. Python ctypes (each is a dlopen and/or per-call dlsym)

| Where | What it loads | Make static? |
|---|---|---|
| `garage_rag/libpq.py`, `native/__init__.py:25`, `__init__.py:13` | psycopg is the **pure-Python** implementation: it `ctypes.CDLL`s libpq (shimmed to the copy PythonXPCService.framework loaded) and calls every PQ* through ctypes | **Yes.** `//ext/postgres` already builds `libpq.a`. Options: psycopg's C implementation (`psycopg_c`, Cython) built against `libpq.a` as a wheel, or as a `*static*` built-in in Python.framework. Removes `libpq.dylib` from `Frameworks/`, the find_library shim and the dyld image walk. Largest ctypes hot path (every query). |
| `extract/tesseract.py:50-85` | `libtesseract.5.5.dylib` (linked by the framework's load command, then re-opened by path via ctypes) | **Yes.** A `_garage_tesseract` built-in like `_garage_git`, linking tesseract + leptonica statically (leptonica is already `.a`; tesseract is built `out_shared_libs` only). Drops the dylib and the ctypes shim. |
| `extract/imageio.py:38-40` | `CDLL` of CoreFoundation, CoreGraphics, ImageIO system frameworks (HEIC decode) | **Yes.** Fold into the same built-in C module (or a `_garage_imageio`) that links `-framework ImageIO -framework CoreGraphics`; system frameworks come from the shared cache, so this is about early binding, not file loading. |
| `extract/placeholder.py:86`, `ingest/materialize.py:69` | `CDLL(find_library("c"))` for `listxattr`, `setiopolicy_np` | libSystem is already loaded; low value. Could move into the same built-in module if one exists. |
| `xpc/host.py:50`, `inference/bridge.py:30`, `ingest/__init__.py:105,209` | `CFUNCTYPE` over function pointers the Swift host passes in | No dlopen/dlsym; ctypes FFI only. Could become a built-in `_garage_host` module the Swift side registers with `PyImport_AppendInittab`, but it's not dyld work. |

## 3. Python extension modules loaded at import (dlopen per `.so`)

- **CPython stdlib, `lib-dynload/`**: `ext/python` configures `--enable-framework --with-static-libpython`
  but no `Setup.local` beyond #216's, so the stdlib's C modules (`_ssl`, `_hashlib`, `_ctypes`,
  `_sqlite3`, `zlib`, `_json`, `_decimal`, `_asyncio`, `_socket`, `select`, `_struct`, …) are each a
  separate `.so` dlopened on first import (several dozen; not counted on a build). **Yes, cheap:**
  list them under `*static*` in the `Setup.local` #216 adds. OpenSSL and zlib are already static
  libs (`no-shared`, `libzlib.a`), so `_ssl`/`_hashlib`/`zlib` link in cleanly. This is probably the
  biggest count of dlopens per process.
- **site-packages native wheels** (cp314t macOS arm64, from `uv.lock`): pydantic-core, grpcio (sdist
  build, `MODULE.bazel:77`), cryptography (`_rust`), cffi, pillow (`_imaging` + its bundled
  `.dylibs/` libjpeg/libtiff/libwebp/freetype/lcms/openjpeg…), lxml (docx/pptx/openpyxl), regex,
  pyyaml, sqlalchemy (cyextension), charset-normalizer, rpds-py (via mcp → jsonschema). protobuf's
  upb extension is already excluded (`MODULE.bazel:92`). `extract/dispatch.py:290` imports extractors
  lazily, so pillow/lxml load on first use. **Partly:** grpcio, regex, pyyaml, sqlalchemy's
  cyextension and pillow could be built from source as static built-ins, but that's a large,
  per-package build effort and pillow's codec dylibs would need static builds too. pydantic-core,
  cryptography and rpds-py are Rust (PyO3) and much harder. Suggest: stdlib first, then grpcio (already
  built from source) and pillow, and leave the Rust ones.

## 4. fork/exec and subprocesses

| Where | What | Removable? |
|---|---|---|
| `attribute/git.py:59,110`, `ingest/scanner.py:277` | `git log`, `git ls-files`, `xcode-select -p` | **Removed by #216** (all three sites). |
| `GarageApp/Services/PostgresService.swift` via `ProcessRunner` (`:195`, `:523`, `:619`, `run()` at `:209`) | `postgres`, `initdb`, `pg_ctl` (stop), `pg_isready`, `pg_dump`, `pg_restore`, `psql`, `createdb`, `dropdb` | `postgres` and `initdb` must stay processes. **`pg_isready`** → `PQping` in-process (libpq is already loaded). **`psql`/`createdb`/`dropdb`** (`:1140-1162`) → SQL over a libpq/gRPC connection. **`pg_ctl stop`** → the code already has a direct SIGINT path (`:633`). `pg_dump`/`pg_restore` stay. |
| Postgres itself | postmaster forks a backend per connection; backends `dlopen` `vector`, `pg_trgm`, `plpgsql`, `dict_snowball` (and `age`) from `lib/` | Fork model is inherent. **Cheap win:** add `vector,pg_trgm,plpgsql` to `shared_preload_libraries` next to `age` (`PostgresService.swift:513`) so the postmaster dlopens them once and every backend inherits them through fork. Linking them into the `postgres` binary would need a Postgres patch; not worth it. |
| `PostgresService.swift:1172` | `DYLD_LIBRARY_PATH` set for the Postgres tools | Runtime search path; hardened runtime ignores `DYLD_*` anyway, and the build fixes rpaths (`bazel/rpath.bzl`). Inferred to be a relic; drop after checking the Developer ID and store builds still start Postgres. |
| `GarageCLI/garage:47`, `GarageMCPCLI/garage-mcp:41` | `/bin/sh` forwarder `exec`s the helper bundle | One extra exec per CLI start; required because codesign rejects a script in `MacOS` and a sandboxed Mach-O forwarder can't start a helper with its own sandbox. Leave. |
| `GarageLauncher/AppDatabase.swift:86`, `AppState.swift:619` | Launch Services opens the app (hidden start / relaunch after reset) | Needed. Leave. |
| Tests only | `Process()` in `DatabaseUITests.swift:142`, `GarageDataMigrationTests.swift:98` | Test code. |

## Suggested order

1. `Setup.local` `*static*` for the stdlib C modules (rides on #216's patch).
2. `shared_preload_libraries` for vector/pg_trgm/plpgsql; `pg_isready`/`psql`/`createdb`/`dropdb` → libpq calls.
3. `_garage_tesseract` (+ ImageIO) built-in; drop `libtesseract.dylib`.
4. psycopg C implementation against `libpq.a`; drop `libpq.dylib` and the ctypes shim.
5. PythonKit direct symbol binding instead of dlsym.
6. Static builds of selected native wheels (grpcio, pillow) if still wanted.
