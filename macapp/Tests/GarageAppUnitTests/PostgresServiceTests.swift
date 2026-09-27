import XCTest
import PythonXPCService
@testable import GarageApp

final class PostgresServiceTests: XCTestCase {

    @MainActor
    func testInitialStatusIsStopped() {
        let service = PostgresService()
        XCTAssertEqual(service.status, .stopped)
    }

    @MainActor
    func testDefaultPortAndDatabase() {
        let service = PostgresService()
        XCTAssertEqual(service.port, 14824)
        XCTAssertEqual(service.databaseName, "garage-rag")
    }

    @MainActor
    func testConnectionURLFormat() throws {
        let service = PostgresService()
        let url = try service.connectionURL()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedUser = NSUserName().addingPercentEncoding(withAllowedCharacters: allowed) ?? NSUserName()
        XCTAssertTrue(url.starts(with: "postgresql+psycopg://\(encodedUser):"))
        XCTAssertFalse(url.contains("postgres-superuser"))
        XCTAssertFalse(url.contains("postgres-master"))
        XCTAssertTrue(url.contains(Self.expectedLocation(service)))
    }

    /// The part of the URL after the credentials: the socket folder when the server has one, else localhost.
    @MainActor
    private static func expectedLocation(_ service: PostgresService) -> String {
        guard let directory = service.socketDirectory else { return "@localhost:14824/garage-rag" }
        let encoded = directory.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? directory
        return "@/garage-rag?host=\(encoded)&port=14824"
    }

