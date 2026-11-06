import AppKit
import Foundation
import GarageXPCKit

/// Gets a launcher connected to the app's private Postgres: starts Garage.app
/// hidden when nothing is listening, then exports `GARAGE_DATABASE_URL` with the
/// password read from the Keychain. Runs before Python starts, so the interpreter's
/// environment already has the URL.
///
/// With `waitUntilReady` false (`garage-mcp`) the app is started but not waited
/// for: the URL only needs the password, and a tool call made while Postgres is
/// still starting fails with a connection error rather than the whole handshake
/// timing out. The one exception is a first run, where the app has not stored a
/// password yet; then it waits for the app to create the cluster.
enum AppDatabase {
    enum Failure: LocalizedError {
        case launchDisabled
        case noAppBundle(String)
        case launchFailed(String)
        case notReady(TimeInterval)
        case noPassword

        var errorDescription: String? {
            switch self {
            case .launchDisabled:
                return "Garage's database is not running, and GARAGE_NO_APP_LAUNCH is set. Open Garage, or unset it."
            case .noAppBundle(let path):
                return "Garage's database is not running, and \(path) is not inside Garage.app, so the app cannot be started."
            case .launchFailed(let reason):
                return "Garage's database is not running and Garage.app could not be started: \(reason)"
            case .notReady(let seconds):
                return "Garage started, but its database did not accept connections within \(Int(seconds))s. "
                    + "Open Garage and check the Database page."
            case .noPassword:
                return "Garage has not created its database yet. Open Garage once to set it up."
            }
        }
    }

    /// How long a cold start (the app launching, Postgres starting, maybe initdb) may take.
    static let readyTimeout: TimeInterval = 60

    static func prepare(appBundle: URL?, executable: String, waitUntilReady: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        // An explicit URL wins: someone pointing the launcher at another database.
        if let url = environment["GARAGE_DATABASE_URL"], !url.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }

        var launched = false
        if !GaragePostgresEndpoint.isAcceptingConnections() {
            guard environment["GARAGE_NO_APP_LAUNCH"] == nil else { throw Failure.launchDisabled }
            guard let appBundle else { throw Failure.noAppBundle(executable) }
            // stderr only: for garage-mcp, stdout is the protocol stream.
            fputs("Starting Garage…\n", stderr)
            try launchHidden(appBundle)
            launched = true
            if waitUntilReady {
                try waitForDatabase()
            }
        }

        var password = try GaragePostgresEndpoint.readPassword()
        if password == nil, launched, !waitUntilReady {
            try waitForDatabase()
            password = try GaragePostgresEndpoint.readPassword()
        }
        guard let password else { throw Failure.noPassword }
        setenv("GARAGE_DATABASE_URL", try GaragePostgresEndpoint.connectionURL(password: password), 1)
    }

    /// Opens the app without activating it or showing its window; `--background`
    /// tells it to start its services and stay in the menu bar.
    private static func launchHidden(_ appBundle: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.arguments = [GarageAppLaunch.backgroundArgument]

        final class Outcome: @unchecked Sendable {
            var error: Error?
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appBundle, configuration: configuration) { _, error in
            outcome.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + readyTimeout) == .success else {
            throw Failure.launchFailed("Launch Services did not answer within \(Int(readyTimeout))s")
        }
        if let error = outcome.error {
            throw Failure.launchFailed(error.localizedDescription)
        }
    }

    private static func waitForDatabase() throws {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if GaragePostgresEndpoint.isAcceptingConnections() {
                return
            }
            usleep(250_000)
        }
        throw Failure.notReady(readyTimeout)
    }
}
