import EmbedClient
import Foundation
import GarageEmbedWorker
import GarageXPCKit
import ImageEmbedBridge
import LlamaModelLoader
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.embed-xpc", category: "GarageEmbedXPCService")

/// The embed helper: runs the Rust embed worker (`rust/garage-embed`), which embeds the chunks each
/// model has no vectors for. It links no Python.
///
/// - The database is reached only through GarageService, at the address and with the per-launch
///   token the app configured (`updateConfiguration`), and the provider settings are the backend's
///   own (`embedding.*` through `GetSetting`).
/// - llama_xpc models are reached over NSXPC through the LlamaXPCService endpoint the app hands this
///   process, and loaded on demand; image models through the GarageImageEmbedXPCService endpoint.
/// - Ollama and LM Studio are reached over HTTP, only at the origins the worker's egress rules allow.
///
/// The sandboxed (App Store) app hosts it in its own process (`InProcessServiceHost`), because image
/// models read the image files the user granted, which only the app can read.
final class GarageEmbedXPCServiceDelegate: GarageXPCServiceBase, GarageEmbedXPCServiceProtocol {
    /// A backfill runs for minutes; keep it off the XPC listener thread. One at a time.
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.embed.worker", qos: .userInitiated)

    private let runLock = NSLock()
    private var isBackfilling = false
    private var cancelRequested = false

    init() {
        super.init(serviceName: "GarageEmbedXPCService", logFileName: "embed-xpc.log")
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
    }

    /// A client that asks for a backfill hears its steps over its own connection.
    override func didAcceptConnection(_ connection: NSXPCConnection) {
        connection.remoteObjectInterface = NSXPCInterface(with: GarageEmbedProgressReceiverProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCSelfTest(
                name: "Embed Worker",
                description: "The Rust embed worker is linked into this process and answers (an embedding with no provider must be refused)."
            ) {
                switch GarageEmbedWorker.embedTexts(provider: "none", modelRef: "none", texts: ["self test"], host: GarageEmbedWorkerHost()) {
                case .failure(let failure) where failure.kind == .failed:
                    return "Linked; refused as expected: \(failure.message)"
                case .failure(let failure):
                    throw GarageXPCSelfTestFailure("The embed worker failed unexpectedly", details: failure.message)
                case .success:
                    throw GarageXPCSelfTestFailure("The embed worker embedded with an unknown provider")
                }
            },
            GarageXPCSelfTest(
                name: "gRPC Connection",
                description: "The embed worker reaches GarageService (its socket, or host and port) with the app's token and lists the registered models."
            ) { [weak self] in
                guard let self, let target = self.grpc else {
                    throw GarageXPCSelfTestSkipped("GARAGE_GRPC_SOCKET / GARAGE_GRPC_PORT are not configured")
                }
                let token = self.configurationValue(GarageXPCConfigurationKey.grpcToken)
                switch GarageEmbedWorker.models(grpc: target, token: token, host: GarageEmbedWorkerHost()) {
                case .success(let models):
                    let names = models.map { "\($0.slug) (\($0.provider), \($0.dims) dims)" }
                    return "Target: \(Self.describe(target))\nModels: \(names.isEmpty ? "none registered" : names.joined(separator: ", "))"
                case .failure(let failure):
                    throw GarageXPCSelfTestFailure("GarageService at \(Self.describe(target)) did not answer", details: failure.message)
                }
            },
            LlamaEndpointSelfTest.make(),
            ImageEmbedAccess.selfTest(),
        ]
    }

    /// GarageService's address from the configuration: its socket wins over host and port.
    private var grpc: GarageEmbedWorker.GRPCTarget? {
        if let socket = configurationValue(GarageXPCConfigurationKey.grpcSocket), !socket.isEmpty {
            return .socket(socket)
        }
        guard let portText = configurationValue(GarageXPCConfigurationKey.grpcPort), let port = Int(portText), port > 0 else {
            return nil
        }
        return .tcp(host: configurationValue(GarageXPCConfigurationKey.grpcHost) ?? "127.0.0.1", port: port)
    }

    private static func describe(_ target: GarageEmbedWorker.GRPCTarget) -> String {
        switch target {
        case .socket(let path): return "unix:\(path)"
        case .tcp(let host, let port): return "\(host):\(port)"
        }
    }

