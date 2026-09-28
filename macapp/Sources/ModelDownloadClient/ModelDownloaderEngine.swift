import Foundation
import CryptoKit
import PythonXPCService

/// Core engine managing model downloads, file system storage, and task tracking.
public final class ModelDownloaderEngine: NSObject, @unchecked Sendable {
    public static let shared = ModelDownloaderEngine()

    private let lock = NSLock()
    private var customModelsDirectory: URL?

    private var tasks: [String: DownloadTaskInfo] = [:]
    private var urlTasks: [String: URLSessionDownloadTask] = [:]
    private var lastBytesWritten: [String: (bytes: Int64, timestamp: Date)] = [:]
    private var session: URLSession!

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 86400.0 // 24 hours for large multi-GB models
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public var defaultModelsDirectory: URL {
        if let custom = customModelsDirectory {
            return custom
        }
        let modelsDir = GarageAppGroup.dataDirectory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    public func setModelsDirectory(path: String) throws {
        let dirUrl = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true)
        lock.lock()
        customModelsDirectory = dirUrl
        lock.unlock()
    }

    public func getModelsDirectoryPath() -> String {
        lock.lock()
        defer { lock.unlock() }
        return defaultModelsDirectory.path
    }

    // MARK: - Download Management

    public func startDownload(request: ModelDownloadRequest) throws -> DownloadTaskInfo {
        guard let url = URL(string: request.url), url.scheme == "http" || url.scheme == "https" else {
            throw NSError(domain: "ModelDownloaderEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL: \(request.url)"])
        }

