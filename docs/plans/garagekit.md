---
layout: default
title: GarageKit — the app's service layer, apart from the UI
description: Moving the gRPC client, the backend lifecycle and the corpus state into a UI-free GarageKit.
---

# GarageKit: the app's service layer, apart from the UI

Written from `main` on 2026-10-04. Nothing here is built yet; file and line references are to the
tree at that date.

The rule the plan builds toward: **GarageKit is everything about the Garage service and the corpus
state that needs neither SwiftUI nor AppKit.** It owns the client of `GarageService`, the lifecycle
of the backend that serves it, and the observable state the pages show. The app keeps the views,
their presentation values, and the platform glue that needs AppKit, the Keychain, StoreKit or
Sparkle.

## Why

`GarageGRPCService` (`macapp/Sources/GarageApp/Services/GarageGRPCService.swift`, with
`GarageGRPCService+Operations.swift` and `GarageGRPCService+Facts.swift`) is the app's whole
relationship with the Python `GarageService`. It starts the server through `GarageXPCService`, it
owns the grpc-swift channel, and it exposes about thirty RPCs. `AppState` (1,930 lines) holds the
state those RPCs produce, the pipeline that runs them, and the app's platform glue, in one
`@MainActor ObservableObject`. The consequences:

- **Views are typed against concrete classes.** `SourcesView.run`, `ModelsView.run` and
  `AppState.runOperation` take `(GarageGRPCService) async throws -> String` closures.
  `GarageMCPService` holds `weak var grpc: GarageGRPCService?` and names
  `GarageGRPCService.McpInstallScope`. `FirstRunCoordinator` and `BugReportDiagnostics` read
  `appState.grpc.status`.
- **Proto messages reach the UI layer.** Every method returns a `Garage_*` message.
  `AppState.scanSources`, `runBackfill` and `runEnrichFacts` compare `status.phase` against
  `"started"`, `"progress"`, `"document"`, `"complete"`, `"skipped"` and `"finished"`.
  `SearchResultItem`, `DocumentListItem`, `FactListItem` and `FactPromptItem` each carry an `init`
  from a proto. Display text for operations is written as `summary` extensions on
  `Garage_StatsResponse`, `Garage_ListModelsResponse`, `Garage_McpStatusResponse` and
  `Garage_SetSettingResponse`. `GarageApp_lib` depends on `//proto:garage_proto_swift` directly.
- **Nothing can be faked.** The only way to exercise code that calls the backend is a real
  `GarageGRPCService` over a `PostgresService`. `StatusViewTests` runs `testServiceQuery()` against
  nothing and asserts on the failure text; `AppStateTests` throws `GarageGRPCError.rpcFailed` from
  inside an operation closure as its stand-in for a server error; `AppState` carries
  `setRegisteredSourcesForTesting`, `setRegisteredModelsForTesting`, `setCorpusStatsForTesting`,
  `setIngestingForTesting`, `setScanningForTesting`, `setQueuesForTesting` and
  `setIngestingAllForTesting` so view tests can put it in a state. `ModelsView+AddModel` throws
  `GarageGRPCError.rpcFailed` for a form validation error, because that is the one error type the
  runner displays.
- **Lifecycle, API and state are one object, in the UI module.** `search()`, `listDocuments()`,
  `listFacts()` and every operation begin with `if status != .running { try await start() }`, so a
  read can launch the server. The server's start needs `PostgresService`, `Paths`,
  `LMStudioTokenStore`, `GarageAppGroup`, `LogLine` and `GarageXPCClient`. The state the pages
  show (`registeredSources`, `registeredModels`, `corpusStats`, the three progress values, the
  queues, `lastCommandOutput`) is `@Published` on `AppState`, which also imports AppKit and
  SwiftUI for panels, the clipboard and `NSWorkspace`.
- **The pages read the registry around the API.** `AppState.fetchRegisteredModels`,
  `fetchRegisteredSources` and `fetchCorpusStats` run `psql` through `PostgresService`, and
  `GarageConfigLoader` reads `garage.json`, although `ListModels`, `ListSources` and `GetStats`
  exist.

A `GarageKit` module gives the views (and later the launchers, the UI tests' readiness probe, or an
extension) one typed, observable, UI-free service layer, and gives the service layer tests that
need no Postgres, no XPC and no Python.

