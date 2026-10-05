---
layout: default
title: Windows Plan — A Native Garage for Windows
description: Engineering plan for a native Windows Garage — a WinUI 3 app on .NET that embeds CPython the way the Mac app does with PythonKit, per-user service processes in place of XPC, and Windows design idioms.
---

# Garage for Windows — plan

Goal: a native Windows Garage with the same shape as the Mac app:

- one app that owns a private Postgres + pgvector cluster;
- independent per-user service processes that embed CPython and run `garage_rag`, as the XPC
  services do;
- a llama.cpp inference service;
- `garage` / `garage-mcp` launchers for terminals and stdio MCP clients;
- a UX that does what the Mac app does, in Windows idioms.

Written against `v1.5-beta` at `2454039` (2026-09-27), and re-checked against `main` `b82c6d2` and
`v1.5-beta` `839bc39` on 2026-09-29 (details in windows-ui.md §8). This plan supersedes the "native Windows"
column in [wsl.md](wsl.md), which was written against `main` and is stale on this branch in places
(Python 3.14, sockets, the gRPC token).

**Verdict: feasible. Expect roughly 3 months to an MVP and 5–6 months to parity** for one engineer;
this is a guess until the Phase 0 spikes land.

- **Cheap:**
  - `garage_rag` is mostly portable;
  - `windows.yaml` already builds Postgres + pgvector and CPython with MSVC and runs
    `test_postgres.py` against them;
  - `proto/garage.proto` is the contract a C# app generates its client from.
- **Expensive:**
  - re-implementing `GarageApp` (views plus `AppState` and the services behind them) in WinUI 3;
  - porting the endpoint hardening `v1.5-beta` added (Unix sockets, peer checks, the in-process
    llama bridge) to Windows primitives.

---

## 0. Scope

In scope:

- **The app.** WinUI 3 (Windows App SDK) on .NET, packaged as MSIX, x64 first and arm64 second.
- **The services.** One per-user process per service, each embedding CPython 3.14 from `//ext/python`
  and `garage_rag` from `garage_python/`, except the llama and download services, which are native.
- **Postgres** 18 + pgvector (+ AGE when built) from `//ext/postgres` pins, built by `windows.yaml`.
- **llama.cpp** from `//ext/llama_cpp`, with Vulkan and CPU backends.
- **Launchers:** `garage.exe` and `garage-mcp.exe`.
- **Distribution:** Microsoft Store, plus direct download with auto-update, from one MSIX.

Out of scope (see §7):

- Messages `chat.db` ingest, which has no Windows counterpart.
- Outlook `.pst`/`.msg`.
- Windows Search integration.
- A free-threaded (3.14t) Windows build. It is designed for but not shipped, matching the Mac, where
  the `python-freethreaded` CI job is informational.

## 1. Where we start (grounding, `v1.5-beta`)

### 1.1 What the Mac app is

| macOS piece | What it does | Python it drives |
|---|---|---|
| `GarageApp` (22k lines of Swift) | SwiftUI UI, `AppState`, `PostgresService`, `OperationRunner`, `FirstRunCoordinator`, `IngestService` | via gRPC |
| `PythonXPCService` framework | `GaragePythonEmbed.c` (isolated `PyConfig`, GIL acquire/release), PythonKit, `GarageXPCServiceBase` / `GarageXPCServiceHost` (managed services, self-tests, log streaming), `GarageSockets`, `GaragePostgresEndpoint`, peer requirement | — |
| `GarageXPCService` | Hosts the `GarageService` gRPC facade | `garage_rag.service.server` |
| `GarageIngestXPCService` | Runs ingest, persisting through the facade | `garage_rag.ingest`, `db.engine` |
| `GarageEmbedXPCService` | Embed worker | `garage_rag.embed` |
| `GarageMCPServerService` | Long-lived MCP HTTP server (opt-in on this branch) | `garage_rag.mcp_server.server` |
| `LlamaXPCService` + `LlamaEngine` / `LlamaServiceHost` / `LlamaModelLoader` | llama.cpp (Metal); NSXPC for the app and `handleServerRequest`; llama-server HTTP on `s/llama` | — |
| `ModelDownloadXPCService` | GGUF downloads with SHA-256 checks against pinned presets | — |
| `GarageLauncher` | `garage` / `garage-mcp` helper bundles: start the app hidden, read the Keychain, export the endpoints | — |
| `GarageUpdater` | Sparkle (Developer ID), inert in App Store builds | — |

The Python surface each host touches is small: six `garage_rag` modules imported, plus two
host-provided C function pointers:

- `xpc/host.py` `install_model_loader(address)`: `int32 loader(const char *alias, char *msg, size_t cap)`.
- `inference/bridge.py` `install(request, release)`: `int32 request(method, path, body, timeout,
  int32 *status, char **reply)` and `void release(char *)`.

ctypes releases the GIL around both calls.

### 1.2 Endpoint hardening already on this branch

From [v1.5-beta-ipc-hardening.md](v1.5-beta-ipc-hardening.md) and CLAUDE.md, all of which Windows
must match:

- **Sockets.** Postgres, the gRPC facade and the llama HTTP API listen on Unix sockets in `s/`
  (0700) at the root of the App Group container. An endpoint whose socket path would overflow
  `sun_path` keeps its old loopback port.
- **gRPC token.** `GARAGE_GRPC_TOKEN` is a random per-launch token (`service/auth.py`) required on
  every call but `EnsureLlamaModel`. Without a token, `CONFIG_CHANGING_METHODS` (`SetSetting`,
  `AddSource`, `McpInstall`, `InitDb`, ...) are answered only by a server bound to the Unix socket;
  on TCP they get `PERMISSION_DENIED`.
