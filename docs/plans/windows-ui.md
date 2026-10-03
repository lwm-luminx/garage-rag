---
layout: default
title: Windows UI Plan — The Garage App Window, Tray and Pages on WinUI 3
description: Implementation plan for the Windows Garage user interface — a WinUI 3 app on .NET 10 with the Mac app's pages in Windows idioms, built against the existing gRPC contract.
---

# Garage for Windows — UI plan

The user interface half of [windows.md](windows.md). That plan covers the whole port (services,
Python bridge, Postgres, packaging); this one covers the app people see:

- the window and its pages;
- the notification-area icon;
- the first-run assistant;
- the view models behind them.

Written against `v1.5-beta` (`2454039`) plus the `windows/python-bridge` work: `winapp/`, `Garage.Python`
and the `winapp` CI job. Re-checked for parity against `main` (`b82c6d2`) and `v1.5-beta` (`839bc39`)
on 2026-09-29; §8 records what changed and what the plan took from it.

**The approach:** port the Mac app's structure page for page, and its presentation logic line for line,
while the controls, layout and behaviour follow Windows conventions (windows.md §3). Build the UI
against the gRPC contract that already exists, so it does not wait for the Windows service host:
every page except ingest can be developed against `garage serve` running from a venv.

---

## 0. Scope

In scope:

- **The app:** `Garage.App`, a WinUI 3 (Windows App SDK) app on .NET 10, plus a UI-free
  `Garage.App.Core` holding every view model, the app state and the presentation types, so they
  can be unit-tested without a UI.
- **The surfaces:**
  - the nine pages;
  - the notification-area icon and its flyout;
  - the first-run assistant;
  - Database Reset;
  - the bug report;
  - Settings.
- **Backend connections:**
  - a development connection to a running `garage serve`, first;
  - the service host's endpoints, once windows.md Phase 2 lands.

Out of scope, in windows.md:

- the service processes, the Python bridge and Postgres supervision;
- the llama.cpp service and model downloads (the Models page shows them once they exist);
- MSIX packaging, signing and updates.

## 1. What the Mac UI is (grounding)

`macapp/Sources/GarageApp`, which the Windows UI mirrors:

| Mac | What |
|---|---|
| `Views/ContentView.swift` | `AppSection` (9 pages) and `SidebarGroup`: Status on top, then **Configuration** (Sources, Models, MCP Server), **Data** (Documents, Facts, Search), **Advanced** (Database, Logs). A unit test holds the order |
| `Views/*View.swift` | One view per page, split into extensions for the large ones (`ModelsView+*`, `StatusView+Services`, `MCPServerView+TryIt`) |
| `Views/*Presentation.swift` | Plain presentation values with the page's wording and state logic (`StatusPagePresentation`, `SourcesPresentation`, `ModelsPresentation`, `MCPServerPresentation`, `DatabasePresentation`, and others), each unit-tested |
| `Views/MenuBar*.swift`, `Components/MenuBar*` | The menu-bar extra: status, quick search, **Ask Garage** (`MenuBarAnswer`: the local model's answer from the `rag_agent` MCP tool, with the tool calls it made and its citations), navigation, Ingest Now, Stop |
| `Views/StatusView.swift` (Library box) | Update Everything and **Automatic Updates** (scheduled maintenance), moved to Status from the Sources page; the launch run of automatic updates waits until every service is up |
| `Views/FirstRunView.swift` + `Services/FirstRunCoordinator.swift` | Setup assistant: wait for services → pick sources → pick models → connect MCP clients |
| `Views/DatabaseResetSheet.swift`, `BugReportView.swift`, `SplashView.swift`, `CheckForUpdatesButton.swift` | Overlays and dialogs |
| `AppState.swift` (+ `+Facts`, `+LlamaModels`) | Shared state. Includes the ingest queue with `cancelAll()` / `cancel(source:)`, `updateEverything()` (scan → ingest → embed → glean facts), scheduled maintenance, and database reset and relaunch |
| `Services/OperationRunner.swift` | Runs an operation as a gRPC call with a busy flag and a rolling log; dedicated runners for backfill and enrich-facts |
| `Services/GarageGRPCService+Operations.swift` | The typed gRPC calls every page uses |

**The contract is already there.** `proto/garage.proto` covers every page except ingest:
- read paths: `GetStatus`, `GetStats`, `Search`, `ListDocuments`/`GetDocument`, `ListFacts`,
  `GetFactStats` (new on `main`), `ListFactPrompts`, `ListSources`, `ListModels`, `GetSetting`,
  `McpStatus`;
- operations: `AddSource`, `RemoveSource`, `Scan`, `SyncSources`, `Reconcile`, `RegisterModel`,
  `SetDefaultModel`, `DropModel`, `Backfill` (streaming), `EnrichFacts` (streaming), `SetSetting`,
  `McpInstall`/`McpUninstall`, `InitDb`.

**Ingest has no RPC.** On the Mac it runs in `GarageIngestXPCService`, which persists through the
facade's ingest-session RPCs, so on Windows it arrives with the service host's `Garage.Ingest`
(§4, phase U3).

**Ask Garage is not gRPC either.** The Mac's `GarageMCPService` sends MCP JSON-RPC (`initialize`,
then `tools/call` for `rag_agent`) to Garage's own MCP server, and decodes the result into
`MenuBarAnswer`. The Windows app does the same, so it needs an MCP endpoint as well as the gRPC
channel (§2.3).

## 2. Architecture

```
winapp/
  src/Garage.Python/          (exists) CPython bridge
  src/Garage.Grpc/            generated GarageService client (proto/garage.proto via Grpc.Tools)
                              + the x-garage-token interceptor (GarageGRPCAuth's counterpart)
  src/Garage.App.Core/        net10.0, no UI references:
                                AppState, OperationRunner, IngestQueue, pipelines
                                view models (CommunityToolkit.Mvvm)
                                presentation types ported from Views/*Presentation.swift
                                IBackend: where the endpoints are (dev connection or service host)
  src/Garage.App/             net10.0-windows10.0.19041.0, WinUI 3:
                                MainWindow (NavigationView), pages, dialogs, tray icon and flyout,
                                first-run window, notifications, single instance, startup task
  tests/Garage.App.Core.Tests/    xUnit v3: presentations, view models, pipelines (fake backend)
  tests/Garage.App.UITests/       FlaUI UI automation, against a fake backend
```

