import Foundation

/// What a `tools/call` returned.
public struct GarageMCPToolResult: Sendable, Equatable {
    /// `structuredContent` as JSON, when the tool returned a typed record (every Garage tool does).
    public var structured: Data?
    /// The text of the result's `content`, joined.
    public var text: String
    /// The tool failed (`isError`); `text` says why.
    public var isError: Bool

    public init(structured: Data?, text: String, isError: Bool) {
        self.structured = structured
        self.text = text
        self.isError = isError
    }

    /// The typed record if there is one, else the text: what a caller decodes.
    public var json: Data { structured ?? Data(text.utf8) }
}

public struct GarageMCPToolCallError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Calls Garage's MCP tools through GarageMCPServerService over XPC (`exchange`), which answers without its HTTP
/// listener: the app's own way to ask its corpus, so the Chat page works whether or not the HTTP server is on,
/// and no port is opened for it. It keeps one MCP session and starts another when the service forgets it.
public final class GarageMCPToolCaller: @unchecked Sendable {
    private let client: GarageMCPServerClient
    private let clientName: String
    private let lock = NSLock()
    private var sessionID: String?
    private var nextID = 1

    public init(client: GarageMCPServerClient = GarageMCPServerClient(), clientName: String = "Garage") {
        self.client = client
        self.clientName = clientName
    }

    /// Runs `tool` with `arguments` (a JSON object). Throws when the exchange or the JSON-RPC call fails; a tool
    /// that ran and failed comes back with `isError`.
    public func call(_ tool: String, arguments: [String: Any]) async throws -> GarageMCPToolResult {
        let params: [String: Any] = ["name": tool, "arguments": arguments]
        var reply: [String: Any]
        do {
            reply = try await request("tools/call", params: params, session: try await session())
        } catch is SessionLost {
            forgetSession()
            reply = try await request("tools/call", params: params, session: try await session())
        }
        if let error = reply["error"] as? [String: Any] {
            throw GarageMCPToolCallError(error["message"] as? String ?? "The MCP server refused the call")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw GarageMCPToolCallError("The MCP server's reply has no result")
        }
        return Self.toolResult(result)
    }

    /// A `tools/call` result as a `GarageMCPToolResult`.
    public static func toolResult(_ result: [String: Any]) -> GarageMCPToolResult {
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        var structured: Data?
        if let object = result["structuredContent"], JSONSerialization.isValidJSONObject(object) {
            structured = try? JSONSerialization.data(withJSONObject: object)
        }
        return GarageMCPToolResult(
            structured: structured,
            text: texts.joined(separator: "\n"),
            isError: result["isError"] as? Bool ?? false
        )
    }

    // MARK: - Session

    private struct SessionLost: Error {}

    private func forgetSession() {
        lock.withLock { sessionID = nil }
    }

    private func session() async throws -> String {
        if let known = lock.withLock({ sessionID }) {
            return known
        }
        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": clientName, "version": "1"],
        ]
        let (reply, headers) = try await exchange(body: rpc("initialize", params: params), session: nil)
        if let error = reply["error"] as? [String: Any] {
            throw GarageMCPToolCallError(error["message"] as? String ?? "The MCP server refused to start a session")
        }
        guard let id = headers["mcp-session-id"], !id.isEmpty else {
            throw GarageMCPToolCallError("The MCP server started no session")
        }
        _ = try? await exchange(body: notification("notifications/initialized"), session: id)
        lock.withLock { sessionID = id }
        return id
    }

    private func request(_ method: String, params: [String: Any], session: String) async throws -> [String: Any] {
        try await exchange(body: rpc(method, params: params), session: session).reply
    }

    private func rpc(_ method: String, params: [String: Any]) -> [String: Any] {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private func notification(_ method: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method]
    }

    /// One POST through the service; the JSON-RPC reply and the reply's headers (names in lower case).
    private func exchange(body: [String: Any], session: String?) async throws -> (reply: [String: Any], headers: [String: String]) {
        var headers = [
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        ]
        if let session {
            headers["mcp-session-id"] = session
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let request: [String: Any] = ["method": "POST", "headers": headers, "body": text]
        let data = try await client.exchange(try JSONSerialization.data(withJSONObject: request))
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = reply["status"] as? Int else {
            throw GarageMCPToolCallError("The MCP service's reply has no status")
        }
        let replyHeaders = reply["headers"] as? [String: String] ?? [:]
        let replyBody = reply["body"] as? String ?? ""
        if status == 404, session != nil {
            throw SessionLost()
        }
        guard (200...299).contains(status) else {
            throw GarageMCPToolCallError("The MCP server answered \(status): \(replyBody.prefix(300))")
        }
        return (Self.jsonRPC(replyBody), replyHeaders)
    }

    /// The JSON-RPC message in a reply body: plain JSON, or the last `data:` line of an event stream.
    public static func jsonRPC(_ body: String) -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            return object
        }
        var found: [String: Any] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                found = object
            }
        }
        return found
    }
}
