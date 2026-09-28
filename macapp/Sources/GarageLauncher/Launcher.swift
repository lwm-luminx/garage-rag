import Darwin
import Foundation
import PythonKit
import PythonXPCService

/// One of the launchers bundled as helper apps in `Garage.app/Contents/Helpers` (reached
/// through `Contents/MacOS/<name>`, a link to the forwarder script in `Resources/launchers`):
/// which Python entry point it runs and how.
public struct LauncherEntryPoint {
    let module: String
    let function: String
    /// Mirror stdout/stderr into the unified log. Off for `garage-mcp`: its stdout is
    /// the MCP protocol stream, which carries corpus text.
    let mirrorsOutputToLog: Bool
    /// Whether this invocation talks to the database, so the app has to be running.
    let needsDatabase: ([String]) -> Bool
    /// Answer `quit` here, before Python and before anything could start the app: `garage` only.
    let answersQuit: Bool
    /// Hold Python back until Postgres accepts connections. Off for `garage-mcp`: it
    /// only opens the database inside tool calls, and an MCP client times out a
    /// server whose `initialize` waits on a cold start.
    let waitsForDatabase: Bool

    /// `garage`: the full CLI.
    public static let cli = LauncherEntryPoint(
        module: "garage_rag.cli",
        function: "main_cli",
        mirrorsOutputToLog: true,
        needsDatabase: LauncherEntryPoint.cliNeedsDatabase,
        answersQuit: true,
        waitsForDatabase: true
    )

    /// `garage-mcp [--config PATH]`: the stdio MCP server that clients spawn.
    public static let mcp = LauncherEntryPoint(
        module: "garage_rag.mcp_server.server",
        function: "main",
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

    /// Whether this is `garage quit`, which never reaches Python.
    func isQuit(_ arguments: [String]) -> Bool {
        answersQuit && LauncherEntryPoint.command(in: arguments) == LauncherEntryPoint.quitCommand
    }
}

public enum Launcher {
    /// Runs `entry` in the embedded interpreter and exits with its status.
    public static func run(_ entry: LauncherEntryPoint) -> Never {
        if entry.isQuit(CommandLine.arguments) {
            exit(AppQuit.run(CommandLine.arguments))
        }
        let executable = executablePath()
        let appBundle = containingAppBundle(of: executable)
        exportMCPLauncherPath(appBundle: appBundle, executable: executable)
        exportModelManifest(in: appBundle)
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
        let status = runPython(entry, appBundle: appBundle)
        if entry.mirrorsOutputToLog {
            LauncherOutputCapturer.shared.flush()
        }
        exit(status)
    }

    /// This binary's real path, links resolved and `..` removed (the `Contents/MacOS`
    /// forwarder execs the helper by a relative path). `Bundle.main` is the helper
    /// bundle, not the app whose Frameworks and Resources the launcher needs.
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

    /// Tells Python where the bundled `garage-mcp` is, so `mcp-install` / `mcp-status`
    /// name the stdio entry point an MCP client can run (sys.executable names an
    /// interpreter the bundle does not ship).
    private static func exportMCPLauncherPath(appBundle: URL?, executable: URL) {
        if let path = mcpLauncherPath(appBundle: appBundle, executable: executable) {
            setenv("GARAGE_MCP_EXECUTABLE", path, 1)
        }
    }

    /// Tells Python where the app's gRPC server listens (`GARAGE_GRPC_SOCKET`), which on-demand model
    /// loads (`EnsureLlamaModel`) go through, unless the caller chose a socket or port already. The app
    /// listens on this socket in the App Group container, not on a TCP port.
    private static func exportGRPCSocket() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[GarageXPCConfigurationKey.grpcSocket] == nil,
              environment[GarageXPCConfigurationKey.grpcPort] == nil,
              let path = GarageSockets.path(for: GarageSockets.grpcName) else { return }
        setenv(GarageXPCConfigurationKey.grpcSocket, path, 1)
    }

    /// Points Python at the models.json the app uses (widths, distance metrics): the one it last
    /// fetched from the website, else the bundle's. Unless the caller chose another; outside the
    /// bundle garage_rag finds the repo's copy.
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