### 2.1 Why a separate Core

- **Testing without a UI:** view models, `AppState` and presentations have no WinUI dependency.
  They run in the ordinary `dotnet test` on any runner, like the Mac's presentation unit tests.
- **Where the logic lives:** the Mac keeps page wording and state rules in plain `*Presentation`
  values beside each view. Porting those types, and their test cases, into Core keeps the two apps
  saying the same thing in the same situations. The XAML then binds to them and holds no logic.

### 2.2 State and threading

- **Observable state:** `AppState` is an `ObservableObject` (CommunityToolkit.Mvvm
  `[ObservableProperty]`), the counterpart of the Mac's `@Published` properties. Pages get view
  models that read it; they do not own global state.
- **UI thread:** every mutation that reaches bound properties is marshalled to the UI thread
  through an `IUiDispatcher` abstraction, a `DispatcherQueue` wrapper in `Garage.App` and an inline
  dispatcher in tests. This mirrors the Mac's main-actor rule.
- **Streaming RPCs** (`Backfill`, `EnrichFacts`, `Scan`) are consumed as `IAsyncEnumerable` with a
  `CancellationToken`. Cancelling the call stops the Python side at its next progress step, as it
  already does for the Mac.
- **`OperationRunner`** ports as-is:
  - one runner for ordinary operations, and dedicated runners for backfill and enrich-facts, so a
    long job never blocks the rest;
  - each keeps a busy flag and a rolling log that the pages show.

### 2.3 Backend connections

`IBackend` supplies the gRPC channel (address plus token), the MCP endpoint that Ask Garage calls
`rag_agent` through, and service status. There are two implementations:

- **`DevBackend`** (from phase U0):
  - connects to a `garage serve` the developer started, from `GARAGE_GRPC_HOST`/`_PORT` and
    `GARAGE_GRPC_TOKEN` (or a dev settings file);
  - with a token, the server answers config-changing methods over loopback (`service/auth.py`),
    so every page but ingest works;
  - for Ask Garage, a `garage mcp-serve` the developer started (streamable HTTP on loopback);
  - chosen only in Debug builds, or with an explicit `--dev-backend` switch; never in a shipped
    build.
