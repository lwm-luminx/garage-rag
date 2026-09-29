import AppKit
import Darwin
import XCTest

/// Base for the XCUITests: every test launches the real app on its own throwaway `--data-directory`,
/// so it gets a new cluster, config and models folder and never touches the real corpus.
///
/// Launch arguments set the launch-time preferences in the argument domain, which overrides
/// UserDefaults for that run without writing them. A test that clicks a control that saves a
/// preference (such as the splash's "Show this window at launch") does write the real
/// `me.rickmark.garage-rag` domain, so tests leave those controls alone or only reach states they
/// already have. The setup assistant's Finish and Skip are the exception: on a `--data-directory`
/// launch they last for that launch only.
///
/// The app's Postgres uses the fixed port 14824 and its quit path stops XPC services by executable
/// name, so a test refuses to run while another Garage is running or its ports are taken.
class GarageUITestCase: XCTestCase {
    static let bundleIdentifier = "me.rickmark.garage-rag"
    static let postgresPort: UInt16 = 14824
    static let grpcPort: UInt16 = 50051
    static let servicePorts: [UInt16] = [14824, 8787, 8790, 50051]
    /// Every test's data folder is named with this, which is how leftovers from an earlier test are
    /// told apart from a Garage (or the real corpus's Postgres) someone is using.
    static let dataDirectoryPrefix = "GarageUITest-"

    private(set) var dataDirectory: URL!
    private(set) var app: XCUIApplication!
    var launchedPIDs: Set<pid_t> = []

