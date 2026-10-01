import Foundation
import PythonXPCService

/// Resolves where the Postgres install and the `garage` CLI live.
///
/// The Bazel-built app bundle (`//macapp:GarageApp`) vendors both under the
/// app bundle's Resources/ so the app runs with zero prerequisites; the
/// `devRepoRoot` fallbacks below only matter when a resource is missing
/// from the bundle.
enum Paths {
    /// The data directory: `Library/Application Support/GarageApp` in the App Group container, which
    /// the App Store and Developer ID builds share, or the per-user one when the process is not
    /// entitled for the group (locally signed and test builds). `GarageDataMigration` moves data
    /// from the per-user location into it at launch.
    static let appSupportDir: URL = {
        let dir = GarageAppGroup.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let pgDataDir = appSupportDir.appendingPathComponent("pgdata", isDirectory: true)

    /// `url` as people should read it: a path under the data directory is shown below
    /// `~/Library/Application Support/GarageApp`, however it is really reached. The group container
    /// path is long and the sandbox's home is its own container, while that one is the path people
    /// know (and, on a Developer ID build, a link to the group folder). Other paths are shown as is.
    static func displayPath(of url: URL, dataDirectory: URL = appSupportDir) -> String {
        let path = url.standardizedFileURL.path
        let data = dataDirectory.standardizedFileURL.path
        // A `--data-directory` folder is not the familiar one: show where it really is.
        guard GarageAppGroup.dataDirectoryOverride == nil,
              path == data || path.hasPrefix(data + "/") else { return path }
        return "~/Library/Application Support/\(GarageAppGroup.dataFolderName)" + path.dropFirst(data.count)
    }

    static let modelsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let logsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Root of everything vendored into the .app bundle, if we're running packaged.
    private static var root: URL {
        return Bundle.main.resourceURL!
    }

    private static let devRepoRoot: URL = {
        let candidate1 = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Developer/garage"))
        if FileManager.default.fileExists(atPath: candidate1.path) {
            return candidate1
        }
        return URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("garage"))
    }()

    static var isPackaged: Bool {
        return true
    }

    static var postgresDir: URL {
        return root.appendingPathComponent("postgres", isDirectory: true)
    }

    /// Directory containing the SQL schema bundled with the application.
    static var schemaDir: URL {
        return root.appendingPathComponent("schema", isDirectory: true)
    }

    /// Path to postgresql.conf configuration file.
    static var postgresConfigFile: URL {
        if let resourceURL = Bundle.main.url(forResource: "postgresql", withExtension: "conf") {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "postgres", withExtension: "conf") {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "postgresql.conf", withExtension: nil) {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "postgres.conf", withExtension: nil) {
            return resourceURL
        }
        let bundledPostgresConf = root.appendingPathComponent("postgres/postgresql.conf")
        if FileManager.default.fileExists(atPath: bundledPostgresConf.path) {
            return bundledPostgresConf
        }
        let bundledConf = root.appendingPathComponent("postgresql.conf")
        if FileManager.default.fileExists(atPath: bundledConf.path) {
            return bundledConf
        }
        let bundledAltConf = root.appendingPathComponent("postgres.conf")
        if FileManager.default.fileExists(atPath: bundledAltConf.path) {
            return bundledAltConf
        }
        let devCandidates = [
            devRepoRoot.appendingPathComponent("macapp/externals/postgresql.conf"),
            devRepoRoot.appendingPathComponent("macapp/externals/postgres.conf"),
        ]
        for candidate in devCandidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return bundledPostgresConf
    }

    /// Path to the models.json manifest: the one last fetched from the website (`ModelCatalog`),
    /// else the copy in the bundle. A fetched copy that lacks a group the bundled one has (the site
    /// not yet redeployed after a release added `image_embedding`) would hide those models, so it
    /// is used only when it covers every group of the bundled copy.
    static var modelsJSON: URL {
        let fetched = ModelCatalog.fetchedURL
        let bundled = bundledModelsJSON
        if FileManager.default.fileExists(atPath: fetched.path),
           ModelCatalog.covers(fetched, groupsOf: bundled) {
            return fetched
        }
        return bundled
    }

    /// The models.json the app ships with (or the repository's, in a development run).
    static var bundledModelsJSON: URL {
        if let resourceURL = Bundle.main.url(forResource: "models", withExtension: "json") {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "models.json", withExtension: nil) {
            return resourceURL
        }
        let bundled = root.appendingPathComponent("models.json")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let bundledDataModels = root.appendingPathComponent("data/models/models.json")
        if FileManager.default.fileExists(atPath: bundledDataModels.path) {
            return bundledDataModels
        }
        let devPath = devRepoRoot.appendingPathComponent("data/models/models.json")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return bundled
    }

    /// Directory containing postgres/initdb/pg_ctl/pg_isready/psql.
    static var postgresBinDir: URL {
        return root.appendingPathComponent("postgres/bin", isDirectory: true)
    }

    /// Directory postgres should treat as its lib dir (for dynamic loading of extensions).
    static var postgresLibDir: URL {
        return root.appendingPathComponent("postgres/lib", isDirectory: true)
    }

    /// Directory postgres should treat as its share dir (extension SQL/control files).
    static var postgresShareDir: URL {
        return root.appendingPathComponent("postgres/share", isDirectory: true)
    }

    static func postgresTool(_ name: String) -> URL {
        postgresBinDir.appendingPathComponent(name)
    }

    /// The bundled `garage` entry point, `Contents/MacOS/garage` (the forwarder to the helper bundle), or
    /// the venv's `garage` script (dev).
    static var garageCLI: URL {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "garage"),
           FileManager.default.fileExists(atPath: aux.path) {
            return aux
        }
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("garage"),
           FileManager.default.fileExists(atPath: execURL.path) {
            return execURL
        }
        let bundled = root.appendingPathComponent("garage", isDirectory: false)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let res = Bundle.main.url(forResource: "garage", withExtension: nil),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        let devCandidates = [
            devRepoRoot.appendingPathComponent(".venv/bin/garage"),
            devRepoRoot.appendingPathComponent("bazel-bin/garage_python/garage"),
        ]
        for candidate in devCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return bundled
    }

    /// The bundled `garage-mcp` entry point, `Contents/MacOS/garage-mcp` (the forwarder to the helper
    /// bundle, the stable path a stdio registration keeps), or the venv's script (dev).
    static var garageMCP: URL {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "garage-mcp"),
           FileManager.default.fileExists(atPath: aux.path) {
            return aux
        }
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("garage-mcp"),
           FileManager.default.fileExists(atPath: execURL.path) {
            return execURL
        }
        let bundled = root.appendingPathComponent("garage-mcp", isDirectory: false)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let res = Bundle.main.url(forResource: "garage-mcp", withExtension: nil),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        let devCandidates = [
            devRepoRoot.appendingPathComponent(".venv/bin/garage-mcp"),
            devRepoRoot.appendingPathComponent("bazel-bin/garage_python/garage-mcp"),
        ]
        for candidate in devCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return bundled
    }

    /// Working directory of the gRPC server, where it finds `./garage.json`,
    /// and where its `.env` lives. In dev mode this is the repo checkout,
    /// matching what a developer running `garage` by hand would get. Packaged
    /// builds have no checkout, so they get a private .env under Application
    /// Support instead (garage reads it via GARAGE_ENV_FILE, not cwd-relative
    /// discovery).
    static var garageWorkingDirectory: URL {
        isPackaged ? appSupportDir : devRepoRoot
    }
}