## Three ways to cut it

### A. Move the classes as they are

Lift `GarageGRPCService`, `GarageGRPCAuth`, the item structs and the service half of `AppState`
into a new module and mark them `public`.

- For: smallest diff; call sites unchanged.
- Against: the module would import `PostgresService`, `Paths`, `LMStudioTokenStore` and the
  AppKit-using services, so it would be the app under another name. The UI would still see protos,
  the state would still be set through `setXForTesting`, and nothing could be faked.

### B. Three layers in the kit: client, backend lifecycle, observable state

The kit holds the endpoint, the token, the connection and a typed client behind protocols; a
`GarageBackend` that starts, probes, stops and reports on the server; and a `GarageStore` that
holds the corpus state and runs the operations and the pipeline that change it. The app provides
what only it can (the Postgres cluster, the bundle's paths, the Keychain, folder grants) through
small protocols, and its views read the kit's observable objects.

- For: the UI compiles against value types, protocols and two observable objects; one place maps
  proto to model and gRPC status to error; the lifecycle and the store are testable with a fake
  process controller and a fake service; `AppState` shrinks to a composition root and the
  platform glue; a later grpc-swift 2 move touches the kit only.
- Against: the largest diff, in two big steps (the store); every model needs a public initializer;
  the streaming callbacks become `AsyncThrowingStream`s; three psql reads must become RPCs, which
  needs `GetStats` to grow on the Python side first.

### C. Thin kit: a connection factory and the generated client

Export `GarageEndpoint`, the token and a `makeClient() -> Garage_GarageServiceAsyncClient`, and
let the app keep using protos and keep the lifecycle and state where they are.

- For: little code.
- Against: protos and `CallOptions` stay in the views; the only fake is a real gRPC server; the
  phase-string knowledge stays scattered; lifecycle and state stay untestable.

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
- `//macapp/Sources/IngestClient` for `GarageXPCClient` (the client of the `GarageXPCService`
  helper that hosts the server), `IngestClient` and `IngestProgressUpdate`.
- `//macapp/Sources/PythonXPCService` (which `IngestClient` brings anyway) for `GarageSockets`,
  `GarageXPCConfigurationKey` and `GarageAppGroup`.

Imports allowed in the kit: Foundation, Observation, OSLog, Combine only if a consumer needs a
publisher, the three above. Never SwiftUI or AppKit. Only `Client/GarageClient*.swift` and
`Client/Mapping/*.swift` import `proto_garage_proto_swift` or `GRPC`. A test holds both lines
(see Tests).

Because `IngestClient` depends on `PythonXPCService_swift`, which links the CPython embedding
shim, the kit's test bundle links `Python.framework` the way `LlamaClientTests/BUILD.bazel` does.

```
macapp/Sources/GarageKit/
  BUILD.bazel
  Client/
    GarageEndpoint.swift            where the server listens: .unixSocket(path) | .tcp(host, port)
    GarageServiceToken.swift        the per-launch x-garage-token value and its metadata key
    GarageConnection.swift          actor owning the EventLoopGroup and ClientConnection
    GarageClientError.swift         typed errors, mapped from GRPCStatus
    GarageServing.swift             the protocols the store and the views depend on
    GarageClient.swift              the grpc-swift implementation: ping, status, corpus reads
    GarageClient+Operations.swift   sources, models, settings, schema, MCP registration
    GarageClient+Streams.swift      scan, backfill, enrichFacts as AsyncThrowingStream
    Mapping/*.swift                 internal init(proto:) and request builders, one per family
  Models/
    Search.swift                    SearchQuery, SearchResultItem
    Documents.swift                 DocumentFilter, DocumentPage, DocumentListItem,
                                    DocumentDetailItem, DocumentChunkItem, DocumentAuthorItem,
                                    DocumentFactItem
    Facts.swift                     FactFilter, FactListPage, FactListItem, FactClassCount,
                                    FactAttribute, FactPromptItem, FactPromptList,
                                    EnrichFactsRequest, EnrichFactsEvent
    Sources.swift                   SourceSpec, SourceRecord, RegisteredSource, ScanEvent,
                                    ScanSummary, SyncOutcome, ReconcileOutcome
    Models.swift                    ModelRecord, ModelRegistration, BackfillEvent
    Service.swift                   ServiceStatus, ServiceVersion, CorpusStatistics, SettingValue,
                                    SettingChange, SchemaOutcome, OperationOutcome
    MCP.swift                       McpInstallScope, McpTransport, McpInstallOutcome,
                                    McpRegistrationStatus
    LogLine.swift                   LogLine, LogLevel (from Services/ProcessRunner.swift)
  Backend/
    GarageBackend.swift             @Observable lifecycle: start, probe, stop, status, logs
    GarageBackendConfiguration.swift  Configuration, DatabaseProviding, BackendProcessControlling
    GarageBackendError.swift        databaseNotOnline, startupTimeout, launchFailed
    GarageBackend+Diagnostics.swift the Status page's "Test": five RPCs, timed, summarized
  State/
    GarageStore.swift               @Observable corpus state and the operations that change it
    GarageStore+Pipeline.swift      scan → ingest → embed → glean, queues, cancellation
    GarageStore+Maintenance.swift   the scheduled run and its three defaults
    OperationRunner.swift           from Services/OperationRunner.swift, unchanged
    IngestService.swift             from Services/IngestService.swift, with an injected database
    GarageConfigReader.swift        from Services/GarageConfigLoader.swift
```

### Observation

Both observable objects are `@Observable` (the Observation framework; the app's
`minimum_os_version` is 14.0) and `@MainActor`. Observation imports nothing from SwiftUI, and a
SwiftUI body that reads `appState.backend.status` or `appState.store.registeredSources` is
tracked property by property, however it reached the object. So `AppState` can stay an
`ObservableObject` (the entry point is `@StateObject private var appState = AppState()`) and
drops the `objectWillChange` forwarding sinks it keeps for `grpc` and the runners today. No view
listens on `appState.objectWillChange` (the `onReceive`s in the views are notification-center
publishers and refresh timers), so nothing depends on the forwarding.

For consumers without SwiftUI (the launchers, tests, a future CLI probe) the backend also exposes
`statusChanges: AsyncStream<GarageBackendStatus>`, fed where `status` is set.

### Client

#### Endpoint and token

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
    /// 32 random bytes, hex encoded. The backend makes one per launch.
    public static func random() -> GarageServiceToken
}
```

`GarageGRPCAuth` goes away: the backend owns the launch's token and hands it to the client, to
the server's environment and, through `helperConfiguration`, to the ingest and embed helpers
(`IngestService` reads `GarageGRPCAuth.token` today).

#### Connection

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

#### Errors

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

#### Protocols

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

`GarageClient: GarageServing` is the real one. The store holds `any GarageServing`; a view that
still calls the API directly asks for the slice it uses; the test double implements the typealias
once.

Timeouts are not on the protocols. `GarageClient` keeps today's per-RPC defaults (30 s for reads,
120 s for operations, 30 min for `removeSource`, 10 min for `scan` and `reconcile`, none for
streams) in a `GarageClient.Timeouts` value its initializer takes, so a test can shorten them.

Requests with many fields are structs with defaults (`SearchQuery` replaces the nine-parameter
`search`, `ModelRegistration` the seven-parameter `registerModel`), the shape the Python
`GarageClient` in `service/client.py` already has.

#### Streaming

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

#### Models

The item files already in the app are the start. `SearchResultItem`, `DocumentListItem`,
`DocumentChunkItem`, `DocumentAuthorItem`, `DocumentFactItem`, `DocumentDetailItem`, `FactListItem`,
`FactAttribute`, `FactClassCount` and `FactListPage` are `public` structs with proto initializers
(`Services/SearchResultItem.swift`, `DocumentListItem.swift`, `FactListItem.swift`). They move as
they are (`SearchResultItem` loses an unused `import SwiftUI`). Their `init(hit:)`,
`init(summary:)`, `init(response:)` become `internal` initializers in `Mapping/`, and each gets a
public memberwise initializer so the app's tests and the mock can make one without a proto
(`SearchResultItem` has one; the others need it). `FactPromptItem` (the record) moves too;
`FactPromptConfig` and `FactPromptConfigError` (the editor's JSON round trip and validation of
what the user types) stay in the app.

`RegisteredModel` and `CorpusStats` (`Services/PostgresService.swift`) and `RegisteredSource`
(`Services/GarageConfigLoader.swift`) are the shapes the pages show today, filled from `psql`.
`RegisteredModel` is `Garage_ModelInfo` field for field and becomes `ModelRecord`.
`RegisteredSource` is `Garage_SourceInfo` plus two config-only fields (`includeCode`, `origin`)
and moves as it is, filled by the store's merge (below). `CorpusStats` carries more than
`Garage_StatsResponse` does: documents by state, embedded chunks, per-model embedding counts,
files seen and indexed, expected elements and fact counts. `CorpusStatistics` takes its shape,
and `GetStats` grows to fill it (step 4).

New value types, each a plain mapping of one proto message: `SourceSpec` (from
`Services/SourcePresets.swift`, same fields), `SourceRecord`, `ServiceStatus`, `ServiceVersion`,
`SettingValue`, `SettingChange`, `SchemaOutcome`, `SyncOutcome` (with its undeclared sources),
`ReconcileOutcome`, `McpInstallOutcome` (with per-target outcomes), `McpRegistrationStatus`, and
`OperationOutcome` (the `success` + `message` pair most operation responses are). `Int32`/`Int64`
become `Int` in the mapping, once. The `summary` display text moves from the proto extensions
onto these types.

### Backend

`GarageBackend` is `GarageGRPCService` minus the API methods and the app types, made observable:

```swift
@Observable @MainActor
public final class GarageBackend {
    public struct Configuration: Sendable {
        public var endpoint: GarageEndpoint              // .appDefault() in the app
        public var workingDirectory: URL                 // GARAGE_WORKING_DIRECTORY
        public var mcpExecutable: URL?                   // GARAGE_MCP_EXECUTABLE, when bundled
        public var modelManifest: URL?                   // GARAGE_MODEL_MANIFEST
        public var modelsDirectory: URL?                 // a --data-directory launch's models folder
        public var lmStudioToken: @Sendable () async throws -> String?   // GARAGE_LMSTUDIO_API_TOKEN
    }

