import Foundation
import Sparkle

/// Sparkle-backed updater, compiled into every configuration except the App
/// Store one. See `AppStoreUpdaterBackend.swift` for the other half.
enum UpdaterBackend {
    static let unavailableReason: String? = nil

    @MainActor
    static func makeDriver(configuration: UpdaterConfiguration) -> UpdaterDriving? {
        SparkleUpdaterDriver(configuration: configuration)
    }
}

@MainActor
final class SparkleUpdaterDriver: NSObject, UpdaterDriving {
    private let controller: SPUStandardUpdaterController
    /// Held here because the controller keeps its delegate weakly.
    private let channels: SparkleChannelDelegate
    private var canCheckObservation: NSKeyValueObservation?

    var onStateChange: (() -> Void)?

    /// Sparkle reads the feed URL and public key out of the app's Info.plist
    /// itself; `configuration` is only the proof that both are there, resolved
    /// before we start the updater so a misconfigured build fails visibly in
    /// the UI instead of silently at signature-check time.
    init(configuration _: UpdaterConfiguration) {
        let channels = SparkleChannelDelegate()
        self.channels = channels
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channels,
            userDriverDelegate: nil
        )
        super.init()

        // `canCheckForUpdates` goes false for the duration of a check, which is
        // what disables the menu item while one is running.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.onStateChange?()
            }
        }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            onStateChange?()
        }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    var receivesBetaUpdates: Bool {
        get { channels.receivesBetaUpdates }
        set {
            guard newValue != channels.receivesBetaUpdates else { return }
            channels.receivesBetaUpdates = newValue
            // Sparkle does this itself for its own settings, not for the channel list.
            controller.updater.resetUpdateCycleAfterShortDelay()
            onStateChange?()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Tells Sparkle which tagged entries to consider; untagged ones always are.
/// A separate object because the controller takes its delegate before the
/// driver's `super.init()` has run.
@MainActor
private final class SparkleChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var receivesBetaUpdates: Bool {
        get { defaults.bool(forKey: updaterReceivesBetaUpdatesKey) }
        set { defaults.set(newValue, forKey: updaterReceivesBetaUpdatesKey) }
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        receivesBetaUpdates ? [updaterBetaChannel] : []
    }
}
