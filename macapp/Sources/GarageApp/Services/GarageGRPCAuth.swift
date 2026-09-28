import Foundation
import GRPC
import NIO
import Security

/// The per-launch shared token that guards the GarageService gRPC port (`garage_rag.service.auth`).
///
/// The app makes a fresh random token each launch, hands it to the gRPC server and the XPC workers as
/// `GARAGE_GRPC_TOKEN` (never through garage.json, never logged), and sends it as `x-garage-token` on every
/// call. The server rejects a call without it, so another local process cannot drive the server's
/// operations (SetSetting, McpInstall, ...). A stopgap until the app reaches the server over XPC with
/// code-signing checks and no network socket; this file goes away then.
enum GarageGRPCAuth {
    static let metadataKey = "x-garage-token"

    /// 32 random bytes, hex encoded; made once per app launch.
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SystemRandomNumberGenerator is also a CSPRNG on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Call options carrying the token, with `timeLimit` when given.
    static func callOptions(timeLimit: TimeLimit = .none) -> CallOptions {
        var options = CallOptions()
        options.timeLimit = timeLimit
        options.customMetadata.add(name: metadataKey, value: token)
        return options
    }
}
