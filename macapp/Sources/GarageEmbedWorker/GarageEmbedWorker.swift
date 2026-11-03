import Foundation
import GarageEmbedFFI

/// Garage's embed worker, written in Rust and linked into this process through its C ABI
/// (`rust/garage-embed-ffi`, `garage_embed.h`).
///
/// The worker reaches the database only through GarageService (`GetEmbeddingBatches`,
/// `UpdateEmbeddings`, `BackfillDistilled`), on its socket and with the app's per-launch token, and
/// the model servers only through its host (`GarageEmbedWorkerHost`), after its own egress rules
/// approved each request. Every call blocks the calling thread until the worker is done, and the
/// host's callbacks run on that thread, so call it from a dispatch queue, never from a task.
public enum GarageEmbedWorker {
    /// Where GarageService listens: its Unix-domain socket (`GARAGE_GRPC_SOCKET`) or a TCP port.
    public enum GRPCTarget: Sendable, Equatable {
        case socket(String)
        case tcp(host: String, port: Int)
    }

    /// One step of a backfill, a `BackfillStatus` field for field: `complete`, `skipped`, `started`,
    /// `progress` or `finished`, with the model's counts and the message the CLI prints.
    public struct Event: Decodable, Sendable, Equatable {
        public let modelSlug: String
        public let phase: String
        public let total: Int
        public let embedded: Int
        public let failed: Int
        public let remaining: Int
        public let batches: Int
        public let message: String

        public init(modelSlug: String, phase: String, total: Int, embedded: Int, failed: Int, remaining: Int, batches: Int, message: String) {
            self.modelSlug = modelSlug
            self.phase = phase
            self.total = total
            self.embedded = embedded
            self.failed = failed
            self.remaining = remaining
            self.batches = batches
            self.message = message
        }

        enum CodingKeys: String, CodingKey {
            case modelSlug = "model_slug"
            case phase, total, embedded, failed, remaining, batches, message
        }
    }

    /// A call that did not succeed, with the worker's status (`GARAGE_EMBED_*`) and reason.
    public struct Failure: Error, LocalizedError, Equatable, Sendable {
        public enum Kind: Int32, Sendable {
            case badRequest = 1
            case panic = 2
            case failed = 3
            case notFound = 4
            case cancelled = 5
            case unknown = -1
        }

        public let kind: Kind
        public let message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// What to embed. The provider settings are always the backend's own (`embedding.*` through
    /// `GetSetting`), so the worker sends to exactly the servers the Python backend would.
    public struct BackfillRequest: Sendable, Equatable {
        public var grpc: GRPCTarget
        /// The app's per-launch token (`GARAGE_GRPC_TOKEN`). A secret: never logged.
        public var token: String?
        /// One model's slug, or every registered model when nil.
        public var model: String?
        public var batchSize: Int?
        public var limit: Int?
        public var skipVerify: Bool
        /// LM Studio's token, which the app keeps in its Keychain (`GARAGE_LMSTUDIO_API_TOKEN`).
        /// A secret: never logged.
        public var lmStudioAPIToken: String?

        public init(
            grpc: GRPCTarget,
            token: String?,
            model: String? = nil,
            batchSize: Int? = nil,
            limit: Int? = nil,
            skipVerify: Bool = false,
            lmStudioAPIToken: String? = nil
        ) {
            self.grpc = grpc
            self.token = token
            self.lmStudioAPIToken = lmStudioAPIToken
            self.model = model
            self.batchSize = batchSize
            self.limit = limit
            self.skipVerify = skipVerify
        }

        var json: [String: Any] {
            var grpcObject: [String: Any] = [:]
            switch grpc {
            case .socket(let path):
                grpcObject["socket"] = path
            case .tcp(let host, let port):
                grpcObject["host"] = host
                grpcObject["port"] = port
            }
            if let token, !token.isEmpty {
                grpcObject["token"] = token
            }
            var object: [String: Any] = ["grpc": grpcObject, "settings": "service", "skip_verify": skipVerify]
            if let model, !model.isEmpty, model != "*" {
                object["model"] = model
            }
            if let batchSize, batchSize > 0 {
                object["batch_size"] = batchSize
            }
            if let limit, limit > 0 {
                object["limit"] = limit
            }
            if let lmStudioAPIToken, !lmStudioAPIToken.isEmpty {
                object["lmstudio_api_token"] = lmStudioAPIToken
            }
            return object
        }
    }

