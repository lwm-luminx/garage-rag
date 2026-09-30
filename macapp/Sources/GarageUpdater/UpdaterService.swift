import Combine
import Foundation

/// Detects whether the code is currently running within a test environment.
/// Mirrors the helper in `GarageApp` — `GarageUpdater` sits below it and can't
/// import it.
public var updaterIsRunningInTestEnvironment: Bool {
    NSClassFromString("XCTestCase") != nil ||
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
    ProcessInfo.processInfo.environment["TEST_WORKSPACE"] != nil ||
    ProcessInfo.processInfo.environment["TEST_SRCDIR"] != nil ||
    ProcessInfo.processInfo.environment["BAZEL_TEST"] != nil
}

/// The slice of Sparkle the app actually uses, behind a protocol so that the
/// App Store build (which embeds no Sparkle at all) and the tests can stand in
/// for it.
@MainActor
public protocol UpdaterDriving: AnyObject {
    /// False while a check is already in flight.
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// Whether entries on the `beta` channel are offered as well as untagged ones.
    var receivesBetaUpdates: Bool { get set }
    /// Invoked when any of the above change, so the service can republish them.
    var onStateChange: (() -> Void)? { get set }
    func checkForUpdates()
}

public enum UpdaterState: Equatable, Sendable {
    case ready
    case unavailable(reason: String)
}

/// Observable front end for Sparkle.
///
/// Every build gets one of these; only Developer ID builds get one backed by a
/// real updater. Everywhere else `state` carries the reason, which the UI shows
/// in place of the controls.
@MainActor
public final class UpdaterService: ObservableObject {
    public static let shared = UpdaterService()

    @Published public private(set) var state: UpdaterState
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var lastUpdateCheckDate: Date?

    /// Whether Sparkle checks on its own schedule. Sparkle persists this itself
    /// (and asks the user once on an early launch if it was never answered), so
    /// this is a view onto the updater's setting, not a second copy of it.
    @Published public var automaticallyChecksForUpdates = false {
        didSet {
            guard !isRepublishing else { return }
            driver?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// "Receive Beta Updates". The driver persists it, so like the setting above
    /// this is a view onto the driver's value.
    @Published public var receivesBetaUpdates = false {
        didSet {
            guard !isRepublishing else { return }
            driver?.receivesBetaUpdates = receivesBetaUpdates
        }
    }

    private let driver: UpdaterDriving?
    /// Set while copying the driver's values in, so `didSet` doesn't write them
    /// straight back out again.
    private var isRepublishing = false

    /// Builds a service driven by a real (or fake) updater.
    public init(driver: UpdaterDriving) {
        self.driver = driver
        state = .ready
        driver.onStateChange = { [weak self] in self?.republishDriverState() }
        republishDriverState()
    }

    /// Builds a service for a configuration that can't update itself.
    public init(unavailableReason: String) {
        driver = nil
        state = .unavailable(reason: unavailableReason)
    }

    /// The initializer the app uses: picks the backend compiled into this
    /// configuration, and only starts it once the Info.plist has been checked.
    public convenience init(
        availability: UpdaterAvailability = .resolve(),
        isTestEnvironment: Bool = updaterIsRunningInTestEnvironment
    ) {
        if let reason = UpdaterBackend.unavailableReason {
            self.init(unavailableReason: reason)
            return
        }
        // Starting Sparkle under XCTest would schedule real update checks
        // against the live feed from a test binary.
        if isTestEnvironment {
            self.init(unavailableReason: "Update checks are disabled while running tests.")
            return
        }
        switch availability {
        case let .unavailable(reason):
            self.init(unavailableReason: reason)
        case let .configured(configuration):
            if let driver = UpdaterBackend.makeDriver(configuration: configuration) {
                self.init(driver: driver)
            } else {
                self.init(unavailableReason: "This build can't update itself.")
            }
        }
    }

    public var isAvailable: Bool {
        state == .ready
    }

    /// Non-nil exactly when `isAvailable` is false.
    public var unavailableReason: String? {
        guard case let .unavailable(reason) = state else { return nil }
        return reason
    }

    /// Runs a user-initiated check, showing Sparkle's own UI — including the
    /// "you're up to date" result that a scheduled check stays silent about.
    public func checkForUpdates() {
        driver?.checkForUpdates()
    }

    private func republishDriverState() {
        guard let driver else { return }
        isRepublishing = true
        defer { isRepublishing = false }

        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        lastUpdateCheckDate = driver.lastUpdateCheckDate
        receivesBetaUpdates = driver.receivesBetaUpdates
    }
}
