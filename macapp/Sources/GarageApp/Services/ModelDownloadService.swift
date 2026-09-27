import Foundation
import SwiftUI
import AppKit
import ModelDownloadClient
import PythonXPCService

/// Service managing the state and operations of the ModelDownload XPC service in the macOS app.
@MainActor
final class ModelDownloadService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var statusMessage: String = "Not connected"
    @Published private(set) var activeDownloads: [DownloadTaskInfo] = []
    @Published private(set) var downloadedModels: [DownloadedModelInfo] = []
    @Published private(set) var modelsDirectory: String = ""
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: String?
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var verificationResults: [String: VerificationResult] = [:]
    @Published private(set) var verifyingPaths: Set<String> = []

    public struct VerificationResult: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let isValid: Bool
        public let computedSha256: String
        public let expectedSha256: String?
        public let verifiedAt: Date
        public let errorMessage: String?

        public init(
            path: String,
            isValid: Bool,
            computedSha256: String,
            expectedSha256: String?,
            verifiedAt: Date = Date(),
            errorMessage: String? = nil
        ) {
            self.path = path
            self.isValid = isValid
            self.computedSha256 = computedSha256
            self.expectedSha256 = expectedSha256
            self.verifiedAt = verifiedAt
            self.errorMessage = errorMessage
        }
    }

    let client: ModelDownloadClient
    /// The models folder the XPC service must use instead of its own default, or nil to leave it.
    /// Set under `--data-directory`: XPC services never see the app's arguments, so the service
    /// would otherwise resolve the real models folder in its own process and list, download into
    /// and delete from the user's real models while the app runs on a test data folder.
    let modelsDirectoryOverride: String?
    private let maxLogLines = 2000
    private var pollTimer: Timer?

    init(
        client: ModelDownloadClient = ModelDownloadClient(),
        modelsDirectoryOverride: String? = GarageAppGroup.dataDirectoryOverride == nil ? nil : Paths.modelsDir.path
    ) {
        self.client = client
        self.modelsDirectoryOverride = modelsDirectoryOverride
    }

    /// Tells the service which models folder to use (`modelsDirectoryOverride`). The service keeps
    /// it in memory only, and launchd may relaunch the service between calls, so this runs before
    /// every call that reads or writes the folder rather than once at launch.
    private func applyModelsDirectoryOverride() async throws {
        guard let path = modelsDirectoryOverride else { return }
        _ = try await client.setModelsDirectory(path: path)
    }

    deinit {
        pollTimer?.invalidate()
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        logs.append(LogLine(stream: stream, text: text, source: "model-download-xpc"))
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
    }

    // MARK: - Status & Refresh

    func ping() async -> Bool {
        do {
            let reply = try await client.ping()
            isConnected = true
            statusMessage = reply
            appendLog("Ping reply: \(reply)")
            return true
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Ping failed: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    func refresh() async {
        do {
            let pingResp = try await client.ping()
            isConnected = true
            try await applyModelsDirectoryOverride()

            let downloads = try await client.listDownloads()
            self.activeDownloads = downloads

            let dir = try await client.getModelsDirectory()
            self.modelsDirectory = dir

            let models = try await client.listDownloadedModels()
            self.downloadedModels = models

            let activeCount = downloads.filter { $0.status == .downloading || $0.status == .queued }.count
            if activeCount > 0 {
                statusMessage = "\(activeCount) download(s) in progress"
                startPollingIfNeeded()
            } else {
                statusMessage = "\(models.count) model(s) available (\(pingResp))"
                stopPollingIfNoActiveDownloads()
            }
        } catch {
            isConnected = false
            statusMessage = "Service unavailable"
            lastError = error.localizedDescription
            appendLog("Failed to refresh model downloader: \(error.localizedDescription)", stream: .stderr)
        }
    }

    // MARK: - Polling for active progress

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollActiveDownloads()
            }
        }
    }

    private func stopPollingIfNoActiveDownloads() {
        let hasActive = activeDownloads.contains { $0.status == .downloading || $0.status == .queued }
        if !hasActive {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func pollActiveDownloads() async {
        guard isConnected else { return }
        if let downloads = try? await client.listDownloads() {
            self.activeDownloads = downloads
            let hasActive = downloads.contains { $0.status == .downloading || $0.status == .queued }
            if !hasActive {
                // Refresh local file list when all downloads finish
                if let models = try? await client.listDownloadedModels() {
                    self.downloadedModels = models
                }
                stopPollingIfNoActiveDownloads()
            }
        }
    }

    // MARK: - Download Actions

    @discardableResult
    func startDownload(
        url: String,
        filename: String? = nil,
        modelId: String? = nil,
        expectedSize: Int64? = nil,
        sha256: String? = nil,
        authToken: String? = nil
    ) async -> Bool {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty else {
            lastError = "Download URL cannot be empty."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        lastSuccess = nil

        let req = ModelDownloadRequest(
            url: trimmedUrl,
            filename: filename?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelId: modelId,
            expectedSize: expectedSize,
            sha256: sha256?.trimmingCharacters(in: .whitespacesAndNewlines),
            authToken: authToken
        )

        do {
            appendLog("Starting download for \(req.filename ?? trimmedUrl)...")
            try await applyModelsDirectoryOverride()
            let taskInfo = try await client.startDownload(request: req)
            lastSuccess = "Started download: \(taskInfo.filename)"
            appendLog("Download task created (ID: \(taskInfo.id)) for \(taskInfo.filename)")
            await refresh()
            startPollingIfNeeded()
            return true
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to start download: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func cancelDownload(taskId: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            appendLog("Cancelling download task \(taskId)...")
            let success = try await client.cancelDownload(taskId: taskId)
            if success {
                lastSuccess = "Download cancelled."
                appendLog("Download cancelled successfully.")
                await refresh()
                return true
            } else {
                lastError = "Could not cancel download."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Error cancelling download: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    @discardableResult
    func pauseDownload(taskId: String) async -> Bool {
        do {
            let success = try await client.pauseDownload(taskId: taskId)
            if success {
                appendLog("Download \(taskId) paused.")
                await refresh()
            }
            return success
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func resumeDownload(taskId: String) async -> Bool {
        do {
            let success = try await client.resumeDownload(taskId: taskId)
            if success {
                appendLog("Download \(taskId) resumed.")
                await refresh()
                startPollingIfNeeded()
            }
            return success
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteDownloadedModel(_ model: DownloadedModelInfo) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            appendLog("Deleting model file \(model.filename)...")
            let success = try await client.deleteDownloadedModel(at: model.path)
            if success {
                lastSuccess = "Model \(model.filename) deleted."
                appendLog("Deleted model \(model.filename).")
                await refresh()
                return true
            } else {
                lastError = "File not found or could not be deleted."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to delete model: \(error.localizedDescription)", stream: .stderr)
            return false
        }
    }

    // MARK: - Query Helpers

    private func matchesModel(info: DownloadedModelInfo, target: String) -> Bool {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { return false }
        if info.filename == cleanTarget || info.path == cleanTarget || info.name == cleanTarget {
            return true
        }
        let targetLast = URL(fileURLWithPath: cleanTarget).lastPathComponent
        let infoLast = URL(fileURLWithPath: info.filename).lastPathComponent
        if !targetLast.isEmpty && (targetLast == infoLast || targetLast == info.name) {
            return true
        }
        if info.path.hasSuffix("/" + cleanTarget) || info.filename.hasSuffix("/" + cleanTarget) || cleanTarget.hasSuffix("/" + info.filename) {
            return true
        }
        return false
    }

    func isModelDownloaded(filename: String) -> Bool {
        downloadedModels.contains { matchesModel(info: $0, target: filename) }
    }

    func isModelDownloading(url: String) -> Bool {
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = URL(fileURLWithPath: cleanUrl).lastPathComponent
        return activeDownloads.contains {
            ($0.url == cleanUrl || $0.filename == cleanUrl || URL(fileURLWithPath: $0.filename).lastPathComponent == last || $0.destinationPath.hasSuffix("/" + cleanUrl)) &&
            ($0.status == .downloading || $0.status == .queued)
        }
    }

    func downloadedModel(for filename: String) -> DownloadedModelInfo? {
        downloadedModels.first { matchesModel(info: $0, target: filename) }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func isVerifying(path: String) -> Bool {
        verifyingPaths.contains(path)
    }

    func verificationResult(for path: String) -> VerificationResult? {
        verificationResults[path]
    }

    @discardableResult
    func verifyModelFile(path: String, expectedSha256: String? = nil) async -> VerificationResult {
        verifyingPaths.insert(path)
        defer { verifyingPaths.remove(path) }

        let fileName = URL(fileURLWithPath: path).lastPathComponent
        appendLog("Calculating SHA-256 checksum for \(fileName)...")
        do {
            let (isValid, hash) = try await client.verifyModelFile(at: path, expectedSha256: expectedSha256)
            let result = VerificationResult(
                path: path,
                isValid: isValid,
                computedSha256: hash,
                expectedSha256: expectedSha256,
                verifiedAt: Date(),
                errorMessage: isValid ? nil : "Checksum mismatch (expected: \(expectedSha256 ?? ""), computed: \(hash))"
            )
            verificationResults[path] = result
            if isValid {
                if let exp = expectedSha256, !exp.isEmpty {
                    lastSuccess = "SHA-256 verified: \(hash.prefix(12))..."
                    appendLog("SHA-256 verified successfully for \(fileName): \(hash)")
                } else {
                    lastSuccess = "Computed SHA-256: \(hash.prefix(12))..."
                    appendLog("Computed SHA-256 for \(fileName): \(hash)")
                }
            } else {
                lastError = "SHA-256 mismatch for \(fileName)"
                appendLog("SHA-256 mismatch for \(fileName): expected \(expectedSha256 ?? ""), got \(hash)", stream: .stderr)
            }
            return result
        } catch {
            let result = VerificationResult(
                path: path,
                isValid: false,
                computedSha256: "",
                expectedSha256: expectedSha256,
                verifiedAt: Date(),
                errorMessage: error.localizedDescription
            )
            verificationResults[path] = result
            lastError = "Verification failed: \(error.localizedDescription)"
            appendLog("Verification failed for \(fileName): \(error.localizedDescription)", stream: .stderr)
            return result
        }
    }

    @discardableResult
    func testDownloadAndVerifySha256() async -> (isValid: Bool, details: String) {
        isBusy = true
        defer { isBusy = false }
        appendLog("Running functional download & SHA-256 integrity verification test...")
        do {
            let (isValid, details) = try await client.testDownloadAndVerifySha256()
            if isValid {
                lastSuccess = "Download & SHA-256 test passed."
                appendLog("Download & SHA-256 verification test passed: \(details)")
            } else {
                lastError = "Download & SHA-256 test failed: \(details)"
                appendLog("Download & SHA-256 test failed: \(details)", stream: .stderr)
            }
            return (isValid, details)
        } catch {
            lastError = error.localizedDescription
            appendLog("Download & SHA-256 test failed: \(error.localizedDescription)", stream: .stderr)
            return (false, "Error: \(error.localizedDescription)")
        }
    }

    func copyToClipboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastSuccess = "Copied to clipboard!"
    }
}
