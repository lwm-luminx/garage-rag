---
layout: default
title: GarageKit — the app's client of GarageService, apart from the UI
description: Moving the Swift gRPC client out of GarageApp into a GarageKit library behind protocols.
---

# GarageKit: the app's client of GarageService, apart from the UI

Written from `main` on 2026-10-04. Nothing here is built yet; file and line references are to the
tree at that date.

## Why

`GarageGRPCService` (`macapp/Sources/GarageApp/Services/GarageGRPCService.swift`, with
`GarageGRPCService+Operations.swift` and `GarageGRPCService+Facts.swift`) is the app's whole
relationship with the Python `GarageService`. It starts the server through `GarageXPCService`, it
owns the grpc-swift channel, and it exposes about thirty RPCs. Three jobs in one `@MainActor
ObservableObject` inside the app module, with these consequences:

- **Views are typed against the concrete class.** `SourcesView.run`, `ModelsView.run` and
  `AppState.runOperation` take `(GarageGRPCService) async throws -> String` closures.
  `GarageMCPService` holds `weak var grpc: GarageGRPCService?` and names
  `GarageGRPCService.McpInstallScope`. `FirstRunCoordinator` and `BugReportDiagnostics` read
  `appState.grpc.status`.
- **Proto messages reach the UI layer.** Every method returns a `Garage_*` message.
  `AppState.scan`, `runBackfill` and `runEnrichFacts` compare `status.phase` against `"started"`,
  `"progress"`, `"document"`, `"complete"`, `"skipped"` and `"finished"`. `SearchResultItem`,
  `DocumentListItem`, `FactListItem` and `FactPromptItem` each carry an `init` from a proto. Display
  text for operations is written as `summary` extensions on `Garage_StatsResponse`,
  `Garage_ListModelsResponse`, `Garage_McpStatusResponse` and `Garage_SetSettingResponse`.
  `GarageApp_lib` depends on `//proto:garage_proto_swift` directly.
- **The API cannot be faked.** The only way to exercise code that calls the backend is a real
  `GarageGRPCService` over a `PostgresService`. `StatusViewTests` runs `testServiceQuery()` against
  nothing and asserts on the failure text; `AppStateTests` throws `GarageGRPCError.rpcFailed` from
  inside an operation closure as its stand-in for a server error. `ModelsView+AddModel` throws
  `GarageGRPCError.rpcFailed` for a form validation error, because that is the one error type the
  runner displays.
- **Lifecycle and API are the same object.** `search()`, `listDocuments()`, `listFacts()` and
  every operation begin with `if status != .running { try await start() }`, so a read can launch the
  server, which needs `PostgresService`, `Paths`, `LMStudioTokenStore`, `GarageAppGroup`, `LogLine`
  and `GarageXPCClient`. None of that belongs beside a search request.

A `GarageKit` module gives the rest of the app (and later the launchers, the UI tests' readiness
probe, or an extension) one typed Swift client whose signatures carry no grpc-swift, no protos and
no server lifecycle.

## Three ways to cut it

### A. Move the class as it is

Lift `GarageGRPCService`, `GarageGRPCAuth` and the item structs into a new module and mark them
`public`.

- For: smallest diff; call sites unchanged.
- Against: the module would have to import `PostgresService`, `Paths`, `LMStudioTokenStore`,
  `LogLine` and `IngestClient.GarageXPCClient`, so the kit would be the app under another name. The
  UI would still see protos and still could not be given a fake. It separates nothing.

### B. Split lifecycle from client; the client behind protocols with its own models

The kit holds the endpoint, the token type, the connection, a typed client and the value types the
pages show. The app keeps starting and stopping the server, and talks to the kit through
protocols it can also implement with a test double.

- For: the UI compiles against Swift value types and protocols only; one place maps proto to model
  and gRPC status to error; the client is testable against an in-process grpc-swift server with no
  Python; a later grpc-swift 2 move touches the kit only.
- Against: the largest diff; every model needs a public initializer; the streaming callbacks
  become `AsyncThrowingStream`s, which changes three `AppState` loops.

### C. Thin kit: a connection factory and the generated client

Export `GarageEndpoint`, the token and a `makeClient() -> Garage_GarageServiceAsyncClient`, and let
the app keep using protos.

- For: little code.
- Against: protos and `CallOptions` stay in the views; the only fake is a real gRPC server; the
  phase-string knowledge stays scattered.

**Recommendation: B.** The rest of this plan is B.

## The design

### Module

