import Foundation

/// The request surface every llama engine exposes, keyed to the llama-server HTTP protocol.
///
/// `LlamaXPCService` hosts the real engine (`LlamaCppEngine`, built on the llama.cpp C API) and
/// serves it over NSXPC and over a loopback HTTP listener. `LlamaClient(inProcessEngine:)` accepts
/// any conformer so tests can drive the client against `MockLlamaServerEngine` without a helper
/// process; nothing in production reaches an in-process engine.
///
/// Every `handle*` method takes and returns the JSON dictionaries of the corresponding
/// llama-server route, so the XPC and HTTP front ends only serialize.
public protocol LlamaInferenceEngine: AnyObject, Sendable {
    /// Path of the loaded model, or nil when nothing is loaded.
    var currentModelPath: String? { get }

    func loadModel(path: String, alias: String?, configJson: String?) -> (success: Bool, message: String)
    /// Loads `path` under `alias` unless that alias is already resident, in which case nothing
    /// changes. Unlike `loadModel`, which replaces a resident alias, this is safe to call before
    /// every request. Engines that hold several models do the check and the load atomically.
    func ensureModel(path: String, alias: String, configJson: String?) -> (success: Bool, message: String)
    /// Unloads every resident model.
    func unloadModel() -> Bool
    /// `POST /models/load` body `{"path"|"model": ..., "alias"?: ..., "config"?: {...}}`: loads one more
    /// model without disturbing the others. Engines that hold a single model replace it.
    func handleModelLoad(jsonString: String) throws -> [String: Any]
    /// `POST /models/unload` body `{"model": alias}`: unloads that one model (404 when absent).
    func handleModelUnload(jsonString: String) throws -> [String: Any]

    func handleHealth() -> [String: Any]
    func handleProps() -> [String: Any]
    func handleModels() -> [String: Any]
    func handleCompletion(jsonString: String) throws -> [String: Any]
    func handleChatCompletion(jsonString: String) throws -> [String: Any]
    func handleEmbeddings(jsonString: String) throws -> [String: Any]
    func handleTokenize(jsonString: String) throws -> [String: Any]
    func handleDetokenize(jsonString: String) throws -> [String: Any]
    func handleRerank(jsonString: String) throws -> [String: Any]
    func handleInfill(jsonString: String) throws -> [String: Any]
    func handleSlots() -> [String: Any]
    func handleSlotAction(slotId: Int, action: String, jsonString: String) throws -> [String: Any]
}

/// Error raised by an engine for a malformed or unserviceable request. `statusCode` is the HTTP
/// status the route dispatcher reports (400 bad request, 404, 501 unsupported, 503 no model, 500).
public struct LlamaEngineError: Error, LocalizedError {
    public let statusCode: Int
    public let message: String

    public init(_ statusCode: Int, _ message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func badRequest(_ message: String) -> LlamaEngineError { LlamaEngineError(400, message) }
    public static func noModel() -> LlamaEngineError { LlamaEngineError(503, "no model loaded") }
    public static func unsupported(_ message: String) -> LlamaEngineError { LlamaEngineError(501, message) }
}

public enum LlamaJSON {
    /// Serializes a response dictionary the way llama-server does (slashes unescaped).
    public static func serialize(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Parses a request body into a dictionary, raising a 400 on anything else.
    public static func parseObject(_ jsonString: String, what: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LlamaEngineError.badRequest("Invalid JSON in \(what) request")
        }
        return dict
    }

