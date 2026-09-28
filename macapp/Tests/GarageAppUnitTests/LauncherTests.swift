import XCTest
import PythonXPCService
@testable import GarageLauncher

/// The launchers run as helper bundles inside Garage.app; what they derive from their own path
/// must still name the outer app, whose Frameworks, Resources and forwarders they use.
final class LauncherTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("LauncherTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func executable(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(
            fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]),
            "could not create \(url.path)"
        )
        return url
    }

    func testTheHelperBundleResolvesToTheOuterApp() throws {
        let launcher = try executable("Applications/Garage.app/Contents/Helpers/garage.app/Contents/MacOS/garage")
        XCTAssertEqual(
            Launcher.containingAppBundle(of: launcher)?.path,
            root.appendingPathComponent("Applications/Garage.app").path
        )
    }

    func testABareLauncherInMacOSStillResolvesToTheApp() throws {
        let launcher = try executable("Applications/Garage.app/Contents/MacOS/garage")
        XCTAssertEqual(
            Launcher.containingAppBundle(of: launcher)?.path,
            root.appendingPathComponent("Applications/Garage.app").path
        )
    }

    func testOutsideAnAppThereIsNoBundle() throws {
        let launcher = try executable("bin/garage")
        XCTAssertNil(Launcher.containingAppBundle(of: launcher))
    }

    /// `GARAGE_MCP_EXECUTABLE` names the forwarder in Contents/MacOS, the stable path a client
    /// registration keeps, not the helper bundle's executable.
    func testTheMCPEntryPointIsTheForwarderInTheApp() throws {
        let launcher = try executable("Applications/Garage.app/Contents/Helpers/garage.app/Contents/MacOS/garage")
        _ = try executable("Applications/Garage.app/Contents/Helpers/garage-mcp.app/Contents/MacOS/garage-mcp")
        let forwarder = try executable("Applications/Garage.app/Contents/MacOS/garage-mcp")
        let appBundle = Launcher.containingAppBundle(of: launcher)
        XCTAssertEqual(Launcher.mcpLauncherPath(appBundle: appBundle, executable: launcher), forwarder.path)
    }

    func testWithoutAForwarderTheSiblingIsUsed() throws {
        let launcher = try executable("bin/garage")
        let sibling = try executable("bin/garage-mcp")
        XCTAssertEqual(Launcher.mcpLauncherPath(appBundle: nil, executable: launcher), sibling.path)
    }

    func testNoMCPLauncherMeansNoPath() throws {
        let launcher = try executable("bin/garage")
        XCTAssertNil(Launcher.mcpLauncherPath(appBundle: nil, executable: launcher))
    }

    // MARK: - garage quit

    func testTheCommandIsFoundPastGlobalOptions() {
        XCTAssertEqual(LauncherEntryPoint.command(in: ["garage", "quit"]), "quit")
        XCTAssertEqual(LauncherEntryPoint.command(in: ["garage", "--config", "/tmp/g.json", "search", "x"]), "search")
        XCTAssertEqual(LauncherEntryPoint.command(in: ["garage", "-c", "quit", "status"]), "status")
        XCTAssertNil(LauncherEntryPoint.command(in: ["garage", "--verbose"]))
    }

    /// `garage quit` must not start the app it is about to quit.
    func testQuitIsAnsweredByTheCLILauncherWithoutTheDatabase() {
        XCTAssertTrue(LauncherEntryPoint.cli.isQuit(["garage", "quit"]))
        XCTAssertTrue(LauncherEntryPoint.cli.isQuit(["garage", "--config", "/tmp/g.json", "quit"]))
        XCTAssertFalse(LauncherEntryPoint.cliNeedsDatabase(["garage", "quit"]))
        XCTAssertTrue(LauncherEntryPoint.cliNeedsDatabase(["garage", "status"]))
    }

    func testOnlyTheCLILauncherAnswersQuit() {
        XCTAssertFalse(LauncherEntryPoint.mcp.isQuit(["garage-mcp", "quit"]))
        XCTAssertFalse(LauncherEntryPoint.cli.isQuit(["garage", "search", "quit"]))
    }
}
