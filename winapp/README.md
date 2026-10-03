# Garage for Windows (`winapp/`)

The native Windows Garage: a .NET 10 app that embeds CPython and runs `garage_rag` the way the Mac
app's XPC services do. The plans are [docs/plans/windows.md](../docs/plans/windows.md) for the port
and [docs/plans/windows-ui.md](../docs/plans/windows-ui.md) for the UI. This folder holds the Python
bridge, the service processes, and the UI through phase U5: the app shell, the reading pages (Search,
Documents, Facts, Database, Logs), the operations pages (Sources, Models, MCP Server, Settings),
ingest, Update Everything and Automatic Updates through Garage's own services, the setup assistant,
the notification-area flyout with quick search and Ask Garage, the bug report and the jump list.

Unlike the rest of the repo, `winapp/` is **not built by Bazel**. It is a plain .NET SDK solution
(`Garage.slnx`), with package versions pinned centrally in `Directory.Packages.props` and the SDK
pinned in `global.json`. Bazel does not see it: there are no `BUILD` files under it.

## Layout

| Path | What |
|---|---|
| `src/Garage.Python` | The owned Python bridge: the counterpart of PythonKit plus `GaragePythonEmbed.c` |
| `src/Garage.Grpc` | The `GarageService` client generated from `proto/garage.proto`, the `x-garage-token` interceptor, and `services.proto` (the app's control plane to its services) with its named-pipe channel |
| `src/Garage.Services` | `Garage.Services.exe`: one Garage service per process (`--service core` runs `GarageService`, `--service ingest` runs `garage_rag.ingest`), embedding CPython, answering the app over a named pipe |
| `src/Garage.App.Core` | Everything the UI decides, with no UI framework: `AppState`, `OperationRunner` (ported from the Mac), the backends (`ServiceHostBackend` over `ServiceManager`, and `DevBackend`), the pipeline (`LibraryCoordinator`), navigation order, presentation values |
| `src/Garage.App` | The WinUI 3 app (`Garage.exe`): window, `NavigationView`, pages, notification-area icon. Unpackaged and self-contained while in development |
| `tests/Garage.Python.Tests` | xUnit v3 tests that embed a real CPython 3.14 and drive `garage_rag` |
| `tests/Garage.App.Core.Tests` | xUnit v3 tests of Core: the pages' view models and presentations (ported with the Mac's test cases) and the pipeline, against a fake client and a fake ingest service |
| `tests/Garage.App.UITests` | FlaUI tests of the built app against a fake backend they serve; run with `GARAGE_UI_TESTS=1` (below) |
| `tests/Garage.Services.Tests` | xUnit v3 tests that start the real service processes as the app does, and (with `GARAGE_TEST_DATABASE_URL`) ingest a folder into a throwaway database through them |

## Run the app

