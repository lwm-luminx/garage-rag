import Darwin
import XCTest

/// The Status page's sections on a new, empty corpus: Health lists what is missing and each row
/// opens its page, Library counts the empty corpus and offers the next step, and the Index
/// Manager row tests the gRPC backend. Nothing here needs a model server or the network.
final class StatusUITests: GarageUITestCase {

    func testLibraryCountsAnEmptyCorpus() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        // The figures show once the database runs and the first stats have been read. An empty
        // garage.json still names a facts model (the default, gemma2-2b), so Facts is on the row too.
        let expected = ["sources": "0", "documents": "0", "chunks": "0", "indexed": "–", "facts": "0"]
        for (figure, value) in expected {
            let shown = element(identifier: "status.figure.\(figure)")
            XCTAssertTrue(
                waitUntil(timeout: 60) { shown.exists && self.shownText(of: shown) == value },
                "the \(figure) figure is not \(value) on an empty corpus (\(shown.exists ? shownText(of: shown) : "missing"))"
            )
        }
        XCTAssertTrue(element(text: "no model").exists, "Indexed does not say there is no model")

        let title = element(identifier: "status.library.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Library has no headline")
        XCTAssertEqual(shownText(of: title), "Nothing to index yet")
        XCTAssertTrue(element(identifier: "status.addSource").exists, "an empty corpus does not offer Add a Source")
        XCTAssertFalse(element(identifier: "status.updateEverything").exists, "Update Everything shows before there is a source")
        XCTAssertFalse(element(identifier: "status.stop").exists, "Stop shows with nothing running")
    }

    func testHealthListsWhatIsMissingAndOpensItsPage() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        let sources = element(identifier: "status.health.sources")
        XCTAssertTrue(sources.waitForExistence(timeout: 60), "Health does not list the missing sources")
        XCTAssertTrue(element(identifier: "status.health.models").exists, "Health does not list the missing embedding model")
        XCTAssertTrue(element(text: "No embedding model").exists, "the models row has no title")
        // With problems listed, the all-clear summary is not shown.
        XCTAssertFalse(element(identifier: "status.health.summary").exists, "Health shows the all-clear beside problems")
        // A running database is not a problem.
        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.element(identifier: "status.health.database").exists },
            "Health lists the running, migrated database"
        )

        click(element(identifier: "status.health.sources.open"))
        XCTAssertTrue(element(identifier: "sources.addFolder").waitForExistence(timeout: 15), "the sources row did not open Sources")

        open(section: "status")
        let openModels = element(identifier: "status.health.models.open")
        XCTAssertTrue(openModels.waitForExistence(timeout: 15), "the models row has no Open button")
        click(openModels)
        XCTAssertTrue(element(identifier: "models.tab").waitForExistence(timeout: 15), "the models row did not open Models")
    }

    func testAddASourceOpensTheSourcesPage() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        let add = element(identifier: "status.addSource")
        XCTAssertTrue(add.waitForExistence(timeout: 60), "no Add a Source button")
        XCTAssertTrue(waitForEnabled(add), "Add a Source stayed disabled")
        click(add)
        XCTAssertTrue(element(identifier: "sources.template.documents").waitForExistence(timeout: 15), "Add a Source did not open Sources")
    }

    /// With a source, Library trades Add a Source for Update Everything, the Sources figure counts
    /// it, and Health stops asking for one. Update Everything is not clicked: with no model it only
    /// proves the scan, which the Sources tests cover.
    func testASourceTurnsAddASourceIntoUpdateEverything() throws {
        let notes = try makeFolder(named: "notes", files: ["one.md": "# One\n"])
        try launchApp()
        waitForBackend()
        addCustomSource(slug: "uitest-status", root: notes)

        open(section: "status")
        let update = element(identifier: "status.updateEverything")
        XCTAssertTrue(update.waitForExistence(timeout: 30), "Library does not offer Update Everything with a source")
        XCTAssertTrue(waitForEnabled(update), "Update Everything stayed disabled with a source and a running database")
        XCTAssertFalse(element(identifier: "status.addSource").exists, "Add a Source still shows with a source")

        let sources = element(identifier: "status.figure.sources")
        XCTAssertTrue(waitUntil(timeout: 30) { sources.exists && self.shownText(of: sources) == "1" }, "the Sources figure did not count the source")
        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.element(identifier: "status.health.sources").exists },
            "Health still says there are no sources"
        )
    }

    func testIndexManagerDetailsAndTest() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        let details = element(identifier: "status.service.grpc.details")
        XCTAssertTrue(details.waitForExistence(timeout: 30), "the Index Manager row has no details button")
        click(details)
        XCTAssertTrue(element(text: "Address").waitForExistence(timeout: 10), "the details do not show the address")
        XCTAssertTrue(element(text: "Test queries the backend and shows its answers here.").exists, "the details do not explain Test before a run")

        let test = element(identifier: "status.service.grpc.test")
        XCTAssertTrue(waitForEnabled(test, timeout: 60), "Test stayed disabled with the backend running")
        click(test)
        XCTAssertTrue(
            element(textContaining: "test passed").waitForExistence(timeout: 60),
            "testing the running backend did not report a pass"
        )
        XCTAssertFalse(element(text: "Test queries the backend and shows its answers here.").exists, "the placeholder stayed after a test")

        // Collapsing hides the details again.
        click(details)
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(text: "Address").exists }, "the details did not fold away")
    }

    func testHelperServicesToolbar() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        for identifier in ["status.services.testAll", "status.services.restartAll", "status.services.refresh"] {
            XCTAssertTrue(element(identifier: identifier).waitForExistence(timeout: 30), "Helper Services has no \(identifier)")
        }
        let details = element(identifier: "status.service.ingest-xpc.details")
        XCTAssertTrue(details.waitForExistence(timeout: 30), "the ingest helper row has no details button")
        XCTAssertEqual(details.label, "Show Ingest details")
        click(details)
        XCTAssertTrue(waitUntil(timeout: 10) { details.label == "Hide Ingest details" }, "the details button did not change to Hide")
    }

    /// Automatic Updates moved from Sources to Status, under Library. Scheduled maintenance is off on
    /// a test launch, so its launch-time toggle is disabled; nothing is switched.
    func testAutomaticUpdatesSitOnStatus() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        XCTAssertTrue(element(text: "Automatic Updates").waitForExistence(timeout: 15), "Status has no Automatic Updates")
        let atLaunch = element(identifier: "status.maintenance.atLaunch")
        XCTAssertTrue(atLaunch.exists, "Automatic Updates has no launch-time toggle")
        XCTAssertFalse(atLaunch.isEnabled, "the launch-time toggle is enabled with scheduled updates off")
        XCTAssertTrue(element(text: "Keep every source up to date").exists, "Automatic Updates has no schedule toggle")

        open(section: "sources")
        XCTAssertTrue(element(identifier: "sources.addFolder").waitForExistence(timeout: 15), "Sources did not open")
        XCTAssertFalse(element(text: "Automatic Updates").exists, "Sources still shows Automatic Updates")
        XCTAssertFalse(element(identifier: "sources.maintenance.atLaunch").exists, "Sources still has the launch-time toggle")
    }

    /// The Index Manager row says how it listens: without remote access on its socket, or on its
    /// port when the socket path is too long for `sun_path` (as it is under a test's data folder in the group container).
    func testIndexManagerSaysHowItListens() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        let socket = dataDirectory.appendingPathComponent("s/grpc", isDirectory: false).path
        let address = sockaddr_un()
        let onSocket = socket.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
        let expected = onSocket ? "Without remote access" : ":\(Self.grpcPort)"
        XCTAssertTrue(
            element(textContaining: expected).waitForExistence(timeout: 60),
            "the Index Manager row does not say \"\(expected)\""
        )
    }

    /// A helper's Test and Restart are icon buttons that still read as Test and Restart.
    func testHelperRowsKeepTheirButtonNames() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        let test = element(identifier: "status.service.ingest-xpc.test")
        let restart = element(identifier: "status.service.ingest-xpc.restart")
        XCTAssertTrue(test.waitForExistence(timeout: 30), "the ingest helper row has no Test button")
        XCTAssertTrue(restart.exists, "the ingest helper row has no Restart button")
        XCTAssertEqual(test.label, "Test", "the Test icon button has no name for VoiceOver")
        XCTAssertEqual(restart.label, "Restart", "the Restart icon button has no name for VoiceOver")
        XCTAssertEqual(element(identifier: "status.service.grpc.test").label, "Test", "the Index Manager's Test icon button has no name")
    }
}