    public private(set) var status: GarageBackendStatus  // stopped | starting | running | stopping | failed(String)
    public private(set) var logs: [LogLine]              // the helper's stdout/stderr, polled as today
    public let endpoint: GarageEndpoint
    public let token: GarageServiceToken                 // one per launch
    public let client: GarageClient
    public var api: any GarageServing { client }
    public var statusChanges: AsyncStream<GarageBackendStatus>

    public init(configuration: Configuration,
                database: any DatabaseProviding,
                process: any BackendProcessControlling = GarageXPCClient())

    public func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws
    public func ensureRunning() async throws            // the auto-start every API method does today
    public func stop() async
    public func terminateImmediately()
    public func refreshStatus() async
    public func helperConfiguration() throws -> [String: String]
    public func diagnostics() async -> BackendDiagnostics   // today's testServiceQuery
}

/// What the backend needs from the database: PostgresService conforms in the app.
public protocol DatabaseProviding: Sendable {
    @MainActor var isRunning: Bool { get }
    func connectionURL() throws -> String
}

/// The helper that hosts the server. GarageXPCClient conforms by an extension in the kit (its
/// startServer, stopServer, isServerRunning, fetchBufferedOutput and clearLogs already have these
/// shapes); a fake conforms in the tests.
public protocol BackendProcessControlling: Sendable {
    func startServer(host: String, port: Int, options: [String: String]) async throws -> (success: Bool, message: String?)
    func stopServer() async throws -> (success: Bool, message: String?)
    func isServerRunning() async throws -> Bool
    func fetchBufferedOutput(clearBuffer: Bool) async throws -> (stdout: String?, stderr: String?)
    func clearLogs() async throws -> Bool
}
```

What moves in unchanged: the readiness loop (`waitUntilReady`, XPC verdict first, then a ping),
the retry on another port when the endpoint is TCP, the log polling, `refreshStatus`, the
environment the server is started with (`GARAGE_DATABASE_URL` from `database.connectionURL()`,
the token as `GARAGE_GRPC_TOKEN`, and the configuration's paths and LM Studio token), and
`helperConfiguration` (environment plus `endpoint.helperConfiguration`). `GarageBackendError` keeps
`databaseNotOnline`, `startupTimeout` and `launchFailed`; `cliNotFound` and `serverNotRunning` are
thrown nowhere and go; `searchFailed` and `rpcFailed` are replaced by `GarageClientError`.

The app supplies the configuration from `Paths`, `GarageAppGroup.dataDirectoryOverride` and
`LMStudioTokenStore`, and `PostgresService` as the database. `AppState.startBackend` becomes
`try await backend.start()` followed by
`xpcServices.configureHelpers(backend.helperConfiguration())`.

The kit never starts Postgres. The cluster (`PostgresService`: initdb, start and stop, the Keychain
password, backups, migrations) stays in the app behind `DatabaseProviding`.

### Store

`GarageStore` is the service half of `AppState`: the state the pages show and the operations and
pipeline that change it.

```swift
@Observable @MainActor
public final class GarageStore {
    public init(backend: GarageBackend,
                ingest: IngestService,
                config: GarageConfigReader = GarageConfigReader(),
                defaults: UserDefaults = .standard,
                factsModelResidency: any FactsModelResidency = NoFactsModelResidency())

