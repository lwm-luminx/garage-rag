import Foundation

/// Represents the current status of a download task.
public enum DownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// Request to initiate downloading a model file.
public struct ModelDownloadRequest: Codable, Sendable {
    /// Remote URL of the model to download (or Hugging Face resolve URL).
    public var url: String
    /// Optional target filename (if nil, extracted from URL).
    public var filename: String?
    /// Optional logical model identifier / alias.
    public var modelId: String?
    /// Optional destination directory path.
    public var destinationDirectory: String?
    /// Optional expected size in bytes.
    public var expectedSize: Int64?
    /// Optional expected SHA256 checksum for verification.
    public var sha256: String?
    /// Optional Authorization header token (e.g. HuggingFace token).
    public var authToken: String?

    public init(
        url: String,
        filename: String? = nil,
        modelId: String? = nil,
        destinationDirectory: String? = nil,
        expectedSize: Int64? = nil,
        sha256: String? = nil,
        authToken: String? = nil
    ) {
        self.url = url
        self.filename = filename
        self.modelId = modelId
        self.destinationDirectory = destinationDirectory
        self.expectedSize = expectedSize
        self.sha256 = sha256
        self.authToken = authToken
    }
}

/// Information and progress of an individual download task.
public struct DownloadTaskInfo: Codable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var filename: String
    public var destinationPath: String
    public var status: DownloadStatus
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var fractionCompleted: Double
    public var bytesPerSecond: Double
    public var estimatedTimeRemaining: TimeInterval?
    public var errorMessage: String?
    public var modelId: String?
    public var expectedSha256: String?
    public var computedSha256: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        url: String,
        filename: String,
        destinationPath: String,
        status: DownloadStatus = .queued,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        fractionCompleted: Double = 0.0,
        bytesPerSecond: Double = 0.0,
        estimatedTimeRemaining: TimeInterval? = nil,
        errorMessage: String? = nil,
        modelId: String? = nil,
        expectedSha256: String? = nil,
        computedSha256: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.destinationPath = destinationPath
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.fractionCompleted = fractionCompleted
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.errorMessage = errorMessage
        self.modelId = modelId
        self.expectedSha256 = expectedSha256
        self.computedSha256 = computedSha256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var formattedProgress: String {
        let downloadedStr = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let percent = Int(fractionCompleted * 100)
            return "\(downloadedStr) / \(totalStr) (\(percent)%)"
        } else {
            return downloadedStr
        }
    }

    public var formattedSpeed: String {
        guard status == .downloading, bytesPerSecond > 0 else { return "" }
        let speedStr = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(speedStr)/s"
    }

    public var formattedETA: String {
        guard status == .downloading, let eta = estimatedTimeRemaining, eta > 0, eta < 86400 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: eta) ?? ""
    }
}

/// Metadata describing a model already downloaded and stored locally.
public struct DownloadedModelInfo: Codable, Identifiable, Sendable {
    public var id: String { path }
    public var name: String
    public var filename: String
    public var path: String
    public var size: Int64
    public var formattedSize: String
    public var modifiedAt: Date
    public var format: String
    public var sha256: String?

    public init(
        name: String,
        filename: String,
        path: String,
        size: Int64,
        modifiedAt: Date = Date(),
        format: String = "gguf",
        sha256: String? = nil
    ) {
        self.name = name
        self.filename = filename
        self.path = path
        self.size = size
        self.formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        self.modifiedAt = modifiedAt
        self.format = format
        self.sha256 = sha256
    }
}