`macapp/Sources/GarageKit`, a `swift_library` named `GarageKit`, declared like
`IngestClient/BUILD.bazel` (`srcs = glob(["**/*.swift"])`, `module_name`, public visibility). A
static library, not a framework: it has no resources, unlike `PythonXPCService.framework`.

Dependencies, and only these:

- `//proto:garage_proto_swift` for the generated messages and `Garage_GarageServiceAsyncClient`,
  which bring `GRPC`, `NIO` and `SwiftProtobuf` (`GarageApp_lib` relies on the same transitive
  modules today).
- `//macapp/Sources/PythonXPCService:PythonXPCService_protocol` for `GarageSockets` (where the
  socket is) and `GarageXPCConfigurationKey` (the keys the helpers read). Pure Swift, no Python.

No SwiftUI, Combine, `PostgresService`, `Paths`, `LogLine` or `IngestClient`.

```
macapp/Sources/GarageKit/
  BUILD.bazel
  GarageEndpoint.swift           where the server listens: .unixSocket(path) | .tcp(host, port)
  GarageServiceToken.swift       the per-launch x-garage-token value and its metadata key
  GarageConnection.swift         actor owning the EventLoopGroup and ClientConnection
  GarageClientError.swift        typed errors, mapped from GRPCStatus
  GarageServing.swift            the protocols the UI depends on
  GarageClient.swift             the grpc-swift implementation: ping, status, corpus reads
  GarageClient+Operations.swift  sources, models, settings, schema, MCP registration
  GarageClient+Streams.swift     scan, backfill, enrichFacts as AsyncThrowingStream
  Models/Search.swift            SearchQuery, SearchResultItem
  Models/Documents.swift         DocumentFilter, DocumentPage, DocumentListItem,
                                 DocumentDetailItem, DocumentChunkItem, DocumentAuthorItem,
                                 DocumentFactItem
  Models/Facts.swift             FactFilter, FactListPage, FactListItem, FactClassCount,
                                 FactAttribute, FactPromptItem, FactPromptList,
                                 EnrichFactsRequest, EnrichFactsEvent
  Models/Sources.swift           SourceSpec, SourceRecord, ScanEvent, ScanSummary, SyncOutcome,
                                 ReconcileOutcome
  Models/Models.swift            ModelRecord, ModelRegistration, BackfillEvent
  Models/Service.swift           ServiceStatus, ServiceVersion, CorpusStatistics, SettingValue,
                                 SettingChange, SchemaOutcome, OperationOutcome
  Models/MCP.swift               McpInstallScope, McpTransport, McpInstallOutcome,
                                 McpRegistrationStatus
  Mapping/*.swift                internal init(proto:) and request builders, one file per family
```

Only `GarageClient*.swift` and `Mapping/*.swift` import `proto_garage_proto_swift`; the models and
protocols import Foundation. A test holds that line (see Tests).

### Endpoint and token

```swift
public enum GarageEndpoint: Hashable, Sendable {
    case unixSocket(path: String)
    case tcp(host: String, port: Int)

    /// The app's own server: `s/grpc` in the App Group container (GarageSockets), or loopback
    /// when that path would overflow sun_path.
    public static func appDefault(host: String = "127.0.0.1", port: Int = 50051) -> GarageEndpoint
    /// `unix:<path>` or `host:port`, as grpc names it and the Status page shows it.
    public var address: String { get }
    /// The keys the Python helpers read (GarageXPCServiceBase.grpcTarget): the socket when there
    /// is one, else host and port. Replaces GarageGRPCService.addressOptions.
    public var helperConfiguration: [String: String] { get }
}

public struct GarageServiceToken: Hashable, Sendable {
    public static let metadataKey = "x-garage-token"
    public let value: String
    public init(value: String)
    /// 32 random bytes, hex encoded. The app makes one per launch.
    public static func random() -> GarageServiceToken
}
```

`GarageGRPCAuth` shrinks to the app's one instance (`static let token = GarageServiceToken.random()`)
and goes away once the backend service owns it (step 5).

### Connection

```swift
actor GarageConnection {
    init(endpoint: GarageEndpoint)
    /// A lazily made ClientConnection on one event loop, with the 256 MiB receive limit that
    /// matches MAX_REQUEST_BYTES in service/server.py.
    func channel() -> GRPCChannel
    /// Close and forget the channel, as cleanupChannel does after a failed ping.
    func reset() async
    func shutdown() async
}
```

