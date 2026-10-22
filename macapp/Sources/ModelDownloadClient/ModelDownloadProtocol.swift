import Foundation
import PythonXPCService_protocol

/// Objective-C compatible protocol for the ModelDownload XPC Service.
@objc(ModelDownloadXPCServiceProtocol)
public protocol ModelDownloadXPCServiceProtocol: GarageCommonXPCServiceProtocol {
    /// Start a download with JSON-encoded request.
    func startDownload(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Cancel an active or queued download.
    func cancelDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void)

    /// Pause an active download.
    func pauseDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void)

    /// Resume a paused download.
    func resumeDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void)

    /// Get current status for a specific download task.
    func getDownloadStatus(taskId: String, with reply: @escaping (String?, Error?) -> Void)

    /// List all download tasks (active, completed, failed, cancelled).
    func listDownloads(with reply: @escaping (String?, Error?) -> Void)

    /// List all model files found in the models directory.
    func listDownloadedModels(directoryPath: String?, with reply: @escaping (String?, Error?) -> Void)

    /// Delete a downloaded model file from disk.
    func deleteDownloadedModel(filePath: String, with reply: @escaping (Bool, Error?) -> Void)

    /// Get the default models directory path.
    func getModelsDirectory(with reply: @escaping (String) -> Void)

    /// Set a custom models directory path.
    func setModelsDirectory(path: String, with reply: @escaping (Bool, Error?) -> Void)

    /// Verify the SHA256 checksum of a model file on disk.
    func verifyModelFile(filePath: String, expectedSha256: String?, with reply: @escaping (Bool, String?, Error?) -> Void)

    /// Download a fixed small test value and verify its SHA256 checksum.
    func testDownloadAndVerifySha256(with reply: @escaping (Bool, String?, Error?) -> Void)

    /// Download the fixed mxbai-embed-xsmall test model resource.
    func downloadFixedTestModel(destinationDirectory: String?, with reply: @escaping (String?, Error?) -> Void)
}
