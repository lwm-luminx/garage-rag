import XCTest

/// The Logs page's table: filling it from the app's own OSLog entries and from an ingest, narrowing
/// it with the text filter, resetting the filters and clearing a source.
final class LogsUITests: GarageUITestCase {

    /// The "visible of total entries" badge as two numbers, or nil while it is not shown.
    private func counts() -> (visible: Int, total: Int)? {
        let badge = element(identifier: "logs.count")
        guard badge.exists else { return nil }
        return Self.parseCounts(shownText(of: badge))
    }

    /// "3,000 of 4,000 entries" as (3000, 4000). The badge's `Text` interpolates its counts as
    /// localized numbers, so a thousand or more carries a grouping separator ("4,000", "4 000"),
    /// and the sources fill past that at launch from the helpers' log files. The footer may go on
    /// (", showing the latest 500"), so only the text up to "entr" is read: digits after it would
    /// otherwise glue onto the total (3,148 of 3,148 became 3,148,500).
    static func parseCounts(_ text: String) -> (visible: Int, total: Int)? {
        let counts = text.components(separatedBy: " entr").first ?? text
        let halves = counts.components(separatedBy: " of ")
        guard halves.count == 2 else { return nil }
        let numbers = halves.compactMap { Int(String($0.filter(\.isNumber))) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    private func selectSource(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "logs.source").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) log source", file: file, line: line)
        segment.click()
    }