    var pgdata: URL { dataDirectory.appendingPathComponent("pgdata", isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false

        // An earlier test that died before its teardown could stop them (its launch failed, or the
        // runner was killed) can leave its Garage or its Postgres on 14824; every later test would
        // then skip. Those carry a GarageUITest- folder in their arguments, so they are safe to stop.
        Self.stopLeftoverTestProcesses(matching: Self.dataDirectoryPrefix)

        let running = Self.runningGarageInstances()
        try XCTSkipUnless(
            running.isEmpty,
            "Quit Garage first (`garage quit`; pids \(running.map(\.processIdentifier))): this test would share its port and its quit path kills XPC services by name."
        )
        for port in Self.servicePorts {
            try XCTSkipIf(Self.isListening(on: port), "Something already listens on 127.0.0.1:\(port).")
        }

        dataDirectory = try makeDataDirectoryParent()
            .appendingPathComponent("\(Self.dataDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        // The app and its gRPC server look for ./garage.json in the data folder before ~/.garage.json,
        // and write sources to the file they found. An empty config here keeps a test from reading or
        // editing the real one.
        try Data("{}\n".utf8).write(to: configFile)
        addTeardownBlock { [weak self] in self?.cleanUp() }
    }

    var configFile: URL { dataDirectory.appendingPathComponent("garage.json", isDirectory: false) }

    /// The folder this test's data folder is made in: `~/Library/Caches/GarageUITests`, which the
    /// sandboxed runner reaches through a temporary exception (`Runner.entitlements`). Not the
    /// runner's temporary folder: that is inside its container, which macOS 27 refuses to the app
    /// under test with no prompt. A subclass whose app cannot reach this folder either (the sandboxed
    /// App Store build) overrides it.
    func makeDataDirectoryParent() throws -> URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return FileManager.default.temporaryDirectory
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Caches/GarageUITests", isDirectory: true)
    }

    /// The app under test: the test target's host app unless a subclass launches another bundle.
    func makeApplication() throws -> XCUIApplication {
        XCUIApplication()
    }

    // MARK: - Launching

    /// Arguments a subclass adds to every launch (the screenshot tests' `--appearance`).
    var additionalLaunchArguments: [String] { [] }

    /// Launches Garage on this test's data folder and waits for its main window (or, with
    /// `firstRunCompleted: false`, the setup assistant).
    ///
    /// `mcpHTTP` turns on the app's HTTP MCP server, which is off by default; the MCP page's tests
    /// and Try It need it.
    @discardableResult
    func launchApp(
        showSplash: Bool = false,
        firstRunCompleted: Bool = true,
        automaticMaintenance: Bool = false,
        mcpHTTP: Bool = true
    ) throws -> XCUIApplication {
        let app = try makeApplication()
        app.launchArguments = [
            "--data-directory", dataDirectory.path,
            "-garage.splash.showAtLaunch", showSplash ? "YES" : "NO",
            "-garage.firstRun.completed", firstRunCompleted ? "YES" : "NO",
            // Off unless a test is about it: adding a source then starts a scan and ingest of every
            // source, which makes the source a test just added busy (not removable) until it ends.
            "-scheduledMaintenanceEnabled", automaticMaintenance ? "YES" : "NO",
            "-scheduledMaintenanceRunsAtLaunch", "NO",
            "-garage.mcp.httpEnabled", mcpHTTP ? "YES" : "NO",
            // The build's bundled models.json, not the website's copy, which can lag the branch under test.
            "-garage.modelCatalog.refreshAtLaunch", "NO",
            // Start from a clean window each time rather than the last run's restored state.
            "-ApplePersistenceIgnoreState", "YES",
        ] + additionalLaunchArguments
        app.launch()
        self.app = app

        let pid = try XCTUnwrap(waitForSingleInstance(timeout: 30), "Garage did not start")
        launchedPIDs.insert(pid)
        return app
    }

    /// The pid of the one running Garage, which `launchApp` checked is the one it launched.
    var appPID: pid_t? {
        let pids = Self.runningGarageInstances().map(\.processIdentifier)
        return pids.count == 1 ? pids[0] : nil
    }

    /// Waits until Postgres serves this test's cluster and the gRPC service the pages' operations
    /// go through is listening.
    func waitForBackend(timeout: TimeInterval = 120, file: StaticString = #filePath, line: UInt = #line) {
        guard let owner = appPID else {
            XCTFail("no single Garage instance to wait on", file: file, line: line)
            return
        }
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.postgresIsServing(from: owner) && self.grpcIsServing },
            "Postgres and gRPC did not come up on the test folder",
            file: file,
            line: line
        )
    }

    /// Quits Garage the way a person does (⌘Q), so its quit path stops Postgres and the XPC
    /// services, and waits for the process to exit.
    func quitApp(file: StaticString = #filePath, line: UInt = #line) {
        guard let pid = appPID else { return }
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 30) { !Self.isAlive(pid) }, "Garage (pid \(pid)) did not quit", file: file, line: line)
        _ = waitUntil(timeout: 15) { !Self.isListening(on: Self.postgresPort) }
    }

    // MARK: - UI

    func dismissSplash() {
        let dismiss = app.buttons["splash.continue"]
        if dismiss.waitForExistence(timeout: 10) {
            dismiss.click()
        }
    }

    /// Clicks Garage's menu bar item and waits for its popover.
    func openPopover(file: StaticString = #filePath, line: UInt = #line) {
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Garage has no menu bar item", file: file, line: line)
        item.click()
        XCTAssertTrue(element(identifier: "menubar.services").waitForExistence(timeout: 10), "the menu bar item did not open its popover", file: file, line: line)
    }

    /// Types `text` into the popover's search field once it takes input.
    func typeInPopoverField(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier: "menubar.search.field")
        XCTAssertTrue(waitForEnabled(field), "the popover's search field stayed disabled", file: file, line: line)
        // The popover puts the cursor in the field as it opens; click it anyway in case it did not.
        field.click()
        field.typeText(text)
    }

    /// Clicks the sidebar row for `section` (the `AppSection` case name, e.g. `"mcp"`).
    func open(section: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(identifier: "sidebar.\(section)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no sidebar row sidebar.\(section)", file: file, line: line)
        row.click()
    }

    func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Any element whose label, title, value or placeholder is exactly `text`: static texts, group
    /// box titles, buttons and text fields all surface it differently.
    func element(text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR title == %@ OR value == %@ OR placeholderValue == %@", text, text, text, text)
        ).firstMatch
    }

    func element(textContaining fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
        ).firstMatch
    }

    func element(textBeginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        ).firstMatch
    }

    /// The text `element` shows. A static text carries it in its value, with an empty label unless the
    /// view sets one; a button, or an element that combines its children, carries it in its label.
    func shownText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    func button(label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
    }

    /// Replaces a text field's contents. The field is scrolled into view and clicked until it holds
    /// keyboard focus: a click on a field at the edge of its scroll view lands on the edge instead,
    /// and typing then fails with "Neither element nor any descendant has keyboard focus".
    func replaceText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let focused = waitUntil(timeout: 15) {
            reveal(field)
            field.click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "\(field) never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Clicks `element` once it is scrolled into view.
    func click(_ element: XCUIElement) {
        reveal(element)
        element.click()
    }

    /// Scrolls the scroll view holding `element` until the element sits well inside its visible
    /// frame. macOS UI tests do not scroll before a click, and pages grow while they run (the
    /// Sources page's progress boxes push its form down), so an element can sit at or past the
    /// bottom edge. A no-op for an element that is not in a scroll view or is already in view.
    func reveal(_ element: XCUIElement) {
        let scrollView = app.scrollViews.containing(NSPredicate(format: "identifier == %@", element.identifier)).firstMatch
        guard !element.identifier.isEmpty, scrollView.exists else { return }
        let margin: CGFloat = 60
        var step: CGFloat = -120
        for _ in 0..<40 {
            // Reading the frame of an element that has gone (a Stop button whose run just ended) fails
            // the test outright; leave it to the caller's own check instead.
            guard element.exists else { return }
            let visible = scrollView.frame.insetBy(dx: 0, dy: min(margin, scrollView.frame.height / 4))
            let frame = element.frame
            let offset: CGFloat
            if frame.maxY > visible.maxY {
                offset = frame.maxY - visible.maxY
            } else if frame.minY < visible.minY {
                offset = frame.minY - visible.minY
            } else {
                return
            }
            // Which way a scroll delta moves content depends on the system's scrolling setting, so
            // learn it from the first step: flip the sign when the element moved the wrong way.
            let delta = offset > 0 ? step : -step
            scrollView.scroll(byDeltaX: 0, deltaY: delta)
            guard element.exists else { return }
            let moved = element.frame.minY - frame.minY
            if moved != 0, (moved > 0) == (offset > 0) {
                step = -step
            }
        }
    }

    /// Opens the Sources page's custom-source form, folded away behind "Custom Source…" until
    /// asked for, and returns its name field. A no-op when the form is already open.
    @discardableResult
    func revealCustomSourceForm(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let slugField = element(identifier: "sources.form.slug")
        if !slugField.exists {
            let show = element(identifier: "sources.form.show")
            XCTAssertTrue(show.waitForExistence(timeout: 15), "no Custom Source button", file: file, line: line)
            click(show)
        }
        XCTAssertTrue(slugField.waitForExistence(timeout: 15), "no slug field", file: file, line: line)
        return slugField
    }

    /// Adds a filesystem source through the Sources page's custom form and waits for its row. `root`
    /// should sit inside this test's data folder, so the source never points at real files.
    func addCustomSource(slug: String, root: URL, file: StaticString = #filePath, line: UInt = #line) {
        open(section: "sources", file: file, line: line)
        let slugField = revealCustomSourceForm(file: file, line: line)
        // The folder first: typing it fills in the name, which the slug then replaces.
        replaceText(in: element(identifier: "sources.form.root"), with: root.path, file: file, line: line)
        replaceText(in: slugField, with: slug, file: file, line: line)

        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit), "Add Source stayed disabled", file: file, line: line)
        click(submit)
        XCTAssertTrue(
            element(identifier: "sources.row.\(slug)").waitForExistence(timeout: 30),
            "the source \(slug) did not appear in the list",
            file: file,
            line: line
        )
    }

    /// A folder inside this test's data folder holding `files`.
    func makeFolder(named name: String, files: [String: String] = [:]) throws -> URL {
        let folder = dataDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, body) in files {
            try Data(body.utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.isEnabled }
    }

    // MARK: - Processes and Postgres

    static func runningGarageInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
    }

    func waitForSingleInstance(timeout: TimeInterval) -> pid_t? {
        waitUntilValue(timeout: timeout) { self.appPID }
    }

    /// Every process of this user whose arguments mention `marker`.
    static func processes(withArgumentContaining marker: String) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
            .filter { $0 > 0 && $0 != me && arguments(of: $0).contains { $0.contains(marker) } }
    }

    /// Stops what an earlier or current test left running under a folder matching `marker`:
    /// Postgres gets a fast shutdown, everything else is killed, and anything still alive after a
    /// few seconds is killed too.
    static func stopLeftoverTestProcesses(matching marker: String) {
        let leftovers = processes(withArgumentContaining: marker)
        guard !leftovers.isEmpty else { return }
        for pid in leftovers {
            let isPostgres = arguments(of: pid).first.map { ($0 as NSString).lastPathComponent == "postgres" } ?? false
            kill(pid, isPostgres ? SIGINT : SIGKILL)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, leftovers.contains(where: isAlive) {
            usleep(100_000)
        }
        for pid in leftovers where isAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's argv, from `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, then the executable path, NUL padding, then argc NUL-terminated arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func isListening(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func postmasterPID() -> pid_t? {
        let pidFile = pgdata.appendingPathComponent("postmaster.pid")
        guard let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let first = content.split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return nil
        }
        return pid
    }

    /// The folder of this test's Postgres socket (`GarageSockets` below the `--data-directory` folder), or
    /// nil when its path is too long for `sun_path` and the app fell back to loopback TCP on 14824.
    var postgresSocketDirectory: String? {
        let directory = dataDirectory.appendingPathComponent("s", isDirectory: true).path
        let socket = directory + "/.s.PGSQL.\(Self.postgresPort)"
        let address = sockaddr_un()
        return socket.utf8.count < MemoryLayout.size(ofValue: address.sun_path) ? directory : nil
    }

    /// True when a postmaster the instance `owner` started serves this test's cluster.
    func postgresIsServing(from owner: pid_t) -> Bool {
        guard let postmaster = postmasterPID(), Self.isAlive(postmaster),
              Self.parent(of: postmaster) == owner else {
            return false
        }
        if let directory = postgresSocketDirectory {
            return Self.isListening(atSocket: directory + "/.s.PGSQL.\(Self.postgresPort)")
        }
        return Self.isListening(on: Self.postgresPort)
    }

    /// True when the app's gRPC server answers: on `s/grpc` in the data folder when that path fits
    /// `sun_path` (as `GarageSockets` decides in the app), else on port 50051.
    var grpcIsServing: Bool {
        let socket = dataDirectory.appendingPathComponent("s/grpc", isDirectory: false).path
        let address = sockaddr_un()
        if socket.utf8.count < MemoryLayout.size(ofValue: address.sun_path) {
            return Self.isListening(atSocket: socket)
        }
        return Self.isListening(on: Self.grpcPort)
    }

    static func isListening(atSocket path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: Array(path.utf8.prefix(buffer.count - 1)))
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    struct ClusterIdentity: Equatable {
        let inode: UInt64
        let created: Date
    }

    func clusterIdentity() throws -> ClusterIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: pgdata.appendingPathComponent("PG_VERSION").path)
        return ClusterIdentity(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            created: attributes[.creationDate] as? Date ?? .distantPast
        )
    }

    // MARK: - Waiting

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        waitUntilValue(timeout: timeout) { condition() ? true : nil } ?? false
    }

    func waitUntilValue<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = value() { return result }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return value()
    }

    /// True when `condition` holds on every check for `duration` seconds.
    func holds(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard condition() else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return true
    }

    // MARK: - Cleanup

    /// Quits what this test started through the app's own quit path, then kills anything left by pid,
    /// and only processes whose arguments name this test's folder (never by name: that could reach a
    /// real Garage), then deletes the folder, which holds the isolated cluster's password too
    /// (`GaragePostgresEndpoint.isolatedPasswordFile`).
    /// Stops this test's Garage without its full quit path, which spends most of a test's time
    /// (about 20 of 26 seconds on the M4) waiting on Postgres's shutdown and the service stops.
    /// The data folder is thrown away, so nothing needs a clean shutdown: Postgres gets a fast
    /// shutdown (SIGINT) first, so the app's own quit finds it stopped and only stops the XPC
    /// services; anything still running a few seconds later is killed. DatabaseUITests covers the
    /// real ⌘Q path.
    private func cleanUp() {
        guard let dataDirectory else { return }
        let ours: (pid_t) -> Bool = { Self.isAlive($0) && Self.arguments(of: $0).contains(dataDirectory.path) }

        // `postgres -D <folder>/pgdata`: the argument names the folder too.
        // Matched by the folder's name rather than its path: Postgres may have been handed the path
        // with /var resolved to /private/var.
        let folderName = dataDirectory.lastPathComponent
        let postmaster = postmasterPID().flatMap { pid in
            Self.isAlive(pid) && Self.arguments(of: pid).contains(where: { $0.contains(folderName) }) ? pid : nil
        }
        if let postmaster {
            kill(postmaster, SIGINT)
        }
        for running in Self.runningGarageInstances() where ours(running.processIdentifier) {
            running.terminate()
        }
        _ = waitUntil(timeout: 5) {
            !Self.runningGarageInstances().contains { ours($0.processIdentifier) }
                && !(postmaster.map(Self.isAlive) ?? false)
        }

        for pid in launchedPIDs.union(Self.runningGarageInstances().map(\.processIdentifier)) where ours(pid) {
            kill(pid, SIGKILL)
        }
        if let postmaster, Self.isAlive(postmaster) {
            kill(postmaster, SIGKILL)
        }
        // Anything else this test started that is still running, such as a postmaster whose pid
        // file was not written yet or a Garage that never became the single instance.
        Self.stopLeftoverTestProcesses(matching: folderName)
        // The next test skips while any of these is taken, so a service left listening would
        // quietly skip the rest of the suite: say so here instead.
        let freed = waitUntil(timeout: 15) { !Self.servicePorts.contains(where: Self.isListening) }
        if !freed {
            let busy = Self.servicePorts.filter(Self.isListening).map { String($0) }.joined(separator: ", ")
            XCTFail("Garage's services still listen on \(busy) after the test; later tests would skip")
        }
        try? FileManager.default.removeItem(at: dataDirectory)
    }
}
