import Foundation
import IngestClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "IngestService")

/// Thread-safe buffer for batching background ingest logs and progress updates before dispatching to MainActor.
private final class IngestBatchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLogs: [LogLine] = []
    private var pendingProgress: [IngestProgressUpdate] = []

    func appendLog(_ line: LogLine) {
        lock.lock()
        pendingLogs.append(line)
        lock.unlock()
    }

    func appendProgress(_ progress: IngestProgressUpdate) {
        lock.lock()
        pendingProgress.append(progress)
        lock.unlock()
    }

    func drain() -> (logs: [LogLine], progress: [IngestProgressUpdate]) {
        lock.lock()
        let logs = pendingLogs
        let progress = pendingProgress
        pendingLogs.removeAll(keepingCapacity: true)
        pendingProgress.removeAll(keepingCapacity: true)
        lock.unlock()
        return (logs, progress)
    }
}

/// Execution strategy for document ingestion (XPC service).
enum IngestExecutionMode: String, CaseIterable, Identifiable, Sendable {
    case xpcService = "xpc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xpcService: return "Out-of-Process (XPC Helper)"
        }
    }

    var shortTitle: String {
        switch self {
        case .xpcService: return "XPC Helper"
        }
    }

    var modeDescription: String {
        switch self {
        case .xpcService:
            return "Runs Python ingestion in a dedicated multi-threaded background process (GarageIngestXPCService) with crash isolation."
        }
    }
}