    /// The live stream starts paused; "Fetch OSLog" reads this process's recent entries instead.
    /// What that adds depends on what OSLogStore hands a test launch (only this process, and not its
    /// debug entries), so the tests below do not count on it: the Unified Log also carries every
    /// line the helper services stream over XPC and the tail of their log files.
    private func fetchRecentOSLog(file: StaticString = #filePath, line: UInt = #line) {
        let fetch = element(identifier: "logs.fetch")
        XCTAssertTrue(fetch.waitForExistence(timeout: 10), "Logs has no Fetch OSLog menu", file: file, line: line)
        fetch.click()
        let item = app.menuItems["Fetch Past 15 mins"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Fetch OSLog offers no 15-minute window", file: file, line: line)
        item.click()
    }

    private func filter(by text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier: "logs.filter")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Logs has no filter field", file: file, line: line)
        let focused = waitUntil(timeout: 15) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "the filter field never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// The log table. Found by identifier: the sidebar is a List, which accessibility may also
    /// report as a table (or outline), and it comes first, so `app.tables.firstMatch` read the
    /// sidebar's "Status".
    private var logTable: XCUIElement {
        let identified = app.descendants(matching: .any).matching(identifier: "logs.table").firstMatch
        if identified.exists { return identified }
        return app.tables.firstMatch.exists ? app.tables.firstMatch : app.outlines.firstMatch
    }

    /// The table's texts: static texts and, for the Message column, which is selectable, text views
    /// (accessibility need not report selectable text as a static text, nor its rows as table rows).
    private var tableTexts: XCUIElementQuery {
        logTable.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.staticText.rawValue,
            XCUIElement.ElementType.textView.rawValue
        ))
    }

    /// A shown row's message: the first Message cell (`logs.row.message`), or failing that the
    /// longest text of the table's first row. Only the first row is read: resolving a query over
    /// every text of thousands of rows outlasts XCUITest's evaluation timeout.
    private func visibleRowMessage() -> String? {
        guard waitUntil(timeout: 10, { self.tableTexts.firstMatch.exists }) else { return nil }
        let table = logTable
        let messageCell = table.descendants(matching: .any).matching(identifier: "logs.row.message").firstMatch
        if messageCell.exists {
            let message = shownText(of: messageCell)
            if !message.isEmpty { return message }
        }
        let row = table.tableRows.firstMatch.exists ? table.tableRows.firstMatch : table.outlineRows.firstMatch
        let texts: [String]
        if row.exists {
            texts = row.descendants(matching: .any).matching(NSPredicate(
                format: "elementType == %d OR elementType == %d",
                XCUIElement.ElementType.staticText.rawValue,
                XCUIElement.ElementType.textView.rawValue
            )).allElementsBoundByIndex.map { shownText(of: $0) }
        } else {
            // No rows reported as rows: take the first few texts one at a time rather than all of them.
            texts = (0..<8).map { tableTexts.element(boundBy: $0) }.filter(\.exists).map { shownText(of: $0) }
        }
        return texts.max { $0.count < $1.count }
    }

    /// After fetching the app's recent OSLog the Unified Log has rows; a phrase from one row narrows the
    /// table to the rows holding it, a phrase from nowhere empties it, and Reset Filters brings it all back.
    func testTableFillsAndTheTextFilterNarrowsIt() throws {
        try launchApp()
        waitForBackend()
        open(section: "logs")
        selectSource("Unified Log")
        fetchRecentOSLog()

        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "the Unified Log has no rows (badge: \(String(describing: counts())))")
        let message = try XCTUnwrap(visibleRowMessage(), "the table shows no rows")
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let phrase = String(firstLine.prefix(24)).trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(phrase.isEmpty, "the first row has no message")

        filter(by: phrase)
        XCTAssertTrue(
            waitUntil(timeout: 10) { (self.counts()?.visible ?? 0) >= 1 && self.element(identifier: "logs.resetFilters").exists },
            "filtering by \"\(phrase)\" hid the row it came from (\(String(describing: counts())))"
        )
        let narrowed = try XCTUnwrap(counts())
        XCTAssertLessThanOrEqual(narrowed.visible, narrowed.total)

        filter(by: "zq-no-log-line-says-this-9321")
        XCTAssertTrue(waitUntil(timeout: 10) { self.counts()?.visible == 0 }, "a phrase from nowhere left rows (\(String(describing: counts())))")
        XCTAssertTrue(element(text: "No Matches").exists, "an empty filter result does not say so")

        click(element(identifier: "logs.resetFilters"))
        XCTAssertTrue(
            waitUntil(timeout: 10) { self.counts().map { $0.visible == $0.total && $0.total > 0 } ?? false },
            "Reset Filters did not bring every row back (\(String(describing: counts())))"
        )
        XCTAssertFalse(element(identifier: "logs.resetFilters").exists, "Reset Filters stayed with no filter set")
    }

    /// Clear empties the source it is on.
    func testClearEmptiesTheSource() throws {
        try launchApp()
        waitForBackend()
        open(section: "logs")
        selectSource("Unified Log")
        fetchRecentOSLog()
        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "the Unified Log has no rows (badge: \(String(describing: counts())))")
        let before = try XCTUnwrap(counts()).total

        let clear = element(identifier: "logs.clear")
        XCTAssertTrue(waitForEnabled(clear, timeout: 10), "Clear stayed disabled with rows")
        clear.click()
        // The stream is paused, but a helper service's own log lines still arrive; far fewer, though.
        XCTAssertTrue(
            waitUntil(timeout: 10) { (self.counts()?.total ?? 0) < before || self.element(text: "No Logs Recorded").exists },
            "Clear did not empty the Unified Log (\(before) before, \(String(describing: counts())) after)"
        )
    }

    /// A Scan & Ingest leaves its worker's lines under Ingest, which XPC delivers without the OSLog.
    /// The source's name is new to this run: Ingest also shows the tail of the helper's log file,
    /// which holds earlier runs' lines, so only a line naming this source shows this ingest's.
    func testIngestFillsTheIngestSource() throws {
        let notes = try makeFolder(named: "notes", files: ["one.md": "# One\n\nA short note for the ingest log.\n"])
        let slug = "uitest-logs-" + UUID().uuidString.prefix(8).lowercased()
        try launchApp()
        waitForBackend()
        addCustomSource(slug: slug, root: notes)
        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        click(scanIngest)

        open(section: "status")
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(waitUntil(timeout: 240) { documents.exists && self.shownText(of: documents) == "1" }, "the note was never ingested")

        open(section: "logs")
        selectSource("Ingest")
        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "an ingest left no lines under Ingest")
        // The ingest worker logs "Initiating ingestion for source '<slug>'" through the XPC log stream.
        // The filter matches a line's message, source and level, and only a message can hold this
        // run's new name, so any row left after filtering by it is a line from this ingest. The badge
        // counts them; the rows themselves are not read, since a selectable message need not report
        // its text to accessibility as a value or label.
        filter(by: slug)
        XCTAssertTrue(
            waitUntil(timeout: 30) { (self.counts()?.visible ?? 0) >= 1 },
            "no line under Ingest names the source \(slug) (\(String(describing: counts())))"
        )
    }
}
