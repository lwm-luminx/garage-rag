import Foundation
import Combine
import Security
import AppKit
import PythonXPCService

public struct RegisteredModel: Identifiable, Hashable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let provider: String
    public let modelRef: String
    public let dims: Int
    public let storedDims: Int
    public let storageKind: String
    public let indexKind: String
    public let tableName: String
    public let isDefault: Bool
    public let modelId: String?
    /// `text` or `image`: which chunks the model embeds.
    public let modality: String

    public init(
        slug: String,
        provider: String,
        modelRef: String,
        dims: Int,
        storedDims: Int,
        storageKind: String,
        indexKind: String,
        tableName: String,
        isDefault: Bool,
        modelId: String? = nil,
        modality: String = "text"
    ) {
        self.slug = slug
        self.provider = provider
        self.modelRef = modelRef
        self.dims = dims
        self.storedDims = storedDims
        self.storageKind = storageKind
        self.indexKind = indexKind
        self.tableName = tableName
        self.isDefault = isDefault
        self.modelId = modelId
        self.modality = modality
    }
}

public struct CorpusStats: Equatable, Sendable {
    public var sourcesCount: Int
    public var documentsCount: Int
    public var documentsOkCount: Int
    public var documentsFailedCount: Int
    public var totalChunks: Int
    public var embeddedChunks: Int
    public var totalSeenFiles: Int
    public var totalIndexedFiles: Int
    public var totalExpectedElements: Int
    public var modelStats: [ModelEmbeddingStats]
    /// Documents per source slug, carried here because the same stats query
    /// already has to visit `documents` — see `PostgresService.fetchCorpusStats`.
    public var sourceDocumentCounts: [String: Int]
    /// Facts distilled so far, and the documents a current fact run covers (one whose
    /// `content_sha256` still matches the document's). Zero on a database without `fact_runs`.
    public var factsCount: Int
    public var documentsDistilledCount: Int
    public var lastUpdated: Date?

    public init(
        sourcesCount: Int = 0,
        documentsCount: Int = 0,
        documentsOkCount: Int = 0,
        documentsFailedCount: Int = 0,
        totalChunks: Int = 0,
        embeddedChunks: Int = 0,
        totalSeenFiles: Int = 0,
        totalIndexedFiles: Int = 0,
        totalExpectedElements: Int = 0,
        modelStats: [ModelEmbeddingStats] = [],
        sourceDocumentCounts: [String: Int] = [:],
        factsCount: Int = 0,
        documentsDistilledCount: Int = 0,
        lastUpdated: Date? = nil
    ) {
        self.sourcesCount = sourcesCount
        self.documentsCount = documentsCount
        self.documentsOkCount = documentsOkCount
        self.documentsFailedCount = documentsFailedCount
        self.totalChunks = totalChunks
        self.embeddedChunks = embeddedChunks
        self.totalSeenFiles = totalSeenFiles
        self.totalIndexedFiles = totalIndexedFiles
        self.totalExpectedElements = totalExpectedElements
        self.modelStats = modelStats
        self.sourceDocumentCounts = sourceDocumentCounts
        self.factsCount = factsCount
        self.documentsDistilledCount = documentsDistilledCount
        self.lastUpdated = lastUpdated
    }

    public struct ModelEmbeddingStats: Identifiable, Hashable, Sendable {
        public var id: String { slug }
        public let slug: String
        public let tableName: String
        public let isDefault: Bool
        public let embeddedCount: Int

        public init(slug: String, tableName: String, isDefault: Bool, embeddedCount: Int) {
            self.slug = slug
            self.tableName = tableName
            self.isDefault = isDefault
            self.embeddedCount = embeddedCount
        }
    }

    public var uningestedElements: Int {
        if totalExpectedElements > 0 {
            return max(0, totalExpectedElements - documentsCount)
        }
        if totalSeenFiles > 0 {
            return max(0, totalSeenFiles - totalIndexedFiles)
        }
        return 0
    }

    public var totalEmbeddedAcrossAllModels: Int {
        modelStats.reduce(0) { $0 + $1.embeddedCount }
    }

    public var totalRequiredEmbeddingsAcrossAllModels: Int {
        modelStats.count * totalChunks
    }

    public var unembeddedChunks: Int {
        if modelStats.isEmpty {
            return totalChunks
        }
        return modelStats.reduce(0) { $0 + max(0, totalChunks - $1.embeddedCount) }
    }

    public var ingestionProgressFraction: Double {
        if totalExpectedElements > 0 {
            return min(1.0, max(0.0, Double(documentsCount) / Double(totalExpectedElements)))
        }
        if totalSeenFiles > 0 {
            return min(1.0, max(0.0, Double(totalIndexedFiles) / Double(totalSeenFiles)))
        }
        if documentsCount > 0 {
            return 1.0
        }
        return 0.0
    }

    public var embeddingProgressFraction: Double {
        let totalRequired = totalRequiredEmbeddingsAcrossAllModels
        guard totalRequired > 0 else {
            if totalChunks > 0 && embeddedChunks > 0 {
                return min(1.0, max(0.0, Double(embeddedChunks) / Double(totalChunks)))
            }
            return 0.0
        }
        return min(1.0, max(0.0, Double(totalEmbeddedAcrossAllModels) / Double(totalRequired)))
    }
}

/// Dedicated queue for the blocking Postgres client tools. Serial on purpose:
/// the cluster runs with max_connections=5, so there is nothing to win by
/// overlapping these, and serializing keeps a backup from racing a stats refresh.
private let postgresCLIQueue = DispatchQueue(
    label: "me.rickmark.garage-rag.postgres-cli",
    qos: .userInitiated
)