/// Observable service that coordinates ingestion through the XPC service or CLI process,
/// maintaining real-time progress state, per-source metrics, and logs for the UI.
@MainActor
final class IngestService: ObservableObject {
    @Published var executionMode: IngestExecutionMode {
        didSet {
            UserDefaults.standard.set(executionMode.rawValue, forKey: "garage.ingest.executionMode")
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isCancelling: Bool = false
    @Published private(set) var activeMode: IngestExecutionMode? = nil
    @Published private(set) var currentSource: String? = nil
    @Published private(set) var pendingSources: Set<String> = []
    /// Every source in the current run, kept for the whole run. `pendingSources`
    /// drains as each source starts, so it cannot distinguish a finished batch
    /// run from a single-source run; combined progress keys off this instead.
    @Published private(set) var runSources: Set<String> = []
    @Published private(set) var latestProgress: IngestProgressUpdate? = nil
    @Published private(set) var progressBySource: [String: IngestProgressUpdate] = [:]
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastSuccess: String? = nil
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var startedAt: Date? = nil

    let xpcClient: IngestClient
    let postgres: PostgresService?
    private let maxLogLines = 4000
    private var activeActivity: NSObjectProtocol? = nil
    private var seenLogKeys: Set<String> = []
    private var seenLogKeyQueue: [String] = []
    private let maxSeenKeys = 2000

    /// Ingest logs arrive from the XPC helper over its log stream (IngestClient); the
    /// app's own OSLog is polled once, by OSLogStreamService, not here as well.
    init(
        client: IngestClient = IngestClient(),
        postgres: PostgresService? = nil
    ) {
        let savedMode = UserDefaults.standard.string(forKey: "garage.ingest.executionMode")
        self.executionMode = savedMode.flatMap(IngestExecutionMode.init) ?? .xpcService
        self.xpcClient = client
        self.postgres = postgres
    }

    var client: IngestClient {
        xpcClient
    }

    func appendLog(_ line: LogLine) {
        appendLogs([line])
    }

    func appendLogs(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }

        var accepted: [LogLine] = []
        accepted.reserveCapacity(lines.count)

        for line in lines {
            let textTrimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textTrimmed.isEmpty else { continue }

            let timeBucket = Int(line.date.timeIntervalSince1970)
            let key = "\(textTrimmed)|\(timeBucket)"

            if seenLogKeys.contains(key) {
                continue
            }
            seenLogKeys.insert(key)
            seenLogKeyQueue.append(key)
            accepted.append(line)
        }

        if seenLogKeyQueue.count > maxSeenKeys {
            let overflow = seenLogKeyQueue.count - maxSeenKeys
            for removed in seenLogKeyQueue.prefix(overflow) {
                seenLogKeys.remove(removed)
            }
            seenLogKeyQueue.removeFirst(overflow)
        }

        guard !accepted.isEmpty else { return }

        // Single @Published mutation for the whole batch instead of one per line - each mutation triggers a
        // reflection-based Combine objectWillChange publish, which is what stalls the main thread when a burst
        // (e.g. Dropbox source scans) drains hundreds or thousands of lines into one appendLogs call.
        logs.append(contentsOf: accepted)
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        appendLog(LogLine(stream: stream, text: text, source: "Ingest"))
    }

    func clearLogs() {
        logs.removeAll()
        seenLogKeys.removeAll()
        seenLogKeyQueue.removeAll()
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
        latestProgress = nil
        progressBySource.removeAll()
    }

    /// Clears the transient banner state after a run finishes while keeping the
    /// per-source "Last Ingest" summaries in `progressBySource`.
    func clearTransientMessages() {
        lastError = nil
        lastSuccess = nil
        latestProgress = nil
    }

    func clearProgressBySource() {
        self.progressBySource.removeAll()
    }

    func setPendingSources(_ slugs: Set<String>) {
        self.pendingSources = slugs
        self.runSources = slugs
    }

    func markSourceActive(_ slug: String) {
        self.pendingSources.remove(slug)
        self.runSources.insert(slug)
        // handleProgressBatch only adopts a source when `currentSource` is unset
        // or the "*" placeholder, so without this the first source of a batch
        // run would stay current for the whole run.
        self.currentSource = slug
    }

    /// The run was cancelled: the sources it had yet to reach will not start.
    func dropPendingSources() {
        self.runSources.subtract(self.pendingSources)
        self.pendingSources.removeAll()
    }

    /// `slug` was cancelled or is being removed: it leaves the run, unless it is the source being
    /// ingested now, which stays until its cancelled ingest ends.
    func dropSource(_ slug: String) {
        self.pendingSources.remove(slug)
        if currentSource != slug {
            self.runSources.remove(slug)
        }
    }

    func clearPendingSources() {
        self.pendingSources.removeAll()
        self.runSources.removeAll()
    }

    func handleProgress(_ progress: IngestProgressUpdate, sourceLabel: String = "Ingest") {
        handleProgressBatch([progress], sourceLabel: sourceLabel)
    }

    func handleProgressBatch(_ updates: [IngestProgressUpdate], sourceLabel: String = "Ingest") {
        guard !updates.isEmpty else { return }
        var progressLogs: [LogLine] = []
        var mergedProgressBySource = progressBySource
        var newCurrentSource: String? = nil

        for progress in updates {
            mergedProgressBySource[progress.source] = progress
            if newCurrentSource == nil && (self.currentSource == nil || self.currentSource == "*") {
                newCurrentSource = progress.source
            }

            logger.debug("IngestService progress (\(sourceLabel, privacy: .public)): phase=\(progress.phase, privacy: .public), msg=\(progress.message, privacy: .public)")

            if !progress.message.isEmpty {
                let stream: LogLine.Stream = progress.isError ? .stderr : .stdout
                let line = LogLine(
                    stream: stream,
                    text: progress.message,
                    source: sourceLabel
                )
                progressLogs.append(line)
            }
        }

        // Assign each @Published property once for the whole batch rather than once per update - see appendLogs
        // for why: bursty sources (e.g. Dropbox scans) can hand this hundreds of updates at a time.
        latestProgress = updates.last
        progressBySource = mergedProgressBySource
        if let newCurrentSource {
            currentSource = newCurrentSource
        }
        if !progressLogs.isEmpty {
            appendLogs(progressLogs)
        }
    }

    /// Cancels any active ingestion run.
    @discardableResult
    func cancel() async -> Bool {
        guard isRunning else { return false }
        isCancelling = true
        let label = "Ingest (XPC)"
        logger.info("IngestService: requesting cancel for '\(self.currentSource ?? "source", privacy: .public)'")
        let line = LogLine(
            stream: .stderr,
            text: "Cancelling ingestion for '\(currentSource ?? "source")'...",
            source: label
        )
        appendLog(line)

        do {
            let success = try await xpcClient.cancelIngest()
            logger.info("IngestService: cancel signal result: \(success)")
            return success
        } catch {
            let errorMsg = "Failed to send cancel signal: \(error.localizedDescription)"
            logger.error("IngestService: cancel signal failed: \(error.localizedDescription, privacy: .public)")
            lastError = errorMsg
            let errLine = LogLine(stream: .stderr, text: errorMsg, source: label)
            appendLog(errLine)
            return false
        }
    }

    /// Performs ingestion for the given source slug with options, streaming progress back to the UI.
    @discardableResult
    nonisolated func ingest(
        slug: String,
        options: IngestOptions = .default,
        mode: IngestExecutionMode? = nil
    ) async -> IngestResult {
        let commandLabel = "Ingest (XPC)"

        let prep = await MainActor.run { () -> (shouldProceed: Bool, errorResult: IngestResult?, runStartDate: Date, targetMode: IngestExecutionMode, dbURL: String?, lmToken: String?) in
            let targetMode = mode ?? self.executionMode

            guard !self.isRunning else {
                let msg = "Ingestion is already running for \(self.currentSource ?? "another source")"
                logger.warning("IngestService: \(msg, privacy: .public)")
                let line = LogLine(stream: .stderr, text: msg, source: commandLabel)
                self.appendLog(line)
                self.lastError = msg
                return (false, IngestResult(succeeded: false, message: msg), Date(), targetMode, nil, nil)
            }

            self.isRunning = true
            self.activeMode = targetMode
            self.currentSource = slug
            let runStartDate = Date()
            self.startedAt = runStartDate
            self.lastError = nil
            self.lastSuccess = nil

            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(slug) (\(targetMode.shortTitle))"
            )
            self.activeActivity = activity

            let startMsg = "Starting ingestion [\(targetMode.title)] for source '\(slug)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)))..."
            logger.info("IngestService: \(startMsg, privacy: .public)")
            let startLine = LogLine(
                stream: .stdout,
                text: startMsg,
                source: commandLabel
            )
            self.appendLog(startLine)

            var effectiveDatabaseURL = options.databaseUrl
            if effectiveDatabaseURL == nil, let postgres = self.postgres, let dbURL = try? postgres.connectionURL() {
                effectiveDatabaseURL = dbURL
            }
            var effectiveLMStudioToken = options.lmStudioApiToken
            if effectiveLMStudioToken == nil, let lmToken = try? LMStudioTokenStore.load() {
                effectiveLMStudioToken = lmToken
            }

            return (true, nil, runStartDate, targetMode, effectiveDatabaseURL, effectiveLMStudioToken)
        }

        guard prep.shouldProceed else {
            return prep.errorResult ?? IngestResult(succeeded: false, message: "Ingestion is already running")
        }

        let targetMode = prep.targetMode
        let selectedClient = self.xpcClient

        let cleanup = { @MainActor [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.isCancelling = false
            self.activeMode = nil
            self.currentSource = nil
            self.startedAt = nil
            if let act = self.activeActivity {
                ProcessInfo.processInfo.endActivity(act)
                self.activeActivity = nil
            }
        }

        let batchBuffer = IngestBatchBuffer()
        let batchFlushTask = Task { [weak self, batchBuffer] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let (logs, progressUpdates) = batchBuffer.drain()
                if !logs.isEmpty || !progressUpdates.isEmpty {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        if !logs.isEmpty {
                            self.appendLogs(logs)
                        }
                        if !progressUpdates.isEmpty {
                            self.handleProgressBatch(progressUpdates, sourceLabel: commandLabel)
                        }
                    }
                }
            }
        }