The app starts Garage's own services: the backend and ingest, each a `Garage.Services.exe`
process that ends with the app. In a checkout it finds everything by itself once the services are
built (`dotnet build Garage.slnx`), CPython 3.14 is installed for the `py` launcher, and
`garage_python\.venv` exists (the root README's Windows quickstart):

```powershell
dotnet run --project winapp\src\Garage.App
```

Data lives in `%LOCALAPPDATA%\Garage`: the services' `logs`, the app's `app-settings.json`, and
optionally a `garage.json`. Without one there, the services read `~/.garage.json`, so the app works
on the corpus the CLI set up. These variables override each piece: `GARAGE_SERVICES_EXE`,
`GARAGE_PYTHON_HOME`, `GARAGE_PYTHON_SITE_PACKAGES`, `GARAGE_PYTHON_PATH` and `GARAGE_DATA_DIR`.

With `GARAGE_POSTGRES_HOME` naming a Windows build of `//ext/postgres` (`windows.yaml`'s
`postgres-windows-x64` artifact), or that build in `postgres\` beside the app, the app runs its own
cluster in the data folder's `pgdata`, on `127.0.0.1:14824`, with its password in Windows
Credential Manager (`Garage/postgres-password`). The Database page then shows the server and its
schema, and offers Back Up, Restore and Reset Database. Without it, the services use the database
`garage.json` names.

MCP over HTTP (`http://127.0.0.1:8787/mcp`), for an assistant that needs an address, is a switch on
the MCP Server page. It starts a third service process and is off by default; assistants connected
over stdio start Garage themselves.

Automatic Updates are on by default, as on the Mac, and run every hour; turn them off on the
Status page.

To use a `garage serve` you started yourself instead, launch with `--dev-backend`, or set
`GARAGE_GRPC_PORT`. Give both the same token, so the server answers the calls that change settings
and sources:

```powershell
$env:GARAGE_GRPC_TOKEN = [guid]::NewGuid().ToString("N")
garage serve --host 127.0.0.1 --port 50051          # in a venv, in its own terminal
dotnet run --project winapp\src\Garage.App -- --dev-backend
```

`GARAGE_GRPC_HOST`/`GARAGE_GRPC_PORT` move the address, and `GARAGE_MCP_URL` names a `garage mcp-serve`
for Ask Garage. Ingest needs Garage's own services, so a development backend cannot ingest. Closing the window hides
it in the notification area; click the icon for quick search and Ask Garage, and use **Quit Garage**
(in the flyout or the icon's menu) to exit. A second launch brings the running window forward instead
of starting another app, and hands over its command line: the jump list's tasks are
`Garage.exe --do search|ask|add-source|update-everything`, and `--background` (launch at sign-in)
starts in the notification area only. A new install opens on the setup assistant; Settings'
**Setup Assistant…** shows it again.

## Build and test

Needs the .NET 10 SDK and, for the tests, a CPython 3.14 for Windows (x64):

```powershell
cd winapp
dotnet build Garage.slnx
dotnet test --solution Garage.slnx
```

The tests find the interpreter from:

- `GARAGE_TEST_PYTHON_HOME`: a CPython home (the folder with `python314.dll`, `Lib`, `DLLs`).
  Without it, they ask the `py` launcher for 3.14. With neither, every test skips.
- `GARAGE_TEST_PYTHON_SITE_PACKAGES`: a site-packages holding `garage_rag`'s dependencies.
  `garage_python/src` from this checkout goes on `sys.path` after it. Without it, the tests that
  import `garage_rag` skip. To create one:

  ```powershell
  py -3.14 -m venv $env:TEMP\garage-venv
  & $env:TEMP\garage-venv\Scripts\python.exe -m pip install -e ..\garage_python
  $env:GARAGE_TEST_PYTHON_SITE_PACKAGES = "$env:TEMP\garage-venv\Lib\site-packages"
  ```

- `GARAGE_TEST_REQUIRE_PYTHON=1` turns those skips into failures; CI sets it.
- `GARAGE_TEST_DATABASE_URL`, a superuser URL as for `test_postgres.py`: the end-to-end ingest test
  creates a throwaway `garage_test_*` database there and drops it. Without it, that test skips.
- `GARAGE_TEST_POSTGRES_HOME`, a Windows build of `//ext/postgres`: the `PostgresSupervisor` tests
  run clusters of their own from it, each in a temporary folder on a free port. Without it, they skip.

CI runs the suite in the `winapp` job of `.github/workflows/windows.yaml`, against the CPython that
job's `python` step builds from `ext/python`'s pins.

`dotnet format Garage.slnx --verify-no-changes` checks style. The build treats warnings, including
the recommended analyzers, as errors.


### UI tests

`tests/Garage.App.UITests` drives the built `Garage.exe` with FlaUI (UI Automation) against a fake
backend each test serves on loopback: a `GarageService` over an in-memory corpus, and an MCP endpoint
whose `rag_agent` gives a fixed answer. The app runs with `--dev-backend` in a throwaway data folder,
so nothing of your own Garage is touched. They take over the desktop, so they run only when asked,
and refuse to start while Garage is running:

```powershell
dotnet build Garage.slnx
$env:GARAGE_UI_TESTS = "1"
dotnet test --project tests\Garage.App.UITests\Garage.App.UITests.csproj --no-build
```

`GARAGE_APP_EXE` names another build of the app. Automation ids follow the Mac's accessibility
identifiers (`menubar.*`, `status.*`, `firstRun.*`), so a test names its counterpart.

### Strings

The app's own wording is in `src/Garage.App/Strings/en-US/Resources.resw`: XAML finds it through
`x:Uid`, code-behind through `Strings.Get`. Core's presentation wording stays in C#, where tests keep
it in step with the Mac's.

## `Garage.Python`

It talks to `python3XY.dll` directly through source-generated P/Invoke (`Native/CPython.cs`). There
is no C shim: the Mac's `GaragePythonEmbed.c` fills in a `PyConfig` struct, while here PEP 741's
`PyInitConfig` API (new in 3.14) sets the same options by name, with no struct layout to mirror.

```csharp
Python.Initialize(PythonEnvironment.FromHome(@"C:\Program Files\Garage\python",
    sitePackagesDir: @"C:\Program Files\Garage\site-packages"));

dynamic server = Python.Import("garage_rag.service.server");
dynamic created = server.create_grpc_server(host: "127.0.0.1", port: 50051);
created[0].start();
```

### Start-up

- The interpreter is **isolated**:
  - `PYTHON*` variables, the working directory, user site-packages and argv are ignored;
  - UTF-8 mode is on;
  - no `.pyc` files are written;
  - Python installs no signal handlers.
- `sys.path` is exactly `PythonEnvironment.SearchPaths`: `Lib`, `DLLs`, the bundle's
  site-packages, then any extra paths.
- `site` is imported afterwards and processes `.pth` files in the bundle's site-packages only. On
  Windows `site.main()` would also add the home folder and `home\Lib\site-packages`, which would let
  a package installed into the interpreter shadow the bundle's.
- `.pth` files matter on Windows: pywin32, which the MCP SDK pulls in there, puts `win32`,
  `win32\lib` and `pythonwin` on the path through one.

### Threads and the GIL

- The GIL is released once start-up finishes.
- `Python.Gil()` returns a `GilScope` (a `ref struct`, so it cannot cross an `await`). Scopes nest.
- Every `PythonObject` operation takes the GIL itself. Hold a scope explicitly only to make several
  calls atomic, or to save the re-entry cost in a loop.
- `Python.AllowThreads()` releases the GIL while the host blocks.
- The Mac keeps Python on one host thread per service. Here any thread may call in, which the gRPC
  server test relies on: its worker threads take the GIL while the test thread waits for the reply.

### `PythonObject`

A strong reference, used through `dynamic` like PythonKit's `PythonObject`:

- keyword arguments;
- `obj[key]` and `obj[a, b]`, which pass a tuple;
- conversions by cast: `(string)`, `(long)`, `(double)`, `(bool)`, `(byte[])`.

It also has an explicit API: `GetAttr`, `Invoke`, `Call(args, kwargs)`, `As<T>()`, and enumeration.

- **Name clashes.** Static members win over Python attributes of the same name, so a Python
  attribute called `Call` or `ToString` is reached with `GetAttr`.
- **Releasing references.** `Dispose` releases the reference at once. An object left to the GC is
  queued and released the next time any thread takes the GIL; a finalizer never waits for it.
- **Errors.** Python exceptions surface as `PythonException`, which carries the qualified type name,
  `str(exc)`, the formatted traceback, and the exception object.

### Host callbacks

`garage_rag` asks its host for C function pointers:

- `garage_rag.inference.bridge.install(request, release)`, the llama request bridge;
- `garage_rag.xpc.host.install_model_loader(loader)`.

In C#, these are `[UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]` methods passed as
`(nint)(delegate* unmanaged[Cdecl]<...>)&Method`. `Interop.NativeUtf8` allocates and frees the
C strings they exchange, as `strdup`/`free` do in the Swift host. `GarageHostContractTests` exercises
both contracts against the real modules.

### Not yet

- **A free-threaded (`python314t.dll`) build.** `PythonEnvironment.FromHome(..., freeThreaded: true)`
  selects the DLL, and the bindings use only exported functions (no macros), but no test runs
  against one yet.
- **Finalizing the interpreter.** `Python.Shutdown()` exists but is untested: a process starts
  CPython once, and services exit instead of finalizing.
