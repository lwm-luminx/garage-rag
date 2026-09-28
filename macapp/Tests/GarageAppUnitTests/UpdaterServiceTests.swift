import XCTest
import GarageUpdater

/// Stands in for Sparkle so the service's own behaviour can be tested without
/// starting a real updater against the live appcast.
@MainActor
private final class FakeUpdaterDriver: UpdaterDriving {
    var canCheckForUpdates = true {
        didSet { onStateChange?() }
    }
    var automaticallyChecksForUpdates = false {
        didSet { onStateChange?() }
    }
    var lastUpdateCheckDate: Date?
    var receivesBetaUpdates = false {
        didSet { onStateChange?() }
    }
    var onStateChange: (() -> Void)?
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}

@MainActor
final class UpdaterConfigurationTests: XCTestCase {

    func testFeedURLIsRequired() {
        assertUnavailable(.resolve(feedURL: nil, publicEDKey: "abc"))
        assertUnavailable(.resolve(feedURL: "   ", publicEDKey: "abc"))
    }

    func testFeedURLMustBeHTTPS() {
        assertUnavailable(.resolve(feedURL: "http://example.com/appcast.xml", publicEDKey: "abc"))
        assertUnavailable(.resolve(feedURL: "file:///tmp/appcast.xml", publicEDKey: "abc"))
    }

    /// `URL(string:)` accepts a scheme with no authority, so an https scheme on its own
    /// does not mean there is anywhere to fetch from.
    func testFeedURLMustHaveAHost() {
        assertUnavailable(.resolve(feedURL: "https:appcast.xml", publicEDKey: "abc"))
        assertUnavailable(.resolve(feedURL: "https:///appcast.xml", publicEDKey: "abc"))
    }

    func testSigningKeyIsRequired() {
        assertUnavailable(.resolve(feedURL: "https://example.com/appcast.xml", publicEDKey: nil))
        assertUnavailable(.resolve(feedURL: "https://example.com/appcast.xml", publicEDKey: ""))
    }

    /// A build that never had its real key pasted in must not check the feed:
    /// it could not verify anything it downloaded.
    func testPlaceholderSigningKeyIsRejected() {
        assertUnavailable(
            .resolve(feedURL: "https://example.com/appcast.xml", publicEDKey: updaterPublicKeyPlaceholder)
        )
    }

    func testFullyConfiguredValuesAreAccepted() {
        let availability = UpdaterAvailability.resolve(
            feedURL: " https://example.com/appcast.xml ",
            publicEDKey: " key "
        )
        guard case let .configured(configuration) = availability else {
            return XCTFail("expected a configured feed, got \(availability)")
        }
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://example.com/appcast.xml")
        XCTAssertEqual(configuration.publicEDKey, "key")
    }

    private func assertUnavailable(
        _ availability: UpdaterAvailability,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(reason) = availability else {
            return XCTFail("expected an unavailable result, got \(availability)", file: file, line: line)
        }
        XCTAssertFalse(reason.isEmpty, "an unavailable result must explain itself", file: file, line: line)
    }
}

@MainActor
final class UpdaterServiceTests: XCTestCase {

    func testServiceWithoutADriverReportsWhyItCannotUpdate() {
        let service = UpdaterService(unavailableReason: "no updater here")

        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.state, .unavailable(reason: "no updater here"))
        XCTAssertEqual(service.unavailableReason, "no updater here")
        XCTAssertFalse(service.canCheckForUpdates)
    }

    func testServiceAdoptsTheDriverStateUpFront() {
        let driver = FakeUpdaterDriver()
        driver.canCheckForUpdates = false
        driver.automaticallyChecksForUpdates = true
        driver.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_000)

        let service = UpdaterService(driver: driver)

        XCTAssertTrue(service.isAvailable)
        XCTAssertNil(service.unavailableReason)
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertTrue(service.automaticallyChecksForUpdates)
        XCTAssertEqual(service.lastUpdateCheckDate, Date(timeIntervalSince1970: 1_000))
    }

    /// Sparkle drops `canCheckForUpdates` for the duration of a check, which is
    /// what greys out the menu item while one is running.
    func testServiceRepublishesLaterDriverChanges() {
        let driver = FakeUpdaterDriver()
        let service = UpdaterService(driver: driver)
        XCTAssertTrue(service.canCheckForUpdates)

        driver.canCheckForUpdates = false

        XCTAssertFalse(service.canCheckForUpdates)
    }

    func testTogglingAutomaticChecksWritesThroughToTheDriver() {
        let driver = FakeUpdaterDriver()
        let service = UpdaterService(driver: driver)

        service.automaticallyChecksForUpdates = true

        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertTrue(service.automaticallyChecksForUpdates)

        service.automaticallyChecksForUpdates = false

        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
    }

    func testBetaUpdatesStartFromTheDriverAndWriteThrough() {
        let driver = FakeUpdaterDriver()
        driver.receivesBetaUpdates = true
        let service = UpdaterService(driver: driver)
        XCTAssertTrue(service.receivesBetaUpdates)

        service.receivesBetaUpdates = false

        XCTAssertFalse(driver.receivesBetaUpdates)
        XCTAssertFalse(service.receivesBetaUpdates)
    }

    func testCheckForUpdatesReachesTheDriver() {
        let driver = FakeUpdaterDriver()
        let service = UpdaterService(driver: driver)

        service.checkForUpdates()
        service.checkForUpdates()

        XCTAssertEqual(driver.checkCount, 2)
    }

    func testCheckForUpdatesIsANoOpWithoutADriver() {
        let service = UpdaterService(unavailableReason: "no updater here")

        service.checkForUpdates()
        service.automaticallyChecksForUpdates = true

        XCTAssertFalse(service.isAvailable)
    }

    /// Whatever the build configuration, a test binary must never start a real
    /// updater and begin checking the live feed.
    func testTheDefaultServiceNeverStartsAnUpdaterUnderTest() {
        let service = UpdaterService(
            availability: .configured(
                UpdaterConfiguration(feedURL: URL(string: "https://example.com/appcast.xml")!, publicEDKey: "key")
            ),
            isTestEnvironment: true
        )

        XCTAssertFalse(service.isAvailable)
        XCTAssertNotNil(service.unavailableReason)
    }

    func testUnconfiguredBuildsStayUnavailable() {
        let service = UpdaterService(
            availability: .unavailable(reason: "no signing key"),
            isTestEnvironment: false
        )

        XCTAssertFalse(service.isAvailable)
        XCTAssertNotNil(service.unavailableReason)
    }

    /// `UpdaterService.shared` is what the app menu, the menu bar and the splash
    /// all bind to; constructing it must be safe from a test host too.
    func testSharedServiceIsUsableUnderTest() {
        XCTAssertFalse(UpdaterService.shared.isAvailable)
        XCTAssertNotNil(UpdaterService.shared.unavailableReason)
    }
}
