import Darwin
import Foundation
import LlamaModelLoaderCore
import OSLog
import PythonKit
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "LlamaInferenceBridge")

/// Lets the Python embedded in this process send `llama_xpc` requests to LlamaXPCService over NSXPC
/// (`handleServerRequest`, through `LlamaServerRequests`) instead of HTTP.
///
/// `install()` hands Python (`garage_rag.inference.bridge.install`) the addresses of two C functions;
/// Python calls them through ctypes, which releases the GIL for the call. XPC only delivers these
/// messages between processes of the same team (`GarageXPCPeerRequirement`), and no socket or port is
/// involved, so this is the narrowest path to the engine the app's services have.
///
/// C signatures:
/// - `int32_t request(const char *method, const char *path, const char *body, double timeout,
///   int32_t *status, char **reply)`: 0 with the HTTP status and the reply body, nonzero with the
///   reason in `reply` when no reply came. `body` may be NULL.
/// - `void release(char *reply)`: frees what `request` put in `reply` (always set, both ways).
public enum LlamaInferenceBridge {
    public typealias Request = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Double,
        UnsafeMutablePointer<Int32>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    public typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registeredWithPython = false

    /// The request function Python calls. A global with no captures, as a C function pointer must be.
    public static let request: Request = { method, path, body, timeout, status, reply in
        guard let method, let path, let reply else {
            reply?.pointee = strdup("the inference bridge was called without a method, path or reply")
            return 2
        }
        let result = LlamaServerRequests.perform(
            method: String(cString: method),
            path: String(cString: path),
            body: body.map { String(cString: $0) },
            timeout: timeout
        )
        switch result {
        case .success(let (code, text)):
            status?.pointee = Int32(clamping: code)
            reply.pointee = strdup(text)
            return 0
        case .failure(let error):
            reply.pointee = strdup("LlamaXPCService did not answer over XPC: \(error.localizedDescription)")
            return 1
        }
    }

    public static let release: Release = { pointer in
        free(pointer)
    }

    /// Registers the functions with Python. Call once Python is ready; takes the GIL itself; later calls
    /// do nothing. Returns false (and logs) when `garage_rag` cannot be imported, so the service still
    /// starts and `llama_xpc` keeps using HTTP.
    @discardableResult
    public static func install() -> Bool {
        lock.lock()
        if registeredWithPython {
            lock.unlock()
            return true
        }
        lock.unlock()
        let requestAddress = Int(bitPattern: unsafeBitCast(request, to: UnsafeRawPointer.self))
        let releaseAddress = Int(bitPattern: unsafeBitCast(release, to: UnsafeRawPointer.self))
        do {
            try GaragePythonRuntime.shared.withGILDescribingErrors {
                let module = try Python.attemptImport("garage_rag.inference.bridge")
                _ = try module.install.throwing.dynamicallyCall(withArguments: [requestAddress, releaseAddress])
            }
            lock.lock()
            registeredWithPython = true
            lock.unlock()
            logger.info("llama_xpc NSXPC bridge installed for Python")
            return true
        } catch {
            logger.error("Could not install the llama_xpc NSXPC bridge: \(error.localizedDescription, privacy: .public)")
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Could not install the llama_xpc NSXPC bridge: \(error.localizedDescription)")
            return false
        }
    }
}