Internal to the kit. An actor, so `GarageClient` is `Sendable` and not bound to the main actor.

### Errors

```swift
public enum GarageClientError: Error, Equatable, LocalizedError {
    case unavailable(String)       // UNAVAILABLE: nothing listening, socket gone
    case unauthenticated           // UNAUTHENTICATED: token missing or wrong
    case permissionDenied(String)  // PERMISSION_DENIED: a config change over TCP (auth.py)
    case invalidArgument(String)   // INVALID_ARGUMENT: ValueError on the server
    case notFound(String)          // NOT_FOUND: LookupError
    case alreadyExists(String)     // ALREADY_EXISTS: FileExistsError
    case deadlineExceeded
    case server(code: Int, message: String)
}
```

Mapped from `GRPCStatus` in one function. `_grpc_errors` in `garage_rag/service/server.py` maps
`LookupError`, `ValueError`, `FileExistsError` and `PermissionError` onto these codes, so the Swift
side gets the vocabulary the CLI has. `errorDescription` is the server's message, which is what
`GarageGRPCService.describe` recovers today. A cancelled call is rethrown as `CancellationError`,
which `OperationRunner` already catches.

### Protocols

Split by what a page needs, composed into one:

```swift
public protocol CorpusReading: Sendable {
    func ping() async throws -> Bool
    func status() async throws -> ServiceStatus
    func version() async throws -> ServiceVersion
    func statistics() async throws -> CorpusStatistics
    func search(_ query: SearchQuery) async throws -> [SearchResultItem]
    func documents(_ filter: DocumentFilter) async throws -> DocumentPage
    func document(id: Int64) async throws -> DocumentDetailItem
    func facts(_ filter: FactFilter) async throws -> FactListPage
}

public protocol SourceAdministering: Sendable {
    func sources() async throws -> [SourceRecord]
    func addSource(_ spec: SourceSpec) async throws -> OperationOutcome
    func removeSource(slug: String) async throws -> OperationOutcome
    func scan(source: String, includeCode: Bool) -> AsyncThrowingStream<ScanEvent, Error>
    func syncSources(dryRun: Bool) async throws -> SyncOutcome
    func importSourcesToConfig() async throws -> OperationOutcome
    func reconcile(source: String, apply: Bool) async throws -> ReconcileOutcome
}

public protocol ModelAdministering: Sendable {
    func models() async throws -> [ModelRecord]
    func registerModel(_ registration: ModelRegistration) async throws -> OperationOutcome
    func setDefaultModel(slug: String) async throws -> OperationOutcome
    func dropModel(slug: String) async throws -> OperationOutcome
    func backfill(model: String?) -> AsyncThrowingStream<BackfillEvent, Error>
}

public protocol FactDistilling: Sendable {
    func enrichFacts(_ request: EnrichFactsRequest) -> AsyncThrowingStream<EnrichFactsEvent, Error>
    func factPrompts() async throws -> FactPromptList
}

public protocol SettingsAdministering: Sendable {
    func initializeSchema(schemaDirectory: String) async throws -> SchemaOutcome
    func setting(named name: String) async throws -> SettingValue
    func setSetting(_ name: String, to value: String) async throws -> SettingChange
}

public protocol MCPRegistering: Sendable {
    func mcpInstall(scope: McpInstallScope, transport: McpTransport, force: Bool)
        async throws -> McpInstallOutcome
    func mcpUninstall(target: String) async throws -> OperationOutcome
    func mcpStatus() async throws -> McpRegistrationStatus
}

public typealias GarageServing = CorpusReading & SourceAdministering & ModelAdministering
    & FactDistilling & SettingsAdministering & MCPRegistering
```

`GarageClient: GarageServing` is the real one. A view asks for the slice it uses (`SourcesView`
takes `any SourceAdministering`), `AppState` holds `any GarageServing`, and the test double
implements the typealias once.

Timeouts are not on the protocols. `GarageClient` keeps today's per-RPC defaults (30 s for reads,
120 s for operations, 30 min for `removeSource`, 10 min for `scan` and `reconcile`, none for
streams) in a `GarageClient.Timeouts` value its initializer takes, so a test can shorten them.

Requests with many fields are structs with defaults (`SearchQuery` replaces the nine-parameter
`search`, `ModelRegistration` the seven-parameter `registerModel`), the shape the Python
`GarageClient` in `service/client.py` already has.

### Streaming

`scan`, `backfill` and `enrichFacts` take `@MainActor` `onStatus:` callbacks today and return the
last status, leaving the caller to read phase strings. Each becomes an `AsyncThrowingStream` of a
typed event:

```swift
public struct BackfillEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case started, progress, complete, skipped, finished
        case other(String)   // a phase this build does not know: a newer server must not break it
                             // (the string is kept for the log)
    }
    public let phase: Phase
    public let model: String
    public let embedded: Int
    public let total: Int
    public let message: String
    public let error: String?
    /// complete | skipped | finished: the per-model outcomes backfill() collects today.
    public var isOutcome: Bool { get }
}
```

`ScanEvent` (`running` with the counts, `finished` with a `ScanSummary`) and `EnrichFactsEvent`
(`started`, `document`, `finished`) follow the same shape. The phase vocabulary is then written down
once, in the kit, with one test per string; the proto fields stay strings. (Follow-on: enums in
`garage.proto` would make the contract exact on both sides.)

Cancelling the consuming task cancels the call, as now: grpc-swift reports CANCELLED and the stream
finishes with `CancellationError`, so the server stops at its next progress step.

### Models

The item files already in the app are the start. `SearchResultItem`, `DocumentListItem`,
`DocumentChunkItem`, `DocumentAuthorItem`, `DocumentFactItem`, `DocumentDetailItem`, `FactListItem`,
`FactAttribute`, `FactClassCount` and `FactListPage` are `public` structs with proto initializers
(`Services/SearchResultItem.swift`, `DocumentListItem.swift`, `FactListItem.swift`). They move as
they are. Their `init(hit:)`, `init(summary:)`, `init(response:)` become `internal` initializers in
`Mapping/`, and each gets a public memberwise initializer so the app's tests and the mock can make
one without a proto (`SearchResultItem` has one; the others need it). `FactPromptItem` (the record)
moves too; `FactPromptConfig` and `FactPromptConfigError` (the editor's JSON round trip and
validation of what the user types) stay in the app.

New value types, each a plain mapping of one proto message: `SourceSpec` (from
`Services/SourcePresets.swift`, same fields), `SourceRecord` (`Garage_SourceInfo`), `ModelRecord`
(`Garage_ModelInfo`), `CorpusStatistics` (`Garage_StatsResponse`), `ServiceStatus`,
`ServiceVersion`, `SettingValue`, `SettingChange`, `SchemaOutcome`, `SyncOutcome` (with its
undeclared sources), `ReconcileOutcome`, `McpInstallOutcome` (with per-target outcomes),
`McpRegistrationStatus` (`Garage_McpStatusResponse` and its clients), and `OperationOutcome`
(the `success` + `message` pair most operation responses are). `Int32`/`Int64` become `Int` in
the mapping, once. The `summary` display text moves from the proto extensions onto these types.

### What stays in the app

- **`GarageGRPCService` keeps the lifecycle** and is renamed `GarageBackendService` in the last
  step (15 files name it): `status`, `start`/`stop`/`terminateImmediately`, `waitUntilReady`,
  `refreshStatus`, the port retry, the environment it builds (`GARAGE_DATABASE_URL`, the token,
  `GARAGE_LMSTUDIO_API_TOKEN`, `GARAGE_MCP_EXECUTABLE`, `GARAGE_MODEL_MANIFEST`, the models
  directory), `helperConfiguration`, and the log polling into `LogLine`s. It owns
  `let endpoint: GarageEndpoint`, `let token: GarageServiceToken` and `let client: GarageClient`,
  and exposes `var api: any GarageServing`. Its readiness probe becomes `client.ping()` with a
  connection reset on failure. The Status page's `testServiceQuery` diagnostic stays here, written
  over `api`.
- **`GarageGRPCError` keeps the lifecycle cases** `databaseNotOnline`, `startupTimeout` and
  `launchFailed`. `cliNotFound` and `serverNotRunning` are thrown nowhere and go; `searchFailed`
  and `rpcFailed` are replaced by `GarageClientError`. `OperationRunner` shows
  `localizedDescription` and needs no change.
- **The auto-start leaves the API path.** The `if status != .running { try await start() }` in
  every method becomes one `ensureRunning()` on the backend service, called by
  `AppState.runOperation` and the four read paths (`search`, `listDocuments`, `getDocument`,
  `listFacts`). The kit never starts a server.
- `OperationRunner`, `LogLine`, and the progress values `ScanProgress`, `BackfillProgress` and
  `EnrichFactsProgress` stay; `AppState` builds them from the kit's events.