    /// Formats an error the way llama-server does: `{"error": {"message": ..., "code": ...}}`.
    public static func errorBody(_ statusCode: Int, _ message: String) -> String {
        serialize(["error": ["message": message, "code": statusCode]])
    }
}

public extension LlamaInferenceEngine {
    /// Default for engines without their own: checks the `/v1/models` list, then loads. Not atomic;
    /// `LlamaCppEngine` overrides it with a check-and-load under its engine lock.
    func ensureModel(path: String, alias: String, configJson: String?) -> (success: Bool, message: String) {
        let resident = (handleModels()["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if resident.contains(alias) {
            return (true, "\(alias) is already loaded")
        }
        return loadModel(path: path, alias: alias, configJson: configJson)
    }

    func serializeJson(_ obj: [String: Any]) -> String {
        LlamaJSON.serialize(obj)
    }

    /// Maps an HTTP method + path onto the engine, returning the status code and JSON body.
    /// Shared by the XPC `handleServerRequest` route and the loopback HTTP listener.
    func handleRoute(endpoint: String, method: String, jsonBody: String?) -> (statusCode: Int, responseBody: String) {
        let path = normalizeRoutePath(endpoint)
        let httpMethod = method.uppercased()
        let body = jsonBody ?? "{}"

        do {
            switch (httpMethod, path) {
            case ("GET", "/health"):
                let dict = handleHealth()
                let ok = (dict["status"] as? String) == "ok"
                return (ok ? 200 : 503, serializeJson(dict))

            case ("GET", "/props"), ("GET", "/get_props"):
                return (200, serializeJson(handleProps()))

            case ("GET", "/v1/models"), ("GET", "/models"):
                return (200, serializeJson(handleModels()))

            case ("POST", "/models/load"):
                return (200, serializeJson(try handleModelLoad(jsonString: body)))

            case ("POST", "/models/unload"):
                return (200, serializeJson(try handleModelUnload(jsonString: body)))

            case ("POST", "/completion"), ("POST", "/completions"), ("POST", "/v1/completions"):
                return (200, serializeJson(try handleCompletion(jsonString: body)))

            case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
                return (200, serializeJson(try handleChatCompletion(jsonString: body)))

            case ("POST", "/v1/embeddings"), ("POST", "/embeddings"), ("POST", "/embedding"):
                return (200, serializeJson(try handleEmbeddings(jsonString: body)))

            case ("POST", "/tokenize"):
                return (200, serializeJson(try handleTokenize(jsonString: body)))

            case ("POST", "/detokenize"):
                return (200, serializeJson(try handleDetokenize(jsonString: body)))

            case ("POST", "/v1/rerank"), ("POST", "/rerank"):
                return (200, serializeJson(try handleRerank(jsonString: body)))

            case ("POST", "/infill"):
                return (200, serializeJson(try handleInfill(jsonString: body)))

            case ("GET", "/slots"):
                return (200, serializeJson(handleSlots()))

            default:
                if httpMethod == "POST", path.hasPrefix("/slots/") {
                    let comps = path.split(separator: "/")
                    if comps.count >= 2, let slotId = Int(comps[1]) {
                        let action = routeQueryValue(endpoint, key: "action") ?? "erase"
                        return (200, serializeJson(try handleSlotAction(slotId: slotId, action: action, jsonString: body)))
                    }
                }
                return (404, LlamaJSON.errorBody(404, "Endpoint not found: \(httpMethod) \(endpoint)"))
            }
        } catch let error as LlamaEngineError {
            return (error.statusCode, LlamaJSON.errorBody(error.statusCode, error.message))
        } catch {
            return (500, LlamaJSON.errorBody(500, error.localizedDescription))
        }
    }
}

private func normalizeRoutePath(_ path: String) -> String {
    var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
    // An absolute-form request target (`http://localhost/v1/embeddings`), which garage-service's
    // host sends over the Unix socket, where the XPC route passes only a path.
    if let scheme = p.range(of: "://") {
        let rest = p[scheme.upperBound...]
        p = rest.firstIndex(where: { $0 == "/" || $0 == "?" }).map { String(rest[$0...]) } ?? "/"
    }
    if let queryIndex = p.firstIndex(of: "?") {
        p = String(p[..<queryIndex])
    }
    if !p.hasPrefix("/") {
        p = "/" + p
    }
    if p.count > 1, p.hasSuffix("/") {
        p.removeLast()
    }
    return p
}

private func routeQueryValue(_ endpoint: String, key: String) -> String? {
    guard let queryIndex = endpoint.firstIndex(of: "?") else { return nil }
    let query = endpoint[endpoint.index(after: queryIndex)...]
    for pair in query.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == key {
            return String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
    }
    return nil
}
