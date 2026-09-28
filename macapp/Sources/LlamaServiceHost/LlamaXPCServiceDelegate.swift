import Foundation
import Darwin
import OSLog
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.llama-xpc", category: "LlamaXPCService")

extension LlamaInferenceEngine {
    /// Aliases of every resident model, from the engine's `/v1/models` listing.
    var residentAliases: [String] {
        (handleModels()["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

/// Presents an inference engine to the host as a managed service. Models are loaded and unloaded
/// directly through the XPC/HTTP routes (several can be resident at once), so `start()` has nothing
/// to do and `stop()` simply unloads everything at shutdown.
final class LlamaEngineManagedService: GarageManagedService {
    let name = "llama-engine"
    private let engine: any LlamaInferenceEngine

    init(engine: any LlamaInferenceEngine) {
        self.engine = engine
    }

    var isRunning: Bool {
        engine.currentModelPath != nil
    }

    func start() throws {
        let aliases = engine.residentAliases
        if aliases.isEmpty {
            logger.info("llama-engine ready; no model loaded yet")
        } else {
            logger.info("llama-engine ready with \(aliases.joined(separator: ", "), privacy: .public)")
        }
    }

    func stop(graceful: Bool) throws {
        guard engine.currentModelPath != nil else { return }
        _ = engine.unloadModel()
        logger.info("llama-engine unloaded all models (graceful: \(graceful, privacy: .public))")
    }
}

/// The llama-server HTTP listener as a managed service: up for the lifetime of the helper, independent
/// of whether a model is loaded (so `/health` can say "no_model_loaded"). The Python `llama_xpc`
/// provider talks to it, on its socket in the App Group folder (`GarageSockets`) or, failing that,
/// on loopback; the app keeps using XPC.
final class LlamaHTTPManagedService: GarageManagedService {
    let name = "llama-http"
    let server: LlamaHTTPServer

    init(server: LlamaHTTPServer) {
        self.server = server
    }

    var isRunning: Bool { server.isListening }

    func start() throws {
        do {
            try server.start()
        } catch {
            throw GarageXPCServiceError.notRunning(error.localizedDescription)
        }
        logger.info("llama HTTP API listening on \(self.server.url, privacy: .public)")
        GarageXPCOutputCapture.shared.log(message: "llama HTTP API listening on \(server.url)")
    }

    func stop(graceful: Bool) throws {
        server.stop()
    }
}

/// The LlamaXPCService process: NSXPC for the app and the llama-server HTTP API (on a socket, or a
/// loopback port) for the Python side, both in front of one `LlamaInferenceEngine`.
///
/// The shipped service (`//macapp/Sources/LlamaXPCService`) runs it on `LlamaCppEngine`; the UI
/// tests' `MockLlamaXPCService` runs it on a deterministic test engine under the same bundle
/// identifier, so everything in front of the engine is the code that ships.
public final class LlamaXPCServiceDelegate: GarageXPCServiceBase, LlamaXPCServiceProtocol {
    private let engine: any LlamaInferenceEngine
    private let engineService: LlamaEngineManagedService
    private let httpService: LlamaHTTPManagedService
    private let engineSelfTests: [GarageXPCSelfTest]

    /// Where the HTTP listener serves, e.g. `unix:/path/s/llama` or `http://127.0.0.1:8790`.
    public var httpURL: String { httpService.server.url }

    /// `httpPort` is used only when `socketPath` is nil. The defaults are what the shipped service
    /// does: the socket `GarageSockets` names unless `GARAGE_LLAMA_HTTP_PORT` asks for a port.
    /// `engineSelfTests` run after the front end's own: tests only one engine can pass (the shipped
    /// service's "Embedding Known Answers", on LlamaCppEngine) come from the service that picks it.
    public init(
        engine: any LlamaInferenceEngine,
        httpPort: UInt16? = LlamaXPCServiceDelegate.configuredHTTPPort(),
        socketPath: String? = LlamaXPCServiceDelegate.configuredSocketPath(),
        engineSelfTests: [GarageXPCSelfTest] = []
    ) {
        self.engine = engine
        self.engineSelfTests = engineSelfTests
        self.engineService = LlamaEngineManagedService(engine: engine)
        self.httpService = LlamaHTTPManagedService(server: LlamaHTTPServer(
            engine: engine,
            port: httpPort ?? LlamaXPCConstants.defaultHTTPPort,
            socketPath: socketPath
        ))
        super.init(
            serviceName: "LlamaXPCService",
            logFileName: "llama-xpc.log",
            usesPython: false
        )
    }

    /// `GARAGE_LLAMA_HTTP_PORT` puts the listener on that loopback port instead of the socket, for
    /// tools that cannot use a socket, or so two builds can coexist on one machine.
    public static func configuredHTTPPort() -> UInt16? {
        if let raw = ProcessInfo.processInfo.environment["GARAGE_LLAMA_HTTP_PORT"], let port = UInt16(raw), port > 0 {
            return port
        }
        return nil
    }

    /// The socket the Python side finds through `GARAGE_LLAMA_SOCKET` (`GarageSockets`), unless a port
    /// was asked for or the path is too long to bind.
    public static func configuredSocketPath() -> String? {
        configuredHTTPPort() == nil ? GarageSockets.path(for: GarageSockets.llamaName) : nil
    }

    public override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: LlamaXPCServiceProtocol.self)
    }

    public override func additionalSelfTests() -> [GarageXPCSelfTest] {
        let engine = self.engine
        let server = self.httpService.server
        return [
            GarageXPCSelfTest(name: "Llama Engine", description: "Queries the llama.cpp engine health route and reports the loaded model.", requiresPython: false) {
                let health = engine.handleHealth()
                guard let status = health["status"] as? String else {
                    throw GarageXPCSelfTestFailure("Llama engine health returned no status", details: String(describing: health))
                }
                let props = engine.handleProps()
                let model = engine.currentModelPath ?? "none"
                let desc = (props["model_description"] as? String) ?? ""
                return "Status: \(status)\nModel: \(model)\n\(desc)"
            },
            GarageXPCSelfTest(name: "Model File", description: "Verifies the currently loaded model path exists on disk.", requiresPython: false) {
                guard let path = engine.currentModelPath else {
                    throw GarageXPCSelfTestSkipped("No model loaded")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw GarageXPCSelfTestFailure("Loaded model file is missing: \(path)")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                return "Model: \(path)\nSize: \(size) bytes"
            },
            GarageXPCSelfTest(name: "HTTP API", description: "Reports whether the llama-server API is listening on its socket (or loopback port).", requiresPython: false) {
                guard server.isListening else {
                    throw GarageXPCSelfTestFailure("llama HTTP API is not listening on \(server.url)")
                }
                return "Listening on \(server.url)"
            },
        ] + engineSelfTests
    }

    public override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(httpService)
        host.register(engineService)
    }

    // MARK: - LlamaXPCServiceProtocol

    private func reply(_ route: String, _ reply: @escaping (String?, Error?) -> Void, _ body: () throws -> [String: Any]) {
        do {
            reply(engine.serializeJson(try body()), nil)
        } catch {
            logger.error("\(route, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    public func health(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleHealth()), nil)
    }

    public func props(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleProps()), nil)
    }

    public func models(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleModels()), nil)
    }