    // Corpus state, filled over the API (today: psql and garage.json).
    public private(set) var registeredSources: [RegisteredSource]
    public private(set) var registeredModels: [ModelRecord]
    public private(set) var corpusStats: CorpusStatistics
    public private(set) var factsModel: String, factsProvider: String
    public private(set) var inferenceModel: String?, inferenceProvider: String?
    public private(set) var factPrompts: [FactPromptItem], factPromptsConfiguredJSON: String, factPromptsError: String?
    public private(set) var isFetchingSources, isFetchingModels, isFetchingStats: Bool

    // The last operation and the long jobs.
    public private(set) var lastCommandOutput: String, lastCommandSucceeded: Bool?, commandInProgress: Bool
    public let garage, scanner, backfill, enrichFacts: OperationRunner
    public private(set) var scanProgress: ScanProgress?, backfillProgress: BackfillProgress?, enrichFactsProgress: EnrichFactsProgress?

    // The pipeline (GarageStore+Pipeline.swift).
    public private(set) var ingestQueue: [String], sourcesAwaitingScan: [String], scanningSlugs: Set<String>
    public private(set) var isIngestingAll, isCancellingAll, isUpdatingEverything: Bool
    public private(set) var sourcesBeingRemoved: Set<String>, lastIngestAllFailure: String?