/// psql and the rest of the Postgres CLIs block their calling thread for the
/// whole invocation, and `PostgresService` is `@MainActor` — running them inline
/// froze the UI for the length of every query. Each invocation goes through this
/// Sendable value instead, which hops to `postgresCLIQueue` rather than the
/// cooperative pool (which must never be blocked). Callers `await` it, so the
/// main actor is free while the tool runs.
struct PostgresCommandRunner: Sendable {
    let port: Int
    /// The server's socket folder, or nil when it listens on loopback TCP (`GaragePostgresEndpoint.socketDirectory`).
    let socketDirectory: String?
    let databaseName: String
    let user: String
    let environment: [String: String]

    /// Runs a bundled Postgres tool to completion off the caller's actor.
    /// Static because initdb and pg_isready run before there is a database to
    /// connect to.
    static func run(
        tool: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async -> (status: Int32, output: String) {
        let executable = Paths.postgresTool(tool)
        return await withCheckedContinuation { continuation in
            postgresCLIQueue.async {
                continuation.resume(returning: ProcessRunner.runSync(
                    executable: executable,
                    arguments: arguments,
                    environment: environment
                ))
            }
        }
    }

    /// Host/port/user flags every client tool in this cluster needs.
    var connectionArguments: [String] {
        GaragePostgresEndpoint.clientArguments(socketDirectory: socketDirectory) + ["-U", user]
    }

    func run(_ tool: String, arguments: [String]) async -> (status: Int32, output: String) {
        await Self.run(tool: tool, arguments: connectionArguments + arguments, environment: environment)
    }

    /// Runs `psql` against the app's own database.
    func psql(_ arguments: [String]) async -> (status: Int32, output: String) {
        await run("psql", arguments: ["-d", databaseName] + arguments)
    }

    /// Runs one statement and returns its rows split on the tab field separator
    /// `-tAF` installs (tuples only, unaligned, no header). Trailing empty
    /// fields are trimmed away with the newline, so rows can be shorter than the
    /// select list — check `count` before indexing.
    func query(
        _ sql: String,
        failureMessage: String = "psql query failed"
    ) async throws -> [[String]] {
        let (status, output) = await psql(["-tAF\t", "-c", sql])
        guard status == 0 else {
            throw PostgresError.other("\(failureMessage): \(output)")
        }
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.components(separatedBy: "\t")
        }
    }

