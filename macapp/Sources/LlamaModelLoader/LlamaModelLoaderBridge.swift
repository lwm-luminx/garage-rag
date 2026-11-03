import Foundation
import OSLog
import LlamaModelLoaderCore
import PythonKit
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "LlamaModelLoader")

/// Lets the Python embedded in this process load llama_xpc models through its Swift host.
///
/// `install()` hands Python (`garage_rag.xpc.host.install_model_loader`) the address of a C
/// function; Python calls it through ctypes, which releases the GIL for the call, so a load that
/// takes seconds does not stall the interpreter's other threads. The function blocks on
/// `LlamaModelLoader.ensureLoadedBlocking`, which loads over NSXPC. Nothing here touches Python
/// while the call is in flight.
///
/// The services that install it are siblings of LlamaXPCService, which cannot look it up by name:
/// they connect through the listener endpoint the app hands them (`GarageLlamaEndpointStore`).
///
/// C signature: `int32_t loader(const char *alias, char *message, size_t capacity)`: 0 when the
/// model is resident (message says whether it was loaded now), nonzero on failure (message says
/// why and what to do). The message is NUL-terminated and truncated to `capacity`.
public enum LlamaModelLoaderBridge {
    public typealias Entry = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedLoader: LlamaModelLoader?

    static var loader: LlamaModelLoader? {
        lock.lock()
        defer { lock.unlock() }
        return installedLoader
    }

    /// Sets the loader the C entry point uses (tests install a fake one).
    public static func setLoader(_ loader: LlamaModelLoader?) {
        lock.lock()
        installedLoader = loader
        lock.unlock()
    }

    /// The function Python calls. A global with no captures, as a C function pointer must be.
    public static let entry: Entry = { aliasPointer, message, capacity in
        guard let aliasPointer else {
            LlamaModelLoaderBridge.write("no model name given", to: message, capacity: capacity)
            return 2
        }
        let alias = String(cString: aliasPointer)
        guard let loader = LlamaModelLoaderBridge.loader else {
            LlamaModelLoaderBridge.write("this process has no llama model loader", to: message, capacity: capacity)
            return 3
        }
        switch loader.ensureLoadedBlocking(alias: alias) {
        case .success(.alreadyLoaded):
            LlamaModelLoaderBridge.write("\(alias) is already loaded", to: message, capacity: capacity)
            return 0
        case .success(.loaded(let detail)):
            LlamaModelLoaderBridge.write(detail, to: message, capacity: capacity)
            return 0
        case .failure(let error):
            let text = error.localizedDescription
            logger.error("On-demand load of \(alias, privacy: .public) failed: \(text, privacy: .public)")
            LlamaModelLoaderBridge.write(text, to: message, capacity: capacity)
            return 1
        }
    }

    /// The entry point's address, as Python receives it.
    public static var entryAddress: Int {
        Int(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self))
    }

    nonisolated(unsafe) private static var registeredWithPython = false

    /// Installs the standard NSXPC loader, on the handed-over LlamaXPCService endpoint (unless a
    /// loader is set already), and registers the entry point with Python, along with
    /// `LlamaInferenceBridge`. Call once Python is ready; takes the GIL itself; later calls do nothing.
    /// Returns false (and logs) when `garage_rag` cannot be imported, so the service still starts.
    @discardableResult
    public static func install() -> Bool {
        lock.lock()
        if registeredWithPython {
            lock.unlock()
            return true
        }
        if installedLoader == nil {
            installedLoader = .standard(service: .handedOverEndpoint())
        }
        lock.unlock()
        do {
            try GaragePythonRuntime.shared.withGILDescribingErrors {
                let host = try Python.attemptImport("garage_rag.xpc.host")
                _ = try host.install_model_loader.throwing.dynamicallyCall(withArguments: [entryAddress])
            }
            lock.lock()
            registeredWithPython = true
            lock.unlock()
            logger.info("llama model loader installed for Python")
            // The same processes send llama_xpc requests over NSXPC rather than HTTP.
            LlamaInferenceBridge.install()
            return true
        } catch {
            logger.error("Could not install the llama model loader: \(error.localizedDescription, privacy: .public)")
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Could not install the llama model loader: \(error.localizedDescription)")
            return false
        }
    }

    /// Self test for a service that installs the loader (`LlamaEndpointSelfTest`).
    public static func selfTest(store: GarageLlamaEndpointStore = .shared) -> GarageXPCSelfTest {
        LlamaEndpointSelfTest.make(store: store)
    }

    static func write(_ text: String, to buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
        guard let buffer, capacity > 0 else { return }
        // Whole scalars only, so a truncated message is still valid UTF-8.
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if bytes.count + encoded.count > capacity - 1 { break }
            bytes.append(contentsOf: encoded)
        }
        bytes.withUnsafeBufferPointer { source in
            buffer.withMemoryRebound(to: UInt8.self, capacity: capacity) { dest in
                if let base = source.baseAddress {
                    dest.update(from: base, count: source.count)
                }
                dest[source.count] = 0
            }
        }
    }
}