    // Maintenance (GarageStore+Maintenance.swift), persisted in `defaults` under today's keys.
    public var scheduledMaintenanceEnabled: Bool, scheduledMaintenanceInterval: TimeInterval, maintenanceRunsAtLaunch: Bool

    public func fetchRegisteredSources() async
    public func fetchRegisteredModels() async
    public func fetchCorpusStats() async
    public func fetchFactsSettings(), fetchFactPrompts() async
    public func runOperation(triggersMaintenance: Bool = false,
                             _ operation: @escaping @MainActor (any GarageServing) async throws -> String) async -> Bool
    public func scanSources(source:includeCode:followedByIngest:) async -> Bool
    public func scanAndIngestSource(slug:options:) async -> Bool
    public func ingestSource(slug:options:mode:) async -> Bool
    public func ingestAllSources(options:mode:) async -> Bool
    public func runBackfill(model:) async -> Bool
    public func runEnrichFacts(source:documentID:prompts:staleOnly:) async -> Bool
    public func removeSource(slug:) async -> Bool
    public func updateEverything() async
    public func cancelAll(), cancel(source:) async, cancelScan(), cancelIngest() async
    public func isBusy(source:), isPending(source:), isQueued(source:) -> Bool
    public func search(_:) async throws -> [SearchResultItem]
    public func listDocuments(_:) async throws -> DocumentPage
    public func getDocument(id:) async throws -> DocumentDetailItem
    public func listFacts(_:) async throws -> FactListPage
    public func setInferenceModel(_:provider:), setFactsModel(_:provider:), saveFactPrompts(configuredJSON:) async -> Bool
    public func clearLogs(for:)
    public func runMaintenanceAtLaunchIfEnabled(), triggerMaintenanceIfEnabled() async, resumeMaintenanceAfterFirstRun()
}