    // MARK: - GarageEmbedXPCServiceProtocol

    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void) {
        let sample = texts.isEmpty ? ["Garage local retrieval-augmented generation test."] : texts
        let target = model ?? "llama_xpc:mxbai-embed-xsmall"
        let (provider, modelRef): (String, String)
        if let colon = target.firstIndex(of: ":") {
            (provider, modelRef) = (String(target[..<colon]), String(target[target.index(after: colon)...]))
        } else {
            (provider, modelRef) = ("llama_xpc", target)
        }
        logger.info("embedTexts requested (\(sample.count, privacy: .public) text(s), \(provider, privacy: .public):\(modelRef, privacy: .public))")
        Self.workerQueue.async {
            switch GarageEmbedWorker.embedTexts(provider: provider, modelRef: modelRef, texts: sample, host: GarageEmbedWorkerHost()) {
            case .success(let vectors):
                reply(true, "Embedded \(sample.count) text(s) with provider '\(provider)' and model '\(modelRef)' successfully. Generated \(vectors.count) vector(s) of dimension \(vectors.first?.count ?? 0).")
            case .failure(let failure):
                logger.error("Embed failed: \(failure.message, privacy: .public)")
                reply(false, "Embed execution failed: \(failure.message)")
            }
        }
    }

    func backfill(requestJson: String, with reply: @escaping (String) -> Void) {
        let receiver = NSXPCConnection.current()?.remoteObjectProxyWithErrorHandler { _ in } as? GarageEmbedProgressReceiverProtocol
        let request: EmbedBackfillRequest
        do {
            request = try JSONDecoder().decode(EmbedBackfillRequest.self, from: Data(requestJson.utf8))
        } catch {
            reply(Self.encode(EmbedBackfillReply(status: .failed, error: "The backfill request did not decode: \(error.localizedDescription)")))
            return
        }
        guard let target = grpc else {
            reply(Self.encode(EmbedBackfillReply(status: .failed, error: "The app has not told the embed service where GarageService listens yet")))
            return
        }
        runLock.lock()
        if isBackfilling {
            runLock.unlock()
            reply(Self.encode(EmbedBackfillReply(status: .busy, error: "A backfill is already running")))
            return
        }
        isBackfilling = true
        cancelRequested = false
        runLock.unlock()

        let token = configurationValue(GarageXPCConfigurationKey.grpcToken)
        let workerRequest = GarageEmbedWorker.BackfillRequest(
            grpc: target,
            token: token,
            model: request.model,
            batchSize: request.batchSize,
            limit: request.limit,
            skipVerify: request.skipVerify,
            lmStudioAPIToken: configurationValue("GARAGE_LMSTUDIO_API_TOKEN")
        )
        let host = GarageEmbedWorkerHost(
            progress: { event in
                let forwarded = EmbedBackfillEvent(
                    modelSlug: event.modelSlug,
                    phase: event.phase,
                    total: event.total,
                    embedded: event.embedded,
                    failed: event.failed,
                    remaining: event.remaining,
                    batches: event.batches,
                    message: event.message
                )
                if !event.message.isEmpty {
                    GarageXPCOutputCapture.shared.log(message: event.message)
                }
                receiver?.didUpdateBackfill(eventJson: Self.encode(forwarded))
            },
            isCancelled: { [weak self] in self?.isCancelRequested ?? true }
        )
        logger.info("Backfill requested (model: \(request.model ?? "every model", privacy: .public))")
        Self.workerQueue.async { [self] in
            let result = GarageEmbedWorker.backfill(workerRequest, host: host)
            runLock.lock()
            isBackfilling = false
            runLock.unlock()
            switch result {
            case .success(let outcomes):
                let events = outcomes.map {
                    EmbedBackfillEvent(
                        modelSlug: $0.modelSlug,
                        phase: $0.phase,
                        total: $0.total,
                        embedded: $0.embedded,
                        failed: $0.failed,
                        remaining: $0.remaining,
                        batches: $0.batches,
                        message: $0.message
                    )
                }
                reply(Self.encode(EmbedBackfillReply(status: .ok, outcomes: events)))
            case .failure(let failure):
                let status: EmbedBackfillReply.Status
                switch failure.kind {
                case .notFound: status = .notFound
                case .cancelled: status = .cancelled
                default: status = .failed
                }
                logger.error("Backfill stopped: \(failure.message, privacy: .public)")
                GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Backfill stopped: \(failure.message)")
                reply(Self.encode(EmbedBackfillReply(status: status, error: failure.message)))
            }
        }
    }

    func cancelBackfill(with reply: @escaping (Bool) -> Void) {
        runLock.lock()
        let running = isBackfilling
        if running {
            cancelRequested = true
        }
        runLock.unlock()
        reply(running)
    }

    private var isCancelRequested: Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return cancelRequested
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "{\"status\": \"failed\", \"error\": \"the reply could not be encoded\"}"
    }
}

/// Makes the service's delegate, for its own process (`main.swift`) or the sandboxed app's
/// (`InProcessServiceHost`).
public func makeGarageEmbedXPCServiceDelegate() -> GarageXPCServiceBase {
    GarageEmbedXPCServiceDelegate()
}