- `IngestService` takes the token from the backend service (an initializer parameter) instead of
  the `GarageGRPCAuth.token` global.
- `GarageMCPService.grpc` becomes `var api: (any MCPRegistering)?`; `McpInstallScope` is the kit's.
- `ModelsView+AddModel` throws a local `ValidationError: LocalizedError` for a bad dimensions
  field instead of `GarageGRPCError.rpcFailed`.

### Threading

`GarageClient` is `Sendable` and not `@MainActor`; a call runs where it is awaited. `AppState` is
`@MainActor`, so its `for try await event in api.backfill(model:)` loop runs on the main actor and
sets `backfillProgress` directly, as the callbacks do today, without the `@MainActor` closure
parameter the `call` helper in `GarageGRPCService+Operations.swift` needs now.

## Steps

Each step leaves `aspect build //:macapp` and `aspect test //macapp/...` green.

1. **Kit skeleton, no callers.** `GarageEndpoint`, `GarageServiceToken`, `GarageConnection`,
   `GarageClientError`, the protocols, the models (the five item files move), and `GarageClient`
   with every RPC the app uses today. `GarageKitTests` with the mapping, error and endpoint tests.
   Add `//macapp/Sources/GarageKit` to `GarageApp_lib`'s deps. The item files' move changes the
   app's imports only.
2. **The backend service holds a client.** `GarageGRPCService` makes `GarageClient(endpoint:
   token:)`, exposes `api`, and its readiness probe uses `client.ping()`. `getOrCreateChannel`,
   `cleanupChannel` and `pingOverChannel` go; the old API methods stay for now.
3. **Move callers page by page**, deleting each old method from `GarageGRPCService+Operations` and
   `+Facts` as its last caller moves:
   - reads: `AppState.search`, `listDocuments`, `getDocument` and `AppState+Facts.listFacts`
     return the kit's models straight from `api`;
   - operations: `runOperation`'s closure type becomes `(any GarageServing)`, then `SourcesView`,
     `ModelsView`, `ModelsView+AddModel`, `FirstRunCoordinator`, `GarageMCPService`,
     `AppState.setInferenceModel`/`setFactsModel`/`fetchFactPrompts`/`saveFactPrompts`;
   - streams: `AppState.scan`, `runBackfill`, `runEnrichFacts` on the event streams.
   Unit tests move with each group.
4. **Remove the old surface.** Delete `GarageGRPCService+Operations.swift`,
   `GarageGRPCService+Facts.swift`, the proto `summary` extensions and `GarageGRPCAuth`. Drop
   `//proto:garage_proto_swift` from `GarageApp_lib`; `grep -rl proto_garage_proto_swift
   macapp/Sources/GarageApp` must print nothing. Add the import-boundary test.
5. **Rename and tidy.** `GarageGRPCService` → `GarageBackendService`, `GarageGRPCError` →
   `GarageBackendError`, `GarageGRPCStatus` → `GarageBackendStatus`; `ensureRunning()` replaces
   the per-method auto-start; the token moves onto the service. (Status page identifiers such as
   `status.service.grpc.test` and the "Index Manager" label are UI contract with the UI tests and
   do not change.)
6. **Test double and injection.** `MockGarageService` in `macapp/Tests/GarageKitTestSupport`
   (testonly, like `LlamaTestSupport`), `AppState(api:)` injection, `StatusViewTests` and
   `AppStateTests` rewritten on the mock, and the in-process server round-trip tests.
7. **Docs.** CLAUDE.md's macOS app section (the module list; the `OperationRunner` bullet names
   `GarageGRPCService+Operations.swift`), `macapp/README.md` "App architecture" (the
   `GarageGRPCService` bullet and a `GarageKit` one), and the `xcodeproj` target list.

## Tests

