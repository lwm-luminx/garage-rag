import AppKit
import Foundation
import PythonXPCService

/// `garage quit`: asks every running Garage to quit the way its Quit menu item does (services
/// stopped, Postgres given its shutdown checkpoint) and waits for it to exit. The launcher answers
/// it before Python starts, so it never opens the app it was asked to close.
enum AppQuit {
    static let bundleIdentifier = "me.rickmark.garage-rag"
    /// The app allows Postgres 15s for its shutdown checkpoint; this covers that and the rest of
    /// the quit.
    static let timeout: TimeInterval = 30

    static let usage = """
        usage: garage quit

        Quit Garage if it is running: its services stop and Postgres shuts down cleanly. Garage
        opens again by itself when a garage or garage-mcp command next needs the database.
        """

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else {
            print("Garage is not running.")
            return 0
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(GarageAppLaunch.quitNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        // isTerminated is updated through the run loop, so spin it rather than sleep.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) {
                print("Garage quit.")
                return 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let pids = running.filter { !$0.isTerminated }.map { String($0.processIdentifier) }
        fputs(
            "Garage (pid \(pids.joined(separator: ", "))) did not quit within \(Int(timeout))s. "
                + "Quit it from its menu bar item.\n",
            stderr
        )
        return 1
    }
}
