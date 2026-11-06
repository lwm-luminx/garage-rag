# Garage for Windows (`winapp/`)

The native Windows Garage: a .NET 10 app that runs Garage's Rust services the way the Mac app's XPC
services do. The plans are [docs/plans/windows.md](../docs/plans/windows.md) for the port and
[docs/plans/windows-ui.md](../docs/plans/windows-ui.md) for the UI. This folder holds the service
processes and the UI through phase U5: the app shell, the reading pages (Search,
Documents, Facts, Database, Logs), the operations pages (Sources, Models, MCP Server, Settings),
ingest, Update Everything and Automatic Updates through Garage's own services, the setup assistant,
the notification-area flyout with quick search and Ask Garage, the bug report and the jump list.

`winapp/` is a .NET SDK solution (`Garage.slnx`), with package versions pinned centrally in
`Directory.Packages.props` and the SDK pinned in `global.json`. The csproj files are the source of
truth: Visual Studio, `dotnet build` and the Windows CI job use them. Bazel builds every project but
the WinUI app and its UI tests too, on macOS and Linux; see [Bazel](#bazel).

## Layout

| Path | What |
|---|---|
| `src/Garage.Grpc` | The `GarageService` client generated from `proto/garage.proto`, the `x-garage-token` interceptor, and `services.proto` (the app's control plane to its services) with its named-pipe channel |
| `src/Garage.Services` | `Garage.Services.exe`: one Garage service per process (`--service core` runs `GarageService`, `--service ingest` the Rust ingest, `--service mcp` the MCP HTTP server), each a Rust library loaded in-process (`garage_service_ffi.dll`, `garage_ingest_ffi.dll`, `garage_mcp_ffi.dll`), answering the app over a named pipe |
| `src/Garage.App.Core` | Everything the UI decides, with no UI framework: `AppState`, `OperationRunner` (ported from the Mac), the backends (`ServiceHostBackend` over `ServiceManager`, and `DevBackend`), the pipeline (`LibraryCoordinator`), navigation order, presentation values |
| `src/Garage.App` | The WinUI 3 app (`Garage.exe`): window, `NavigationView`, pages, notification-area icon. Built unpackaged and self-contained |
| `tests/Garage.App.Core.Tests` | xUnit v3 tests of Core: the pages' view models and presentations (ported with the Mac's test cases) and the pipeline, against a fake client and a fake ingest service |
| `tests/Garage.App.UITests` | FlaUI tests of the built app against a fake backend they serve; run with `GARAGE_UI_TESTS=1` (below) |
| `tests/Garage.Services.Tests` | xUnit v3 tests that start the real service processes as the app does, and (with `GARAGE_TEST_DATABASE_URL`) ingest a folder into a throwaway database through them |
| `packaging` | The MSIX (Microsoft Store, App Installer) and the MSI (per machine, WiX v5), both made from one staged layout; see [packaging/README.md](packaging/README.md) |

## Run the app

The app starts Garage's own services: the backend and ingest, each a `Garage.Services.exe`
process that ends with the app, running its Rust library in-process. In a checkout it finds
everything by itself once the services are built (`dotnet build Garage.slnx`) and the libraries are
(`cargo build --release -p garage-service-ffi -p garage-ingest-ffi -p garage-mcp-ffi` in `rust\`,
with libgit2 and SQLite from vcpkg as `windows.yaml`'s `rust` job installs them):

```powershell
dotnet run --project winapp\src\Garage.App
```

Data lives in `%LOCALAPPDATA%\Garage`: the services' `logs`, the app's `app-settings.json`, and
optionally a `garage.json`. Without one there, the services read `~/.garage.json`, so the app works
on the corpus the CLI set up. These variables override each piece: `GARAGE_SERVICES_EXE`,
`GARAGE_NATIVE_DIR` (the folder with the three DLLs), `GARAGE_SQL_DIR` (the schema `InitDb` applies)
and `GARAGE_DATA_DIR`.

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

The look is the Garage design system (Garage violet on violet-tinted neutrals, light and dark).
`src/Garage.App/Theme/GarageTheme.xaml` holds its colour tokens as `Garage*Brush` and points WinUI's
own resource keys at them (the accent, text, cards, buttons, inputs, callouts, the navigation pane),
so pages use the standard keys and styles and take the look from there. `App.xaml` adds the page
title, its rule, `GarageCardStyle` and `DangerButtonStyle` (destructive actions). High contrast keeps
the system's colours. `--appearance light|dark` pins the theme for one run, as on the Mac, for
screenshots and tests.

## Build and test

Needs the .NET 10 SDK and, for the service tests, the Rust libraries:

```powershell
cd winapp
dotnet build Garage.slnx
dotnet test --solution Garage.slnx
```

The service tests find the Rust libraries from `GARAGE_TEST_NATIVE_DIR`, or a Cargo build in
`rust\target\release` (then `debug`); without them they skip (`GARAGE_TEST_REQUIRE_NATIVE=1` turns
the skip into a failure; CI sets it). The other tests read:

- `GARAGE_TEST_DATABASE_URL`, a superuser URL as for the Rust database tests: the end-to-end ingest test
  creates a throwaway `garage_test_*` database there (with `psql`, from `GARAGE_TEST_POSTGRES_HOME`
  or the PATH) and drops it. Without it, that test skips.
- `GARAGE_TEST_POSTGRES_HOME`, a Windows build of `//ext/postgres`: the `PostgresSupervisor` tests
  run clusters of their own from it, each in a temporary folder on a free port. Without it, they skip.

CI runs the suite in the `winapp` job of `.github/workflows/windows.yaml`, against the libraries its
`rust` job builds and the Postgres its `postgres` job builds.

`dotnet format Garage.slnx --verify-no-changes` checks style. The build treats warnings, including
the recommended analyzers, as errors.

## Bazel

```bash
aspect build //winapp/...          # macOS or Linux (plain bazel works too)
aspect test //winapp/...
```

Bazel builds `Garage.Grpc`, `Garage.App.Core`, `Garage.Services` and their test
projects with [rules_dotnet](https://github.com/bazel-contrib/rules_dotnet), on the .NET SDK 10.0.400
(`winapp.MODULE.bazel`). `Garage.App` and `Garage.App.UITests` stay `dotnet`-only: WinUI's XAML
compiler and FlaUI run only on Windows, inside MSBuild.

- **Each project's `BUILD.bazel` mirrors its csproj** through the macros in `bazel/defs.bzl`, which
  compile with the `csc` options the SDK uses (net10.0, C# `latest`, nullable, warning level 10,
  warnings as errors) and add what the SDK generates: the implicit `global using`s, AssemblyInfo
  (version 1.0.0.0) and, for tests, xunit.v3's entry point (`bazel/*.cs`).
- **`//winapp/bazel:csproj_sync_test`** fails when a csproj and its `BUILD.bazel` part: references,
  `NoWarn`, `AllowUnsafeBlocks`, `InternalsVisibleTo`, net10.0-windows, the ASP.NET Core framework,
  each `<Protobuf>` item, and the props `defs.bzl` assumes. A new project in `Garage.slnx` needs a
  `BUILD.bazel` (or a place in `NOT_BAZEL`, `bazel/projects.py`).
- **NuGet:** `nuget.bzl` pins every package the Bazel-built projects restore, with the sha512 of the
  `.nupkg` nuget.org serves. After changing `Directory.Packages.props` or a `PackageReference`, run
  `python3 winapp/bazel/repin.py` (it runs `dotnet restore` and reads each `project.assets.json`); the
  sync test fails until then.
- **gRPC:** `bazel/proto.bzl` runs the `protoc` and `grpc_csharp_plugin` from the pinned Grpc.Tools
  package with MSBuild's options, so the generated C# is byte-for-byte what `dotnet build` generates.
- **net10.0-windows** projects compile as net10.0 with the SDK's Windows platform attributes.
  `Garage.Services.Tests` calls Windows APIs, so its test runs only on Windows; elsewhere
  `:Garage.Services.Tests_compile` compiles the same sources. `Garage.App.Core.Tests` runs anywhere,
  skipping the tests that need Windows path rules.
- **Not carried over:** the SDK's own analyzers (NetAnalyzers and the code-style rules that
  `AnalysisLevel` and `EnforceCodeStyleInBuild` enable). Analyzers from the targeting pack and from
  NuGet packages (LibraryImport, CommunityToolkit.Mvvm's generators, xunit.analyzers) do run. `dotnet
  build` stays the analyzer gate.
- **rules_dotnet patch** (`bazel/rules_dotnet_roslyn_analyzers.patch`): rules_dotnet takes a single
  analyzer from packages that ship them per Roslyn version, which drops CommunityToolkit.Mvvm's
  source generator; the patch picks the highest `roslyn<X.Y>` folder the compiler supports, as NuGet
  does.

Bazel on Windows is untried: `proto.bzl` generates through a shell action, and Windows CI builds
with `dotnet` only.

CI: the `winapp-bazel` job in `ci.yaml` runs `bazel test //winapp/...` on Linux on every push. The
macOS Bazel job's `aspect test //...` runs the tests too, but with `--build_tests_only`, so only the
Linux job compiles `Garage.Services` and `:Garage.Services.Tests_compile`.


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