    /// Runs one statement expected to yield a single value.
    func scalar(
        _ sql: String,
        failureMessage: String = "psql query failed"
    ) async throws -> String {
        let (status, output) = await psql(["-tAc", sql])
        guard status == 0 else {
            throw PostgresError.other("\(failureMessage): \(output)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The running server as the Database page describes it. Built from `fetchServerDetails`' rows:
/// one `server` row (version, database size in bytes) and one `extension` row per extension.
struct DatabaseServerDetails: Equatable, Sendable {
    struct Extension: Equatable, Sendable {
        let name: String
        let version: String
    }

    var serverVersion: String = ""
    var databaseSizeBytes: Int64?
    var extensions: [Extension] = []

    init(serverVersion: String = "", databaseSizeBytes: Int64? = nil, extensions: [Extension] = []) {
        self.serverVersion = serverVersion
        self.databaseSizeBytes = databaseSizeBytes
        self.extensions = extensions
    }

    init(rows: [[String]]) {
        for row in rows {
            switch row.first ?? "" {
            case "server":
                if row.count > 1 { serverVersion = row[1] }
                if row.count > 2 { databaseSizeBytes = Int64(row[2]) }
            case "extension" where row.count > 1:
                extensions.append(Extension(name: row[1], version: row.count > 2 ? row[2] : ""))
            default:
                continue
            }
        }
        extensions.sort { $0.name < $1.name }
    }
}

enum PostgresStatus: Equatable {
    case stopped
    case starting
    case needsMigration
    case running
    case stopping
    case failed(String)
}

/// Owns the lifecycle of a private Postgres cluster dedicated to this app:
/// its own data directory, its own port, its own database. Never touches any
/// system-wide Postgres install (brew services, /var/lib/postgresql, etc).
@MainActor
final class PostgresService: ObservableObject {
    @Published private(set) var status: PostgresStatus = .stopped
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var pendingMigrations: [String] = []

    /// Fixed, non-default port so this never collides with a system Postgres on 5432.
    let port = GaragePostgresEndpoint.port
    let databaseName = GaragePostgresEndpoint.databaseName

    private let runner = ProcessRunner()
    private let maxLogLines = 2000
    private var cachedPassword: String?

    /// Where the server puts its socket, fixed for the life of the app (it follows `--data-directory`).
    /// Nil when the socket's path would be too long, and the server listens on loopback TCP instead.
    let socketDirectory: String? = GaragePostgresEndpoint.socketDirectory

    func connectionURL() throws -> String {
        try GaragePostgresEndpoint.connectionURL(password: postgresPassword(), socketDirectory: socketDirectory)
    }

    func standardConnectionURLString() throws -> String {
        try GaragePostgresEndpoint.connectionURL(
            password: postgresPassword(),
            scheme: "postgresql",
            socketDirectory: socketDirectory
        )
    }

    func standardConnectionURL() throws -> URL {
        let urlString = try standardConnectionURLString()
        guard let url = URL(string: urlString) else {
            throw PostgresError.other("could not create standard PostgreSQL connection URL: \(urlString)")
        }
        return url
    }

    @discardableResult
    func copyStandardConnectionURLToClipboard() throws -> String {
        let urlString = try standardConnectionURLString()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        return urlString
    }

    @discardableResult
    func openInRegisteredHandler() throws -> Bool {
        let url = try standardConnectionURL()
        return NSWorkspace.shared.open(url)
    }

    /// A Sendable snapshot of the connection parameters, built on the main
    /// actor (where the Keychain-backed password lives) and used off it.
    private func commandRunner() throws -> PostgresCommandRunner {
        PostgresCommandRunner(
            port: port,
            socketDirectory: socketDirectory,
            databaseName: databaseName,
            user: NSUserName(),
            environment: runtimeEnvironment(password: try postgresPassword())
        )
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private var isInitialized: Bool {
        FileManager.default.fileExists(atPath: Paths.pgDataDir.appendingPathComponent("PG_VERSION").path)
    }

    /// Runs initdb into Paths.pgDataDir if it hasn't been created yet.
    func ensureInitialized() async throws {
        guard !isInitialized else { return }
        // The corpus is still in the pre-App-Group folder (GarageDataMigration could not move it,
        // usually because a postgres was still running from it). A new, empty cluster here would
        // hide it, so refuse and let the next launch finish the move.
        if !isRunningInTestEnvironment, GarageAppGroup.dataDirectoryOverride == nil,
           GarageDataMigration.hasUnmigratedCluster() {
            throw PostgresError.other(
                "The database is still in \(GarageAppGroup.legacyDataDirectory.path) and could not be moved "
                    + "into the shared folder \(Paths.appSupportDir.path). Quit every copy of Garage, "
                    + "then open it again."
            )
        }
        try FileManager.default.createDirectory(at: Paths.pgDataDir, withIntermediateDirectories: true)
        let password = try await loadPassword()
        let passwordFile = Paths.appSupportDir
            .appendingPathComponent(".initdb-password-\(UUID().uuidString)")
        try Data((password + "\n").utf8).write(to: passwordFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordFile.path
        )
        defer { try? FileManager.default.removeItem(at: passwordFile) }

        var initdbArguments = [
            "-D", Paths.pgDataDir.path,
            "-U", NSUserName(),
            "-E", "UTF8",
            "--auth=scram-sha-256",
            "--pwfile=\(passwordFile.path)",
            "--no-instructions",
            "-c", "shared_memory_type=mmap",
            "-c", "dynamic_shared_memory_type=mmap",
            "-c", "shared_buffers=128kB",
            "-c", "max_connections=5"
        ]
        if FileManager.default.fileExists(atPath: Paths.postgresShareDir.path) {
            initdbArguments.append(contentsOf: ["-L", Paths.postgresShareDir.path])
        }

        let (status, output) = await PostgresCommandRunner.run(
            tool: "initdb",
            arguments: initdbArguments,
            environment: runtimeEnvironment(password: password)
        )
        for rawLine in output.split(separator: "\n") {
            appendLog(PostgresLogParser.parse(rawText: String(rawLine), stream: .stdout, source: "initdb"))
        }
        guard status == 0 else {
            throw PostgresError.initFailed(output)
        }

        let configFile = Paths.postgresConfigFile
        if FileManager.default.fileExists(atPath: configFile.path) {
            let destinationConf = Paths.pgDataDir.appendingPathComponent("postgresql.conf")
            try? FileManager.default.removeItem(at: destinationConf)
            try? FileManager.default.copyItem(at: configFile, to: destinationConf)
        }
    }

    func start() async throws {
        guard status == .stopped || isFailed else { return }
        status = .starting

        // A postgres launched by a previous run of this app (an older build,
        // or this app after a crash/force-quit that skipped
        // applicationWillTerminate) can still be alive and holding our data
        // directory's lock and port. If we skip this and it's still up,
        // pg_isready below happily reports that ghost process as ready, so
        // we silently talk to a stale postmaster -- one that may have
        // resolved its shared library paths (like pgvector's) against a
        // now-replaced app bundle -- instead of starting a fresh one from
        // the current bundle. Always clear it first; this is a no-op when
        // nothing is running.
        await Self.stopAnyRunningInstance()

        do {
            try await ensureInitialized()
            // Read the password before launching anything, so a Keychain problem shows
            // up as the reason the database is down rather than as an authentication
            // failure from the first connection.
            _ = try await loadPassword()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }

        try FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)

        // Only this account's Garage processes may connect: the socket lives in an owner-only folder
        // of the App Group container, and TCP is off. Loopback TCP is open to every account on the
        // Mac, so it is used only when the socket's path is too long to bind (`GarageSockets`).
        let listen: [String]
        if let socketDirectory {
            do {
                try GarageSockets.ensureDirectory(URL(fileURLWithPath: socketDirectory, isDirectory: true))
            } catch {
                status = .failed("could not create the database's socket folder: \(error.localizedDescription)")
                throw error
            }
            listen = [
                "-c", "listen_addresses=",
                "-c", "unix_socket_directories=\(Self.quotedSetting(socketDirectory))",
                "-c", "unix_socket_permissions=0700",
            ]
        } else {
            appendLog(LogLine(
                stream: .stderr,
                text: "The socket path in \(GarageSockets.directory.path) is too long; listening on localhost:\(port) instead",
                source: "garage"
            ))
            listen = ["-c", "listen_addresses=localhost", "-c", "unix_socket_directories="]
        }
        var postgresArguments = [
            "-D", Paths.pgDataDir.path,
            "-p", String(port),
            "-c", "logging_collector=off",
            "-c", "log_line_prefix=%m [%p] ",
            "-c", "shared_memory_type=mmap",
            "-c", "dynamic_shared_memory_type=mmap",
        ] + listen
        // Apache AGE hooks the parser, so it has to be loaded into every backend, and
        // create_graph resolves its operator classes through search_path. ag_catalog goes
        // last so Garage's own unqualified names still land in public. Passed here rather
        // than in postgresql.conf so clusters initialized by an older build get it too;
        // skipped when the library isn't bundled, since a missing preload stops the server.
        if FileManager.default.fileExists(atPath: Paths.postgresLibDir.appendingPathComponent("age.dylib").path) {
            postgresArguments.append(contentsOf: [
                "-c", "shared_preload_libraries=age",
                "-c", "search_path=\"$user\", public, ag_catalog",
            ])
        }
        let configFile = Paths.postgresConfigFile
        if FileManager.default.fileExists(atPath: configFile.path) {
            postgresArguments.append(contentsOf: ["--config-file=\(configFile.path)"])
        }

        do {
            try runner.run(
                executable: Paths.postgresTool("postgres"),
                arguments: postgresArguments,
                environment: runtimeEnvironment(),
                source: "postgres"
            ) { [weak self] line in
                let parsed = PostgresLogParser.parse(line: line)
                self?.appendLog(parsed)
            }
        } catch {
            status = .failed("failed to launch postgres: \(error.localizedDescription)")
            throw error
        }

        let ready = await waitUntilReady(timeout: 30)
        guard ready else {
            status = .failed("postgres did not become ready within 30s")
            throw PostgresError.startupTimeout
        }

        do {
            try await ensureDatabaseExists(runner: try commandRunner())
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
        let pending = (try? await fetchPendingMigrations()) ?? []
        self.pendingMigrations = pending
        if !pending.isEmpty {
            status = .needsMigration
        } else {
            status = .running
        }
    }

    /// Fire-and-forget fast shutdown (SIGINT) for app-quit paths that can't await cleanup
    /// (see AppDelegate.applicationWillTerminate). Prefer stop() elsewhere.
    func terminateImmediately() {
        runner.interrupt()
        Self.stopAnyRunningInstanceSync()
    }

    func stop() async {
        guard status == .running || status == .needsMigration || status == .starting || runner.isRunning else {
            await Self.stopAnyRunningInstance()
            return
        }
        status = .stopping
        // A fast shutdown (SIGINT), not SIGTERM's smart one: the XPC services keep pooled connections
        // open, and a smart shutdown waits for them until the grace period ends in SIGKILL, which
        // leaves the cluster without a shutdown checkpoint to crash-recover on the next start.
        runner.interrupt()
        // Poll for the process to actually exit rather than assuming; the shutdown checkpoint of a
        // busy cluster can take a few seconds.
        for _ in 0..<100 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if runner.isRunning {
            runner.forceKill()
        }
        await Self.stopAnyRunningInstance()
        pendingMigrations = []
        status = .stopped
    }

    /// Stops any active Postgres server running against the app's pgdata
    /// directory, even if started by an earlier app instance or process.
    static func stopAnyRunningInstance() async {
        await withCheckedContinuation { continuation in
            postgresCLIQueue.async {
                stopAnyRunningInstanceSync()
                continuation.resume()
            }
        }
    }

    /// The blocking form. `applicationWillTerminate` has no way to await, so it
    /// pays the pg_ctl + SIGINT grace period on the calling thread; everywhere
    /// else should use `stopAnyRunningInstance()`.
    nonisolated static func stopAnyRunningInstanceSync() {
        // Paths.pgDataDir is the developer's live cluster; unit tests must never signal or kill it.
        guard !isRunningInTestEnvironment else { return }
        let pidFile = Paths.pgDataDir.appendingPathComponent("postmaster.pid")
        guard FileManager.default.fileExists(atPath: pidFile.path) else { return }
        // After a crash or power loss the file can outlive its postmaster, and its pid may since
        // belong to another process. Signal nothing that is not a postgres; the file is stale.
        guard GarageDataMigration.runningPostmaster(in: Paths.pgDataDir) != nil else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }

        let pgCtl = Paths.postgresTool("pg_ctl")
        if FileManager.default.isExecutableFile(atPath: pgCtl.path) {
            _ = ProcessRunner.runSync(
                executable: pgCtl,
                arguments: ["stop", "-D", Paths.pgDataDir.path, "-m", "fast", "-s"]
            )
        }

        guard FileManager.default.fileExists(atPath: pidFile.path),
              let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let firstLine = content.split(separator: "\n").first,
              let pid = Int32(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return
        }

        if GarageDataMigration.isPostgresProcess(pid) {
            // Fast shutdown, as in stop(); SIGTERM would wait for connected clients.
            kill(pid, SIGINT)
            var exited = false
            for _ in 0..<20 {
                usleep(50_000)
                if kill(pid, 0) != 0 {
                    exited = true
                    break
                }
            }
            if !exited && kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
                usleep(100_000)
            }
        }

        // pg_ctl removes this on a clean stop; the manual kill path above
        // does not. Clear it ourselves so the next postgres we launch never
        // has to reason about a leftover lock from a process we just killed.
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Deletes the cluster directory for "Reset Database". Postgres must already be stopped: while a
    /// postmaster still runs from it, nothing is deleted. The Keychain password stays, so the next
    /// `start()` initializes a new cluster with the same credential.
    func deleteClusterForReset() async throws {
        // Paths.pgDataDir is the developer's live cluster; unit tests must never delete it.
        guard !isRunningInTestEnvironment else { return }
        let pgdata = Paths.pgDataDir
        if let pid = GarageDataMigration.runningPostmaster(in: pgdata) {
            throw PostgresError.other("Postgres (pid \(pid)) is still running from \(pgdata.path); nothing was deleted.")
        }
        if FileManager.default.fileExists(atPath: pgdata.path) {
            // Off the main actor: a large cluster is many thousands of files.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: pgdata)
            }.value
        }
        pendingMigrations = []
        status = .stopped
        appendLog(LogLine(stream: .stdout, text: "deleted database cluster \(pgdata.path) for a reset", source: "postgres"))
    }

    /// Writes a portable PostgreSQL custom-format dump of the app's database.
    func backupDatabase(to destination: URL) async throws {
        try requireRunning()
        let runner = try commandRunner()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (dumpStatus, output) = await runner.run("pg_dump", arguments: [
            "--format=custom", "--no-owner", "--no-privileges",
            "--file", destination.path, databaseName,
        ])
        guard dumpStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw PostgresError.other("pg_dump failed: \(output)")
        }
        appendLog(LogLine(stream: .stdout, text: "backed up database to \(destination.path)", source: "pg_dump"))
    }

    /// Replaces the app's database with a PostgreSQL custom-format dump.
    func restoreDatabase(from source: URL) async throws {
        try requireRunning()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PostgresError.other("backup file does not exist: \(source.path)")
        }

        let runner = try commandRunner()
        try await dropDatabase(runner: runner)
        try await createDatabase(runner: runner)
        let (restoreStatus, output) = await runner.run("pg_restore", arguments: [
            "--no-owner", "--no-privileges", "--exit-on-error",
            "--dbname", databaseName, source.path,
        ])
        guard restoreStatus == 0 else {
            throw PostgresError.other("pg_restore failed: \(output)")
        }
        appendLog(LogLine(stream: .stdout, text: "restored database from \(source.path)", source: "pg_restore"))
    }

    /// What the Database page's details show about the running server: its version, how much disk
    /// the database takes, and the extensions installed in it. One psql call for all three.
    func fetchServerDetails() async throws -> DatabaseServerDetails {
        try requireRunning()
        let rows = try await commandRunner().query(
            """
            SELECT 'server', current_setting('server_version'), pg_database_size(current_database())::text
            UNION ALL
            SELECT 'extension', extname, extversion FROM pg_extension WHERE extname <> 'plpgsql'
            """,
            failureMessage: "could not read the server's details"
        )
        return DatabaseServerDetails(rows: rows)
    }

    /// `url` for display: the password, when there is one, replaced by bullets. Copy and the
    /// registered handler still get the real URL; the screen (and the accessibility API) never does.
    nonisolated static func redactedConnectionString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let password = components.percentEncodedPassword, !password.isEmpty else {
            return url.absoluteString
        }
        components.percentEncodedPassword = "REDACTED"
        return (components.string ?? url.absoluteString).replacingOccurrences(of: ":REDACTED@", with: ":••••••@")
    }