    func testSocketURLNamesTheFolderAndThePort() throws {
        let url = try GaragePostgresEndpoint.connectionURL(
            password: "s3cr@t",
            scheme: "postgresql",
            socketDirectory: "/Users/me/Library/Group Containers/TEAM.group.x/s"
        )
        XCTAssertTrue(url.hasSuffix("@/garage-rag?host=%2FUsers%2Fme%2FLibrary%2FGroup%20Containers%2FTEAM.group.x%2Fs&port=14824"))
        XCTAssertTrue(url.contains(":s3cr%40t@"))
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.queryItems?.first { $0.name == "host" }?.value, "/Users/me/Library/Group Containers/TEAM.group.x/s")
    }

    func testTCPURLWhenThereIsNoSocket() throws {
        let url = try GaragePostgresEndpoint.connectionURL(password: "pw", socketDirectory: nil)
        XCTAssertTrue(url.hasSuffix(":pw@localhost:14824/garage-rag"))
        XCTAssertEqual(GaragePostgresEndpoint.clientArguments(socketDirectory: nil), ["-h", "localhost", "-p", "14824"])
        XCTAssertEqual(GaragePostgresEndpoint.clientArguments(socketDirectory: "/s"), ["-h", "/s", "-p", "14824"])
    }

    func testSocketFolderIsQuotedAsOneListElement() {
        XCTAssertEqual(PostgresService.quotedSetting("/a b/s"), "\"/a b/s\"")
        XCTAssertEqual(PostgresService.quotedSetting("/a\"b,c"), "\"/a\"\"b,c\"")
    }

    func testSocketPathLimitIsSunPath() {
        XCTAssertEqual(GarageSockets.maxPathLength, 103)
        XCTAssertTrue(GarageSockets.fits(String(repeating: "a", count: 103)))
        XCTAssertFalse(GarageSockets.fits(String(repeating: "a", count: 104)))
        XCTAssertNil(GarageSockets.path(for: "grpc", in: URL(fileURLWithPath: "/" + String(repeating: "d", count: 110))))
    }

    @MainActor
    func testConnectionURLUsesLoggedInUserNotPostgresSuperuser() throws {
        let service = PostgresService()
        let url = try service.connectionURL()
        let currentUser = NSUserName()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedUser = currentUser.addingPercentEncoding(withAllowedCharacters: allowed) ?? currentUser

        XCTAssertFalse(url.contains("postgres-superuser"))
        XCTAssertFalse(url.contains("postgres-master"))
        XCTAssertTrue(url.contains("://\(encodedUser):"))
    }

    @MainActor
    func testConnectionURLIsConsistentAcrossCalls() throws {
        let service = PostgresService()
        let url1 = try service.connectionURL()
        let url2 = try service.connectionURL()
        XCTAssertEqual(url1, url2)
    }

    @MainActor
    func testStandardConnectionURLFormat() throws {
        let service = PostgresService()
        let urlString = try service.standardConnectionURLString()
        let url = try service.standardConnectionURL()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedUser = NSUserName().addingPercentEncoding(withAllowedCharacters: allowed) ?? NSUserName()

        XCTAssertTrue(urlString.starts(with: "postgresql://\(encodedUser):"))
        XCTAssertFalse(urlString.contains("psycopg"))
        XCTAssertFalse(urlString.contains("postgres-superuser"))
        XCTAssertFalse(urlString.contains("postgres-master"))
        XCTAssertTrue(urlString.contains(Self.expectedLocation(service)))

        XCTAssertEqual(url.scheme, "postgresql")
        XCTAssertEqual(url.user, encodedUser)
        if service.socketDirectory == nil {
            XCTAssertEqual(url.host, "localhost")
            XCTAssertEqual(url.port, 14824)
        }
        XCTAssertEqual(url.path, "/garage-rag")
        XCTAssertEqual(url.absoluteString, urlString)
    }

    @MainActor
    func testStandardConnectionURLMatchesConnectionURLCredentials() throws {
        let service = PostgresService()
        let psycopgURL = try service.connectionURL()
        let standardURL = try service.standardConnectionURLString()

        // Extract user and host parts
        let psycopgSuffix = psycopgURL.replacingOccurrences(of: "postgresql+psycopg://", with: "")
        let standardSuffix = standardURL.replacingOccurrences(of: "postgresql://", with: "")
        XCTAssertEqual(psycopgSuffix, standardSuffix)
    }

    @MainActor
    func testCopyStandardConnectionURLToClipboard() throws {
        let service = PostgresService()
        let urlString = try service.copyStandardConnectionURLToClipboard()
        let clipboardContent = NSPasteboard.general.string(forType: .string)

        XCTAssertEqual(clipboardContent, urlString)
        XCTAssertTrue(clipboardContent?.starts(with: "postgresql://") == true)
    }

    func testPostgresStatusEquality() {
        XCTAssertEqual(PostgresStatus.stopped, PostgresStatus.stopped)
        XCTAssertEqual(PostgresStatus.starting, PostgresStatus.starting)
        XCTAssertEqual(PostgresStatus.needsMigration, PostgresStatus.needsMigration)
        XCTAssertEqual(PostgresStatus.running, PostgresStatus.running)
        XCTAssertEqual(PostgresStatus.stopping, PostgresStatus.stopping)
        XCTAssertEqual(PostgresStatus.failed("test"), PostgresStatus.failed("test"))
        XCTAssertNotEqual(PostgresStatus.failed("a"), PostgresStatus.failed("b"))
        XCTAssertNotEqual(PostgresStatus.stopped, PostgresStatus.running)
        XCTAssertNotEqual(PostgresStatus.needsMigration, PostgresStatus.running)
    }

    func testPostgresErrorDescriptions() {
        let initError = PostgresError.initFailed("init error output")
        XCTAssertTrue(initError.localizedDescription.contains("initdb failed"))
        XCTAssertTrue(initError.localizedDescription.contains("init error output"))

        let startError = PostgresError.startupTimeout
        XCTAssertTrue(startError.localizedDescription.contains("postgres did not report ready in time"))

        let otherError = PostgresError.other("custom failure message")
        XCTAssertEqual(otherError.localizedDescription, "custom failure message")
    }

    @MainActor
    func testConnectionURLIsShownWithoutThePassword() throws {
        let url = try XCTUnwrap(URL(string: "postgresql://garage:s3cr%40t@localhost:14824/garage"))

        let shown = PostgresService.redactedConnectionString(url)

        XCTAssertEqual(shown, "postgresql://garage:••••••@localhost:14824/garage")
        XCTAssertFalse(shown.contains("s3cr"))
    }

    func testSocketConnectionURLIsShownWithoutThePassword() throws {
        let url = try XCTUnwrap(URL(string: "postgresql://garage:s3cr%40t@/garage?host=%2Ftmp%2Fs&port=14824"))

        let shown = PostgresService.redactedConnectionString(url)

        XCTAssertFalse(shown.contains("s3cr"))
        XCTAssertTrue(shown.contains("garage:••••••@"))
    }

    func testConnectionURLWithoutAPasswordIsShownAsIs() throws {
        let url = try XCTUnwrap(URL(string: "postgresql://garage@localhost:14824/garage"))

        XCTAssertEqual(PostgresService.redactedConnectionString(url), url.absoluteString)
    }

    @MainActor
    func testDeleteClusterForResetIsANoOpInTests() async throws {
        // deleteClusterForReset() removes the live pgdata directory; under XCTest it must not touch it.
        let service = PostgresService()
        XCTAssertEqual(service.status, .stopped)
        try await service.deleteClusterForReset()
        XCTAssertEqual(service.status, .stopped)
        XCTAssertTrue(service.pendingMigrations.isEmpty)
    }

    @MainActor
    func testInitialPendingMigrationsIsEmpty() {
        let service = PostgresService()
        XCTAssertTrue(service.pendingMigrations.isEmpty)
    }

    @MainActor
    func testSetPendingMigrationsForTesting() {
        let service = PostgresService()
        service.setPendingMigrationsForTesting(["001_extensions.sql", "002_types.sql"])
        XCTAssertEqual(service.pendingMigrations, ["001_extensions.sql", "002_types.sql"])
    }

    @MainActor
    func testRefreshPendingMigrationsWhenStoppedReturnsEmpty() async {
        let service = PostgresService()
        let result = await service.refreshPendingMigrations()
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(service.pendingMigrations.isEmpty)
    }
}