- **Peer checks.** Every XPC listener requires peers signed by team `DWVXMLB45Y`
  (`GarageXPCPeerRequirement`).
- **Credentials.** The Postgres password lives in the data-protection keychain under the App Group
  access group.
- **MCP.** Assistants register stdio `garage-mcp`; the HTTP server on `127.0.0.1:8787` runs only
  once the user turns it on (`garage.mcp.httpEnabled`).

### 1.3 What in `garage_rag` is not portable

Everything else is portable: path handling normalises separators (`walker.py`, `pathrules.py` use
`as_posix()`), and there is no `fork`.

| Where | What | Windows fix |
|---|---|---|
| `garage_python/pyproject.toml:89` | `environments` is darwin/arm64 only | Add `sys_platform == 'win32' and platform_machine == 'AMD64'` (and `ARM64`); repin |
| `config/__init__.py:200`, `net/egress.py:174`, `service/client.py:198` | A socket path "must start with `/`" | `os.path.isabs` (or `Path.is_absolute`) |
| `service/server.py:1555–1598` | Socket bind: `mkdir(mode=0o700)`, `chmod(0o600)`, `S_ISSOCK`, `fcntl` lock, `AF_UNIX` staleness probe | Windows branch: the host creates the directory with an owner-only ACL; lock with `msvcrt.locking`; skip the probe or port it (see §2.2) |
| `inference/transport.py` → `httpx.HTTPTransport(uds=)` | A llama socket through httpcore needs `socket.AF_UNIX`, which as far as I know CPython does not expose on Windows (verify) | Inside services, use the in-process bridge (§2.4); outside, loopback + token |
| `native/__init__.py:23` | Loaded-library lookup is Darwin-only (`.dylib`) | Enumerate loaded modules (`EnumProcessModules` / `GetModuleFileNameW` via ctypes) for `tesseract*.dll`, `libpq.dll` |
| `libpq.py` | libpq name set lists `.dylib` names | **Done differently:** `pyproject.toml` depends on `psycopg[binary]` on `win32`, whose wheel bundles libpq, so psycopg never looks for a system one. Revisit only if the app ships its own `libpq.dll` from the Postgres build |
| `extract/placeholder.py:83`, `ingest/materialize.py:66` | Placeholder xattrs and the dataless I/O policy (`setiopolicy_np`) are Darwin-only | Cloud Files attributes (§5.2) |
| `extract/imageio.py:115` | HEIC through macOS ImageIO | A host decode bridge over WIC (§5.3) |
| `extract/messages.py`, `ingest/conversations.py` | Apple Messages `chat.db` | Not on Windows; hide the Messages source template |
| `mcp_server/install.py` | Client targets under `~/Library/Application Support` | Windows targets (§4.4) |
| `attribute/git.py:51` | macOS git-stub check | Harmless on Windows; git may be absent, in which case attribution falls back (§5.4) |
| `config/__init__.py:260` | `pwd` in `expand_home` | Already guarded by `APP_SANDBOX_CONTAINER_ID`, which Windows never sets |

Windows CI runs only `test_postgres.py` today. The whole suite has to run there (§8).

## 2. Architecture

```
┌────────────────────────── Garage.App (WinUI 3, .NET) ─────────────────────────┐
│ tray icon · NavigationView pages · AppState (MVVM) · PostgresSupervisor       │
│ ServiceManager (Job Object) · gRPC client (GarageService, from garage.proto)  │
└───────┬───────────────┬────────────────┬───────────────┬──────────────┬───────┘
        │ control pipes (gRPC over named pipes, peer = same package)   │
        ▼               ▼                ▼               ▼              ▼
  Garage.Core      Garage.Ingest     Garage.Embed    Garage.Mcp     Garage.Llama
  (CPython:        (CPython:         (CPython:       (CPython:      (native llama.cpp,
  service.server)  ingest)           embed)          mcp_server)    Vulkan/CPU)
        │  GarageService gRPC (token; UDS if gRPC supports it — §2.2)  ▲
        └───────────── inference bridge / model loader (fn ptrs) ──────┘
                                   │
                              Postgres 18 (UDS in LocalState\s, SCRAM)
```

### 2.1 Services: per-user processes, not Windows Services

The Service Control Manager is the wrong analogue for XPC. Its services run in session 0 under
service accounts, while Garage's data, the user's files, OneDrive and credentials belong to the
signed-in user. XPC services are per-user, launched by the app, and die with it. The Windows
equivalent:

- **Processes.** One full-trust exe per service, declared in the MSIX manifest, started by the app's
  `ServiceManager` and assigned to a **Job Object** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so
  every service dies with the app, as XPC services do.
- **Common protocol.** `services.proto` mirrors `GarageCommonXPCServiceProtocol`: `Ping`,
  `GetServiceInfo`, `UpdateConfiguration`, `RunDiagnostic`, `GetServiceStatus`, `RunSelfTests`,
  `RestartServices`, `FetchLogs`, `FetchBufferedOutput`, `ClearLogs` and a server-streaming
  `SubscribeToLogStream` (in place of the reverse `GarageXPCLogReceiverProtocol`).
  Service-specific RPCs extend it, as `GarageXPCServiceProtocol` / `GarageMCPServerServiceProtocol`
  do.