    /// Fetches all registered embedding models directly from the backing database.
    func listRegisteredModels() async throws -> [RegisteredModel] {
        try requireRunning()
        let sql = "SELECT slug, provider, model_ref, dims, stored_dims, storage_kind, index_kind, table_name, is_default, coalesce(model_id, ''), coalesce(modality, 'text') FROM embedding_models ORDER BY id;"
        let rows = try await commandRunner().query(sql)
        var models: [RegisteredModel] = []
        for parts in rows {
            guard parts.count >= 9 else { continue }
            let slug = parts[0]
            let provider = parts[1]
            let modelRef = parts[2]
            let dims = Int(parts[3]) ?? 0
            let storedDims = Int(parts[4]) ?? 0
            let storageKind = parts[5]
            let indexKind = parts[6]
            let tableName = parts[7]
            let isDefault = parts[8] == "t" || parts[8] == "true"
            let modelId = parts.count >= 10 && !parts[9].isEmpty ? parts[9] : nil
            let modality = parts.count >= 11 && !parts[10].isEmpty ? parts[10] : "text"
            models.append(RegisteredModel(
                slug: slug,
                provider: provider,
                modelRef: modelRef,
                dims: dims,
                storedDims: storedDims,
                storageKind: storageKind,
                indexKind: indexKind,
                tableName: tableName,
                isDefault: isDefault,
                modelId: modelId,
                modality: modality
            ))
        }
        return models
    }