/// The facts model's residency around a distillation run. AppState+LlamaModels conforms, loading
/// the model inside the enrich-facts runner (so a run refused as "already running" never loads)
/// and unloading it afterwards unless it is also the search model. The default does nothing.
public protocol FactsModelResidency: Sendable {
    @MainActor func prepareForDistilling(log: OperationRunner) async
    @MainActor func releaseAfterDistilling() async
}
```

The bodies are today's `AppState` methods, moved. Three change in substance:

- `fetchRegisteredModels` calls `api.models()` instead of `postgres.listRegisteredModels()`
  (`Garage_ModelInfo` already carries every column that query selects).
- `fetchRegisteredSources` keeps its merge of `garage.json` (through `GarageConfigReader`) with the
  database, but the database side comes from `api.sources()` (`Garage_SourceInfo` carries
  `document_count` and `expected_elements`) instead of `postgres.listRegisteredSources()`.
- `fetchCorpusStats` calls `api.statistics()` once `GetStats` reports what the `psql` query
  computes (step 4).

`IngestService` moves with the store. It imports only Foundation, `IngestClient` and OSLog; its
one use of `PostgresService` (a fallback database URL) becomes the backend's `DatabaseProviding`.
`VolumeAccessService` still hands it the folder-granted `IngestClient` as today.
`GarageConfigLoader` moves as `GarageConfigReader` (Foundation and `PythonXPCService` only: the
sources, facts and inference settings and the default embedding model in `garage.json`, and the
model presets in the bundled catalog); `ModelCatalog`, which refreshes that catalog from the
website, stays in the app.

### What stays in the app

- **`AppState` as the composition root and the platform glue.** It makes `PostgresService`,
  `GarageBackend` (with the configuration from `Paths`), `GarageStore`, `XPCServiceManager`,
  `VolumeAccessService`, `LlamaService`, `ModelDownloadService`, `GarageMCPService`, the updater
  and the setup assistant, and exposes `backend` and `store` to the views. It keeps `launch()` and
  `launchServices` (the data-folder migration, catalog refresh, log streams, helper streams, the
  setup assistant's hand-off), `startPostgres`/`stopPostgres`/`terminateImmediately`,
  `startBackend`, the database reset and relaunch, the migrations (`PostgresService.applyMigrations`
  runs `psql` before the backend is up, so `InitDb` cannot replace it), the LM Studio token
  (Keychain, then a backend restart), the folder and TCC prompts (`NSOpenPanel`), the clipboard
  and `NSWorkspace` actions, backups and restore, model presets, and UI-only flags
  (`autoStartPostgres`, `isResettingDatabase`, `databaseResetOutcome`, `isApplyingMigrations`).
- **`AppState+LlamaModels`** conforms to `FactsModelResidency` and keeps the default embedding
  model's preload.
- **`GarageMCPService`** keeps the HTTP server's lifecycle (through `MCPServerClient`) and
  registers clients through `backend.api` as `any MCPRegistering`. It imports no UI and could move
  later.
- **`PostgresService`** conforms to `DatabaseProviding`. It uses AppKit for the clipboard and
  `NSWorkspace`; those two methods belong in the app regardless.
- **Views** read `appState.backend.status` and `appState.store.<state>`, and call `store`
  operations. `SourcesView.run`, `ModelsView.run` and `ModelsView+AddModel` pass
  `(any GarageServing)` closures to `store.runOperation`. `ModelsView+AddModel` throws a local
  `ValidationError: LocalizedError` for a bad dimensions field instead of
  `GarageGRPCError.rpcFailed`. The Status page's identifiers (`status.service.grpc.test`) and the "Index Manager" label are
  contract with the UI tests and do not change.
- **`ProcessRunner`** (subprocesses for `PostgresService`) stays; `LogLine` and `LogLevel` leave
  it for the kit, which sixteen app files then import.

### Threading

`GarageClient` is `Sendable` and not `@MainActor`; a call runs where it is awaited. `GarageBackend`
and `GarageStore` are `@MainActor`, so the store's `for try await event in api.backfill(model:)`
loop runs on the main actor and sets `backfillProgress` directly, as the callbacks do today,
without the `@MainActor` closure parameter the `call` helper in
`GarageGRPCService+Operations.swift` needs now.

## Steps

Each step leaves `aspect build //:macapp` and `aspect test //macapp/...` green.

