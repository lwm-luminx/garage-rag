import Foundation
import OSLog
import IngestClient
import LlamaModelLoader
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.embed-xpc", category: "GarageEmbedXPCService")

final class GarageEmbedXPCServiceDelegate: GarageXPCServiceBase, GarageEmbedXPCServiceProtocol {
    /// Embedding work can take a long time; keep it off the XPC listener thread.
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.embed.worker", qos: .userInitiated)

    init() {
        super.init(
            serviceName: "GarageEmbedXPCService",
            logFileName: "embed-xpc.log",
            requiredPythonModules: ["grpc", "psycopg", "google.protobuf", "garage_rag"]
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCStandardSelfTests.serviceModule("garage_rag.embed", attributes: ["get_embedder", "embed_via_grpc"]),
            LlamaModelLoaderBridge.selfTest(),
        ]
    }

    /// Embeddings made here (`embedTexts`, `embed_via_grpc`) load their llama_xpc model on demand,
    /// through the LlamaXPCService endpoint the app hands this process (`setLlamaEndpoint`).
    override func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {
        LlamaModelLoaderBridge.install()
    }

    // MARK: - GarageEmbedXPCServiceProtocol

    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("embedTexts requested (\(texts.count, privacy: .public) text(s), model: \(model ?? "default", privacy: .public))")
        guard ensurePythonReady() else {
            reply(false, "Python initialization error: \(runtime.statusSnapshot().error ?? "unavailable")")
            return
        }
        Self.workerQueue.async { [self] in
            let result = withPython { () -> String in
                let sampleTexts = texts.isEmpty ? ["Garage local retrieval-augmented generation test."] : texts
                let embedModule = try Python.attemptImport("garage_rag.embed")
                var details = "Embed module loaded successfully."

                if embedModule.get_embedder != Python.None {
                    let targetModel = model ?? "llama_xpc:mxbai-embed-xsmall"
                    let provider: String
                    let modelRef: String
                    if let colonIdx = targetModel.firstIndex(of: ":") {
                        provider = String(targetModel[..<colonIdx])
                        modelRef = String(targetModel[targetModel.index(after: colonIdx)...])
                    } else {
                        provider = "llama_xpc"
                        modelRef = targetModel
                    }

                    let embedder = try embedModule.get_embedder.throwing.dynamicallyCall(withArguments: [provider, modelRef])
                    if embedder.embed != Python.None {
                        let pyTexts = PythonObject(sampleTexts)
                        let pyVectors = try embedder.embed.throwing.dynamicallyCall(withArguments: [pyTexts])
                        let count = Int(Python.len(pyVectors)) ?? 0
                        var dims = 0
                        if count > 0 {
                            dims = Int(Python.len(pyVectors[0])) ?? 0
                        }
                        details = "Embedded \(sampleTexts.count) text(s) with provider '\(provider)' and model '\(modelRef)' successfully. Generated \(count) vector(s) of dimension \(dims)."
                    }
                }
                return details
            }
            switch result {
            case .success(let details):
                reply(true, details)
            case .failure(let error):
                let errDetails = "Embed execution failed: \(error.localizedDescription)"
                logger.error("\(errDetails, privacy: .public)")
                reply(false, errDetails)
            }
        }
    }
}

// MARK: - Process Entry Point

let delegate = GarageEmbedXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