    public func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("completion", reply) { try engine.handleCompletion(jsonString: requestJson) }
    }

    public func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("chatCompletion", reply) { try engine.handleChatCompletion(jsonString: requestJson) }
    }

    public func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("embeddings", reply) { try engine.handleEmbeddings(jsonString: requestJson) }
    }

    public func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("tokenize", reply) { try engine.handleTokenize(jsonString: requestJson) }
    }

    public func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("detokenize", reply) { try engine.handleDetokenize(jsonString: requestJson) }
    }

    public func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("rerank", reply) { try engine.handleRerank(jsonString: requestJson) }
    }

    public func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("infill", reply) { try engine.handleInfill(jsonString: requestJson) }
    }

    public func slots(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleSlots()), nil)
    }

    public func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("slotAction", reply) { try engine.handleSlotAction(slotId: slotId, action: action, jsonString: requestJson) }
    }

    public func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void) {
        let result = engine.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        reply(result.statusCode, result.responseBody, nil)
    }

    public func loadModel(modelPath: String, alias: String?, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        logger.info("Loading model from path: \(modelPath, privacy: .public), alias: \(alias ?? "none", privacy: .public)")
        // Loading blocks for seconds; keep the XPC thread free and answer when the engine is done.
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            let result = engine.loadModel(path: modelPath, alias: alias, configJson: configJson)
            if result.success {
                GarageXPCOutputCapture.shared.log(message: "llama-engine loaded \(modelPath)")
            } else {
                logger.error("Failed to load model: \(result.message, privacy: .public)")
            }
            reply(result.success, result.message, nil)
        }
    }

    public func ensureModel(modelPath: String, alias: String, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        logger.info("Ensuring model \(alias, privacy: .public) (\(modelPath, privacy: .public))")
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            let alreadyLoaded = engine.residentAliases.contains(alias)
            let result = engine.ensureModel(path: modelPath, alias: alias, configJson: configJson)
            if !result.success {
                logger.error("Failed to load model on demand: \(result.message, privacy: .public)")
            } else if !alreadyLoaded {
                GarageXPCOutputCapture.shared.log(message: "llama-engine loaded \(alias) on demand from \(modelPath)")
            }
            reply(result.success, result.message, nil)
        }
    }

    public func getListenerEndpoint(with reply: @escaping (NSXPCListenerEndpoint?, Error?) -> Void) {
        let endpoint = anonymousListenerEndpoint()
        logger.info("Handing out the anonymous listener endpoint")
        reply(endpoint, nil)
    }

    public func unloadModel(with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Unloading all models")
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            reply(engine.unloadModel(), nil)
        }
    }
}