- **Transport.** gRPC over **named pipes** (supported by ASP.NET Core's server and
  `Grpc.Net.Client` on .NET 8+), one pipe per service, named with the per-session prefix. The pipe
  ACL grants the current user's SID only.
- **Peer check** (the `GarageXPCPeerRequirement` analogue): on connect, `GetNamedPipeClientProcessId`
  → `OpenProcess` → `GetPackageFamilyName`, and refuse any client whose package family name isn't
  Garage's. Unpackaged development builds fall back to checking that the client's image path is
  inside the app's directory, like the Mac's looser requirement for local signing.
- **`GarageServiceHost`** ports `GarageXPCServiceBase` / `GarageXPCServiceHost`: managed services
  with states and restart counts, status snapshots, self-tests (`GarageXPCSelfTests`), stdout/stderr
  capture (`GarageXPCOutputCapture`), a file logger, and a crash handler that writes a minidump.

**Built so far** (windows-ui.md U3): one `Garage.Services.exe`, run once per service (core, ingest,
and mcp while its switch is on)
rather than one executable each; `services.proto` with Ping, status, self tests, logs, the log stream,
Shutdown and the ingest calls; Kestrel on named pipes with `CurrentUserOnly`; the peer check (the app
that started the service, or the service's own folder; the package check waits for the MSIX); the
Job Object; and `ServiceManager` in `Garage.App.Core`. Not yet: `UpdateConfiguration`, restart
counts, minidumps, `PostgresSupervisor` and the Credential Locker.

The App Store build on this branch hosts `GarageIngestXPCService` and `GarageXPCService` in the
app's own process. The Windows Store has no such constraint on full-trust MSIX processes, so keep
them separate; crash isolation is the point.

### 2.2 The GarageService gRPC endpoint

`service/auth.py` already gives the right answer for a transport without owner-only sockets. With a
token configured, every call is authenticated and config-changing methods are allowed. So:

- **Baseline (works today):** loopback TCP with `GARAGE_GRPC_TOKEN`, generated per launch by the app.
  - Services get it in their environment, as on macOS.
  - The launchers read it from a token file in `LocalState\s\`. That directory is owner-only by ACL
    and inside the package, the same trust boundary as the Mac's 0700 `s/`.
  - Add **`Host`/authority validation**, so a DNS-rebinding page cannot reach it. Browsers can't
    speak h2c gRPC, but the check costs nothing.
- **Hardening (spike S2):** Windows 10 1803+ has AF_UNIX, and Postgres uses it (§2.5). Whether
  gRPC core accepts `unix:C:\...` on Windows is **unverified**.
  - If it does, bind there with an owner-only ACL on the directory, as on macOS.
  - The `unix_socket=True` path in `config_change_allowed` then holds on Windows too.
  - If not, the token alone stands.
- **Keep `auth.py` on Windows.** Its docstring says the module goes away once the Mac talks to the
  server over XPC with no socket. On Windows the token remains the guard unless the facade moves
  onto the named-pipe control plane, so gate its removal by platform.

### 2.3 Embedding CPython: the PythonKit equivalent

On macOS the stack has three layers:

- **`GaragePythonEmbed.c`:** isolated `PyConfig` with `home` = `site-python`, explicit `sys.path`,
  plus `AcquireGIL`/`ReleaseGIL`;
- **PythonKit:** dynamic member lookup and calls;
- **Swift:** keeps the interpreter on one host thread and releases the GIL so the gRPC server's
  worker threads run.

**Decided and built: an owned bridge, `Garage.Python`** (`winapp/src/Garage.Python`; see
`winapp/README.md`). It differs from the original recommendation in one respect: there is no C shim.

1. **Start-up through PEP 741.** 3.14's `PyInitConfig` API sets `PyConfig` options by name
   (`PyInitConfig_SetInt/SetStr/SetStrList`, `Py_InitializeFromInitConfig`), so C# calls
   `python314.dll` directly and no struct layout has to be mirrored. The options match
   `GaragePythonEmbed.c`'s: isolated, UTF-8 mode, no bytecode, no signal handlers, and an explicit
   `module_search_paths` (`Lib`, `DLLs`, the bundle's site-packages, extras) with no landmark search.
2. **`site` handled explicitly.** The interpreter starts with `site_import=0`, then
   `site.addsitedir(<bundle site-packages>)` processes that folder's `.pth` files only.
   - On Windows `site.main()` would also add the home folder and `home\Lib\site-packages`, which
     exist, and would let a package installed into the interpreter shadow the bundle's.
   - The bundle still needs `.pth` processing: pywin32, a Windows-only dependency the MCP SDK pulls
     in, puts `win32`, `win32\lib` and `pythonwin` on the path that way.
   - Both were found by the tests.
3. **`PythonObject : DynamicObject`** over an owned `PyObject*`, as planned:
   - dynamic members, calls with keyword arguments, and indexing (a multi-index passes a tuple);
   - conversions by cast;
   - `PythonException` with the qualified type, message, traceback and exception object.
   - Every operation takes the GIL itself, re-entrantly. A collected object is decref'd the next
     time any thread takes the GIL, never on the finalizer thread.
4. **`GilScope`** (`Python.Gil()`, a `ref struct` over `PyGILState_Ensure/Release`) and
   **`AllowThreadsScope`**. There is no dedicated interpreter thread: any thread may call in.
5. **Callbacks** are `[UnmanagedCallersOnly]` methods passed as integers, and
   `Interop.NativeUtf8` plays `strdup`/`free`, as planned.

Spike S1 is done. The tests embed CPython 3.14 and cover:
- isolation and `sys.path`;
- 64 concurrent host threads;
- Python threads running while no host thread holds the GIL;
- conversions and exceptions;
- deferred release;
- ctypes callbacks, including one that calls back into Python;
- both `garage_rag` host contracts (`inference.bridge.install` and
  `xpc.host.install_model_loader`) against the real modules;
- `create_grpc_server` from `garage_rag.service.server`, started in the embedded interpreter and
  answering a `GarageClient` ping.

pythonnet and CSnakes were not needed.

Why not adopt a library outright, as recorded when this was open:

- The bundled interpreter is **3.14.7** (`ext/python/python.MODULE.bazel`), and the branch runs
  **3.14t** in CI.
- pythonnet's 3.14 support and its free-threading support were both unverified; its runtime also
  wants to own initialisation.
- CSnakes had the same version questions and adds a source generator to the build.
- The call surface is about ten call sites. The owned layer uses only exported functions (no
  macros), so it carries no version lag and should hold under free-threading. A `python314t.dll` run
  is still to do.

### 2.4 Inference: the llama service and the bridge

- **`Garage.Llama.exe`** ports `LlamaEngine` (llama.cpp C API over P/Invoke to `llama.dll` /
  `ggml*.dll` built from `//ext/llama_cpp`) and `LlamaServiceHost`. It has two front ends, as on
  macOS:
  - the control pipe, for load/unload/health/test calls and `HandleServerRequest`;
  - a llama-server-compatible HTTP API for Python outside the services.
- **Backends:** Vulkan (NVIDIA, AMD and Intel GPUs) plus CPU fallback, selected at load. CUDA is
  optional later. `known-answers.yaml` gains a Windows x64 CPU job and a Vulkan job, both held to
  `MIN_COSINE` (0.98) against the Apple-silicon reference, as Metal and Linux x86-64 already are.
- **In-service Python** (`Garage.Core`, `Garage.Embed`, `Garage.Mcp`): the host installs the
  `inference.bridge` request/release pointers and the `xpc.host` model loader. They forward over the
  host's control pipe to `Garage.Llama`. No socket or port is involved, matching the NSXPC path.
- **Python outside the services** (launchers, a venv `garage`):
  - loopback HTTP on `127.0.0.1:8790` with a per-launch **`GARAGE_LLAMA_TOKEN`** bearer header and
    a `Host` check (both are new; the macOS HTTP API had neither before it moved to a socket);
  - or the AF_UNIX path, if spike S2 finds httpcore can do UDS on Windows.
  - `inference/transport.py` adds the header when the variable is set; the destination is loopback,
    so `egress.py` needs no new allowlist entry.

### 2.5 Postgres

**Built** (windows-ui.md U3): `PostgresSupervisor` in `Garage.App.Core`, the password in Windows
Credential Manager (the same store the Credential Locker uses; package scoping comes with the
MSIX), loopback TCP on 14824 until spike S2, and Database Reset with relaunch.

- **Build and supervision.** Built by `windows.yaml` (Postgres, pgvector, ICU, zlib; add OpenSSL and
  AGE) and supervised by the app, not the Windows service manager: `initdb`, `pg_ctl start`, and
  `pg_ctl stop -m fast` in place of SIGINT. On Windows `pg_ctl` signals through the
  `pgsignal_<pid>` pipe, and the same rule applies: never a smart shutdown that waits on pooled
  connections.
- **Transport.** Postgres has supported Unix sockets on Windows since 13. Set
  `unix_socket_directories` to `LocalState\s`, `listen_addresses=''`, and keep
  `local ... scram-sha-256`.
  - Windows `sun_path` is 108 bytes, and `...\AppData\Local\Packages\<PFN>\LocalState\s\.s.PGSQL.14824`
    can overflow it with a long user name, so keep the macOS rule: overflow → loopback port 14824
    with SCRAM.
  - Verify that libpq on Windows accepts a drive-letter socket directory in `host=` (spike S2).
- **Password.** Stored in the package's **Credential Locker** (`Windows.Security.Credentials.PasswordVault`),
  which is scoped to the package identity. That makes it the analogue of the App Group keychain
  access group: the app, its services and the execution-alias launchers share it; other apps can't
  read it.
- **Defender.** Real-time scanning of `pgdata` slows Postgres badly. The app can't add an exclusion
  (that needs elevation and changes a security setting), so Troubleshooting documents it and the
  Database page detects slow fsync and links there.
- **Database Reset.** The same flow as `DatabaseResetSheet` → `resetDatabaseAndRelaunch`: stop
  services, delete `pgdata`, `AppInstance.Restart("--after-database-reset <pid>")`, and the new
  instance waits for the old one to exit before `initdb`.

### 2.6 Data location

The App Group container's analogue is the package's **`ApplicationData.Current.LocalFolder`**
(`%LOCALAPPDATA%\Packages\<PFN>\LocalState`). It is private to the package and shared by every
process in it, including the execution-alias launchers.

```
LocalState\
  garage.json   pgdata\   models\   logs\
  s\            ← owner-only ACL: Postgres socket, gRPC socket or token file, llama token
```

`garage.json` stays the one config. `~/.garage.json` / `./garage.json` keep working for a venv
`garage`. Unpackaged development builds use `%LOCALAPPDATA%\Garage`, as unentitled Mac builds use
`~/Library/Application Support/GarageApp`.

### 2.7 Launchers

`garage.exe` and `garage-mcp.exe` are Native AOT C# (fast start matters for stdio MCP clients),
exposed as MSIX **app execution aliases**, so they are on `PATH` and run with package identity.
They do what `GarageLauncher` does:

- When a command needs the database and the socket or port doesn't answer, start the app with
  `--background`.
- Read the Postgres password from the Credential Locker, export `GARAGE_DATABASE_URL` (socket
  directory or port) and `GARAGE_GRPC_SOCKET` or the token, then exec the embedded interpreter on
  `garage_rag.cli` / `garage_rag.mcp_server`.
- Stdio registrations therefore carry no database URL or secret.
- `garage quit` signals every running Garage through a named event (in place of the distributed
  notification) and waits.

### 2.8 Egress, on the .NET side too

The Python guarantees carry over unchanged: one choke point, the allowlist, communications
loopback-only, and the AST test. The C# code has its own outbound traffic (model downloads, update
checks), so give it the same shape:

- one `Garage.Net` assembly owns `HttpClient`, with no proxy, no automatic redirects, and origins
  pinned to the model catalog hosts and the update feed;
- `Microsoft.CodeAnalysis.BannedApiAnalyzers` bans `HttpClient`, `WebRequest`, `Socket` and friends
  everywhere else, failing the build as `test_egress_block.py` fails the suite.

## 3. UX: the same app in Windows idioms

The information architecture matches the Mac app page for page; the idioms change. The
implementation plan for the UI (projects, page-by-page mapping, phases U0–U5, testing) is
[windows-ui.md](windows-ui.md).

| macOS | Windows |
|---|---|
| Menu-bar extra (`MenuBarView`) | **Notification-area icon.** Left-click opens a Fluent flyout (service status, quick search, Ask Garage, quick add, "Update Everything"); right-click opens a context menu (Open Garage, Pause maintenance, Quit). WinUI 3 has no tray API: H.NotifyIcon.WinUI or `Shell_NotifyIcon` |
| Sidebar `ContentView` | `NavigationView` (left): Status, Search, Documents, Sources, Models, MCP, Database, Logs. **Settings in the navigation footer**, not a separate preferences window |
| Window chrome | Mica backdrop, custom title bar, Segoe Fluent Icons, follows light/dark, accent colour and text scaling |
| `PageStatus` banners | `InfoBar` (informational / warning / error / success) |
| `DatabaseResetSheet`, confirmations | `ContentDialog` |
| `FirstRunView` (services → sources → models → MCP clients) | A full-window setup assistant with the same four steps and a progress header; `TeachingTip`s after it |
| `SourcePresets` templates | Windows templates: Documents, Desktop, OneDrive, Dropbox, a code folder; Messages hidden, Mail limited to `.eml` |
| Folder access (`VolumeAccessService`) | `FolderPicker` (no security-scoped bookmarks; a full-trust MSIX reads the user's files) |
| Job progress in `OperationRunner` | App notifications (toasts) with progress bars for Update Everything, backfill and enrich-facts, plus in-page progress |
| Login item | MSIX `StartupTask`, which the user controls in Settings > Apps > Startup |
| `garage` on `PATH` | App execution aliases |
| Keychain | Credential Locker (package-scoped) |
| Sparkle / App Store | Microsoft Store, plus an `.appinstaller` feed for direct download from the same MSIX; the Store build ignores the feed, as App Store builds make Sparkle inert |
| `BugReportView` | Same flow; attaches `logs\` and service self-test output; no OSLog, so `OSLogStreamService` becomes the services' log streams |
| Taskbar | Jump list: Search, Add Source, Update Everything |
| Accessibility | Narrator names on every control, full keyboard navigation, high-contrast themes |

State management is MVVM with **CommunityToolkit.Mvvm** (`[ObservableProperty]`,
`[RelayCommand]`), the closest match to `AppState`'s `@Published` and the service objects.
Page view models reuse the Mac's decomposition (`OperationRunner`, `IngestService` with its queue,
`cancelAll()`, `cancel(source:)`) so behaviour stays the same across platforms.

## 4. Python changes

1. **Lockfile:** Windows environments in `pyproject.toml`; `./tools/repin`; re-verify the macOS
   Bazel build, since `@pypi` reads the same lock. Expect Windows-only packages to appear:
   `pip install -e garage_python` on Windows 3.14 already pulls in pywin32, through the MCP SDK.
   Every dependency installs from wheels there today.
2. **Paths and sockets:**
   - absolute-path checks via `os.path.isabs`;
   - a Windows branch for the socket bind in `service/server.py` (ACL set by the host, `msvcrt`
     lock, no `S_ISSOCK`);
   - `GARAGE_LLAMA_TOKEN` in `inference/transport.py`.
3. **Native lookup:** `native.loaded_library` on Windows (module enumeration), and `libpq.dll` in
   `libpq.py`.
4. **`mcp-install` Windows targets:**
   - `%APPDATA%\Claude\claude_desktop_config.json`;
   - `~\.claude.json`;
   - the VS Code / Cline paths under `%APPDATA%\Code\User\...`;
   - the stdio command is the `garage-mcp` execution alias
     (`%LOCALAPPDATA%\Microsoft\WindowsApps\garage-mcp.exe`), with no database URL, as on macOS.
   - **Done in U2** (windows-ui.md): the `%APPDATA%` targets (Claude Desktop, Cline in Cursor and
     VS Code, Zed), and platform-aware versions of the three tests below. Still to do: register the
     `garage-mcp` execution alias once the MSIX exists (§2.7).
   - Three tests in `tests/test_mcp_install.py` assumed POSIX and failed on Windows. They passed on
     Linux CI:
     - `test_non_executable_launcher_is_ignored` depends on the Unix executable bit;
     - `test_sandboxed_service_targets_the_account_home` imports `pwd`;
     - `test_unsandboxed_targets_follow_home` sets `HOME`, which `Path.home()` ignores on Windows in
       favour of `USERPROFILE`.

     Make them platform-aware alongside the Windows targets.
5. **Placeholders and HEIC:** §5.
6. **Windows CI:** the whole suite (§8).

## 5. Platform features

### 5.1 Extraction parity

| Feature | Windows |
|---|---|
| Text, Markdown, code, PDF, Office, `.eml` | As-is |
| Images via Tesseract | The app ships its own codec-less Tesseract built with MSVC, never a user-installed one (§5.5); `tessdata` beside the DLL; found through `native.loaded_library` |
| HEIC/HEIF | §5.3 |
| `.emlx`, Messages `chat.db` | Not on Windows |
| Outlook `.msg`/`.pst` | Follow-up (§7); would be `communication` |

### 5.2 Cloud placeholders (OneDrive, Dropbox, iCloud for Windows)

All three use the Cloud Files API. Python exposes `os.stat().st_file_attributes` on Windows, so
`is_placeholder` checks `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x400000),
`FILE_ATTRIBUTE_RECALL_ON_OPEN` (0x40000) and `FILE_ATTRIBUTE_OFFLINE` (0x1000) without opening the
file.

