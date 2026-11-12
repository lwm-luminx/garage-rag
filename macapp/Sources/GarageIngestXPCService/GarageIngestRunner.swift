import Foundation
import GarageIngestFFI
import GarageXPCKit

/// Garage's ingest loop, written in Rust and linked into this process through its C ABI
/// (`rust/garage-ingest-ffi`, `garage_ingest.h`'s `garage_ingest_run`).
///
/// The loop walks each source, makes cloud placeholders local, hashes the files, decides what each
/// one needs and stores it through GarageService, on its socket (or port) and with the app's
/// per-launch token, with the settings GarageService runs with. It reads each file's text with its
/// own readers (`rust/garage-readers`: text, mail, PDF, Office, and pictures through Vision) and the
/// names iMessage contacts shared, so this host only hears progress and answers whether to stop. A
/// run blocks the calling thread, and the callbacks run on that thread.
final class GarageIngestRunner {
    /// Where GarageService listens.
    enum GRPCTarget: Equatable {
        case socket(String)
        case tcp(host: String, port: Int)
    }

    /// What `garage_ingest_run` replied: an error when a source failed, could not be read or none
    /// is enabled.
    struct Outcome {
        let error: String?
        let cancelled: Bool
    }

    /// Each `IngestProgress` event, as JSON.
    private let progress: (String) -> Void
    private let isCancelled: () -> Bool
    /// The reader process each file's bytes go to, when this process can reach one (the app, which
    /// hosts ingest in its own process and embeds GarageParseXPCService). Without it the readers run
    /// here, as in the ingest service's own process, where a crash costs only that process.
    private let parser: GarageParseClient?

    init(
        progress: @escaping (String) -> Void,
        isCancelled: @escaping () -> Bool,
        parser: GarageParseClient? = GarageParseClient.isAvailable ? GarageParseClient() : nil
    ) {
        self.progress = progress
        self.isCancelled = isCancelled
        self.parser = parser
    }

    /// Runs `source` (a slug, or `*` for every enabled source). `contactNames` are `[handle, name]`
    /// pairs from Contacts; `token` is the app's per-launch gRPC token. Neither is logged.
    func run(
        source: String,
        grpc: GRPCTarget,
        token: String?,
        includeCode: Bool,
        force: Bool,
        limit: Int?,
        contactNames: [[String]]?
    ) -> Result<Outcome, Error> {
        var facade: [String: Any] = [:]
        switch grpc {
        case .socket(let path):
            facade["socket"] = path
        case .tcp(let host, let port):
            facade["host"] = host
            facade["port"] = port
        }
        if let token, !token.isEmpty {
            facade["token"] = token
        }
        var request: [String: Any] = [
            "facade": facade,
            "source": source,
            "settings": "service",
            // The Rust readers, with GarageService's `extraction.*` settings.
            "readers": [String: Any](),
            "include_code": includeCode,
            "force": force,
            // Git history through the libgit2 linked in, as `_garage_git` reads it for Python.
            "read_git": true,
        ]
        if let limit, limit > 0 {
            request["limit"] = limit
        }
        if let contactNames, !contactNames.isEmpty {
            request["contact_names"] = contactNames.filter { $0.count == 2 }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request), let text = String(data: data, encoding: .utf8) else {
            return .failure(GarageIngestRunnerError("the request could not be encoded as JSON"))
        }
        var host = GarageIngestHost(
            context: Unmanaged.passUnretained(self).toOpaque(),
            read: nil,
            release: Self.releaseEntry,
            progress: Self.progressEntry,
            cancelled: Self.cancelledEntry,
            shared_names: nil,
            http: Self.httpEntry,
            access_token: Self.accessTokenEntry,
            parse: parser == nil ? nil : Self.parseEntry
        )
        var result: UnsafeMutablePointer<CChar>?
        let status = withExtendedLifetime(self) {
            text.withCString { garage_ingest_run($0, &host, &result) }
        }
        defer { garage_ingest_string_free(result) }
        let reply = result.map { Data(String(cString: $0).utf8) } ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard status == 0, let object else {
            let message = object?["error"] as? String ?? String(decoding: reply, as: UTF8.self)
            return .failure(GarageIngestRunnerError(message.isEmpty ? "the ingest library failed (\(status))" : message))
        }
        return .success(Outcome(error: object["error"] as? String, cancelled: object["cancelled"] as? Bool ?? false))
    }