- **`ServiceHostBackend`** (from phase U3):
  - the `ServiceManager` from windows.md §2.1 starts the services, generates the per-launch token,
    exposes service status (the Status page's service rows) and provides ingest;
  - Ask Garage goes to `Garage.Mcp`, as the Mac goes to its own MCP service;
  - this is what ships.

## 3. Pages and surfaces

Each row lists the Mac source it ports, the WinUI treatment, and the RPCs behind it.

| Surface | Mac source | Windows | RPCs |
|---|---|---|---|
| **Shell** | `ContentView` | `NavigationView`, left mode. Status first; `NavigationViewItemHeader`s for Configuration, Data, Advanced; **Settings in the footer**. Mica backdrop, custom title bar, Segoe Fluent Icons in place of SF Symbols. Keep the `AppSection` order test | — |
| **Status** | `StatusView`, `+Services`, `StatusPagePresentation`, `IndexingPresentation`, `ServiceRowPresentation` | Summary cards. A **Library** box holds Update Everything and the Automatic Updates switch and schedule; the launch run waits until every service is up. An indexing progress `InfoBar`; service rows with self-test results ("7 passed, 1 skipped") and icon-button actions with tooltips; quick add | `GetStatus`, `GetStats`; service status from `IBackend` |
| **Sources** | `SourcesView`, `SourcesPresentation` | `ListView` of sources with per-row status and actions; Add Source through `FolderPicker` in a `ContentDialog` (slug, class, trust). Automatic Updates is no longer here; it moved to Status | `ListSources`, `AddSource`, `RemoveSource`, `Scan`, `SyncSources`, `Reconcile`, `ImportSourcesToConfig`; ingest via `IBackend` |
| **Models** | `ModelsView` + extensions, `ModelsPresentation` | Model list with default and provider, row actions as icon buttons with tooltips; register-model dialog; embedding inspection; backfill with progress. Local llama models appear once `Garage.Llama` exists | `ListModels`, `RegisterModel`, `SetDefaultModel`, `DropModel`, `Backfill`, `EnsureLlamaModel` |
| **MCP Server** | `MCPServerView`, `+TryIt`, `MCPServerPresentation`, `MCPClientRowPresentation` | Client rows (Claude Desktop, Claude Code, ...) with Install / Update / Remove; stdio by default; the HTTP server behind an explicit toggle (`garage.mcp.httpEnabled` behaviour); "Try it" panel | `McpStatus`, `McpInstall`, `McpUninstall`, `Search` |
| **Documents** | `DocumentsView`, `CorpusTaxonomy` | List/detail (`TwoPaneView` or split): filters by class and trust; the document's chunks and authors | `ListDocuments`, `GetDocument` |
| **Facts** | `FactsView`, `FactPromptsSection` | Fact counts per prompt and model; fact list with grounding spans; prompts section; "Glean facts" with progress | `GetFactStats`, `ListFacts`, `ListFactPrompts`, `EnrichFacts` |
| **Search** | `SearchView` | `AutoSuggestBox` query, trust/class filters, results with excerpts; Ctrl+F from anywhere | `Search` |
| **Database** | `DatabaseView`, `DatabasePresentation`, `DatabaseResetSheet` | Schema and contents summaries; Reset Database as a `ContentDialog` with typed confirmation, then relaunch (`AppInstance.Restart`) | `GetStats`, `InitDb`; reset via `IBackend` |
| **Logs** | `LogsView`, `LogTableView` | Virtualized list with level filter and search. Under it, a status bar with the counts ("showing the latest ...") and the copy/export/clear actions, as the Mac's table now has. Sources: the app log, then the services' log streams (U3) | — / service log streams |
| **Settings** | (scattered in the Mac app) | Footer page: backend and connection, launch at startup (`StartupTask`), notifications, update channel (stable or beta, as the Mac's beta channel; windows.md §6 for the feeds), about and third-party notices. The maintenance schedule stays on Status with Automatic Updates | `GetSetting`, `SetSetting` |
| **Tray icon** | `MenuBarView`, `MenuBarStatus`, `MenuBarQuickSearch`, `MenuBarAnswer`, `MenuBarNavigation` | Notification-area icon (H.NotifyIcon.WinUI). Left-click opens a flyout with status, quick search, **Ask Garage**, page links, Ingest Now and Stop. Ask shows the answer with the tool calls it took and citations that open the document; it is available when a generating model is configured (the Mac's `canAsk`). Right-click opens a context menu (Open Garage, Pause maintenance, Quit). The icon reflects idle, working or error | `GetStatus`, `Search`; MCP `tools/call` `rag_agent` |
| **First run** | `FirstRunView`, `FirstRunCoordinator` | Full-window assistant with a step header: services → sources (Windows templates: Documents, Desktop, OneDrive, a code folder) → models → MCP clients. Uses the same `AppState` operations as the pages | as the pages |
| **Bug report** | `BugReportView`, `BugReport*` | Dialog that gathers logs and self-test output into a folder and opens it in Explorer; nothing is sent automatically | — |
| **Notifications** | — | App notifications (`AppNotificationManager`) with progress for Update Everything, backfill and enrich-facts; completion and failure toasts | — |
| **Taskbar** | — | Jump list: Search, Ask Garage, Add Source, Update Everything | — |
| **Tip jar** (Store build only) | `TipJarView` (on `v1.5-beta`, not yet on `main`) | The Mac App Store build offers tips as in-app purchases. The Microsoft Store counterpart is Store add-ons (consumables) through `Windows.Services.Store.StoreContext`; the `.appinstaller` build shows no tip jar, as the Developer ID build has none | Store API |

**Keyboard:**
- **Ctrl+1…9** jump to pages in `AppSection` order (the Mac's Cmd+number);
- **Ctrl+F** focuses search;
- **Ctrl+,** opens Settings;
- **F5** refreshes the current page.

## 4. Phases

Estimates assume one engineer familiar with WinUI and are rough until U0 is done.

| Phase | Work | Depends on | Estimate |
|---|---|---|---|
| **U0 — Shell** | `Garage.Grpc` (generated client + token interceptor), `Garage.App.Core` skeleton (`AppState`, `OperationRunner`, `IUiDispatcher`, `IBackend`, `DevBackend`), `Garage.App` shell (window, `NavigationView` with groups, Mica, title bar, single instance, tray icon with an empty flyout), `AppSection` order test, CI build of the app in the `winapp` job | nothing new | 1 week |
| **U1 — Reading pages** | Search, Documents, Facts, Database (read-only), Status (backend and corpus only), Logs (app log); presentation types ported with their Mac test cases | U0 | 2–3 weeks |
| **U2 — Operations** | `OperationRunner` wired to pages; Sources (without ingest), Models (register, default, drop, backfill with progress), MCP Server (install, update, remove, HTTP toggle), Settings, Facts' Glean; notifications | U1 | 2–3 weeks |
| **U3 — Service host** | `ServiceHostBackend`; Status service rows and self-tests; the ingest queue, Ingest Now, Stop, cancel per source; the Library box (Update Everything, Automatic Updates with the launch run held until services are up); Database Reset and relaunch; service log streams | windows.md Phase 2 (service platform, `Garage.Ingest`) | 2–3 weeks |
| **U4 — Onboarding and tray** | First-run assistant; complete tray flyout (quick search, **Ask Garage** over MCP `rag_agent`, Ingest Now, Stop, state icon); bug report; jump list; launch at startup; update channel setting | U3 (Ask can be built earlier against `garage mcp-serve`) | 2–3 weeks |
| **U5 — Finish** | Accessibility pass (Narrator, keyboard, high contrast, text scaling); strings in `.resw` resources; FlaUI UI tests (§5); performance with a large corpus (virtualization); Store build's tip jar (Store add-ons), once the Mac's reaches `main` | U4 | 2 weeks |

The llama-dependent parts of Models and first run (local models, downloads) follow windows.md
Phase 4 and slot into U2–U4 once they exist. Until then those pages offer Ollama and LM Studio only.

### Progress

**U0 — done (2026-09-29, uncommitted on `windows/python-bridge`, based on `v1.5-beta` `839bc39`).**

- **`Garage.Grpc`:** the client generated from `proto/garage.proto` (Grpc.Tools 2.84), and
  `GarageEndpoint`:
  - cleartext HTTP/2 to loopback;
  - a 256 MiB message limit matching the server's;
  - an `x-garage-token` interceptor that replaces any stale token and never prints it.
- **`Garage.App.Core`:**
  - `AppSection`/`SidebarGroup`, in the Mac's order, with Ctrl+number shortcuts;
  - `IBackend` and `DevBackend`, reading `GARAGE_GRPC_HOST`/`PORT`/`TOKEN` and `GARAGE_MCP_URL`;
  - `IUiDispatcher`;
  - `OperationRunner`, ported rule for rule: it refuses while busy, logs line by line, logs
    "`<label>` cancelled" (a gRPC `Cancelled` counts), and keeps 4,000 lines;
  - `AppState`, holding the connection, version and corpus counts;
  - `ConnectionPresentation`.
- **`Garage.App`** (WinUI 3, Windows App SDK 2.5.1, unpackaged, self-contained):
  - single instance, redirecting to the running app;
  - the `NavigationView`: Status, the three group headers, Settings in the footer;
  - Mica and a custom title bar;
  - Ctrl+1…9 and Ctrl+, shortcuts;
  - a Status page with the connection `InfoBar` and Refresh (automation ID `status.refresh`);
  - placeholder pages naming their phase, and a Settings page showing the backend;
  - a notification-area icon (H.NotifyIcon.WinUI 2.4.1) with Open and Quit;
  - closing the window hides it; Quit exits.
- **Tests:** 33 Core tests. With the bridge's 42, the solution runs 75 in `dotnet test`, which the
  `winapp` CI job already runs.
- **Verified by hand through UI Automation:**
  - without a server, Status reads "Garage isn't reachable";
  - with `garage serve` on loopback and a shared token, Refresh reads "Connected to Garage 1.5.0"
    and the corpus counts;
  - a second launch exits and hands off to the running app;
  - closing hides to the tray.
- **Decisions taken at their recommended defaults:** H.NotifyIcon.WinUI for the tray (decision 1),
  and unpackaged during development (decision 2).
- **Not yet:**
  - UI automation in CI (FlaUI, §5);
  - an app icon (the tray draws a generated "G");
  - the Segoe Fluent glyphs, which stand in for the Mac's SF Symbols and need a design pass.

**U1 — done (2026-09-29, uncommitted, same branch).** The reading pages, each a Core view model
kept for the session, so a page's query, filters and selection survive navigation.

- **Search:**
  - query, mode (Hybrid / Vector / Full-Text), limit 1–100, and class/trust/source filters;
  - results with an inspector (rank, score, matched-by, heading, authors, URI, snippet, full
    content, copy);
  - the Mac's status and empty-state wording;
  - the first hit opens.
- **Documents:** filters and a list of 200 per request; the detail shows the summary, extractor,
  authors, facts and ordered chunks.
- **Facts:**
  - search, Source/Kind/Class filters, pages of 200 with Load More;
  - counts from `GetFactStats` ("N facts from M documents");
  - the grounded excerpt with the span emphasized, and sorted attributes.
- **Database:** the Contents box from `GetStats`. The server row, Schema, backups and Reset wait for
  U3, but their presentations (`DatabaseHeadline`, `DatabaseSchemaPresentation`) are ported and
  tested now.
- **Logs:**
  - the app's own log (connection changes and failures) and the operations runner's;
  - text and level filters, newest-first, and at most 500 rows;
  - the status bar ("N of M entries, showing the latest 500"), with Copy and Clear.
- **Ported from the Mac with their test cases:**
  - `LogTableViewTests`: level inference, which is the Mac's four-pass rules with its prefix regex
    verbatim, plus text matching, level filters, the count text and the rows shown;
  - `FactListItemTests`: grounding in Unicode scalars, plus an astral-plane case, where UTF-16
    indices would drift;
  - `DatabasePresentationTests`: "On this Mac" reads "On this PC".
- **Corrections found on the way:**
  - The U0 `OperationRunner` trimmed its log one line at a time. The Mac trims a full buffer to
    three quarters (`LogLine.trimCount`), because trimming only the overflow re-laid the visible
    rows on every append during an ingest. `LogBuffer` now does the Mac's trim, and every log
    uses it.
  - The Python server puts the whole exception in the gRPC detail: for a database error, the full
    SQL and its parameters, including the query's embedding. `RpcErrors.Describe` shows the first
    line ("column c.direction does not exist"), and every page words errors through it.
- **Tests:** 98 Core tests plus the bridge's 42, so the solution runs 140.
- **Verified by hand through UI Automation, against `garage serve` over a real corpus:**
  - Documents lists 53 and opens detail;
  - Facts shows the empty state (no facts gleaned);
  - Database reads 2 sources · 242 documents · 2,226 chunks · Indexed 0% with 1 model;
  - Logs records the connection;
  - with a wrong token, and with no server, every page reports the failure and Logs records it.
- **Found against that corpus:** its database predated migration `014_chunk_direction.sql`
  (merged from `v1.5-beta`). Search and document detail failed with "column … direction does not
  exist", and the pages now show exactly that. `garage init-db` applies it. On Windows this is the
  Database page's Schema row's job once the service host exists (U3).
- **Left for later:**
  - F5 refresh (U2, with the page commands);
  - the Mac's "Reveal in Finder" (Windows: "Show in Explorer", with Sources in U2);
  - the Status page's Library box (U3).

**U2 — done (2026-09-29, uncommitted, same branch).** The operations pages. Ordinary operations run
on `AppState.Operations`; backfill and fact distillation have their own runners
(`AppState.Backfill`, `AppState.Facts`), as on the Mac, so a long job never blocks the rest. Toasts
announce a finished scan, backfill or Glean (`ToastNotifier` over `AppNotificationManager`; a
refused registration drops notifications rather than failing the operation).

- **Sources:**
  - rows with symbol, tint, badges (DISABLED, NOT SYNCED, UNREADABLE), status, progress and counts;
  - Add Source (a dialog with a folder picker and a suggested name that follows the folder), Scan
    (per source or all, streaming "Counting items… N so far"), Sync with `garage.json`, and Remove
    (with a confirmation);
  - NOT SYNCED comes from a dry-run `SyncSources`, which loading never applies;
  - UNREADABLE is checked on this PC (`LocalAccess`).
  - The macOS permission cards have no Windows counterpart. Ingest waits for U3 (the button says so).
- **Models:**
  - the Embedding card and summary, the models with their progress, Register (the catalog supplies
    the dimensions), Make Default, and Drop (with a confirmation);
  - Embed and Embed All, streaming progress on the backfill runner, with Stop;
  - the distillation provider and model.
  - Local llama models follow the llama service.
- **MCP Server:**
  - one row per assistant, with Connect / Update / Disconnect and Connect All, registering stdio as
    the Mac does;
  - an HTTP entry is told apart from a stdio one by reading the assistant's own config
    (`McpClientConfigReader`: `mcpServers`, `servers`, `context_servers`), as the Mac reads it;
  - the server row reads "HTTP off": the HTTP server runs under the service host (U3).
- **Settings:** the Ollama and LM Studio addresses, and the distillation and answer providers and
  models. They are saved with `SetSetting`, which validates first, so a refused value keeps the edit
  and shows why.
- **Facts:** Glean Facts (`EnrichFacts` with `stale_only`) on its own runner, with per-document
  progress and Stop.
- **Python, needed by the MCP page:** `mcp-install` targets on Windows use `%APPDATA%` for the
  desktop apps (Claude Desktop; Cline in Cursor and VS Code; Zed's `%APPDATA%\Zed`). The dot-folder
  clients stay under the home folder. macOS and Linux are unchanged. The three POSIX-only tests in
  `test_mcp_install.py` are now platform-aware (windows.md §4 item 4).
- **Ported from the Mac with their test cases:**
  - `SourcesPresentationTests`: idle rows, badges, symbols (plus Windows folders: OneDrive,
    `G:\My Drive`, drive roots), tints, suggested names (plus Windows paths and diacritics) and the
    summary;
  - `ModelsPresentationTests`: required and missing counts, summary, which rows are embedding,
    headline kinds, providers;
  - `MCPServerPresentationTests`: the headline, rows and summaries; "this Mac" reads "this PC".
- **Tests:** 177 Core tests plus the bridge's 42, so the solution runs 219.
- **Verified live through UI Automation, fully isolated:**
  - The setup:
    - a throwaway `garage_ui_test` database, and a scratch config;
    - `garage serve` with its home, AppData and working folder redirected, so MCP registration
      wrote only scratch client configs. The real Claude Desktop config's hash was unchanged
      afterwards;
    - the test database was dropped and the scratch folder removed.
  - Add Source through the dialog, with the name suggested;
  - Scan: "3 items found, none indexed yet";
  - Register `bge-m3`, then Embed All: "3 embeddings to go", then "Search ready";
  - Connect Claude Desktop, which merged into its config and kept `preferences`, then Disconnect;
  - a Settings save landed in the scratch config only;
  - Glean Facts: "Gleaning facts… 1 of 3", then "5 facts from 3 documents".
- **Fixed on the way:**
  - A backfill message that already names its model got the name again ("bge-m3: bge-m3: …").
  - The Models and MCP lists were `ItemsControl`s, which UI Automation cannot see into (FlaUI
    needs that). They are `ListView`s now.
- **Not yet verified:** that the toasts appear. The notifier registers and the operations call it,
  but UI Automation cannot read the notification centre.

**U3 — done (2026-09-29, uncommitted, same branch), with the carry-overs at the end.** The app now runs Garage's own
service processes instead of a `garage serve` started by hand, and ingests.

- **The service platform** (windows.md §2.1, the part of Phase 2 U3 needs):
  - `Garage.Services.exe`, one executable started once per service (`--service core`, `--service
    ingest`), each in its own process and each embedding CPython through `Garage.Python`. This
    departs from §2.1's one executable per service; the processes, and so the crash isolation,
    are the same.
  - **core** runs `create_grpc_server` on a loopback port the app picks, behind a fresh
    `GARAGE_GRPC_TOKEN`. **ingest** runs `garage_rag.ingest.ingest_xpc`, persisting through core,
    as GarageIngestXPCService does, with progress over the `set_c_progress_callback` hook.
  - The control plane is `services.proto` over named pipes (Kestrel's named-pipe transport,
    `CurrentUserOnly`): Ping, status, self tests, logs and a log stream, Shutdown; plus
    IngestSource (streaming) and CancelIngest. The peer check admits the app that started the
    service, or a process run from the service's own folder; the package check follows the MSIX.
  - Self tests (Python runtime, stdlib extensions, site-packages, libpq, libtesseract, service
    module, database, gRPC connection for ingest, logging) run at start-up and on Test.
  - Each service keeps a log file in the data folder's `logs`, a ring buffer and a live stream.
  - The app's `ServiceManager` starts core, waits for it, then ingest. Every process goes in a
    kill-on-close Job Object. The manager restarts a service on request and asks each for its state
    every 10 seconds.
  - **Where things are** (`ServiceHostLayout`): environment variables first, then beside the app,
    then, in a checkout, the services' build output, the `py` launcher's 3.14,
    `garage_python\.venv` and `garage_python\src`. The data folder is `%LOCALAPPDATA%\Garage`
    (`GARAGE_DATA_DIR` moves it); its `garage.json` is found first, then `~/.garage.json`.
  - `ServiceHostBackend` is the default. `--dev-backend`, or `GARAGE_GRPC_PORT` set, keeps the
    `garage serve` workflow.
- **The pipeline** (`LibraryCoordinator`, a port of `AppState`'s): scan, Scan & Ingest of one
  source, the ingest queue over every source, Stop (`cancelAll`) and per-source Cancel, Update
  Everything (scan, read, index, glean), and Automatic Updates. Those run on a schedule (15
  minutes to 24 hours, on by default as on the Mac), optionally at launch once the services are
  up, and a second after a source is added or a model registered. Indexing and gleaning go through
  the Models and Facts pages' own runs, so their progress shows whoever started them. Settings
  are in the data folder's `app-settings.json`.
- **Status:** the Library box (headline, bar, detail, current item, the "Scan › Read › Index ›
  Glean" trail, Update Everything or Stop, or Add a Source), Automatic Updates, and the Services
  box. Each service row has Test, Restart and its self-test results.
- **Sources:** Update Everything, Stop, an activity banner, and per row Scan & Ingest or Cancel.
  Rows show queued, reading (percent, counts, current file), stopping, and whether the last ingest
  failed or was cancelled.
- **Logs:** the scan and ingest runners' buffers, and each service's log stream.
- **Ported from the Mac with their test cases:** the ingest rows of `SourcesPresentationTests`,
  `IndexingPresentation` (as `LibraryPresentation`) and `ServiceRowPresentation`.
- **Tests:** 195 Core tests, 20 service tests and the bridge's 42, so the solution runs 257. The
  service tests start the real processes as the app does. With `GARAGE_TEST_DATABASE_URL`, one reads
  a folder into a throwaway `garage_test_*` database through both services.
- **Verified live through UI Automation**, with a throwaway `garage_ui_test` database and a scratch
  data folder (both removed afterwards):
  - the app starts both services and connects; the rows read "Running · 8 passed" and "9 passed";
  - Update Everything walks Read, Index (bge-m3) and Glean (gemma2:2b), and the counts update;
  - Stop during a 403-file read ends the run at the read ("355 documents to read");
  - Scan & Ingest on a row, then its Cancel: "Last ingest was cancelled";
  - killing the app ends both services (the Job Object).
- **Garage's own Postgres** (windows.md §2.5), tested against `windows.yaml`'s `postgres-windows-x64`
  build (Postgres 18.6 with pgvector):
  - `PostgresSupervisor` runs `initdb` on first start (UTF-8, ICU collation under the C locale,
    SCRAM, user `garage`), then `pg_ctl start` on `127.0.0.1:14824`, and creates `garage-rag`, the
    Mac's port and database. A server an earlier run left up is stopped and started again; Quit stops
    it with a fast shutdown. It runs outside the services' Job Object, so a crash of the app does
    not cut it off mid-write.
  - The generated password is kept in Windows Credential Manager (`Garage/postgres-password`,
    `WindowsCredentialStore`). It reaches the services only as `GARAGE_DATABASE_URL` in their
    environment, with `GARAGE_LIBPQ` naming the build's own `libpq.dll` and `PSYCOPG_IMPL=python`,
    so there is one libpq. A lost password stops the start with a message saying so; the services
    never fall back to another database.
  - Found through `GARAGE_POSTGRES_HOME`, or `postgres\` beside the app. Without one the app uses the
    database `garage.json` names, as before.
  - After the services start, the app applies the schema (`InitDb`), and for a new cluster, or one
    with no sources, registers the sources `garage.json` declares (`SyncSources`), as the Mac's
    `finishDatabaseReset`.
  - **Database page:** the server row (`DatabaseHeadline`: running, port, version, cluster folder)
    and **Reset Database**: a confirmation with the Mac's wording, then the services and Postgres
    stop, `pgdata` is deleted, and the app relaunches with `--after-database-reset <pid>`. The new
    instance waits for the old one to exit, creates the new database and reports how that went.
  - Verified live, isolated (scratch data folder and credential, both removed): first start,
    schema, the declared source registered, Scan & Ingest, then Reset and Relaunch ("A new database
    was created, with the 1 source garage.json declares"); the ingest service's self tests read
    "psycopg 3.3.6 (python), libpq 18.6" and "PostgreSQL 18.6, pgvector 0.8.6".
  - Tests: 4 against the real build (`GARAGE_TEST_POSTGRES_HOME`; the `winapp` CI job now downloads
    it), including a Credential Manager round trip, and 6 of the database preparation and server row.
    The solution runs 267.
- **Database page, the rest:** the Schema row (`DatabaseSchemaPresentation`: "Schema up to date"
  with Check Again, which re-runs `InitDb`; updates to apply when the start-up schema step failed)
  and the extensions installed; **Back Up…** (`pg_dump --format=custom`, to a `.garagedump` file)
  and **Restore…** (`dropdb --force`, `createdb`, `pg_restore`, then the schema, as the Mac does;
  the pipeline stops first and every page rereads afterwards), with the Mac's confirmation wording.
  Postgres has no tracked migrations table here: the app applies the whole schema on every start,
  so an update cannot stay pending past a launch.
- **Status:** a Database row among the services ("Running · PostgreSQL 18.6 · port 14824"), with
  Test (the server's size and extensions) and Restart. The services' self tests run again once the
  schema is in, as the Mac re-runs its helpers' tests after configuring them; before that a new
  cluster has no pgvector and the Database Connection test fails.
- **MCP over HTTP:** a third service, `Garage.Services --service mcp`, runs
  `garage_rag.mcp_server.server.start_background_server` on `127.0.0.1:8787/mcp` (the Mac's
  GarageMCPServerService). It runs only while the MCP Server page's switch is on (off by default,
  remembered in `app-settings.json` as `mcp.httpEnabled`), so no port is open otherwise. The server
  row follows the service; an HTTP registration at the live address reads as connected, and
  `IBackend.Mcp` names it for Ask Garage (U4). Its self tests add HTTP Server.
- **`garage_rag`:** `ingest.StreamToLog` answers `isatty()` (False). The services route Python's
  output through it, and uvicorn's log formatter asks, which stopped the MCP server from starting.
- **Tests:** the solution runs 272. New: backup, change and restore against the real Postgres
  build; the MCP service answering an MCP `initialize` over HTTP and closing its port when switched
  off; the switch's remembered preference; the Database row and the schema action.
- **Verified live** (isolated as before): on a new cluster the rows read "Database · Running ·
  PostgreSQL 18.6 · port 14824", "Garage Backend · 8 passed", "Ingest · 9 passed", "MCP Server ·
  Off"; the Database page "Schema up to date" with pg_trgm 1.6 and vector 0.8.6; the MCP switch
  brought the server up and an MCP `initialize` got 200.
- **Carried over:**
  - The AF_UNIX socket in place of the loopback port (spike S2).
  - Scanning a source added during a run once the run ends (the Mac's `queueSourceScan`).
  - "Documents to glean" in the Library box: `GetStats` does not report distilled documents.
  - A run's new facts are embedded by the next run, since indexing comes before gleaning, as on the
    Mac.

**U4 — done (2026-09-30, uncommitted, same branch).** Onboarding and the notification area.

- **Setup assistant** (`FirstRunCoordinator`, `FirstRunView`; the Mac's, page for page): services →
  data → models → assistants, replacing the pages until it is finished or skipped (`firstRun.completed`
  in `app-settings.json`). It drives the Sources, Models and MCP Server pages' own view models, so the
  two cannot disagree, and holds Automatic Updates until it closes (`LibraryCoordinator.HoldForFirstRun`;
  the Mac's `isMaintenanceDeferredForFirstRun`). An install that already has sources or models skips it;
  a relaunch after Reset Database always shows it; Settings' **Setup Assistant…** re-runs it.
  - Page 1's rows come from the app's own Postgres, the start-up schema step (`DatabaseViewModel.SchemaApplied`),
    the backend service and the MCP service; Retry starts again what failed.
  - The data page offers this PC's folders: Documents, Desktop, Downloads, OneDrive (`%OneDrive%`),
    Dropbox (its `info.json`), Google Drive for desktop (`<drive>:\My Drive`) and `~\source\repos`,
    with the Mac's slugs where both have the folder; Add Folder… adds others. No Mail or Messages.
  - The models page reads the catalog (`data/models/models.json`, shipped beside the app, or
    `GARAGE_MODEL_MANIFEST`) and registers with Ollama or LM Studio under each provider's name for the
    model (`provider_refs`); the distillation model is a preset or a typed name. The built-in engine
    joins with the llama service (windows.md Phase 4).
- **Notification-area flyout** (`TrayStatus` from the Mac's `MenuBarStatus`, `AskAnswer` from
  `MenuBarAnswer`, `TrayViewModel`, `TrayFlyoutWindow`): a borderless window at the corner of the
  screen with Open and Quit, quick search (five hybrid hits a quarter second after typing; a hit opens
  its file; Enter opens the Search page), **Ask Garage** (`rag_agent` over Garage's MCP server through
  `McpHttpClient`, decision 6's minimal client: `initialize`, then `tools/call`, with the session kept;
  the answer, its footnote and citations), the services row ("All systems go"), and the activity with
  Ingest Now or Stop and the stage trail. The icon follows the Mac's: a blue "G" (open door), grey
  (closed), an orange "!" for what blocks the app, pulsing while the pipeline works; its tooltip is
  the accessible label. Right-click: Open, Ask Garage, Pause/Resume Automatic Updates, Report a Bug, Quit.
- **Bug report** (`BugReportRedactor`, `BugReportComposer`, `BugReportDestination`,
  `BugReportDiagnostics`; the Mac's): a dialog with the draft, diagnostics (on) and recent log lines
  (off), and a preview of exactly what Copy Report, Save… and Open Issue on GitHub hand over. The
  redactor knows Windows home folders in each spelling a log carries (`C:\Users\name`, forward
  slashes, JSON-escaped). Nothing is sent by the app. Crashes are logged to `logs\app-crash.log`.
- **Jump list** (`ICustomDestinationList`, with or without package identity): Search, Ask Garage,
  Add Source, Update Everything, each `Garage.exe --do …`, which a second launch hands to the running app.
- **Settings**: launch at sign-in (the account's `Run` key, starting with `--background` in the
  notification area only; a packaged build will declare a `StartupTask`), the update channel (Stable or
  Beta; chosen only by the App Installer build, which follows `garage.appinstaller` or
  `garage-beta.appinstaller`), Setup Assistant…, Report a Bug…, and About with the third-party notices.
- **Keyboard:** F5 rereads the current page; Ctrl+F opens Search with the cursor in its field.
- **Tests:** 313 Core tests (new: the Mac's `MenuBarStatusTests`, `MenuBarAnswerTests`,
  `FirstRunTests`, `BugReportTests` and `TipJarTests` cases, the MCP client against a fake server,
  the assistant's walk through the real page models).
- **Verified live**, isolated (scratch data folder, a scratch "OneDrive" folder, scratch credential;
  all removed): the assistant came up on a new cluster, added the picked folder, registered bge-m3 on
  Ollama and the distillation model, listed this PC's assistants (none was connected), and Automatic
  Updates read and embedded the folder once it closed; the flyout read "All systems go · 2 documents in
  1 source", quick search found the note, and **Ask Garage answered "The workbench is on the north wall,
  under the pegboard." (Searched once · gemma2:2b)** through the MCP service; launch at sign-in wrote and
  removed its `Run` value; the bug report's preview redacted the home folder, user name and the
  database password.
- **Fixed on the way:** the flyout measured its content before its window was live, which WinUI turns
  into a fail-fast (it now fits once loaded); the bug report read the sources and models before their
  pages had (it loads them first); the flyout window's title clashed with the main window's.

**U5 — done (2026-09-30, uncommitted, same branch), except what needs a Store or a packaged build.**

- **Accessibility:**
  - every control a keyboard or Narrator user reaches has a name; a UI test walks every page and
    holds it (Accessibility Insights' name rule), and found three icon-and-text buttons without one;
  - page titles and section headings are UIA headings (levels 1 and 2), the assistant's step list
    names the current step, and the Library headline is a live region Narrator reads as it changes;
  - high contrast: tinted circles take the highlight colour, and their glyphs `TintGlyphBrush`
    (the highlight text colour), instead of white on an app colour;
  - text sizes come from the type ramp styles, so they follow Windows' text scaling.
- **Strings in `.resw`:** `Strings/en-US/Resources.resw` holds the XAML's 165 strings (through
  `x:Uid`) and code-behind's plain ones (`Strings.Get`). Interpolated sentences in code-behind, and
  Core's presentation wording (decision 5: kept in C# and in step with the Mac by tests), stay in code.
- **UI tests** (`tests/Garage.App.UITests`, FlaUI): the built app against a fake backend the test
  serves (GarageService over gRPC with an in-memory corpus, and an MCP endpoint whose `rag_agent`
  answers deterministically), in a throwaway data folder: the setup assistant end to end, Search,
  Ask Garage from the tray (through the jump list's `--do ask`), Add Source (`--do add-source`), the
  Logs status bar counts, Documents over a 25,000-document corpus, and every control's name. They run
  with `GARAGE_UI_TESTS=1` and refuse to share the desktop with a running Garage. CI runs them as a
  step that reports without failing the job until hosted runners prove steady.
- **Large corpora:** Documents loads the next 200 as the list nears its end (`LoadMoreAsync`); against
  25,000 documents the first page shows in about a second and scrolling to the end asks for one more
  page. Facts already pages; Logs shows the latest 500; Search returns at most 100. The long lists sit
  in grid rows, so they virtualize.
- **Tip jar** (Store build only): `TipProducts` with the Mac's product identifiers as in-app offer
  tokens, `TipJarViewModel`, and `StoreTipStore` over `Windows.Services.Store` (consumables, reported
  fulfilled at once). Settings shows it only when the app runs from the Store; the add-ons are made in
  Partner Center with those tokens.
- **Tests:** the solution runs 389 (Core 315, services and Postgres, the bridge, and 7 UI tests).
- **Not verified here:** the tip jar's purchase (needs the Store build and Partner Center add-ons);
  the packaged build's `StartupTask` and update channel switch (windows.md §6); Narrator itself and
  Accessibility Insights' full scan (the name rule is automated; the rest is a manual pass).

**A usable UI** (read, search, manage sources and models, connect Claude, against `garage serve`
plus the CLI for ingest) exists after **U2, about 5–7 weeks in**. **Parity with the Mac app** comes
after U5, about 11–14 weeks, overlapping windows.md Phases 2–5.

## 5. Testing

- **Core unit tests** (`Garage.App.Core.Tests`, xUnit v3, in the existing `winapp` CI job):
  - **presentations:** port every Swift presentation test case, so both apps agree on wording and
    states;
  - **view models and pipelines:** against a fake `IBackend` and a fake gRPC client. Cover Update
    Everything's order, cancellation mid-stream, busy flags, and the dedicated runners not blocking
    ordinary operations;
  - **the `AppSection` order test.**
- **Integration:** a job that starts `garage serve` with a token, on the CPython and Postgres
  `windows.yaml` already builds, and drives the Core view models through real RPCs. This catches
  contract drift between `garage.proto` and the Python server.
- **UI automation:** FlaUI (UI Automation, MIT). WinAppDriver is unmaintained. It drives
  `Garage.App` against a fake backend, mirroring the Mac's UI test targets
  (`macapp/Tests/GarageAppUITests`: Status, Models, Logs, MenuBar, MenuBarAsk, and the rest):
  - first run end to end;
  - Search and Add Source;
  - Update Everything from the Library box, with progress;
  - Ask Garage from the tray, against a deterministic answer (the Mac uses
    `DeterministicLlamaEngine`);
  - the Logs status bar counts.

  Keep automation IDs aligned with the Mac's `accessibilityIdentifier`s (e.g.
  `status.updateEverything`, `status.library.title`), so a test on one platform names its
  counterpart. UI Automation needs an interactive desktop session, so this may need a self-hosted
  runner if hosted runners prove flaky.
- **Accessibility:** Accessibility Insights for Windows automated checks on each page, in U5.

## 6. Decisions needed

1. **Tray icon:** H.NotifyIcon.WinUI (MIT, recommended; handles the flyout and context menu), or
   an own `Shell_NotifyIcon` wrapper.
2. **Packaged during development:** develop unpackaged, with the Windows App SDK bootstrapper, for
   a fast inner loop, and package MSIX only in CI (recommended). The alternative is packaged from
   the start, which exercises MSIX-only behaviour (execution aliases, `LocalState`, Credential
   Locker) earlier.
3. **Ingest before the service host:** wait for `Garage.Ingest` in U3 (recommended, keeps parity
   with the Mac), or add an `Ingest` streaming RPC to `garage.proto` so `DevBackend` can ingest
   sooner. The RPC is a cross-platform contract change and would duplicate the Mac's XPC path.
4. **Minimum Windows version:** Windows 10 1809 (the Windows App SDK floor), or Windows 11 only.
   Mica has a fallback on Windows 10; the AF_UNIX sockets windows.md wants need 1803 or later
   either way.
5. **Shared wording:** port the presentation types' strings into C# and keep them in step by
   tests (recommended for now), or move page wording into a shared resource both apps load (more
   machinery; worth it only if the apps drift).
6. **MCP client for Ask Garage** (taken in U4: the minimal client, `McpHttpClient`): a minimal JSON-RPC client (`initialize`, `tools/call`) like the
   Mac's `GarageMCPService` (recommended: two methods, no dependency), or the official C# MCP SDK
   (`ModelContextProtocol`), which is more complete and heavier.

## 7. Risks

- **WinUI 3 gaps:**
  - no built-in tray icon (solved by the library in decision 1);
  - multi-window and dialog-owner quirks (the first-run window and `ContentDialog` need a
    `XamlRoot`);
  - slower cold start than WPF, which matters for launch at startup; measure in U0.
- **Windows App SDK versioning:** pin one version in `Directory.Packages.props` and update
  deliberately. The runtime ships with the MSIX (framework dependency) or self-contained, which is
  decided in windows.md §6.
- **Mac drift:** the Mac UI keeps moving. Two days after this plan was first written, `main` had
  added Ask Garage, moved Automatic Updates between pages, and added `GetFactStats` (§8). Port each
  phase from a recorded commit, and at the start of each phase diff `macapp/Sources/GarageApp`,
  `proto/garage.proto` and `garage_python/src/garage_rag/mcp_server` since the last one recorded
  in §8.
- **Large corpora:** Documents, Facts and Logs must virtualize (`ItemsRepeater`/`ListView` with
  incremental loading), and page RPCs must paginate. Test with a corpus the size of the Google
  Drive example (25,000 files) in U5.

## 8. Parity checks

Each check records the commits compared and what the plan took from them. The next check diffs
from the last row.

| Date | Compared | Changes that reached the plan |
|---|---|---|
| 2026-09-27 | `v1.5-beta` `2454039` | The plan's baseline |
| 2026-09-29 | `main` `b82c6d2` (97 commits past the baseline, which it contains), `v1.5-beta` `839bc39` | See below |
| 2026-09-29 (U3) | `v1.5-beta` `b809c88` | The App Store build asks for the home folder before the disk, and reads Contacts only for communication sources. Neither has a Windows counterpart: nothing is sandboxed, and ingest passes no contact names |

What the 2026-09-29 check found:

**On `main` (and `v1.5-beta`):**
- **Ask Garage** in the menu bar (`MenuBarAnswer`, via the `rag_agent` MCP tool):
  - added to the tray flyout (§3) and the jump list;
  - an MCP endpoint added to `IBackend` (§2.3);
  - decision 6 (§6) on the MCP client;
  - a FlaUI test (§5).
- **Automatic Updates moved** from Sources to a Library box on Status, next to Update Everything;
  the launch run waits for every service. Moved in §3 and U3.
- **`GetFactStats` RPC** (with `garage facts list|stats`): Facts page (§3).
- **Icon-button row actions** on Status and Models; **a status bar under the Logs table**: §3.
- **A beta update channel** (Sparkle): Settings' update channel (§3), and a beta `.appinstaller`
  feed in windows.md §6.
- **`garage mcp-install` registers stdio by default**, as the app does: no change needed, since
  the plan already registers stdio.
- **Postgres externals collapsed** into one `//ext/postgres` package (with
  `postgres19.MODULE.bazel` beside `postgres.MODULE.bazel`):
  - `tools/windows/fetch_ext.py` still finds `ext/postgres/postgres.MODULE.bazel`;
  - no UI change.
- **Messages contact names and message direction:** macOS-only data, no Windows UI change.

**On `v1.5-beta` only (not yet on `main`):**
- **The tip jar** (App Store in-app purchases): a Store-only item in U5, planned as Store add-ons.

**For this branch:** `windows/python-bridge` forked from `2454039`, so it has none of the above
yet. Merge `v1.5-beta` into it before opening the PR. Expect conflicts in `README.md` (`main`
changed the `mcp-install` lines this branch's rewrite keeps) and possibly in `CLAUDE.md` (edits
beside the insertion point of the "Windows app" section).