        defer {
            batchFlushTask.cancel()
            Task { @MainActor [weak self, batchBuffer] in
                let (remainingLogs, remainingProgress) = batchBuffer.drain()
                if let self = self {
                    if !remainingLogs.isEmpty {
                        self.appendLogs(remainingLogs)
                    }
                    if !remainingProgress.isEmpty {
                        self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                    }
                }
                if self?.isRunning == true {
                    cleanup()
                }
            }
        }

        let effectiveOptions = IngestOptions(
            includeCode: options.includeCode,
            limit: options.limit,
            force: options.force,
            grpcHost: options.grpcHost,
            grpcPort: options.grpcPort,
            databaseUrl: prep.dbURL,
            lmStudioApiToken: prep.lmToken,
            grpcToken: GarageGRPCAuth.token
        )

        if let dbURL = prep.dbURL {
            _ = try? await selectedClient.setDatabaseURL(dbURL, lmStudioApiToken: prep.lmToken)
        }

        do {
            let result = try await selectedClient.ingest(
                slug: slug,
                options: effectiveOptions,
                onLog: { message, level in
                    let stream: LogLine.Stream = level >= 40 ? .stderr : .stdout
                    batchBuffer.appendLog(LogLine(stream: stream, text: message, source: commandLabel))
                },
                onProgress: { progress in
                    batchBuffer.appendProgress(progress)
                }
            )

            batchFlushTask.cancel()
            let (remainingLogs, remainingProgress) = batchBuffer.drain()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if !remainingLogs.isEmpty {
                    self.appendLogs(remainingLogs)
                }
                if !remainingProgress.isEmpty {
                    self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                }
                if result.succeeded {
                    let successMsg = result.message ?? "Ingestion finished successfully for \(slug) [\(targetMode.shortTitle)]"
                    logger.info("IngestService: \(successMsg, privacy: .public)")
                    self.lastSuccess = successMsg
                    let line = LogLine(stream: .stdout, text: successMsg, source: commandLabel)
                    self.appendLog(line)
                } else {
                    let errorMsg = result.message ?? "Ingestion failed for \(slug) [\(targetMode.shortTitle)]"
                    logger.error("IngestService: \(errorMsg, privacy: .public)")
                    self.lastError = errorMsg
                    let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                    self.appendLog(line)
                }
                cleanup()
            }

            return result
        } catch {
            batchFlushTask.cancel()
            let (remainingLogs, remainingProgress) = batchBuffer.drain()
            let errorMsg = "Ingestion error for \(slug) [\(targetMode.shortTitle)]: \(error.localizedDescription)"
            logger.error("IngestService: \(errorMsg, privacy: .public)")
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if !remainingLogs.isEmpty {
                    self.appendLogs(remainingLogs)
                }
                if !remainingProgress.isEmpty {
                    self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                }
                self.lastError = errorMsg
                let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                self.appendLog(line)
                cleanup()
            }
            return IngestResult(succeeded: false, message: errorMsg)
        }
    }

    #if DEBUG
    func setRunningForTesting(_ running: Bool) {
        self.isRunning = running
    }
    #endif
}
