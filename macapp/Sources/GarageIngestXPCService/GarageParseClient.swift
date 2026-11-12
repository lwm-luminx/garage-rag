import Foundation
import GarageXPCKit

/// Ingest's side of GarageParseXPCService: hands one file's bytes to the reader process and waits for
/// its answer, on the ingest thread.
///
/// Anything but an answer is that file's failure, reported as a nonzero status and a reason the
/// pipeline remembers with the file's hash: the reader process crashed (the connection was
/// interrupted mid-file; launchd starts a fresh one for the next file), or it ran past its deadline,
/// when the connection is dropped, which ends the process, and the next file gets a new one.
final class GarageParseClient: @unchecked Sendable {
    /// The longest a file may take: `base` plus `perMegabyte` for each MB of it.
    struct Deadline {
        var base: TimeInterval = 120
        var perMegabyte: TimeInterval = 2

        func seconds(forBytes count: Int) -> TimeInterval {
            base + perMegabyte * Double(count) / 1_048_576
        }
    }

    enum Answer: Equatable {
        case reply(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let makeConnection: () -> NSXPCConnection
    let deadline: Deadline

    init(deadline: Deadline = Deadline(), makeConnection: @escaping () -> NSXPCConnection = GarageParseClient.serviceConnection) {
        self.deadline = deadline
        self.makeConnection = makeConnection
    }

    static func serviceConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: GarageParseXPC.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageParseXPCProtocol.self)
        return connection
    }

    /// Whether this process can reach the reader process: the app itself, which embeds it.
    static var isAvailable: Bool {
        let service = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/GarageParseXPCService.xpc", isDirectory: true)
        return Bundle.main.bundleURL.pathExtension == "app" && FileManager.default.fileExists(atPath: service.path)
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let connection = makeConnection()
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === connection { self.connection = nil }
            self.lock.unlock()
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Drops the connection, which ends a reader process that is still at work.
    private func drop(_ connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection { self.connection = nil }
        lock.unlock()
        connection.invalidate()
    }

    /// Reads `bytes` in the reader process; blocks until it answers, fails or runs out of time.
    func parse(request: String, bytes: Data) -> Answer {
        let connection = currentConnection()
        let done = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            // An interrupted connection mid-call: the reader process died on this file.
            box.set(.failed("the reader crashed on this file (\((error as NSError).localizedDescription))"))
            done.signal()
        } as? GarageParseXPCProtocol
        guard let proxy else {
            return .failed("the reader process could not be reached")
        }
        proxy.parse(request, bytes: bytes) { reply, error in
            if let reply {
                box.set(.reply(reply))
            } else {
                box.set(.failed(error ?? "the reader process gave no answer"))
            }
            done.signal()
        }
        let seconds = deadline.seconds(forBytes: bytes.count)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            drop(connection)
            return .failed("the reader took longer than \(Int(seconds)) seconds on this file")
        }
        return box.answer ?? .failed("the reader process gave no answer")
    }
}

/// The first answer a call gets: the reply and the error handler can both fire.
private final class AnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GarageParseClient.Answer?

    func set(_ answer: GarageParseClient.Answer) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = answer }
    }

    var answer: GarageParseClient.Answer? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
