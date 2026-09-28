import AppKit
import PythonXPCService

/// Keeps the app running in the menu bar after the main window closes (this
/// is a menu-bar-resident app, not a document-based one), and makes sure the
/// Postgres child process is signaled and stopped on every quit path — Cmd+Q,
/// Dock > Quit, system shutdown, or the menu bar's own Quit item — not just the one button
/// that calls AppState.stopPostgres() directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState? {
        get { _appState ?? AppState.shared }
        set { _appState = newValue }
    }
    private var _appState: AppState?
    private var isTerminating = false
    private var quitObserver: NSObjectProtocol?

    /// Quit Garage (⌘Q and the menu bar's Quit). AppKit refuses to terminate while a window shows a
    /// sheet ("App termination blocked by modal sheet"), and the splash is shown as one at every
    /// launch. The sheets are SwiftUI's, so they are closed through their views' state
    /// (`garageWillQuit`); ending them in AppKit alone left the state set, and SwiftUI put the
    /// sheet back before `terminate:` looked. `terminate:` then runs once no sheet is attached (or
    /// after a second), from the run loop: never from inside a main-actor task, where
    /// `.terminateLater` deadlocks (see `AppState.terminateFromRunLoop`).
    static func quit() {
        NotificationCenter.default.post(name: .garageWillQuit, object: nil)
        terminateWhenNoSheet(deadline: Date().addingTimeInterval(1))
    }

    private static func terminateWhenNoSheet(deadline: Date) {
        let windowsWithSheets = NSApp.windows.filter { $0.attachedSheet != nil }
        if windowsWithSheets.isEmpty || Date() >= deadline {
            // A sheet no view state closed: end it in AppKit as a last resort.
            for window in windowsWithSheets {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            RunLoop.main.perform { NSApp.terminate(nil) }
            return
        }
        // Let SwiftUI apply the state change and animate the sheet out before looking again.
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { terminateWhenNoSheet(deadline: deadline) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The `garage` / `garage-mcp` launchers open the app with `--background` when its
    /// database is not running: start the services, keep to the menu bar, and close
    /// the window SwiftUI opens at launch (the Dock icon or menu bar item reopens it).
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearanceArgument()

        // `garage quit`: quit as the Quit menu item does, from the run loop.
        quitObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(GarageAppLaunch.quitNotification),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.quit() }
        }

        guard CommandLine.arguments.contains(GarageAppLaunch.backgroundArgument) else { return }
        Task { @MainActor [weak self] in
            self?.appState?.launch()
            for window in NSApp.windows where window.title == "Garage" {
                window.close()
            }
        }
    }

    /// `--appearance light|dark` pins the app's appearance for this run (see `GarageAppLaunch`).
    private func applyAppearanceArgument() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: GarageAppLaunch.appearanceArgument),
              arguments.indices.contains(index + 1) else { return }
        switch arguments[index + 1].lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true

        let state = self.appState
        // After "Reset Database" relaunched the app, everything here is already stopped and what is
        // running belongs to the new instance: quit at once, without the shutdown below.
        if state?.hasHandedOffToRelaunch == true {
            return .terminateNow
        }

        Task { @MainActor in
            let shutdownTask = Task { @MainActor in
                if let state = state {
                    await state.stopPostgres()
                } else {
                    await PostgresService.stopAnyRunningInstance()
                }
            }

            // Room for Postgres's shutdown checkpoint (PostgresService.stop polls for up to 10s).
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                shutdownTask.cancel()
            }

            _ = await shutdownTask.result
            timeoutTask.cancel()

            if let state = state {
                state.terminateImmediately()
            } else {
                XPCServiceManager.stopAnyRunningInstances()
                PostgresService.stopAnyRunningInstanceSync()
            }

            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let state = appState {
            state.terminateImmediately()
        } else {
            XPCServiceManager.stopAnyRunningInstances()
            PostgresService.stopAnyRunningInstanceSync()
        }
    }
}