    /// Fetches all registered ingest sources directly from the backing database along with their document counts.
    func listRegisteredSources() async throws -> [RegisteredSource] {
        try requireRunning()
        let sql = """
        SELECT s.slug, s.kind, s.root, s.default_class::text, s.default_trust::text, s.enabled, count(d.id), coalesce(s.expected_elements, 0)
        FROM sources s
        LEFT JOIN documents d ON d.source_id = s.id
        GROUP BY s.id, s.slug, s.kind, s.root, s.default_class, s.default_trust, s.enabled, s.expected_elements
        ORDER BY s.id;
        """
        let rows = try await commandRunner().query(sql)
        var sources: [RegisteredSource] = []
        for parts in rows {
            guard parts.count >= 6 else { continue }
            let slug = parts[0]
            let kind = parts[1]
            let root = parts[2]
            let corpusClass = parts[3]
            let trust = parts[4]
            let enabled = parts[5] == "t" || parts[5] == "true"
            let docCount = parts.count >= 7 ? (Int(parts[6]) ?? 0) : 0
            let expectedElements = parts.count >= 8 ? (Int(parts[7]) ?? 0) : 0
            sources.append(RegisteredSource(
                slug: slug,
                kind: kind,
                root: root,
                corpusClass: corpusClass,
                trust: trust,
                enabled: enabled,
                includeCode: false,
                origin: .database,
                documentCount: docCount,
                expectedElements: expectedElements
            ))
        }
        return sources
    }

    /// Returns the list of unapplied migration SQL file names from Paths.schemaDir.
    func fetchPendingMigrations() async throws -> [String] {
        let runner = try commandRunner()
        let schemaDir = Paths.schemaDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: schemaDir.path) else {
            return []
        }
        let sqlFiles = files.filter { $0.hasSuffix(".sql") }.sorted()
        if sqlFiles.isEmpty {
            return []
        }

        let sql = """
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = 'schema_migrations'
        );
        """
        let tableExists = try await runner.scalar(
            sql,
            failureMessage: "failed to check schema_migrations table"
        )
        if tableExists != "t" && tableExists != "true" {
            return sqlFiles
        }

        let appliedOutput = try await runner.scalar(
            "SELECT version FROM schema_migrations;",
            failureMessage: "failed to query applied migrations"
        )
        let appliedVersions = Set(
            appliedOutput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        return sqlFiles.filter { file in
            let version = (file as NSString).deletingPathExtension
            return !appliedVersions.contains(version) && !appliedVersions.contains(file)
        }
    }

