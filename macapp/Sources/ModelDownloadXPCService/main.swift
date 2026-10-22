import Foundation
import Darwin
import OSLog
import ModelDownloadClient
import GarageXPCKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.model-download-xpc", category: "ModelDownloadXPCService")

final class ModelDownloadXPCServiceDelegate: GarageXPCServiceBase, ModelDownloadXPCServiceProtocol {
    private let engine = ModelDownloaderEngine.shared

    init() {
        super.init(
            serviceName: "ModelDownloadXPCService",
            logFileName: "model-download-xpc.log"
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: ModelDownloadXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        let engine = self.engine
        return [
            GarageXPCSelfTest(name: "Models Directory", description: "Models directory exists and is writable.", requiresPython: false) {
                let path = engine.getModelsDirectoryPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw GarageXPCSelfTestFailure("Models directory does not exist: \(path)")
                }
                let probe = URL(fileURLWithPath: path).appendingPathComponent(".write-probe-\(ProcessInfo.processInfo.processIdentifier)")
                do {
                    try "ok".write(to: probe, atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: probe)
                } catch {
                    throw GarageXPCSelfTestFailure("Models directory is not writable: \(path)", details: error.localizedDescription)
                }
                let models = engine.listDownloadedModels(directoryPath: nil)
                return "Models directory: \(path)\nDownloaded models: \(models.count)"
            },
            GarageXPCSelfTest(name: "Download Tasks", description: "Reports the state of the model downloader task queue.", requiresPython: false) {
                let downloads = engine.listDownloads()
                let active = downloads.filter { $0.status == .downloading }.count
                let paused = downloads.filter { $0.status == .paused }.count
                let failed = downloads.filter { $0.status == .failed }.count
                return "Total tasks: \(downloads.count), Active: \(active), Paused: \(paused), Failed: \(failed)"
            },
        ]
    }

    // MARK: - ModelDownloadXPCServiceProtocol

    func startDownload(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.info("Starting model download")
            let request = try engine.deserialize(ModelDownloadRequest.self, from: requestJson)
            let taskInfo = try engine.startDownload(request: request)
            logger.info("Download task started with ID: \(taskInfo.id, privacy: .public) for URL: \(taskInfo.url, privacy: .public)")
            let responseJson = engine.serialize(taskInfo)
            reply(responseJson, nil)
        } catch {
            logger.error("Failed to start download: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func cancelDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Canceling download task: \(taskId, privacy: .public)")
        let success = engine.cancelDownload(taskId: taskId)
        reply(success, nil)
    }

    func pauseDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Pausing download task: \(taskId, privacy: .public)")
        let success = engine.pauseDownload(taskId: taskId)
        reply(success, nil)
    }

    func resumeDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Resuming download task: \(taskId, privacy: .public)")
        let success = engine.resumeDownload(taskId: taskId)
        reply(success, nil)
    }

    func getDownloadStatus(taskId: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Getting download status for task: \(taskId, privacy: .public)")
        if let info = engine.getDownloadStatus(taskId: taskId), let json = engine.serialize(info) {
            reply(json, nil)
        } else {
            logger.warning("Download task not found: \(taskId, privacy: .public)")
            let error = NSError(domain: "ModelDownloadXPCService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Download task not found"])
            reply(nil, error)
        }
    }

    func listDownloads(with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Listing download tasks")
        let downloads = engine.listDownloads()
        let json = engine.serialize(downloads)
        reply(json, nil)
    }

    func listDownloadedModels(directoryPath: String?, with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Listing downloaded models in directory: \(directoryPath ?? "default", privacy: .public)")
        let models = engine.listDownloadedModels(directoryPath: directoryPath)
        let json = engine.serialize(models)
        reply(json, nil)
    }

    func deleteDownloadedModel(filePath: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            logger.info("Deleting downloaded model at path: \(filePath, privacy: .public)")
            let success = try engine.deleteDownloadedModel(filePath: filePath)
            reply(success, nil)
        } catch {
            logger.error("Failed to delete model at path \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, error)
        }
    }

    func getModelsDirectory(with reply: @escaping (String) -> Void) {
        let path = engine.getModelsDirectoryPath()
        logger.debug("Getting models directory: \(path, privacy: .public)")
        reply(path)
    }

    func setModelsDirectory(path: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            logger.info("Setting models directory to: \(path, privacy: .public)")
            try engine.setModelsDirectory(path: path)
            reply(true, nil)
        } catch {
            logger.error("Failed to set models directory to \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, error)
        }
    }

    func verifyModelFile(filePath: String, expectedSha256: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            logger.info("Verifying model file at path: \(filePath, privacy: .public)")
            let result = try engine.verifyModelFile(filePath: filePath, expectedSha256: expectedSha256)
            reply(result.isValid, result.computedSha256, nil)
        } catch {
            logger.error("Failed to verify model file at \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, nil, error)
        }
    }

    func testDownloadAndVerifySha256(with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            logger.info("Running test download and SHA256 verification")
            let testResult = try engine.testDownloadAndVerifySha256()
            reply(testResult.isValid, testResult.details, nil)
        } catch {
            logger.error("Test download and verification failed: \(error.localizedDescription, privacy: .public)")
            reply(false, nil, error)
        }
    }

    func downloadFixedTestModel(destinationDirectory: String?, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.info("Starting fixed test model download")
            let task = try engine.downloadFixedTestModel(destinationDirectory: destinationDirectory)
            let json = engine.serialize(task)
            reply(json, nil)
        } catch {
            logger.error("Fixed test model download failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }
}

// MARK: - Process Entry Point

let delegate = ModelDownloadXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