1. **Kit skeleton, no callers.** `Client/`, `Models/` (the five item files move; `LogLine` and
   `LogLevel` leave `ProcessRunner.swift`), `OperationRunner` moves unchanged, and `GarageClient`
   has every RPC the app uses today. `GarageKitTests` with the mapping, error and endpoint tests.
   Add `//macapp/Sources/GarageKit` to `GarageApp_lib`'s deps. The app's imports change, nothing
   else.
2. **Callers move to the typed client.** `GarageGRPCService` makes a `GarageClient(endpoint:
   token:)` and exposes `api`; its readiness probe uses `client.ping()`; `getOrCreateChannel`,
   `cleanupChannel` and `pingOverChannel` go. Then page by page, deleting each old method as its
   last caller moves: the reads (`AppState.search`, `listDocuments`, `getDocument`,
   `AppState+Facts.listFacts`), the operations (`runOperation`'s closure type becomes
   `(any GarageServing)`, then `SourcesView`, `ModelsView`, `ModelsView+AddModel`,
   `FirstRunCoordinator`, `GarageMCPService`, `AppState.setInferenceModel`/`setFactsModel`/
   `fetchFactPrompts`/`saveFactPrompts`), the streams (`scanSources`, `runBackfill`,
   `runEnrichFacts` on the event streams). Ends with `GarageGRPCService+Operations.swift`,
   `GarageGRPCService+Facts.swift`, the proto `summary` extensions and `GarageGRPCAuth` deleted,
   `//proto:garage_proto_swift` dropped from `GarageApp_lib`, and the import-boundary test added.
3. **`GarageBackend`.** The lifecycle moves into the kit as written above, behind
   `Configuration`, `DatabaseProviding` and `BackendProcessControlling`; `PostgresService`
   conforms; `AppState.grpc` becomes `backend` and loses its forwarding sink; `IngestService`
   takes the token from the backend; `GarageGRPCService.swift` is deleted. Lifecycle tests with a
   fake process controller and a fake database (below).
4. **`GetStats` grows.** The SQL in `PostgresService.fetchCorpusStats` moves into the Python
   `ops` function behind `GetStats`, `StatsResponse` gains the fields (additive), `CorpusStatistics`
   fills from them, and `test_postgres.py` judges the query against a real server. A Python and
   proto change with no Swift in it; it can land before step 3.
5. **`GarageStore`, part one: state and operations.** The corpus state, the operation runners,
   `runOperation`, the facts settings and prompts, the four reads, `removeSource`, `runBackfill`
   and `runEnrichFacts` (with `FactsModelResidency`), and `GarageConfigReader`. The three `psql`
   reads become `api.models()`, `api.sources()` and `api.statistics()`. `AppState` keeps the scan
   and ingest pipeline one more step and reads everything else from `store`. `MockGarageService`
   in `GarageKitTestSupport`, store tests on it, and the `setXForTesting` methods deleted in
   favour of state the mock produces.
6. **`GarageStore`, part two: the pipeline.** `IngestService` moves; `scanSources`, the ingest
   methods, the queues and cancellation, `updateEverything`/`runPipeline`, and the scheduled
   maintenance (with `UserDefaults` injected) follow. `AppState` is the composition root and the
   platform glue listed above.
7. **Docs and project.** CLAUDE.md's macOS app section (the module list; the `OperationRunner`
   bullet names `GarageGRPCService+Operations.swift`), `macapp/README.md` "App architecture" (the
   `GarageGRPCService` bullet becomes `GarageKit`: backend, store, client), and
   `//macapp/Tests/GarageKitTests` in the `xcodeproj` target list.

## Tests