On macOS the pipeline thread also turns the dataless I/O policy off, so that only the materialize
thread can trigger a download. **Whether Windows has a per-thread equivalent is an open question.**
`RtlSetThreadPlaceholderCompatibilityMode` changes how placeholders are *presented*, not whether
reading hydrates them. Until research says otherwise:

- check attributes before every open (a race remains, and `MaterializationBudget` still bounds it);
- add a test that a placeholder is never opened outside `materialize.py`.

### 5.3 HEIC through the host

Same licensing constraint as the Mac: no libheif (LGPL/GPL, HEVC patents). Windows decodes HEIC
through WIC, but only with the *HEIF Image Extensions* and the *HEVC Video Extensions* (a paid Store
item that is often missing) installed. Reuse the bridge pattern:

- the host installs an `image_decode(path, &rgba, &w, &h)` function pointer backed by
  `Windows.Graphics.Imaging.BitmapDecoder`;
- `extract/imageio.py` gains a Windows implementation that calls it;
- when the codec is missing, the file gets an `ingest_outcomes` row that says so, and the Sources
  page links to the extension in the Store.

### 5.4 Git attribution

- Attribution needs `git` on `PATH`. Git for Windows is common but not guaranteed, and bundling
  MinGit (GPL-2.0) adds a notices and source obligation.