    /// Whether the ingest library is linked and answers: the walker's default rules, summarized.
    static func libraryCheck() -> Result<String, Error> {
        var result: UnsafeMutablePointer<CChar>?
        let status = "{}".withCString { garage_ingest_policy($0, &result) }
        defer { garage_ingest_string_free(result) }
        let reply = result.map { Data(String(cString: $0).utf8) } ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard status == 0, let object else {
            let message = object?["error"] as? String ?? String(decoding: reply, as: UTF8.self)
            return .failure(GarageIngestRunnerError(message.isEmpty ? "the ingest library failed (\(status))" : message))
        }
        let excluded = (object["exclude_dirs"] as? [Any])?.count ?? 0
        let extensions = (object["indexable_extensions"] as? [Any])?.count ?? 0
        return .success("Linked; \(excluded) excluded folder names, \(extensions) indexable extensions")
    }

    // MARK: - The C host

    private static let releaseEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, reply in
        free(reply)
    }

    private static let progressEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, event in
        guard let context, let event else { return }
        Unmanaged<GarageIngestRunner>.fromOpaque(context).takeUnretainedValue().progress(String(cString: event))
    }

    /// Answers a host call: the request's JSON object in, `handle`'s JSON object out, or the error's
    /// message with a nonzero status.
    private static func answer(
        _ request: UnsafePointer<CChar>?,
        _ reply: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        _ handle: ([String: Any]) throws -> [String: Any]
    ) -> Int32 {
        guard let reply else { return 1 }
        do {
            guard
                let request,
                let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any]
            else {
                throw GarageIngestRunnerError("the request is not a JSON object")
            }
            let answer = try JSONSerialization.data(withJSONObject: handle(object))
            reply.pointee = strdup(String(decoding: answer, as: UTF8.self))
            return 0
        } catch {
            reply.pointee = strdup(error.localizedDescription)
            return 1
        }
    }

    /// A cloud source's requests (`http`: Dropbox, OneDrive), over URLSession.
    private static let httpEntry: GarageIngestHostCall = { _, request, reply in
        answer(request, reply) { try GarageCloudHTTP.send($0) }
    }

    /// A cloud source's token (`access_token`), from the provider the build registered.
    private static let accessTokenEntry: GarageIngestHostCall = { _, request, reply in
        answer(request, reply) { object in
            let token = try GarageCloudCredentials.accessToken(
                service: object["service"] as? String ?? "",
                source: object["source"] as? String ?? "",
                refresh: object["refresh"] as? Bool ?? false
            )
            return ["access_token": token]
        }
    }

    /// One file's bytes to the reader process (`parse`): its answer, or the file's failure.
    private static let parseEntry: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32 = { context, request, bytes, count, reply in
        guard let context, let request, let reply else { return 1 }
        let runner = Unmanaged<GarageIngestRunner>.fromOpaque(context).takeUnretainedValue()
        guard let parser = runner.parser else {
            reply.pointee = strdup("no reader process")
            return 1
        }
        let text = String(cString: request)
        let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
        switch parser.parse(request: text, bytes: data) {
        case .reply(let answer):
            reply.pointee = strdup(answer)
            return 0
        case .failed(let reason):
            reply.pointee = strdup(reason)
            return 1
        }
    }

    private static let cancelledEntry: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { context in
        guard let context else { return false }
        return Unmanaged<GarageIngestRunner>.fromOpaque(context).takeUnretainedValue().isCancelled()
    }
}

/// A run that could not start or failed as a whole.
struct GarageIngestRunnerError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