    /// Starts the isolated interpreter (PyConfig API) with `home`, stdlib, `lib-dynload`
    /// and `site-packages` from `site-python` in `PythonXPCService.framework`, which the
    /// launcher links, exactly like the XPC services do.
    private static func startPython() -> Bool {
        let runtime = GaragePythonRuntime.shared
        switch runtime.initializeIfNeeded() {
        case .success(let env):
            if isDebugging {
                fputs("[GARAGE_CLI] Python home: \(env.home.path)\n", stderr)
            }
            return true
        case .failure(let error):
            fputs("Error starting embedded Python: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static var isDebugging: Bool {
        ProcessInfo.processInfo.environment["GARAGE_DEBUG"] != nil || CommandLine.arguments.contains("--debug")
    }

    private static func runPython(_ entry: LauncherEntryPoint, appBundle: URL?) -> Int32 {
        guard startPython() else {
            return 1
        }
        do {
            return try GaragePythonRuntime.shared.withGIL { () throws -> Int32 in
                let sys = try Python.attemptImport("sys")
                sys.argv = PythonObject(CommandLine.arguments)
                attachStandardStreams(sys)

                do {
                    _ = try Python.attemptImport("site")
                } catch {
                    fputs("Warning: Could not import site module: \(error)\n", stderr)
                }

                if isDebugging {
                    let env = ProcessInfo.processInfo.environment
                    fputs("[GARAGE_CLI] Dynamic Python: \(env["PYTHON_LIBRARY"] ?? "default")\n", stderr)
                    fputs("[GARAGE_CLI] libpq: \(GaragePythonRuntime.shared.libpqPath ?? "not loaded")\n", stderr)
                    fputs("[GARAGE_CLI] Python sys.path: \(sys.path)\n", stderr)
                }

                let module: PythonObject
                do {
                    module = try Python.attemptImport(entry.module)
                } catch {
                    if let traceback = try? Python.attemptImport("traceback") {
                        _ = traceback.print_exc()
                    }
                    fputs("Error importing \(entry.module): \(error)\n", stderr)
                    fputs("[GARAGE_CLI] Python sys.path at failure: \(sys.path)\n", stderr)
                    return 1
                }
                // The throwing call surfaces Python exceptions as errors instead of PythonKit's `try!` trap. They are
                // handled here, with the GIL held: a PythonError that left this scope would be released without it,
                // which is a fatal Python error.
                do {
                    let result = try module[dynamicMember: entry.function].throwing.dynamicallyCall(withArguments: [])
                    return Int32(Int(result) ?? 0)
                } catch PythonError.exception(let exception, _)
                    where Bool(Python.isinstance(exception, Python.SystemExit)) == true {
                    return exitStatus(of: exception)
                } catch {
                    fputs("Error running \(entry.module).\(entry.function): \(GaragePythonRuntime.describe(error))\n", stderr)
                    return 1
                }
            }
        } catch {
            // Traceback formatting and any other Python access must happen with the GIL held.
            _ = try? GaragePythonRuntime.shared.withGIL {
                fputs("Error running \(entry.module).\(entry.function): \(GaragePythonRuntime.describe(error))\n", stderr)
            }
            return 1
        }
    }

    /// The status `SystemExit` asks for, as `python -m` would exit with it: argparse's `--help` and `exit(n)`.
    /// None is 0, an integer is itself, anything else is printed to stderr and exits 1.
    private static func exitStatus(of systemExit: PythonObject) -> Int32 {
        let code = systemExit.code
        if code == Python.None {
            return 0
        }
        if let status = Int(code) {
            return Int32(truncatingIfNeeded: status)
        }
        fputs("\(code)\n", stderr)
        return 1
    }

    /// Hands Python usable stdin/stdout/stderr when the embedded interpreter has none.
    private static func attachStandardStreams(_ sys: PythonObject) {
        do {
            let io = try Python.attemptImport("io")
            if sys.stdin == Python.None || Bool(Python.hasattr(sys.stdin, "read")) != true {
                let stdinObj = io.open(0, mode: "r", encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdin = stdinObj
                sys.__stdin__ = stdinObj
            }
            if sys.stdout == Python.None || Bool(Python.hasattr(sys.stdout, "write")) != true {
                let stdoutObj = io.open(1, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdout = stdoutObj
                sys.__stdout__ = stdoutObj
            }
            if sys.stderr == Python.None || Bool(Python.hasattr(sys.stderr, "write")) != true {
                let stderrObj = io.open(2, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stderr = stderrObj
                sys.__stderr__ = stderrObj
            }
        } catch {
            fputs("Warning: Could not configure standard streams for Python: \(error)\n", stderr)
        }
    }
}