- Recommendation: don't bundle; detect it.
  - The Sources page shows "Git not found — authorship falls back to metadata and path rules" with
    a link.
  - `garage scan` reports it.
- Carry over the review's git hardening (`-c core.fsmonitor=false`, `GIT_CONFIG_NOSYSTEM=1`), which
  applies on every platform.

### 5.5 Tesseract without GPL code

**The problem.** The Tesseract most Windows users have is UB Mannheim's build: the one Tesseract's
docs point to, `winget install UB-Mannheim.TesseractOCR`, and what the README's CLI quickstart
installs. It is built with MSYS2/MinGW and installs about 50 DLLs beside `libtesseract-5.dll`
(Apache-2.0), among them:

- **`libjbig-0.dll` (JBIG-KIT): GPL-2.0-or-later**, pulled in through libtiff;
- the GTK text stack (glib/gio/gobject, pango, cairo, fribidi, libthai, graphite2): LGPL-2.1+,
  pulled in by the training tools;
- the MinGW C++ runtime (`libstdc++-6`, `libgcc_s_seh-1`): GPL-3 with the GCC Runtime Library
  Exception.

The installer carries no license text for any of them; its only license file is Tesseract's
(`doc\LICENSE`). Using that build on your own machine is fine, and the CLI may keep loading it:
Garage does not distribute it. **The app must never ship it.** Redistributing `libjbig` in the MSIX
would put GPL obligations on the package, and the rest would need notices nobody supplied.

**The rule: the app ships its own Tesseract, built the way the macOS app's is, and loads only that.**
`ext/leptonica/BUILD.bazel` and `ext/tesseract/BUILD.bazel` already define a build whose only
licenses are Apache-2.0 and BSD-2-Clause. Windows repeats it with MSVC and CMake from the same pins
(`ext/leptonica/leptonica.MODULE.bazel`, `ext/tesseract/tesseract.MODULE.bazel`, fetched by
`tools/windows/fetch_ext.py`, which already maps `leptonica` and `tesseract` to those files):

- **Leptonica 1.87.0, static, with every codec off:**
  - `ENABLE_GIF`, `ENABLE_JPEG`, `ENABLE_OPENJPEG`, `ENABLE_PNG`, `ENABLE_TIFF`, `ENABLE_WEBP` and
    `ENABLE_ZLIB` set to `OFF`, plus `BUILD_PROG=OFF`, `SW_BUILD=OFF`, `BUILD_SHARED_LIBS=OFF`.
  - No codec is needed: `extract/tesseract.py` hands Tesseract pixels Pillow already decoded
    (`TessBaseAPISetImage`), so Leptonica never reads an image file.
  - Dropping libtiff drops JBIG, the GPL component, with it.