- **`macapp/Tests/GarageKitTests`** (`macos_unit_test`). The kit links neither PythonKit nor the C
  embedding shim, only `PythonXPCService_protocol`, so unlike `LlamaClientTests` it should need no
  `Python.framework` link line; verify that when writing the BUILD file.
  - Mapping per family: the moved `testSearchResultItemModel`,
    `testSearchResultItemDisplayTitleFallbacks` and `FactListItemTests`, plus one test per new
    model.
  - `GRPCStatus` → `GarageClientError` for every code the server emits.
  - Phase strings → event enums, including an unknown phase → `.other`.
  - `GarageEndpoint.appDefault()` names `s/grpc` (today's `testAddressNamesTheSocketWhenThereIsOne`)
    and `helperConfiguration` (today's `testHelperConfigurationNamesWhereTheServerListens`).
  - Round trips through a real channel: a grpc-swift `Server` bound to a Unix socket in a short
    temporary directory (`sun_path` is 104 bytes; `GarageSocketsAndPeersTests` has the pattern),
    serving a `Garage_GarageServiceAsyncProvider` that records the request and metadata it saw and
    answers canned protos. One test per RPC family asserts the request proto the fake received and
    the model that came back; one asserts a missing token arrives as `.unauthenticated`; one
    cancels a `backfill` stream midway and asserts the server side saw the cancellation.
- **`GarageAppUnitTests`.** `GarageGRPCServiceTests` keeps the lifecycle tests
  (`testStartRefusedWhenDatabaseOffline`, status equality, error text) and loses the mapping ones.
  `StatusViewTests.testServiceQuery` and `AppStateTests` run against `MockGarageService`.
- **UI tests** are unchanged: they drive the real app and probe the socket.
- **Boundary test.** A `py_test` beside `garage_python/tests/test_appcast.py` (which already reads
  under `macapp/`) asserting that no file under `macapp/Sources/GarageApp` imports
  `proto_garage_proto_swift` or `GRPC`, and that inside the kit only `GarageClient*.swift` and
  `Mapping/` do. The same idea as `test_egress_block.py`'s AST scan, for the Swift side.

## Build and CI

- `aspect gazelle` does not manage Swift targets; the two new BUILD files are hand-written after
  `IngestClient/BUILD.bazel` and `LlamaClientTests/BUILD.bazel`.
- `aspect run //:xcodeproj` picks the kit up through `GarageApp_lib`'s deps; add
  `//macapp/Tests/GarageKitTests` to `top_level_targets` in `macapp/BUILD.bazel` so it has a
  scheme.
- `.github/workflows/macos.yaml` runs on pull requests that touch `macapp/**` or `proto/**`, so
  every step gets the full build and the unit tests. The Linux `swiftcheck` job runs
  `tools/swiftcheck/check.sh`; run it after every edit made without a Mac.
- `aspect lint //...` (the macOS `lint` job) covers the new targets with no extra setup.

## Out of scope, worth noting

- **The pages read the registry around the API.** `AppState.fetchRegisteredModels`,
  `fetchRegisteredSources` and `fetchCorpusStats` run `psql` through `PostgresService`, and
  `GarageConfigLoader` reads `garage.json`, although `ListModels`, `ListSources` and `GetStats`
  exist and the kit wraps them from step 1. Moving those three onto `api` is the natural next
  change: the pages would then work against any `GarageServing`, and page loads would stop
  spawning `psql`. It is not in this plan because `fetchRegisteredSources` merges config and
  database sources (`origin: .both`) in a way the server does not report yet.
- **The facade RPCs** (`BeginIngestSession` through `UpdateEmbeddings`) are called by the Python
  ingest and embed workers, not by the app. The kit does not wrap them until a Swift caller exists.
- **grpc-swift 2.** rules_swift's `swift_client_proto` compiler generates the v1 client (`GRPC`,
  `NIO`). The kit confines v1 to `GarageConnection` and `GarageClient*`, so a later move to
  `GRPCCore` touches the kit only. Not now.
- **Launchers over the kit.** `garage` and `garage-mcp` decide whether the server is up by the
  socket's presence and start the app otherwise; a `ping()` through the kit would be exact, but
  pulls grpc-swift into the helper bundles. Later.
- **Phase enums in the proto.** See Streaming.

## Risks and open questions

- **No Swift compiler in a web session.** The plan is written against the sources; each step
  needs a Mac or the macOS CI job to validate. Expect `public` ceremony (explicit initializers,
  `Sendable` conformances) to be most of the diff.
- **`@testable import GarageApp`** reaches into `GarageGRPCService` today (`testServiceQuery`,
  `terminateImmediately`). Those tests keep working through step 4 and move to the mock in step 6.
  `GarageKitTests` uses `@testable import GarageKit` for the internal mapping initializers, as the
  app's tests do for the app.
- **`McpInstallScope` and `SourceSpec`** are named by `GarageMCPService`, `FirstRunCoordinator`
  and the source presets; moving them is a rename, but one that touches several files in step 3.
- **Names.** `GarageServing` or `GarageAPI`; `GarageBackendService` or keeping `GarageGRPCService`
  for the lifecycle object. Decide before step 5; this plan uses the former in both cases.