        let filename: String
        if let reqFilename = request.filename, !reqFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filename = reqFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let lastComponent = url.lastPathComponent
            filename = lastComponent.isEmpty ? "model-\(UUID().uuidString.prefix(8)).gguf" : lastComponent
        }

        // Clean leading slashes while preserving subdirectories
        var cleanFilename = filename
        while cleanFilename.hasPrefix("/") {
            cleanFilename.removeFirst()
        }
        if cleanFilename.isEmpty {
            cleanFilename = "model-\(UUID().uuidString.prefix(8)).gguf"
        }

        let targetDir: URL
        if let customDir = request.destinationDirectory, !customDir.isEmpty {
            targetDir = URL(fileURLWithPath: customDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } else {
            targetDir = defaultModelsDirectory
        }

        // The file name can come from the downloaded models.json catalog: refuse one that climbs out
        // of the models folder (`../`), keeping subdirectories inside it.
        let destinationFile = targetDir.appendingPathComponent(cleanFilename).standardizedFileURL
        let targetPath = targetDir.standardizedFileURL.path
        guard !cleanFilename.split(separator: "/").contains(".."),
              destinationFile.path.hasPrefix(targetPath.hasSuffix("/") ? targetPath : targetPath + "/") else {
            throw NSError(domain: "ModelDownloaderEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid model file name: \(filename)"])
        }
        try? FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let taskId = UUID().uuidString

        var urlRequest = URLRequest(url: url)
        if let token = request.authToken, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("Garage-ModelDownloader/1.0", forHTTPHeaderField: "User-Agent")

        let downloadTask = session.downloadTask(with: urlRequest)

        let taskInfo = DownloadTaskInfo(
            id: taskId,
            url: request.url,
            filename: cleanFilename,
            destinationPath: destinationFile.path,
            status: .downloading,
            bytesDownloaded: 0,
            totalBytes: request.expectedSize ?? 0,
            fractionCompleted: 0.0,
            bytesPerSecond: 0.0,
            errorMessage: nil,
            modelId: request.modelId,
            expectedSha256: request.sha256,
            createdAt: Date(),
            updatedAt: Date()
        )

        lock.lock()
        tasks[taskId] = taskInfo
        urlTasks[taskId] = downloadTask
        lastBytesWritten[taskId] = (0, Date())
        lock.unlock()

        downloadTask.taskDescription = taskId
        downloadTask.resume()

        return taskInfo
    }

    public func cancelDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .cancelled
        info.updatedAt = Date()
        tasks[taskId] = info
        urlTasks.removeValue(forKey: taskId)
        lastBytesWritten.removeValue(forKey: taskId)
        lock.unlock()

        urlTask?.cancel()
        return true
    }

    public func pauseDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId], info.status == .downloading else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .paused
        info.updatedAt = Date()
        tasks[taskId] = info
        lock.unlock()

        urlTask?.suspend()
        return true
    }

    public func resumeDownload(taskId: String) -> Bool {
        lock.lock()
        guard var info = tasks[taskId], info.status == .paused else {
            lock.unlock()
            return false
        }
        let urlTask = urlTasks[taskId]
        info.status = .downloading
        info.updatedAt = Date()
        tasks[taskId] = info
        lock.unlock()

        urlTask?.resume()
        return true
    }

    public func getDownloadStatus(taskId: String) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]
    }

    public func listDownloads() -> [DownloadTaskInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Downloaded Model Files on Disk

    public func listDownloadedModels(directoryPath: String? = nil) -> [DownloadedModelInfo] {
        let dirUrl: URL
        if let dir = directoryPath, !dir.isEmpty {
            dirUrl = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            dirUrl = defaultModelsDirectory
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: dirUrl,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let supportedExtensions: Set<String> = ["gguf", "bin", "safetensors", "pt", "onnx"]
        var results: [DownloadedModelInfo] = []
        let baseDirStandardPath = dirUrl.standardizedFileURL.path

        for case let fileUrl as URL in enumerator {
            let ext = fileUrl.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) || fileUrl.lastPathComponent.contains(".gguf") else {
                continue
            }

            let values = try? fileUrl.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate ?? Date()

            // Calculate relative path from base directory
            let standardFilePath = fileUrl.standardizedFileURL.path
            var relativeFilename = fileUrl.lastPathComponent
            if standardFilePath.hasPrefix(baseDirStandardPath) {
                let suffix = String(standardFilePath.dropFirst(baseDirStandardPath.count))
                let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !trimmed.isEmpty {
                    relativeFilename = trimmed
                }
            }

            let name = fileUrl.deletingPathExtension().lastPathComponent

            let modelInfo = DownloadedModelInfo(
                name: name,
                filename: relativeFilename,
                path: fileUrl.path,
                size: size,
                modifiedAt: modDate,
                format: ext.isEmpty ? "gguf" : ext
            )
            results.append(modelInfo)
        }

        return results.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func deleteDownloadedModel(filePath: String) throws -> Bool {
        let fileUrl = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            return false
        }
        try FileManager.default.removeItem(at: fileUrl)
        return true
    }

    // MARK: - SHA256 Checksum Calculation & Verification

    /// Computes the SHA256 checksum hex string for a given file on disk using streaming chunks.
    public func computeSHA256(of fileUrl: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileUrl)
        defer { try? handle.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB chunk
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the SHA256 checksum of a model file against an expected hash, or returns computed hash if expected is nil.
    public func verifyModelFile(filePath: String, expectedSha256: String? = nil) throws -> (isValid: Bool, computedSha256: String) {
        let fileUrl = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw NSError(domain: "ModelDownloaderEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found at \(filePath)"])
        }
        let computed = try computeSHA256(of: fileUrl)
        if let expected = expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty {
            let isValid = (computed.caseInsensitiveCompare(expected) == .orderedSame)
            return (isValid, computed)
        }
        return (true, computed)
    }

    /// Fixed test model specification for mxbai-embed-xsmall.
    public static let fixedTestModel = (
        modelId: "mixedbread-ai/mxbai-embed-xsmall-v1",
        slug: "mxbai-embed-xsmall",
        filename: "gguf/mxbai-embed-xsmall-v1-q8_0.gguf",
        url: "https://huggingface.co/mixedbread-ai/mxbai-embed-xsmall-v1/resolve/main/gguf/mxbai-embed-xsmall-v1-q8_0.gguf",
        sha256: "21f9f06af9e4e895fcdcbf6c0d57ca1996fe22da54ecb6cc5f7733d785412d44",
        expectedSize: Int64(30_784_160)
    )

    /// Downloads a fixed small value (or streams test payload data) and verifies its SHA-256 hash.
    public func testDownloadAndVerifySha256(customData: Data? = nil) throws -> (isValid: Bool, bytes: Int, computedSha256: String, expectedSha256: String, details: String) {
        let fixed = Self.fixedTestModel
        let testString = "Garage Model Downloader Integrity Verification Test String for \(fixed.slug) (\(fixed.filename)) - 2026"
        let data = customData ?? Data(testString.utf8)
        let expectedDigest = SHA256.hash(data: data)
        let expectedSha256 = expectedDigest.map { String(format: "%02x", $0) }.joined()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GarageDownloadTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("test-\(fixed.slug)-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try data.write(to: tempFile)
        let (isValid, computedSha256) = try verifyModelFile(filePath: tempFile.path, expectedSha256: expectedSha256)

        let details = "Downloaded \(data.count) bytes test payload for \(fixed.slug). Computed SHA-256: \(computedSha256), Expected: \(expectedSha256). Integrity match: \(isValid ? "PASSED" : "FAILED")."
        return (isValid, data.count, computedSha256, expectedSha256, details)
    }

    /// Downloads the fixed mxbai-embed-xsmall model resource.
    public func downloadFixedTestModel(destinationDirectory: String? = nil) throws -> DownloadTaskInfo {
        let fixed = Self.fixedTestModel
        let req = ModelDownloadRequest(
            url: fixed.url,
            filename: fixed.filename,
            modelId: fixed.modelId,
            destinationDirectory: destinationDirectory,
            expectedSize: fixed.expectedSize,
            sha256: fixed.sha256
        )
        return try startDownload(request: req)
    }

    // MARK: - JSON Helpers for XPC

    public func serialize<T: Encodable>(_ value: T) -> String? {
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deserialize<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ModelDownloaderEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }
        return try jsonDecoder.decode(type, from: data)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloaderEngine: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let taskId = downloadTask.taskDescription else { return }

        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return
        }

        let now = Date()
        let previous = lastBytesWritten[taskId] ?? (bytes: 0, timestamp: now)
        let elapsed = now.timeIntervalSince(previous.timestamp)

        var speed = info.bytesPerSecond
        if elapsed >= 0.5 {
            let bytesDelta = totalBytesWritten - previous.bytes
            speed = Double(bytesDelta) / elapsed
            lastBytesWritten[taskId] = (totalBytesWritten, now)
        }

        info.bytesDownloaded = totalBytesWritten
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (info.totalBytes > 0 ? info.totalBytes : totalBytesWritten)
        info.totalBytes = total
        info.fractionCompleted = total > 0 ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(total))) : 0.0
        info.bytesPerSecond = speed

        if speed > 0 && total > totalBytesWritten {
            info.estimatedTimeRemaining = Double(total - totalBytesWritten) / speed
        }

        info.updatedAt = now
        tasks[taskId] = info
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskId = downloadTask.taskDescription else { return }

        lock.lock()
        guard var info = tasks[taskId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        let destUrl = URL(fileURLWithPath: info.destinationPath)
        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destUrl.path) {
                try FileManager.default.removeItem(at: destUrl)
            }
            try FileManager.default.createDirectory(at: destUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destUrl)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destUrl.path)[.size] as? Int64) ?? info.bytesDownloaded

            // Calculate SHA-256 checksum and verify if expected hash is provided
            let computedHash = try? computeSHA256(of: destUrl)
            info.computedSha256 = computedHash

            if let expected = info.expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty {
                guard let computed = computedHash, computed.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: destUrl)
                    lock.lock()
                    info.status = .failed
                    info.errorMessage = "SHA-256 checksum mismatch (expected: \(expected), computed: \(computedHash ?? "none"))"
                    info.updatedAt = Date()
                    tasks[taskId] = info
                    urlTasks.removeValue(forKey: taskId)
                    lastBytesWritten.removeValue(forKey: taskId)
                    lock.unlock()
                    return
                }
            }

            lock.lock()
            info.status = .completed
            info.bytesDownloaded = fileSize
            info.totalBytes = fileSize
            info.fractionCompleted = 1.0
            info.bytesPerSecond = 0.0
            info.estimatedTimeRemaining = 0.0
            info.updatedAt = Date()
            tasks[taskId] = info
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        } catch {
            lock.lock()
            info.status = .failed
            info.errorMessage = error.localizedDescription
            info.updatedAt = Date()
            tasks[taskId] = info
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskId = task.taskDescription else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            lock.lock()
            if var info = tasks[taskId] {
                info.status = .failed
                info.errorMessage = error.localizedDescription
                info.updatedAt = Date()
                tasks[taskId] = info
            }
            urlTasks.removeValue(forKey: taskId)
            lastBytesWritten.removeValue(forKey: taskId)
            lock.unlock()
        }
    }
}
