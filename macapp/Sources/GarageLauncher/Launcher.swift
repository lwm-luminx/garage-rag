import Darwin
import Foundation
import GarageCLIFFI
import PythonXPCService_protocol

/// One of the launchers bundled as helper apps in `Garage.app/Contents/Helpers` (reached
/// through `Contents/MacOS/<name>`, a link to the forwarder script in `Resources/launchers`):
/// which entry point of the Rust CLI (`rust/garage-cli`, linked statically) it runs and how.
public struct LauncherEntryPoint {
    /// The C `main` the Rust library exports.
    let main: (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32
    /// Mirror stdout/stderr into the unified log. Off for `garage-mcp`: its stdout is
    /// the MCP protocol stream, which carries corpus text.
    let mirrorsOutputToLog: Bool
    /// Whether this invocation talks to the database, so the app has to be running.
    let needsDatabase: ([String]) -> Bool
    /// Answer `quit` here, before the CLI and before anything could start the app: `garage` only.
    let answersQuit: Bool
    /// Hold the command back until Postgres accepts connections. Off for `garage-mcp`: it
    /// only opens the database inside tool calls, and an MCP client times out a
    /// server whose `initialize` waits on a cold start.
    let waitsForDatabase: Bool

    /// `garage`: the full CLI.
    public static let cli = LauncherEntryPoint(
        main: garage_cli_main,
        mirrorsOutputToLog: true,
        needsDatabase: LauncherEntryPoint.cliNeedsDatabase,
        answersQuit: true,
        waitsForDatabase: true
    )

    /// `garage-mcp [--config PATH]`: the stdio MCP server that clients spawn.
    public static let mcp = LauncherEntryPoint(
        main: garage_mcp_main,
        mirrorsOutputToLog: false,
        needsDatabase: { arguments in !arguments.contains("--help") && !arguments.contains("-h") },
        answersQuit: false,
        waitsForDatabase: false
    )

    /// Subcommands that never open the database.
    static let commandsWithoutDatabase: Set<String> = ["config", "mcp-install", "mcp-uninstall", "mcp-status", "version"]

    /// `garage quit`, which the launcher answers itself (`AppQuit`).
    static let quitCommand = "quit"

    /// `garage [global options] COMMAND ...`: false for help, bare `garage`, `quit` and
    /// `commandsWithoutDatabase`, so those work without starting the app.
    static func cliNeedsDatabase(_ arguments: [String]) -> Bool {
        if arguments.contains("--help") || arguments.contains("-h") {
            return false
        }
        guard let command = command(in: arguments), command != quitCommand else { return false }
        return !commandsWithoutDatabase.contains(command)
    }

    /// The subcommand of `garage [global options] COMMAND ...` (`arguments` includes the program
    /// name), past `--config PATH` / `-c PATH` and other options; nil when there is none.
    static func command(in arguments: [String]) -> String? {
        var remaining = arguments.dropFirst()
        while let option = remaining.first, option.hasPrefix("-") {
            remaining = remaining.dropFirst()
            if option == "--config" || option == "-c" {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.first
    }

    /// Whether this is `garage quit`, which never reaches the CLI.
    func isQuit(_ arguments: [String]) -> Bool {
        answersQuit && LauncherEntryPoint.command(in: arguments) == LauncherEntryPoint.quitCommand
    }
}

public enum Launcher {
    /// Runs `entry` in this process and exits with its status.
    public static func run(_ entry: LauncherEntryPoint) -> Never {
        if entry.isQuit(CommandLine.arguments) {
            exit(AppQuit.run(CommandLine.arguments))
        }
        let executable = executablePath()
        let appBundle = containingAppBundle(of: executable)
        exportMCPLauncherPath(appBundle: appBundle, executable: executable)
        exportModelManifest(in: appBundle)
        exportSchemaDirectory(in: appBundle)
        exportGRPCSocket()
        GarageSockets.exportLlamaSocket()

        if entry.needsDatabase(CommandLine.arguments) {
            do {
                try AppDatabase.prepare(
                    appBundle: appBundle,
                    executable: executable.path,
                    waitUntilReady: entry.waitsForDatabase
                )
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if entry.mirrorsOutputToLog {
            LauncherOutputCapturer.shared.start()
        }
        let status = runMain(entry)
        if entry.mirrorsOutputToLog {
            LauncherOutputCapturer.shared.flush()
        }
        exit(status)
    }

    /// This binary's real path, links resolved and `..` removed (the `Contents/MacOS`
    /// forwarder execs the helper by a relative path). `Bundle.main` is the helper
    /// bundle, not the app whose Resources the launcher needs.
    static func executablePath() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The outermost `.app` the launcher runs from: `Garage.app` for the helper bundle at
    /// `Garage.app/Contents/Helpers/<helper>.app/Contents/MacOS/<launcher>`, and also for a
    /// bare `Garage.app/Contents/MacOS/<launcher>`. Nil outside an app bundle.
    static func containingAppBundle(of executable: URL) -> URL? {
        var outermost: URL?
        var cursor = executable.deletingLastPathComponent()
        while cursor.pathComponents.count > 1 {
            if cursor.pathExtension == "app" {
                outermost = cursor
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return outermost
    }

    /// The stable `garage-mcp` entry point an MCP client can run: `Contents/MacOS/garage-mcp`
    /// of the app, which forwards to the helper bundle. Next to the executable when the
    /// launcher is not inside the app.
    static func mcpLauncherPath(appBundle: URL?, executable: URL) -> String? {
        var candidates: [URL] = []
        if let appBundle {
            candidates.append(appBundle.appendingPathComponent("Contents/MacOS/garage-mcp", isDirectory: false))
        }
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("garage-mcp", isDirectory: false))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Tells the service where the bundled `garage-mcp` is, so `mcp-install` / `mcp-status`
    /// name the stdio entry point an MCP client can run.
    private static func exportMCPLauncherPath(appBundle: URL?, executable: URL) {
        if let path = mcpLauncherPath(appBundle: appBundle, executable: executable) {
            setenv("GARAGE_MCP_EXECUTABLE", path, 1)
        }
    }

    /// Tells the service where the app's gRPC server listens (`GARAGE_GRPC_SOCKET`), which on-demand
    /// model loads (`EnsureLlamaModel`) go through, unless the caller chose a socket or port already.
    /// The app listens on this socket in the App Group container, not on a TCP port.
    private static func exportGRPCSocket() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[GarageXPCConfigurationKey.grpcSocket] == nil,
              environment[GarageXPCConfigurationKey.grpcPort] == nil,
              let path = GarageSockets.path(for: GarageSockets.grpcName) else { return }
        setenv(GarageXPCConfigurationKey.grpcSocket, path, 1)
    }

    /// Points the service at the models.json the app uses (widths, distance metrics): the one it
    /// last fetched from the website, else the bundle's. Unless the caller chose another; outside
    /// the bundle the service finds the repo's copy.
    private static func exportModelManifest(in appBundle: URL?) {
        guard ProcessInfo.processInfo.environment["GARAGE_MODEL_MANIFEST"] == nil, let appBundle else { return }
        let candidates = [
            GarageAppGroup.fetchedModelCatalog,
            appBundle.appendingPathComponent("Contents/Resources/models.json"),
        ]
        if let manifest = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            setenv("GARAGE_MODEL_MANIFEST", manifest.path, 1)
        }
    }

    /// Points `init-db` at the schema the app bundles (`Contents/Resources/schema`,
    /// `//macapp/externals:schema_output`), as the app does for its own service (`GARAGE_SQL_DIR`).
    private static func exportSchemaDirectory(in appBundle: URL?) {
        guard ProcessInfo.processInfo.environment["GARAGE_SQL_DIR"] == nil, let appBundle else { return }
        let schema = appBundle.appendingPathComponent("Contents/Resources/schema", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: schema.path, isDirectory: &isDirectory), isDirectory.boolValue {
            setenv("GARAGE_SQL_DIR", schema.path, 1)
        }
    }

    /// Calls the entry point's C `main` with this process's arguments.
    private static func runMain(_ entry: LauncherEntryPoint) -> Int32 {
        let arguments = CommandLine.arguments
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        defer {
            for pointer in pointers {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        pointers.append(nil)
        return pointers.withUnsafeBufferPointer { buffer in
            entry.main(Int32(arguments.count), buffer.baseAddress)
        }
    }
}
