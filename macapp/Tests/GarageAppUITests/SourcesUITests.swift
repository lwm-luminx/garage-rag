import XCTest

/// The Sources page: adding and removing a source, its toolbar, and an end-to-end ingest of a
/// small folder of Markdown files.
final class SourcesUITests: GarageUITestCase {

    private let slug = "uitest-notes"

    /// A folder of Markdown files inside this test's data folder, so the source never points at real files.
    private func makeNotesFolder(files: [String: String]) throws -> URL {
        let folder = dataDirectory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func addSource(root: URL, file: StaticString = #filePath, line: UInt = #line) {
        open(section: "sources", file: file, line: line)
        let slugField = revealCustomSourceForm(file: file, line: line)
        replaceText(in: slugField, with: slug, file: file, line: line)
        replaceText(in: element(identifier: "sources.form.root"), with: root.path, file: file, line: line)

        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit), "Add / Update Source stayed disabled", file: file, line: line)
        click(submit)
        XCTAssertTrue(
            element(identifier: "sources.row.\(slug)").waitForExistence(timeout: 30),
            "the new source did not appear in the list",
            file: file,
            line: line
        )
    }

    /// Scrolls the Sources page until `element` is in the accessibility tree. The location cards sit in
    /// a lazy grid, which leaves a card scrolled out of view out of the tree, and adding a source
    /// through the custom form leaves the page scrolled down to it. Which way a delta scrolls depends on
    /// the system setting, so it tries one way, then the other.
    private func scrollIntoTree(_ element: XCUIElement) -> Bool {
        let page = app.scrollViews.containing(NSPredicate(format: "identifier == %@", "sources.addFolder")).firstMatch
        guard page.exists else { return element.exists }
        for delta in [CGFloat](repeating: 200, count: 10) + [CGFloat](repeating: -200, count: 20) {
            if element.exists { return true }
            page.scroll(byDeltaX: 0, deltaY: delta)
        }
        return element.exists
    }

    func testToolbarOffersCombinedActions() throws {
        try launchApp()
        waitForBackend()
        open(section: "sources")

        XCTAssertTrue(element(text: "No sources configured yet.").waitForExistence(timeout: 15), "no empty state on a new folder")
        let scanIngestAll = element(identifier: "sources.scanIngestAll")
        XCTAssertTrue(scanIngestAll.exists, "no Scan & Ingest All button")
        XCTAssertFalse(scanIngestAll.isEnabled, "Scan & Ingest All is enabled with no sources")
        let updateEverything = element(identifier: "sources.updateEverything")
        XCTAssertTrue(updateEverything.exists, "no Update Everything button")
        XCTAssertFalse(updateEverything.isEnabled, "Update Everything is enabled with no sources")
        XCTAssertTrue(element(identifier: "sources.sync").exists, "no sync button")
        XCTAssertTrue(element(identifier: "sources.diskAccess.refresh").exists, "no disk access refresh button")

        // The common locations are cards; the custom form is folded away until asked for.
        XCTAssertTrue(element(identifier: "sources.template.documents").exists, "no Documents card")
        XCTAssertTrue(element(identifier: "sources.addFolder").exists, "no Add Folder button")
        XCTAssertFalse(element(identifier: "sources.form.slug").exists, "the custom form is open before anyone asked for it")
        let show = element(identifier: "sources.form.show")
        XCTAssertTrue(show.exists, "no Custom Source button")
        click(show)
        XCTAssertTrue(element(identifier: "sources.form.slug").waitForExistence(timeout: 10), "Custom Source did not open the form")

        // Folded into the buttons above.
        for retired in ["Refresh Sources", "Scan All Sources", "Ingest All Sources", "Sync Config → DB", "Import DB → Config", "Test Ingest Paths & Disk Access"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    func testAddAndRemoveSource() throws {
        let notes = try makeNotesFolder(files: ["one.md": "# One\n\nA note.\n"])
        try launchApp()
        waitForBackend()

        addSource(root: notes)
        XCTAssertFalse(element(text: "No sources configured yet.").exists, "the empty state stayed after adding a source")

        // The form still names the source it just added.
        let remove = element(identifier: "sources.form.remove")
        XCTAssertTrue(waitForEnabled(remove), "Remove Source stayed disabled")
        remove.click()
        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.element(identifier: "sources.row.\(self.slug)").exists },
            "the removed source stayed in the list"
        )
        XCTAssertTrue(element(text: "No sources configured yet.").waitForExistence(timeout: 15), "no empty state after removing the only source")
    }

    func testSyncKeepsConfigAndDatabaseInStep() throws {
        let notes = try makeNotesFolder(files: ["one.md": "# One\n"])
        try launchApp()
        waitForBackend()
        addSource(root: notes)

        // Adding a source registers it in the database only; garage.json is untouched until a sync.
        XCTAssertFalse(try String(contentsOf: configFile, encoding: .utf8).contains(slug), "adding a source wrote garage.json")

        let sync = element(identifier: "sources.sync")
        XCTAssertTrue(waitForEnabled(sync), "the sync button stayed disabled")
        sync.click()
        // Sync copies the database-only source into the test folder's garage.json (two RPCs in turn).
        XCTAssertTrue(
            waitUntil(timeout: 30) { ((try? String(contentsOf: self.configFile, encoding: .utf8)) ?? "").contains(self.slug) },
            "sync did not copy the source into garage.json"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "sources.row.\(slug)").count, 1,
            "the source is not listed exactly once after sync"
        )
    }

    /// Scan & Ingest on a folder of two notes ends with both documents in the corpus: the Status
    /// page counts them and the Documents page lists them.
    func testScanAndIngestIndexesTheFolder() throws {
        let notes = try makeNotesFolder(files: [
            "alpha.md": "# Alpha note\n\nGarage keeps a local index of personal documents.\n",
            "beta.md": "# Beta note\n\nHybrid search fuses keyword and vector results.\n",
        ])
        try launchApp()
        waitForBackend()
        addSource(root: notes)

        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        scanIngest.click()

        open(section: "status")
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(
            waitUntil(timeout: 240) { documents.exists && self.shownText(of: documents) == "2" },
            "the Status page never counted both notes"
        )

        open(section: "documents")
        XCTAssertTrue(element(text: "Alpha note").waitForExistence(timeout: 30), "Documents does not list the first note")
        XCTAssertTrue(element(text: "Beta note").exists, "Documents does not list the second note")
    }

    /// With automatic maintenance on, adding a source starts a scan and ingest of every source. The page
    /// stays usable while they run: another source can be added (it used to be turned away with "A
    /// garage command is already running" for as long as the scan walked the folder).
    func testAddingASourceWorksWhileMaintenanceRuns() throws {
        let first = try makeNotesFolder(files: Self.longNotes())
        let second = dataDirectory.appendingPathComponent("more", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("# More\n".utf8).write(to: second.appendingPathComponent("more.md"))

        try launchApp(automaticMaintenance: true)
        waitForBackend()
        addSource(root: first)

        // The activity module above the list shows the scan, then the ingest, with its Stop button.
        let progress = element(identifier: "sources.cancelAll")
        XCTAssertTrue(progress.waitForExistence(timeout: 30), "adding a source did not start maintenance")

        replaceText(in: element(identifier: "sources.form.slug"), with: "uitest-more")
        replaceText(in: element(identifier: "sources.form.root"), with: second.path)
        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit, timeout: 10), "Add / Update Source is disabled while maintenance runs")
        click(submit)

        XCTAssertTrue(
            element(identifier: "sources.row.uitest-more").waitForExistence(timeout: 15),
            "the second source was not added while maintenance ran"
        )
        XCTAssertTrue(progress.exists, "maintenance finished before the second add, so this run proves nothing; add more notes")
    }

    /// The custom form names a source after its folder until the person types a name of their own.
    func testNameFillsInFromTheFolder() throws {
        let folder = try makeFolder(named: "Field Notes")
        try launchApp()
        waitForBackend()
        open(section: "sources")

        let slugField = revealCustomSourceForm()
        replaceText(in: element(identifier: "sources.form.root"), with: folder.path)
        XCTAssertTrue(
            waitUntil(timeout: 10) { (slugField.value as? String) == "field-notes" },
            "the name was not filled in from the folder (\(slugField.value ?? "nil"))"
        )
        XCTAssertTrue(element(text: "from the folder").exists, "the form does not say where the name came from")

        replaceText(in: slugField, with: "my-notes")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(text: "from the folder").exists }, "a typed name still says it came from the folder")
        // Changing the folder now leaves the typed name alone.
        replaceText(in: element(identifier: "sources.form.root"), with: dataDirectory.appendingPathComponent("elsewhere").path)
        XCTAssertTrue(holds(for: 2) { (slugField.value as? String) == "my-notes" }, "changing the folder replaced a typed name")
    }

    /// A location card knows its source by name: once a source named "documents" exists (here one
    /// on a test folder, never the real ~/Documents), the Documents card says it is added and can no
    /// longer be clicked, and the toolbar's Update Everything and Scan & Ingest All turn on.
    func testAddingASourceEnablesTheToolbarAndMarksItsCard() throws {
        let folder = try makeFolder(named: "docs", files: ["one.md": "# One\n"])
        try launchApp()
        waitForBackend()
        open(section: "sources")

        let card = element(identifier: "sources.template.documents")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "no Documents card")
        XCTAssertEqual(card.label, "Add Documents")
        for id in ["desktop", "downloads"] {
            XCTAssertTrue(element(identifier: "sources.template.\(id)").exists, "no \(id) card")
        }

        addCustomSource(slug: "documents", root: folder)

        XCTAssertTrue(scrollIntoTree(card), "the Documents card is gone after adding a source")
        // Reading a label while the card is briefly gone (the grid is rebuilt when the source list
        // refreshes) fails the test outright, so check that it exists first.
        XCTAssertTrue(
            waitUntil(timeout: 15) { card.exists && card.label == "Documents, added" },
            "the Documents card does not say it is added (\(card.exists ? card.label : "no card"))"
        )
        XCTAssertFalse(card.isEnabled, "the Documents card can still be clicked once added")
        XCTAssertTrue(waitForEnabled(element(identifier: "sources.updateEverything")), "Update Everything stayed disabled with a source")
        XCTAssertTrue(waitForEnabled(element(identifier: "sources.scanIngestAll")), "Scan & Ingest All stayed disabled with a source")
        XCTAssertTrue(element(identifier: "sources.row.documents.scanIngest").exists, "the source's row has no Scan & Ingest")
        XCTAssertFalse(element(text: "No sources configured yet.").exists, "the empty state stayed after adding a source")
    }

    /// Stop ends a Scan & Ingest before it gets through the folder: the run ends as cancelled (or,
    /// stopped while still counting, with no ingest at all), the row can be run again, and not every
    /// note was indexed.
    func testStopEndsARunningScanAndIngest() throws {
        let files = Self.longNotes()
        let notes = try makeNotesFolder(files: files)
        try launchApp()
        waitForBackend()
        addSource(root: notes)

        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        click(scanIngest)

        let stop = element(identifier: "sources.cancelAll")
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "the run shows no Stop button")
        XCTAssertTrue(element(identifier: "sources.row.\(slug).cancel").exists, "the running source's row offers no Cancel")
        reveal(stop)
        let activityTitle = element(identifier: "sources.activity.title")
        guard stop.exists else {
            return XCTFail("the Stop button went away before it could be pressed (activity: \(activityTitle.exists ? shownText(of: activityTitle) : "none"))")
        }
        stop.click()

        XCTAssertTrue(waitUntil(timeout: 120) { !stop.exists }, "the run did not stop")
        let title = element(identifier: "sources.activity.title")
        if title.exists {
            XCTAssertTrue(shownText(of: title).hasSuffix("cancelled"), "a stopped run ended as \"\(shownText(of: title))\"")
        }
        XCTAssertTrue(waitForEnabled(scanIngest), "the row cannot be run again after Stop")

        open(section: "status")
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(documents.waitForExistence(timeout: 30), "no Documents figure")
        XCTAssertTrue(
            holds(for: 5) { (Int(self.shownText(of: documents)) ?? 0) < files.count },
            "every note was indexed although the run was stopped (\(shownText(of: documents)))"
        )
    }

    /// A folder that is gone after it was added: the row says it cannot be read, with the UNREADABLE
    /// tag, once access is checked again.
    func testASourceWhoseFolderIsGoneCannotBeRead() throws {
        let folder = try makeFolder(named: "vanishing", files: ["one.md": "# One\n"])
        try launchApp()
        waitForBackend()
        addCustomSource(slug: "uitest-gone", root: folder)

        let status = element(identifier: "sources.row.uitest-gone.status")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the row has no status line")
        XCTAssertFalse(shownText(of: status).hasPrefix("Can't be read"), "a folder that exists cannot be read")

        try FileManager.default.removeItem(at: folder)
        click(element(identifier: "sources.diskAccess.refresh"))
        XCTAssertTrue(
            waitUntil(timeout: 15) { self.shownText(of: status).hasPrefix("Can't be read") },
            "the row of a missing folder says \"\(shownText(of: status))\""
        )
        XCTAssertTrue(shownText(of: status).contains("does not exist"), "the row does not say the folder is gone (\(shownText(of: status)))")
        XCTAssertTrue(element(text: "UNREADABLE").exists, "the row has no UNREADABLE tag")
    }

    /// A folder that does not exist is turned away: no source is added.
    func testAddingAFolderThatDoesNotExistAddsNothing() throws {
        try launchApp()
        waitForBackend()
        open(section: "sources")

        let slugField = revealCustomSourceForm()
        replaceText(in: element(identifier: "sources.form.root"), with: dataDirectory.appendingPathComponent("no-such-folder").path)
        replaceText(in: slugField, with: "uitest-missing")
        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit), "Add Source stayed disabled")
        click(submit)

        XCTAssertTrue(waitForEnabled(submit), "the form stayed busy")
        XCTAssertTrue(holds(for: 5) { !self.element(identifier: "sources.row.uitest-missing").exists }, "a folder that does not exist was added")
        XCTAssertTrue(element(text: "No sources configured yet.").exists, "the empty state went away")
    }

    /// Enough long notes that a Scan & Ingest of them is still running when a test acts on it. A dozen
    /// was not: the M4 got through all twelve before the Stop button could be pressed. Not many more
    /// than needed, since every ingested file adds log lines to the page, and a long log makes each
    /// accessibility snapshot (and so every UI test step) crawl. Varied prose, so the quality gate
    /// does not reject it as machine-generated, and under 1,500 chunks a document.
    private static func longNotes(count: Int = 48) -> [String: String] {
        var notes: [String: String] = [:]
        for index in 0..<count {
            notes["long-\(index).md"] = "# Long note \(index)\n\n" + prose(seed: UInt64(index + 1), characters: 1_200_000)
        }
        return notes
    }

    /// Deterministic, varied English-looking paragraphs of about `characters` characters.
    private static func prose(seed: UInt64, characters: Int) -> String {
        let words = [
            "garage", "keeps", "a", "local", "index", "of", "personal", "documents", "notes", "and", "code",
            "search", "fuses", "keyword", "vector", "results", "with", "reciprocal", "rank", "fusion", "the",
            "archive", "grows", "slowly", "every", "evening", "while", "letters", "from", "old", "friends",
            "arrive", "in", "batches", "that", "nobody", "reads", "twice", "because", "memory", "is", "kind",
        ]
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        var text = ""
        text.reserveCapacity(characters + 200)
        while text.count < characters {
            var sentence = ""
            for position in 0..<(8 + next() % 12) {
                let word = words[next() % words.count]
                sentence += position == 0 ? word.capitalized : " " + word
            }
            text += sentence + (next() % 5 == 0 ? ".\n\n" : ". ")
        }
        return text
    }
}