    /// Embeds the chunks each model (or the one named) has no vectors for. `host.progress` hears
    /// every step; the result is each model's outcome (`complete`, `skipped` or `finished`).
    public static func backfill(_ request: BackfillRequest, host: GarageEmbedWorkerHost) -> Result<[Event], Failure> {
        run(garage_embed_backfill, request.json, host: host).flatMap { reply in
            struct Outcomes: Decodable { let outcomes: [Event] }
            do {
                return .success(try JSONDecoder().decode(Outcomes.self, from: reply).outcomes)
            } catch {
                return .failure(Failure(kind: .unknown, message: "the worker's result did not decode: \(error.localizedDescription)"))
            }
        }
    }

    /// Embeds a few texts with one provider and model (a self test or a diagnostic), with the
    /// default provider settings and `settings` over them (`ollama_host`, `lmstudio_host`, ...).
    public static func embedTexts(
        provider: String,
        modelRef: String,
        texts: [String],
        settings: [String: String] = [:],
        host: GarageEmbedWorkerHost
    ) -> Result<[[Float]], Failure> {
        let request: [String: Any] = ["provider": provider, "model_ref": modelRef, "texts": texts, "settings": settings]
        return run(garage_embed_texts, request, host: host).flatMap { reply in
            struct Vectors: Decodable { let vectors: [[Float]] }
            do {
                return .success(try JSONDecoder().decode(Vectors.self, from: reply).vectors)
            } catch {
                return .failure(Failure(kind: .unknown, message: "the worker's result did not decode: \(error.localizedDescription)"))
            }
        }
    }

    /// A model GarageService has registered.
    public struct Model: Decodable, Sendable, Equatable {
        public let slug: String
        public let provider: String
        public let modelRef: String
        public let dims: Int

        enum CodingKeys: String, CodingKey {
            case slug, provider, dims
            case modelRef = "model_ref"
        }
    }

    /// The models GarageService has registered, which also shows the worker reaches it with `token`.
    public static func models(grpc: GRPCTarget, token: String?, host: GarageEmbedWorkerHost) -> Result<[Model], Failure> {
        let request = BackfillRequest(grpc: grpc, token: token).json.filter { $0.key == "grpc" }
        return run(garage_embed_models, request, host: host).flatMap { reply in
            struct Models: Decodable { let models: [Model] }
            do {
                return .success(try JSONDecoder().decode(Models.self, from: reply).models)
            } catch {
                return .failure(Failure(kind: .unknown, message: "the worker's result did not decode: \(error.localizedDescription)"))
            }
        }
    }

    private typealias Entry = (
        UnsafePointer<CChar>?,
        UnsafePointer<GarageEmbedHost>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    /// Calls `entry` with `request` and `host`; the result's JSON, or the failure it reports.
    private static func run(_ entry: Entry, _ request: [String: Any], host: GarageEmbedWorkerHost) -> Result<Data, Failure> {
        guard let data = try? JSONSerialization.data(withJSONObject: request), let text = String(data: data, encoding: .utf8) else {
            return .failure(Failure(kind: .badRequest, message: "the request could not be encoded as JSON"))
        }
        var cHost = host.cHost
        var result: UnsafeMutablePointer<CChar>?
        let status = withExtendedLifetime(host) {
            text.withCString { entry($0, &cHost, &result) }
        }
        defer { garage_embed_string_free(result) }
        let reply = result.map { Data(String(cString: $0).utf8) } ?? Data()
        guard status == 0 else {
            let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            let message = object?["error"] as? String ?? String(decoding: reply, as: UTF8.self)
            return .failure(Failure(kind: Failure.Kind(rawValue: status) ?? .unknown, message: message))
        }
        return .success(reply)
    }
}
