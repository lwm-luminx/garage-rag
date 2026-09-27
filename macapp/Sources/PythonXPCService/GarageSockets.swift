import Darwin
import Foundation

/// The Unix-domain sockets Garage's own processes talk over: Postgres, the `GarageService` gRPC port
/// and LlamaXPCService's llama-server API.
///
/// A loopback TCP port is open to every process of every account on the Mac. A socket in an
/// owner-only (0700) folder of the App Group container is reachable only by this account, and, in
/// the sandbox, only by processes entitled to the group: the app, its XPC services and the
/// launcher helpers. The folder sits right below the container root, because a socket's path must
/// fit `sockaddr_un.sun_path` (104 bytes with its NUL), and the data folder
/// (`.../Library/Application Support/GarageApp`) is already too deep for most user names.
///
/// When the path would still not fit (a very long user name), `path(for:)` answers nil and the
/// caller keeps its loopback TCP port, as every build before this one did.
public enum GarageSockets {
    /// Folder name below the container root (or below the data folder, when unentitled).
    public static let directoryName = "s"

    /// `sizeof(sockaddr_un.sun_path)` less the terminating NUL.
    public static let maxPathLength: Int = {
        let address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path) - 1
    }()

    /// Socket file names. Postgres names its own `.s.PGSQL.<port>` inside `unix_socket_directories`.
    public static let grpcName = "grpc"
    public static let llamaName = "llama"
    public static var postgresName: String { ".s.PGSQL.\(GaragePostgresEndpoint.port)" }

    /// `<group container>/s` when entitled for the group; below the `--data-directory` override (UI tests)
    /// or the per-user data folder otherwise.
    public static var directory: URL {
        if let override = GarageAppGroup.dataDirectoryOverride {
            return override.appendingPathComponent(directoryName, isDirectory: true)
        }
        if GarageAppGroup.isEntitled,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GarageAppGroup.identifier) {
            return container.appendingPathComponent(directoryName, isDirectory: true)
        }
        return GarageAppGroup.legacyDataDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The socket's path in `directory`, or nil when it is too long to bind.
    public static func path(for name: String, in directory: URL = directory) -> String? {
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        return fits(path) ? path : nil
    }

    /// Whether `path` fits `sun_path`.
    public static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxPathLength
    }

    /// The variable that tells Python where LlamaXPCService's llama-server API listens.
    public static let llamaSocketVariable = "GARAGE_LLAMA_SOCKET"

    /// Sets `GARAGE_LLAMA_SOCKET` for the Python this process embeds, before it starts, unless it is
    /// set already or `GARAGE_LLAMA_HTTP_PORT` moved LlamaXPCService to a loopback port.
    public static func exportLlamaSocket() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[llamaSocketVariable] == nil,
              environment["GARAGE_LLAMA_HTTP_PORT"] == nil,
              let path = path(for: llamaName) else { return }
        setenv(llamaSocketVariable, path, 0)
    }

    /// Creates `directory` owner-only (0700), tightening it when it already exists.
    @discardableResult
    public static func ensureDirectory(_ directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Removes a socket file a crashed listener left behind, so a new one can bind. Only removes sockets.
    public static func removeStaleSocket(at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        if !isAcceptingConnections(at: path) {
            unlink(path)
        }
    }

    /// True when something accepts connections on the socket at `path`. A refused connection (or no
    /// file) returns at once, so this is cheap to poll.
    public static func isAcceptingConnections(at path: String) -> Bool {
        guard fits(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: Array(path.utf8))
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
