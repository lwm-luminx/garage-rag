import Foundation
import GarageIngestFFI

/// Garage's ingest loop, written in Rust and linked into this process through its C ABI
/// (`rust/garage-ingest-ffi`, `garage_ingest.h`'s `garage_ingest_run`).
///
/// The loop walks each source, makes cloud placeholders local, hashes the files, decides what each
/// one needs and stores it through GarageService, on its socket (or port) and with the app's
/// per-launch token, with the settings GarageService runs with. Only the text of a file, and the
/// names iMessage contacts shared, come from this host (`read`, `sharedNames`), which still answers
/// them with the Python readers until each has a Rust port. A run blocks the calling thread, and
/// the callbacks run on that thread.
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

    /// `{"path", "uri", "size", "mtime"}` -> `read_for_host`'s reply, as JSON.
    private let read: (String) -> String?
    /// `{"directory"}` -> `{"names": [[handle, name], ...]}`, as JSON.
    private let sharedNames: (String) -> String?
    /// Each `IngestProgress` event, as JSON.
    private let progress: (String) -> Void
    private let isCancelled: () -> Bool

    init(
        read: @escaping (String) -> String?,
        sharedNames: @escaping (String) -> String?,
        progress: @escaping (String) -> Void,
        isCancelled: @escaping () -> Bool
    ) {
        self.read = read
        self.sharedNames = sharedNames
        self.progress = progress
        self.isCancelled = isCancelled
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
            read: Self.readEntry,
            release: Self.releaseEntry,
            progress: Self.progressEntry,
            cancelled: Self.cancelledEntry,
            shared_names: Self.sharedNamesEntry
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

    // MARK: - The C host

    private static func answer(
        _ context: UnsafeMutableRawPointer?,
        _ request: UnsafePointer<CChar>?,
        _ reply: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        _ body: (GarageIngestRunner, String) -> String?
    ) -> Int32 {
        guard let context, let request, let reply else {
            reply?.pointee = strdup("the host was called without a context, request or reply")
            return 1
        }
        let runner = Unmanaged<GarageIngestRunner>.fromOpaque(context).takeUnretainedValue()
        guard let text = body(runner, String(cString: request)) else {
            reply.pointee = strdup("the host could not answer")
            return 1
        }
        reply.pointee = strdup(text)
        return 0
    }

    private static func field(_ name: String, of request: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any]
        return object?[name] as? String
    }

    private static let readEntry: GarageIngestHostCall = { context, request, reply in
        GarageIngestRunner.answer(context, request, reply) { runner, request in
            GarageIngestRunner.field("path", of: request).flatMap(runner.read)
        }
    }

    private static let sharedNamesEntry: GarageIngestHostCall = { context, request, reply in
        GarageIngestRunner.answer(context, request, reply) { runner, request in
            GarageIngestRunner.field("directory", of: request).flatMap(runner.sharedNames)
        }
    }

    private static let releaseEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, reply in
        free(reply)
    }

    private static let progressEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, event in
        guard let context, let event else { return }
        Unmanaged<GarageIngestRunner>.fromOpaque(context).takeUnretainedValue().progress(String(cString: event))
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
