import Darwin
import Foundation
import Network
import OSLog
import LlamaClient
import PythonXPCService_protocol

/// Minimal HTTP/1.1 listener, on a Unix-domain socket or the loopback interface, that forwards every
/// request to an engine's llama-server route table.
///
/// This exists for the Python side: `garage backfill` and `garage enrich-facts` run in their own
/// process (the CLI), where NSXPC is not available, so the `llama_xpc` provider speaks plain HTTP
/// to this listener instead. Given a `socketPath` (the app passes one in its owner-only App Group
/// folder, `GarageSockets`) it listens there and nowhere else, so only this account's Garage
/// processes reach it; otherwise it binds 127.0.0.1, which every account on the Mac can reach. It
/// answers one request per
/// connection (`Connection: close`), and understands exactly what the engine needs: a request
/// line, headers, and an optional `Content-Length` body. Nothing else is implemented on purpose.
public final class LlamaHTTPServer: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    /// The Unix-domain socket to listen on instead of `host:port`, or nil for TCP.
    public let socketPath: String?
    private let engine: any LlamaInferenceEngine
    private let queue = DispatchQueue(label: "me.rickmark.garage-rag.llama-http", qos: .userInitiated)
    private let logger = Logger(subsystem: "me.rickmark.garage-rag.llama-xpc", category: "http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Largest request body accepted; embedding batches are well under this.
    private static let maxBodyBytes = 64 * 1024 * 1024
    private static let maxHeaderBytes = 64 * 1024

    /// Where the listener is, for logs and `/props`: `unix:<path>` or `http://host:port`.
    public var url: String { socketPath.map { "unix:\($0)" } ?? "http://\(host):\(port)" }

    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener?.state == .ready
    }

    public init(
        engine: any LlamaInferenceEngine,
        host: String = "127.0.0.1",
        port: UInt16 = LlamaXPCConstants.defaultHTTPPort,
        socketPath: String? = nil
    ) {
        self.engine = engine
        self.host = host
        self.port = port
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    /// Binds the port and starts accepting connections. Throws when the port is taken or the
    /// listener fails to become ready within a few seconds, so a managed-service `start()` can
    /// report it instead of silently serving nothing.
    public func start() throws {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        if let socketPath {
            try Self.prepareSocketPath(socketPath)
            parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw LlamaEngineError(500, "invalid HTTP port \(port)")
            }
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        let newListener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<String?>(nil)

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("llama HTTP listener ready on \(self?.url ?? "", privacy: .public)")
                ready.signal()
            case .failed(let error):
                failure.value = error.localizedDescription
                self?.logger.error("llama HTTP listener failed: \(error.localizedDescription, privacy: .public)")
                ready.signal()
            case .cancelled:
                self?.logger.info("llama HTTP listener cancelled")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        lock.lock()
        listener = newListener
        lock.unlock()
        newListener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            stop()
            throw LlamaEngineError(500, "llama HTTP listener did not become ready on \(url)")
        }
        if let message = failure.value {
            stop()
            throw LlamaEngineError(500, "llama HTTP listener could not bind \(url): \(message)")
        }
        if let socketPath {
            // The folder is already owner-only; the socket is too, in case it is ever moved out of it.
            chmod(socketPath, 0o600)
        }
    }

    /// Creates the socket's folder owner-only and removes a socket file a crashed listener left
    /// behind (a new one cannot bind over it). A socket something still answers on, or anything
    /// that is not a socket, is left alone, and the bind then fails.
    static func prepareSocketPath(_ path: String) throws {
        try GarageSockets.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        GarageSockets.removeStaleSocket(at: path)
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        current?.cancel()
        for connection in open {
            connection.cancel()
        }
        if current != nil, let socketPath {
            unlink(socketPath)
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        connections[id] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }

    /// Reads until the header block is complete, then until `Content-Length` bytes of body arrived.
    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data {
                buffer.append(data)
            }
            if let error = error {
                self.logger.debug("llama HTTP receive failed: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeaderBytes {
                    self.respond(connection, status: 431, body: LlamaJSON.errorBody(431, "request header too large"))
                } else if isComplete {
                    connection.cancel()
                } else {
                    self.readRequest(connection, buffer: buffer)
                }
                return
            }

            guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
                self.respond(connection, status: 400, body: LlamaJSON.errorBody(400, "request head is not UTF-8"))
                return
            }
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first.map { $0.split(separator: " ", omittingEmptySubsequences: true) } ?? []
            guard requestLine.count >= 2 else {
                self.respond(connection, status: 400, body: LlamaJSON.errorBody(400, "malformed request line"))
                return
            }
            let method = String(requestLine[0])
            let target = String(requestLine[1])

            var contentLength = 0
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if contentLength > Self.maxBodyBytes {
                self.respond(connection, status: 413, body: LlamaJSON.errorBody(413, "request body too large"))
                return
            }

            let bodyStart = headerEnd.upperBound
            let available = buffer.count - (bodyStart - buffer.startIndex)
            if available < contentLength {
                if isComplete {
                    self.respond(connection, status: 400, body: LlamaJSON.errorBody(400, "request body truncated"))
                } else {
                    self.readRequest(connection, buffer: buffer)
                }
                return
            }

            let bodyData = buffer[bodyStart..<(bodyStart + contentLength)]
            let body = contentLength > 0 ? String(data: bodyData, encoding: .utf8) : nil
            if contentLength > 0 && body == nil {
                self.respond(connection, status: 400, body: LlamaJSON.errorBody(400, "request body is not UTF-8"))
                return
            }

            // Inference blocks; keep the listener queue free for the next connection.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.engine.handleRoute(endpoint: target, method: method, jsonBody: body)
                self.respond(connection, status: result.statusCode, body: result.responseBody)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n"
        head += "Server: garage-llama-xpc\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

/// A value guarded by a lock, for handing results out of Network.framework callbacks.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
