import Foundation
import GarageIngestFFI
import GarageXPCKit

/// Reads file bytes with Garage's readers (`garage_ingest_parse`). It holds no grant and opens no file:
/// the bytes come over the connection. Each call runs on its own queue so the listener stays free, and
/// a reader that crashes takes only this process down.
final class GarageParseService: NSObject, GarageParseXPCProtocol {
    private let queue = DispatchQueue(label: "me.rickmark.garage.parse", qos: .utility)

    func parse(_ request: String, bytes: Data, withReply reply: @escaping (String?, String?) -> Void) {
        queue.async {
            var result: UnsafeMutablePointer<CChar>?
            let status = bytes.withUnsafeBytes { buffer in
                request.withCString { garage_ingest_parse($0, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &result) }
            }
            defer { garage_ingest_string_free(result) }
            let text = result.map { String(cString: $0) } ?? ""
            if status == 0 {
                reply(text, nil)
            } else {
                let error = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                reply(nil, error?["error"] as? String ?? "the readers failed (\(status))")
            }
        }
    }
}

final class GarageParseListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = GarageParseService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: GarageParseXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let listenerDelegate = GarageParseListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume()