- **`macapp/Tests/GarageKitTests`** (`macos_unit_test`, linking `Python.framework` like
  `LlamaClientTests` because `IngestClient` brings the CPython shim):
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
  - Lifecycle, with a fake `BackendProcessControlling` and a fake `DatabaseProviding`: refused
    while the database is down (today's `testStartRefusedWhenDatabaseOffline`); `starting` →
    `running` once the fake reports running and the in-process server answers a ping; `failed`
    with the helper's message when `startServer` fails; the port retry when the endpoint is TCP
    and no ping answers; `stop` and `terminateImmediately`; the environment handed to
    `startServer` (database URL, token, the configuration's paths); `statusChanges` yields each
    transition.
  - Store, with `MockGarageService` and a fake ingest: the reads fill the state; the merge of
    config and database sources; `runOperation` refuses a second operation; the progress values
    follow the event streams; `removeSource` cancels a scan that covers the source; the pipeline
    order and cancellation; the maintenance defaults round-trip through an injected
    `UserDefaults`.
- **`GarageAppUnitTests`.** `GarageGRPCServiceTests` goes with the class; `AppStateTests`,
  `StatusViewTests` and the view tests build their state through `MockGarageService` instead of
  `setXForTesting`.
- **UI tests** are unchanged: they drive the real app and probe the socket.
- **Boundary test.** A `py_test` beside `garage_python/tests/test_appcast.py` (which already reads
  under `macapp/`) asserting that no file under `macapp/Sources/GarageKit` imports SwiftUI or
  AppKit, that only `Client/GarageClient*.swift` and `Client/Mapping/` there import
  `proto_garage_proto_swift` or `GRPC`, and that no file under `macapp/Sources/GarageApp` imports
  either. The same idea as `test_egress_block.py`'s AST scan, for the Swift side.

## Build and CI

- `aspect gazelle` does not manage Swift targets; the new BUILD files are hand-written after
  `IngestClient/BUILD.bazel`, `LlamaClientTests/BUILD.bazel` and `LlamaTestSupport/BUILD.bazel`.
- `aspect run //:xcodeproj` picks the kit up through `GarageApp_lib`'s deps; add
  `//macapp/Tests/GarageKitTests` to `top_level_targets` in `macapp/BUILD.bazel` so it has a
  scheme.
- `.github/workflows/macos.yaml` runs on pull requests that touch `macapp/**` or `proto/**`, so
  every step gets the full build and the unit tests. The Linux `swiftcheck` job runs
  `tools/swiftcheck/check.sh`; run it after every edit made without a Mac. Step 4's Python and
  proto change runs in the Linux `python` job against the pgvector service container.
- `aspect lint //...` (the macOS `lint` job) covers the new targets with no extra setup.

## Out of scope, worth noting

- **More services could follow the same rule.** `GarageMCPService` (HTTP MCP server lifecycle),
  `OSLogStreamService` and `XPCServiceManager` import no UI and could move into the kit later;
  `LlamaService` needs only its `statusColor` moved to a presentation value first;
  `ModelDownloadService` needs its `NSWorkspace` and `NSPasteboard` calls split off. None of them
  is needed for the views to stop seeing the gRPC layer, so none is in this plan.
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
  `Sendable` conformances) to be much of the diff in steps 1 and 3.
- **Steps 5 and 6 are large.** They move most of a 1,930-line file. Splitting part one further
  (reads and settings first, then the runners and streams) is fine; the boundary between the two
  parts is the scan and ingest queue, which is one tangle and moves whole.
- **Observation beside Combine.** `AppState` stays an `ObservableObject` while `backend` and
  `store` are `@Observable`. Body reads are tracked either way; anything that subscribed to
  `appState.objectWillChange` for service state would stop firing. Today nothing does, and the
  boundary test can grep for new subscriptions. Views and services that use `.sink` on the kit's
  former `@Published` properties (grep `objectWillChange` and `$` bindings in step 3 and 5) are
  rewritten against `withObservationTracking` or the `AsyncStream`s.
- **`@testable import GarageApp`** reaches into `GarageGRPCService` today (`testServiceQuery`,
  `terminateImmediately`). Those tests move to the kit's lifecycle tests in step 3.
  `GarageKitTests` uses `@testable import GarageKit` for the internal mapping initializers, as the
  app's tests do for the app.
- **`McpInstallScope` and `SourceSpec`** are named by `GarageMCPService`, `FirstRunCoordinator`
  and the source presets; moving them is a rename, but one that touches several files in step 2.
- **Names.** `GarageServing` or `GarageAPI`; `GarageStore` or `GarageSession`; `GarageBackend` or
  `GarageBackendService`. Decide before step 3; this plan uses the first of each.