    /// Refreshes the pendingMigrations list and returns it.
    @discardableResult
    func refreshPendingMigrations() async -> [String] {
        guard status == .running || status == .needsMigration else {
            pendingMigrations = []
            return []
        }
        let list = (try? await fetchPendingMigrations()) ?? []
        self.pendingMigrations = list
        if !list.isEmpty {
            status = .needsMigration
        } else if status == .needsMigration {
            status = .running
        }
        return list
    }

    #if DEBUG
    func setPendingMigrationsForTesting(_ migrations: [String]) {
        self.pendingMigrations = migrations
    }
    #endif

    /// Applies all pending schema migrations and updates the database status.
    func applyMigrations() async throws {
        guard status == .running || status == .needsMigration else {
            throw PostgresError.other("Postgres is not running")
        }
        let runner = try commandRunner()
        let schemaDir = Paths.schemaDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: schemaDir.path) else {
            throw PostgresError.other("Schema directory not found at \(schemaDir.path)")
        }
        let sqlFiles = files.filter { $0.hasSuffix(".sql") }.sorted()

        let createTableSql = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        );
        """
        let (initTableStatus, initTableOutput) = await runner.psql(["-c", createTableSql])
        guard initTableStatus == 0 else {
            throw PostgresError.other("Failed to initialize schema_migrations table: \(initTableOutput)")
        }

        let (_, appliedOutput) = await runner.psql(["-tAc", "SELECT version FROM schema_migrations;"])
        let appliedVersions = Set(
            appliedOutput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        for file in sqlFiles {
            let version = (file as NSString).deletingPathExtension
            if appliedVersions.contains(version) || appliedVersions.contains(file) {
                continue
            }
            let filePath = schemaDir.appendingPathComponent(file).path
            let (migStatus, migOutput) = await runner.psql(["-f", filePath])
            guard migStatus == 0 else {
                throw PostgresError.other("Migration \(file) failed: \(migOutput)")
            }

            let recordSql = "INSERT INTO schema_migrations (version) VALUES ('\(version)') ON CONFLICT (version) DO NOTHING;"
            _ = await runner.psql(["-c", recordSql])
            appendLog(LogLine(stream: .stdout, text: "applied migration: \(file)", source: "migrate"))
        }

        let pending = (try? await fetchPendingMigrations()) ?? []
        self.pendingMigrations = pending
        if !pending.isEmpty {
            status = .needsMigration
        } else {
            status = .running
        }
    }

    /// Overall corpus counts and documents per source. The per-model counts come
    /// from `modelRegistrySQL` and `countEmbeddings`: the bundled Postgres is built
    /// without libxml, so `query_to_xml` cannot count a dynamically named table here.
    private static let corpusStatsSQL = """
    WITH latest_runs AS (
        SELECT DISTINCT ON (source_id) seen_count, indexed_count
        FROM ingest_runs
        ORDER BY source_id, started_at DESC
    ),
    core AS (
        SELECT
            (SELECT count(*) FROM sources) AS sources_count,
            (SELECT count(*) FROM documents) AS documents_count,
            (SELECT count(*) FROM documents WHERE state = 'ok') AS documents_ok,
            (SELECT count(*) FROM documents WHERE state <> 'ok') AS documents_failed,
            (SELECT count(*) FROM chunks) AS chunks_count,
            (SELECT coalesce(sum(seen_count), 0) FROM latest_runs) AS seen_count,
            (SELECT coalesce(sum(indexed_count), 0) FROM latest_runs) AS indexed_count,
            (SELECT coalesce(sum(expected_elements), 0) FROM sources) AS expected_elements
    ),
    per_source AS (
        SELECT s.id AS ord, s.slug, count(d.id) AS document_count
        FROM sources s
        LEFT JOIN documents d ON d.source_id = s.id
        GROUP BY s.id, s.slug
    )
    SELECT tag, c1, c2, c3, c4, c5, c6, c7, c8
    FROM (
        SELECT 0 AS section, 0 AS ord, 'core' AS tag,
               sources_count::text AS c1,
               documents_count::text AS c2,
               documents_ok::text AS c3,
               documents_failed::text AS c4,
               chunks_count::text AS c5,
               seen_count::text AS c6,
               indexed_count::text AS c7,
               expected_elements::text AS c8
        FROM core
        UNION ALL
        SELECT 2, ord, 'source', slug, document_count::text, '', '', '', '', '', ''
        FROM per_source
    ) stat_rows
    ORDER BY section, ord;
    """

    /// Registered models and whether each one's vector table exists. A separate statement so that a
    /// database without the registry (`004_registry.sql`) still reports its core counts.
    private static let modelRegistrySQL = """
    SELECT slug, table_name, is_default::text, (to_regclass(format('public.%I', table_name)) IS NOT NULL)::text
    FROM embedding_models
    ORDER BY id;
    """

    /// Facts and the documents with a current fact run. A separate statement, like the registry's,
    /// because a database from before `013_fact_prompts.sql` has no `fact_runs`.
    private static let factsStatsSQL = """
    SELECT (SELECT count(*) FROM facts)::text,
           (SELECT count(DISTINCT r.document_id)
              FROM fact_runs r
              JOIN documents d ON d.id = r.document_id AND d.content_sha256 = r.content_sha256)::text;
    """

    /// Queries the Postgres database for overall corpus, ingestion, and embedding statistics.
    func fetchCorpusStats() async throws -> CorpusStats {
        try requireRunning()
        let rows = try await commandRunner().query(Self.corpusStatsSQL)

        var core: [String] = []
        var modelStats: [CorpusStats.ModelEmbeddingStats] = []
        var sourceDocumentCounts: [String: Int] = [:]
        var existingModelTables: Set<String> = []

        for row in rows {
            switch row.first {
            case "core":
                core = Array(row.dropFirst())
            case "source" where row.count >= 3:
                sourceDocumentCounts[row[1]] = Int(row[2]) ?? 0
            default:
                continue
            }
        }

        guard core.count >= 8 else {
            throw PostgresError.other("unexpected stats output: \(rows)")
        }

        // Without the registry there is nothing to count; the core counts still stand.
        for row in (try? await commandRunner().query(Self.modelRegistrySQL)) ?? [] where row.count >= 4 {
            modelStats.append(CorpusStats.ModelEmbeddingStats(
                slug: row[0],
                tableName: row[1],
                isDefault: row[2] == "true",
                embeddedCount: 0
            ))
            if row[3] == "true" {
                existingModelTables.insert(row[1])
            }
        }
        modelStats = try await countEmbeddings(for: modelStats, existingTables: existingModelTables)

        var factsCount = 0
        var documentsDistilledCount = 0
        if let row = (try? await commandRunner().query(Self.factsStatsSQL))?.first, row.count >= 2 {
            factsCount = Int(row[0]) ?? 0
            documentsDistilledCount = Int(row[1]) ?? 0
        }

        // The headline "embedded" number is the default model's, so the
        // progress bar tracks the model search actually uses.
        let embeddedChunks = modelStats.first(where: \.isDefault)?.embeddedCount
            ?? modelStats.first?.embeddedCount
            ?? 0

        return CorpusStats(
            sourcesCount: Int(core[0]) ?? 0,
            documentsCount: Int(core[1]) ?? 0,
            documentsOkCount: Int(core[2]) ?? 0,
            documentsFailedCount: Int(core[3]) ?? 0,
            totalChunks: Int(core[4]) ?? 0,
            embeddedChunks: embeddedChunks,
            totalSeenFiles: Int(core[5]) ?? 0,
            totalIndexedFiles: Int(core[6]) ?? 0,
            totalExpectedElements: Int(core[7]) ?? 0,
            modelStats: modelStats,
            sourceDocumentCounts: sourceDocumentCounts,
            factsCount: factsCount,
            documentsDistilledCount: documentsDistilledCount,
            lastUpdated: Date()
        )
    }

    /// Counts each model's `emb_<slug>` table in a second statement. Table names cannot be bound as
    /// parameters, and the bundled Postgres has no libxml for `query_to_xml`, so the statement is built
    /// here from names that exist and match the `emb_` pattern `db/models.py` generates.
    private func countEmbeddings(
        for models: [CorpusStats.ModelEmbeddingStats],
        existingTables: Set<String>
    ) async throws -> [CorpusStats.ModelEmbeddingStats] {
        let countable = models.filter {
            existingTables.contains($0.tableName) && $0.tableName.range(of: "^emb_[a-z0-9_]+$", options: .regularExpression) != nil
        }
        guard !countable.isEmpty else { return models }

        let sql = countable
            .map { "SELECT '\($0.tableName)', count(*) FROM public.\"\($0.tableName)\"" }
            .joined(separator: " UNION ALL ")
        var counts: [String: Int] = [:]
        for row in try await commandRunner().query(sql) where row.count >= 2 {
            counts[row[0]] = Int(row[1]) ?? 0
        }
        return models.map { model in
            CorpusStats.ModelEmbeddingStats(
                slug: model.slug,
                tableName: model.tableName,
                isDefault: model.isDefault,
                embeddedCount: counts[model.tableName] ?? 0
            )
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func requireRunning() throws {
        guard status == .running || status == .needsMigration else {
            throw PostgresError.other("Postgres must be running to manage the database")
        }
    }

    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (code, messages) = await PostgresCommandRunner.run(
                tool: "pg_isready",
                arguments: GaragePostgresEndpoint.clientArguments(socketDirectory: socketDirectory)
            )
            if code == 0 { return true }
            appendLog(LogLine(stream: .stdout, text: String(messages), source: "pg_isready"))
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func ensureDatabaseExists(runner: PostgresCommandRunner) async throws {
        // Connects to the always-present `postgres` database, since the app's
        // own one is what we are checking for.
        let (checkStatus, output) = await runner.run("psql", arguments: [
            "-d", "postgres",
            "-tAc", "SELECT 1 FROM pg_database WHERE datname = '\(databaseName)'",
        ])
        guard checkStatus == 0 else {
            throw PostgresError.other("could not query pg_database: \(output)")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return
        }
        try await createDatabase(runner: runner)
    }

    private func createDatabase(runner: PostgresCommandRunner) async throws {
        let (createStatus, createOutput) = await runner.run("createdb", arguments: [databaseName])
        guard createStatus == 0 else {
            throw PostgresError.other("createdb failed: \(createOutput)")
        }
        appendLog(LogLine(stream: .stdout, text: "created database \(databaseName)", source: "postgres"))
    }

    private func dropDatabase(runner: PostgresCommandRunner) async throws {
        let (dropStatus, dropOutput) = await runner.run("dropdb", arguments: ["--force", databaseName])
        guard dropStatus == 0 else {
            throw PostgresError.other("dropdb failed: \(dropOutput)")
        }
    }

    /// Environment postgres needs to find its own dylibs and pgvector's shared
    /// object when running from a relocated (vendored) bundle.
    private func runtimeEnvironment(password: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = Paths.postgresLibDir.path
        // Without this, postgres fails at startup on macOS with "FATAL:
        // postmaster became multithreaded during startup" — some locale
        // initialization on this platform spins up threads before postgres's
        // fork-safety check runs. Confirmed via direct testing; the postgres
        // HINT suggesting LC_ALL is correct.
        env["LC_ALL"] = "C"
        if let password {
            env["PGPASSWORD"] = password
        }
        return env
    }

    /// The password `loadPassword()` read (as `start()` does before anything connects). Never
    /// touches the Keychain: a read there can wait on an access prompt, which on the main actor
    /// freezes the window. Tests keep the password in memory and have it at once.
    private func postgresPassword() throws -> String {
        if let cachedPassword {
            return cachedPassword
        }
        if isRunningInTestEnvironment {
            let resolved = try KeychainPostgresPassword.resolve(clusterExists: false)
            cachedPassword = resolved.password
            return resolved.password
        }
        throw PostgresError.other("The database password has not been read yet. Start the database first.")
    }

    /// Reads (or, for a new cluster, creates) the password on a background thread, moving a
    /// login-keychain item into the App Group keychain on the way, then caches it for
    /// `postgresPassword()`. The window stays responsive while macOS shows a Keychain prompt.
    private func loadPassword() async throws -> String {
        if let cachedPassword {
            return cachedPassword
        }
        let clusterExists = isInitialized
        let resolved = try await Task.detached(priority: .userInitiated) {
            try KeychainPostgresPassword.resolve(clusterExists: clusterExists)
        }.value
        for line in resolved.log {
            appendLog(LogLine(stream: .stdout, text: line, source: "keychain"))
        }
        cachedPassword = resolved.password
        return resolved.password
    }

    /// A directory as one element of a list setting such as `unix_socket_directories`: double-quoted,
    /// with embedded quotes doubled, so a comma in the path cannot split it (`SplitDirectoriesString`).
    nonisolated static func quotedSetting(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private enum KeychainPostgresPassword {
    // The item, its keychains and the migration between them live in GaragePostgresEndpoint,
    // shared with the bundled launchers, which read the same item to connect.
    private static let passwordLength = 32
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    // Touched from the background task `loadPassword()` runs `resolve` in.
    private static let lock = NSLock()
    private static var inMemoryPassword: String?
    private static var migrationAttempted = false

    /// The cluster's password and what to log about where it came from. Reads the Keychain, which
    /// can block on an access prompt: never call it on the main actor.
    static func resolve(clusterExists: Bool) throws -> (password: String, log: [String]) {
        var log: [String] = []
        // A failed read is not "no password yet". Generating one here would overwrite
        // the cluster's real password in the Keychain (save updates the existing item)
        // and lock the app out of its own database, so read and save errors surface
        // as they are. Tests never reach the Keychain: load/save keep it in memory.
        if let migration = migrateIfNeeded() {
            log.append(migration)
        }
        if let storedPassword = try load() {
            return (storedPassword, log)
        }
        // A cluster without a password this build can read was made by another build (the App
        // Store and Developer ID builds share the data folder, and a locally signed build cannot
        // read their shared Keychain item). A new password would not open it and would hide the
        // real problem.
        if !isRunningInTestEnvironment, clusterExists {
            throw PostgresError.other(
                "The database in \(Paths.pgDataDir.path) exists, but its password is not in a "
                    + "Keychain this build can read (service \(GaragePostgresEndpoint.keychainService)). It was "
                    + "probably created by another Garage build."
            )
        }
        let generatedPassword = try generate()
        let store = try save(generatedPassword)
        log.append("stored a new database password in the \(store) keychain")
        return (generatedPassword, log)
    }

    /// Copies a login-keychain password into the App Group keychain, once per launch, so the
    /// launchers read it without a prompt. Returns a line for the log when something happened;
    /// a failure is logged too but never blocks start-up, since `load` still finds the old item.
    static func migrateIfNeeded() -> String? {
        let firstAttempt = lock.withLock {
            defer { migrationAttempted = true }
            return !migrationAttempted
        }
        guard !isRunningInTestEnvironment, firstAttempt else { return nil }
        do {
            switch try GaragePostgresEndpoint.migrateLegacyPassword() {
            case .groupKeychainUnavailable, .alreadyInGroupKeychain, .nothingToMigrate:
                return nil
            case .migrated:
                return "copied the database password into the App Group keychain (\(GaragePostgresEndpoint.keychainAccessGroup)); "
                    + "the login keychain item stays for older builds"
            }
        } catch {
            return "could not move the database password into the App Group keychain: \(error.localizedDescription)"
        }
    }

    static func load() throws -> String? {
        if isRunningInTestEnvironment {
            return lock.withLock { inMemoryPassword }
        }
        // The same read the bundled launchers do.
        return try GaragePostgresEndpoint.readPassword()
    }

    /// Stores the password and names where it went (the App Group keychain, or the login keychain
    /// for a build without an application identifier).
    @discardableResult
    static func save(_ password: String) throws -> String {
        if isRunningInTestEnvironment {
            lock.withLock { inMemoryPassword = password }
            return "in-memory"
        }
        if let file = GaragePostgresEndpoint.isolatedPasswordFile {
            // Owner-only from the moment it exists; the folder is a throwaway test folder.
            guard FileManager.default.createFile(
                atPath: file.path,
                contents: Data(password.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw PostgresError.other("could not save the Postgres password in \(file.path)")
            }
            return "isolated data folder"
        }
        do {
            switch try GaragePostgresEndpoint.savePassword(password) {
            case .group:
                return "App Group"
            case .legacy:
                return "login"
            }
        } catch {
            throw PostgresError.other(error.localizedDescription)
        }
    }

    static func generate() throws -> String {
        var password = ""
        while password.count < passwordLength {
            var bytes = [UInt8](repeating: 0, count: passwordLength)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw PostgresError.other("could not generate Postgres password (OSStatus \(status))")
            }
            for byte in bytes where byte < 248 && password.count < passwordLength {
                password.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return password
    }
}

enum PostgresError: LocalizedError {
    case initFailed(String)
    case startupTimeout
    case other(String)

    var errorDescription: String? {
        switch self {
        case .initFailed(let output): "initdb failed:\n\(output)"
        case .startupTimeout: "postgres did not report ready in time"
        case .other(let message): message
        }
    }
}
