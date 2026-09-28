import XCTest
import PythonXPCService
@testable import GarageApp

final class GarageDataMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var shared: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GarageDataMigrationTests-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("Application Support/GarageApp", isDirectory: true)
        shared = root.appendingPathComponent("Group Containers/group/Library/Application Support/GarageApp", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ relativePath: String, in base: URL, _ text: String = "x") throws {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relativePath: String, in base: URL) -> String? {
        try? String(contentsOf: base.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testMovesEverythingAndLinksTheOldFolder() throws {
        try write("pgdata/PG_VERSION", in: legacy, "18")
        try write("models/bge-m3-Q8_0.gguf", in: legacy)
        try write("garage.json", in: legacy, "{}")
        try write(".DS_Store", in: legacy)

        let outcome = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertEqual(outcome.moved, ["garage.json", "models", "pgdata"])
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertTrue(outcome.linkedLegacyDirectory)
        XCTAssertEqual(read("pgdata/PG_VERSION", in: shared), "18")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), shared.standardizedFileURL.path)
        // Old paths still resolve, through the link.
        XCTAssertEqual(read("pgdata/PG_VERSION", in: legacy), "18")
    }

    func testSecondRunIsANoOp() throws {
        try write("pgdata/PG_VERSION", in: legacy, "18")
        GarageDataMigration.migrate(from: legacy, to: shared)

        let again = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertEqual(again, GarageDataMigration.Outcome())
        XCTAssertEqual(read("pgdata/PG_VERSION", in: shared), "18")
    }

    func testNeverOverwritesAClusterAlreadyInTheSharedFolder() throws {
        try write("pgdata/PG_VERSION", in: legacy, "legacy")
        try write("pgdata/PG_VERSION", in: shared, "shared")

        let outcome = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertNotNil(outcome.skipped["pgdata"])
        XCTAssertFalse(outcome.linkedLegacyDirectory)
        XCTAssertEqual(read("pgdata/PG_VERSION", in: shared), "shared")
        XCTAssertEqual(read("pgdata/PG_VERSION", in: legacy), "legacy")
    }

    func testReplacesEmptyDirectoriesAServiceCreatedFirst() throws {
        try write("models/model.gguf", in: legacy)
        try fm.createDirectory(at: shared.appendingPathComponent("models"), withIntermediateDirectories: true)
        try write("logs/.DS_Store", in: shared)

        let outcome = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertEqual(outcome.moved, ["models"])
        XCTAssertNotNil(read("models/model.gguf", in: shared))
    }

    func testLeavesPgdataWhilePostgresRunsFromIt() throws {
        try write("pgdata/PG_VERSION", in: legacy, "18")
        // Our own pid is certainly alive.
        try write("pgdata/postmaster.pid", in: legacy, "\(getpid())\n\(legacy.path)/pgdata\n")
        try write("models/model.gguf", in: legacy)

        // No test process is a postgres, so stand one in for the check.
        let outcome = GarageDataMigration.migrate(from: legacy, to: shared, isPostmaster: { $0 == getpid() })

        XCTAssertEqual(outcome.moved, ["models"])
        XCTAssertNotNil(outcome.skipped["pgdata"])
        XCTAssertFalse(outcome.linkedLegacyDirectory)
        XCTAssertTrue(GarageDataMigration.hasUnmigratedCluster(legacy: legacy, shared: shared))
    }

    func testAStalePidFileDoesNotBlockTheMove() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try write("pgdata/PG_VERSION", in: legacy, "18")
        try write("pgdata/postmaster.pid", in: legacy, "\(process.processIdentifier)\n")

        let outcome = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertEqual(outcome.moved, ["pgdata"])
        XCTAssertFalse(GarageDataMigration.hasUnmigratedCluster(legacy: legacy, shared: shared))
    }

    func testAPidFileNamingAnotherLiveProcessDoesNotBlockTheMove() throws {
        // After a reboot the stale file's pid can belong to any process; this test's own is alive
        // and is not a postgres.
        try write("pgdata/PG_VERSION", in: legacy, "18")
        try write("pgdata/postmaster.pid", in: legacy, "\(getpid())\n\(legacy.path)/pgdata\n")

        let outcome = GarageDataMigration.migrate(from: legacy, to: shared)

        XCTAssertEqual(outcome.moved, ["pgdata"])
        XCTAssertFalse(GarageDataMigration.isPostgresProcess(getpid()))
    }

    func testNothingToDoWithoutAnOldFolder() throws {
        try fm.removeItem(at: legacy)

        XCTAssertEqual(GarageDataMigration.migrate(from: legacy, to: shared), GarageDataMigration.Outcome())
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    func testSameFolderIsNotAMigration() throws {
        try write("pgdata/PG_VERSION", in: legacy, "18")

        XCTAssertEqual(GarageDataMigration.migrate(from: legacy, to: legacy), GarageDataMigration.Outcome())
        XCTAssertFalse(GarageDataMigration.hasUnmigratedCluster(legacy: legacy, shared: legacy))
    }

    func testLinksTheUnsandboxedPathOnAFreshInstall() throws {
        try fm.removeItem(at: legacy)

        XCTAssertTrue(GarageDataMigration.linkLegacyDirectory(legacy, to: shared))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), shared.standardizedFileURL.path)
        try write("garage.json", in: shared, "{}")
        XCTAssertEqual(read("garage.json", in: legacy), "{}")
    }

    func testAnExistingLinkIsLeftAsIs() throws {
        try write("pgdata/PG_VERSION", in: legacy, "18")
        XCTAssertTrue(GarageDataMigration.migrate(from: legacy, to: shared).linkedLegacyDirectory)

        XCTAssertFalse(GarageDataMigration.linkLegacyDirectory(legacy, to: shared))

        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.removeItem(at: legacy)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: elsewhere)
        XCTAssertFalse(GarageDataMigration.linkLegacyDirectory(legacy, to: shared))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), elsewhere.path)
    }

    func testAFolderStillThereIsNotReplacedByALink() throws {
        try write("pgdata/PG_VERSION", in: legacy, "the other build's")

        XCTAssertFalse(GarageDataMigration.linkLegacyDirectory(legacy, to: shared))
        XCTAssertEqual(read("pgdata/PG_VERSION", in: legacy), "the other build's")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: legacy.path))
    }

    func testAppGroupIdentifierIsTeamPrefixed() {
        // The macOS form: a Developer ID build may use it without a provisioning profile.
        XCTAssertTrue(GarageAppGroup.identifier.hasPrefix("DWVXMLB45Y."))
        XCTAssertEqual(GarageFileLogger.appGroupIdentifier, GarageAppGroup.identifier)
    }

    func testTestHostIsNotEntitledSoPathsStayPerUser() {
        XCTAssertFalse(GarageAppGroup.isEntitled)
        XCTAssertEqual(GarageAppGroup.dataDirectory, GarageAppGroup.legacyDataDirectory)
    }
}
