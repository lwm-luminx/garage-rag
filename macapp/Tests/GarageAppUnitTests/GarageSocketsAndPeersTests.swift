import Darwin
import XCTest
import PythonXPCService

/// `GarageSockets` (the owner-only folder the app's endpoints listen in) and `GarageXPCPeerRequirement`
/// (who may talk to the XPC services).
final class GarageSocketsAndPeersTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // A short name, so every socket path in it fits sun_path.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("g\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try XCTSkipUnless(GarageSockets.fits(directory.path + "/grpc"), "the temporary folder's path is too long for a socket")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnsureDirectoryIsOwnerOnly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try GarageSockets.ensureDirectory(directory)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o700)
    }

    func testSocketNamesStayInTheFolder() {
        XCTAssertEqual(GarageSockets.path(for: GarageSockets.grpcName, in: directory), directory.path + "/grpc")
        XCTAssertEqual(GarageSockets.path(for: GarageSockets.llamaName, in: directory), directory.path + "/llama")
        XCTAssertEqual(GarageSockets.postgresName, ".s.PGSQL.14824")
        XCTAssertEqual(GarageSockets.directory.lastPathComponent, GarageSockets.directoryName)
    }

    func testStaleSocketIsRemovedButALiveOneAndOtherFilesAreNot() throws {
        try GarageSockets.ensureDirectory(directory)
        let path = directory.path + "/grpc"

        let fd = try bindSocket(at: path)
        // Room for the probes below: each connects and closes without being accepted, and with a
        // backlog of 1 the second is refused, which reads as a stale socket.
        XCTAssertEqual(listen(fd, 16), 0)
        XCTAssertTrue(GarageSockets.isAcceptingConnections(at: path))
        GarageSockets.removeStaleSocket(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "a live socket was removed")

        close(fd)
        XCTAssertFalse(GarageSockets.isAcceptingConnections(at: path))
        GarageSockets.removeStaleSocket(at: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "a stale socket was left behind")

        let file = directory.path + "/llama"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: file))
        GarageSockets.removeStaleSocket(at: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), "a regular file was removed")
    }

    func testPeerRequirementNamesTheTeam() {
        XCTAssertEqual(
            GarageXPCPeerRequirement.requirement(forTeam: "DWVXMLB45Y"),
            "anchor apple generic and certificate leaf[subject.OU] = \"DWVXMLB45Y\""
        )
        XCTAssertTrue(GarageXPCPeerRequirement.isTeamIdentifier("DWVXMLB45Y"))
        XCTAssertFalse(GarageXPCPeerRequirement.isTeamIdentifier("dwvxmlb45y"))
        XCTAssertFalse(GarageXPCPeerRequirement.isTeamIdentifier("DWVXMLB45"))
        XCTAssertFalse(GarageXPCPeerRequirement.isTeamIdentifier("DWVXMLB4\" or"))
    }

    private func bindSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8))
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "bind \(path): \(String(cString: strerror(errno)))")
        return fd
    }
}