- **Tesseract 5.5.3, shared:**
  - `BUILD_TRAINING_TOOLS=OFF`, which removes pango, cairo, glib and ICU;
  - `DISABLE_ARCHIVE=ON`, `DISABLE_CURL=ON`, `DISABLE_TIFF=ON`, `GRAPHICS_DISABLED=ON`,
    `OPENMP_BUILD=OFF`, `BUILD_TESTS=OFF`, `INSTALL_CONFIGS=OFF`;
  - `TESSERACT_DISABLE_DEBUG_FONTS` and `TESSERACT_IMAGEDATA_AS_PIX` defined (`/D` in
    `CMAKE_CXX_FLAGS`), for the same reasons `ext/tesseract/BUILD.bazel` gives: without codecs,
    DebugPixa's TIFF-encoded fonts and the PNG round trip of each text line would fail.
- **MSVC, not MinGW.** The C++ runtime is then the Visual C++ Redistributable (`vcruntime140`,
  `msvcp140`) under Microsoft's redistribution terms, not `libstdc++`/`libgcc`.
- **Language data:** `eng.traineddata` from `tessdata_fast` 4.1.0 (Apache-2.0), in `tessdata\`
  beside the DLL. It is an `http_file` in `tesseract.MODULE.bazel`; check that `fetch_ext.py`
  handles `http_file` as well as `http_archive`, and extend it if not.
- **The result:** one Tesseract DLL plus `eng.traineddata`, whose licenses are exactly the three
  entries already in `NATIVE_COMPONENTS` for macOS (Tesseract, tessdata_fast, Leptonica). The
  pinned version (5.5.3) is also newer than UB Mannheim's 5.4.0.

**Enforcement: checks that fail the build, so GPL code cannot come back unnoticed.**

1. **An import allowlist for the Tesseract DLL.**
   - A `windows.yaml` step reads the built DLL's imports (`dumpbin /dependents`, or `pefile` from
     Python) and fails on any DLL outside a short allowlist: the `api-ms-win-*` sets, `KERNEL32`,
     the other system DLLs the first build actually needs, `VCRUNTIME140`, `VCRUNTIME140_1` and
     `MSVCP140`.
   - A codec, libtiff or a MinGW runtime appearing fails the job. Record the exact allowlist from
     the first green build.
2. **A package audit when the MSIX is built.**
   - List every DLL in the package, and fail on any that is not mapped to a `NATIVE_COMPONENTS`
     entry (or to a NuGet package in the notices).
   - Also fail on any name in a denylist: `libjbig*`, `libgcc_s*`, `libstdc++*`, `libwinpthread*`,
     `*pango*`, `*cairo*`, `libglib*`, `libgio*`.
   - This covers every future native dependency, not only Tesseract.
3. **Loader order.**
   - The host loads the bundled DLL by path at start-up, as `PythonXPCService.framework` links
     libtesseract on macOS. `native.loaded_library` on Windows (§1.3) finds it, and
     `extract/tesseract.py` checks that first.
   - `_find_windows_library`, the search for UB Mannheim's `libtesseract-5.dll` added for the CLI,
     stays a CLI-only fallback. Inside the app, set `GARAGE_BUNDLED_NATIVES=1` in the services'
     environment and have `tesseract.py` skip that search when it is set.
   - A missing bundled DLL then fails loudly rather than silently loading a user-installed build.
     This is about predictable behaviour: loading a user's own copy is not redistribution.
   - Confirm the DLL's name from the first MSVC build (CMake names it `tesseract<major><minor>.dll`
     there, e.g. `tesseract55.dll`), and add it to the lookup's patterns.

**What stays as it is:** the README's CLI quickstart keeps `winget install UB-Mannheim.TesseractOCR`.
Users install that build themselves, and Garage neither ships nor modifies it.

## 6. Build and distribution

- **Build system — decision needed.** Bazel has weak support for WinUI 3 and MSIX. Recommendation:
  - **decided:** `winapp/` builds with the .NET 10 SDK (`dotnet build winapp/Garage.slnx`), with no
    Bazel rules and no `BUILD` files under it; the `winapp` job in `windows.yaml` builds and tests
    it against the CPython that workflow builds;
  - native dependencies come from `windows.yaml`'s MSVC builds, pinned by `ext/*/*.MODULE.bazel`
    through `tools/windows/fetch_ext.py`, which already happens for Postgres and CPython;
  - extend it to llama.cpp (Vulkan + CPU), Tesseract and Leptonica (codec-less, with MSVC; §5.5),
    OpenSSL and AGE;
  - `site-packages` comes from `uv pip install --target` against the locked Windows environment.
  - This departs from CLAUDE.md's "one Bazel monorepo"; CLAUDE.md says so under "Windows app".
- **Notices.** Add the Windows natives and the NuGet packages (Windows App SDK, CommunityToolkit,
  H.NotifyIcon, Grpc.*) to `tools/third_party_notices.py` `NATIVE_COMPONENTS`, and ship
  `THIRD_PARTY_NOTICES.txt` in the package. The Windows-only Python packages from the lockfile
  (pywin32, PSF licence) come in through `uv.lock` once it carries a Windows environment.
  - The package audit in §5.5 checks the reverse direction: no DLL ships without a notices entry,
    and none from the GPL denylist ships at all.
- **Signing and distribution.** One MSIX signed with an EV or Azure Trusted Signing certificate,
  distributed two ways:
  - **Microsoft Store:** the Store re-signs it;
  - **direct download:** an `.appinstaller` feed on `garagerag.app` with `OnLaunch` update checks,
    the counterpart of the Sparkle appcast in `docs/appcast.xml`. The Mac now has a beta channel
    in Sparkle; mirror it with a second feed (`garage-beta.appinstaller`) that Settings can switch
    to. The Store build uses package flights for betas instead.
  - **Tips:** the Mac App Store build (on `v1.5-beta`) offers tips as in-app purchases. The Store
    build offers the same as Store add-ons; the `.appinstaller` build has none.
- **Capabilities.** `runFullTrust` and `internetClient` (downloads, updates). No broad file-system
  capability is needed, since full-trust processes read the user's files.
- **Built** ([winapp/packaging](../../winapp/packaging/README.md)):
  - `stage.ps1` lays out the shipped folder from `windows.yaml`'s Python and Postgres builds;
  - `msix.ps1` packs it as the MSIX, with a `StartupTask` and the notification activator in the
    manifest, and writes the `.appinstaller` feed;
  - `msi.ps1` builds a per-machine MSI with WiX v5, for IT deployment, and `Garage-Setup.exe`, a
    bootstrapper that installs Microsoft's Visual C++ Redistributable first when needed;
  - the Visual C++ runtime Postgres and ICU need always comes from Microsoft's signed
    Redistributable. The MSIX carries its DLLs, since the VCLibs framework package stops at 14.39,
    older than the toolset that builds Postgres;
  - CI's `package` job builds all three, unsigned.
  - Not yet: the execution-alias launchers, llama.cpp and Tesseract (none is built for Windows yet),
    and signing in CI.

## 7. Out of scope and follow-ups

- Outlook `.msg`/`.pst` extraction (communications; needs a licence-compatible parser).
- A Windows counterpart for Messages. Phone Link has no public store; nothing to do.
- The free-threaded 3.14t interpreter on Windows. The bridge is designed to work under it; ship it
  when the Mac does.
- ARM64 llama.cpp backends beyond CPU (Qualcomm Adreno via Vulkan is uneven).

## 8. Testing and CI

- **Python:** extend `windows.yaml` to run the whole venv pytest suite on the built interpreter, not
  only `test_postgres.py`. New tests cover:
  - Windows socket and ACL handling;
  - `mcp-install` targets;
  - Cloud Files attribute detection (fixture attributes via a mocked `os.stat`);
  - the `GARAGE_LLAMA_TOKEN` header;
  - `native.loaded_library` on Windows.
- **Egress:** `test_egress_block.py` unchanged; BannedApiAnalyzers on the C# side (§2.8).
- **C#:** xUnit for the bridge (import, call, kwargs, exception translation, GIL across threads,
  callbacks through `[UnmanagedCallersOnly]`), `GarageServiceHost` state machines, the peer check,
  `PostgresSupervisor` (with a real cluster from the CI build), and view models.
- **UI:** WinAppDriver or Appium smoke tests for first run and Search, like
  `macapp/Tests/GarageAppUITests`, with a deterministic llama engine as `DeterministicLlamaEngine`
  provides on macOS.
- **Known answers:** Windows x64 CPU and Vulkan jobs in `known-answers.yaml`.
- **Runners:** `windows-latest` for everything except Vulkan, which needs a GPU runner (self-hosted,
  or Vulkan's software rasterizer, SwiftShader, for correctness only).

## 9. Phases

| Phase | Work | Estimate |
|---|---|---|
| **0 — Spikes** | ~~S1: `Garage.Python` hosting 3.14 and running `create_grpc_server` with the GIL released, including an `[UnmanagedCallersOnly]` callback~~ (done, §2.3). S2: gRPC core `unix:` on Windows; httpcore UDS on Windows; libpq drive-letter socket directory; socket-path length under `LocalState`. S3: WinUI 3 tray + window + single instance + `StartupTask`. S4: llama.cpp Vulkan/CPU build and known answers. S5: MSIX execution aliases reading `LocalState` and the Credential Locker from a stdio client's spawn | 2 weeks |
| **1 — Portable `garage_rag`** | §1.3 table, §4, §5.2; the whole suite on Windows CI | 2–3 weeks |
| **2 — Service platform** | `services.proto`, `GarageServiceHost`, named pipes + peer check, Job Object, `PostgresSupervisor`, Credential Locker, `Garage.Core` / `Garage.Ingest` / `Garage.Embed` | 3–4 weeks |
| **3 — MVP UI** | Tray flyout, Status, Search, Sources (with Update Everything), MCP (stdio registration, HTTP opt-in), launchers. **First usable build** | 3–4 weeks |
| **4 — Inference** | `Garage.Llama` (engine, control pipe, bridge, loopback HTTP + token), downloads via BITS with SHA-256 against the catalog, the Models page | 3 weeks |
| **5 — Parity** | Documents, Database (reset/relaunch), Logs, first-run assistant, bug report, HEIC bridge, toasts, jump list | 3–4 weeks |
| **6 — Ship** | MSIX signing, `.appinstaller` feed, Store submission, notices, docs (`docs/support/windows.md`, troubleshooting: Defender, Git, HEVC extension) | 2 weeks |

## 10. Decisions

Decided:

1. **The Python bridge:** an owned layer, `Garage.Python` (§2.3), built and tested.
2. **The build system:** the .NET 10 SDK for `winapp/`, outside Bazel (§6).

Still open:

3. **Distribution:** Store plus `.appinstaller` from one MSIX (recommended), or unpackaged with
   Velopack. Unpackaged loses the Credential Locker's package scoping, execution aliases and
   `LocalState`, which several of the choices above lean on.
4. **Architectures:** whether arm64 ships in the first release or follows.
