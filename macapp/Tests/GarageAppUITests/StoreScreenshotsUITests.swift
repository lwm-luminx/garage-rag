import AppKit
import ScreenCaptureKit
import XCTest

/// Mac App Store screenshots: the main pages at a 1440 × 900 point window (2880 × 1800 pixels on a
/// Retina display, 1440 × 900 on a standard one; both are store sizes), in light and dark mode,
/// over the made-up fixture corpus (`macapp/Tests/Fixtures`) rather than anyone's real files.
///
/// Opt-in, because it downloads an embedding model and takes several minutes. Set
/// `GARAGE_STORE_SCREENSHOTS` (with `xcodebuild test`, `TEST_RUNNER_GARAGE_STORE_SCREENSHOTS`) to `1`
/// or to a folder:
///
///     TEST_RUNNER_GARAGE_STORE_SCREENSHOTS=1 \
///       xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppUITests \
///       -only-testing:GarageAppUITests/StoreScreenshotsUITests
///
/// Each page is written as `<nn>-<page>-<appearance>.png` and also kept as an attachment in the
/// result bundle. The test runner is sandboxed, so it cannot write to the Desktop or most of the home
/// folder: with `1`, or a folder it cannot write, the files go to `store-screenshots` in the runner's
/// own temporary folder,
/// `~/Library/Containers/me.rickmark.garage-rag.GarageAppUITests.xctrunner/Data/tmp/store-screenshots`,
/// and the log names it. The app opens its window at 1440 × 900 points (`--window-size`), below the
/// menu bar and behind the Dock if it has to, so the display needs 900 points below the menu bar.
///
/// Only the window is captured, through ScreenCaptureKit rather than `XCUIElement.screenshot()`: that
/// one crops the screen, so the Dock, a notification or the wallpaper at the rounded corners would
/// show. The window is rendered on its own at 2880 × 1800 pixels without its shadow, and its corners
/// are filled with a neutral grey, since App Store Connect takes no transparency. This needs Screen
/// Recording permission for the test runner: the first run asks for it and fails, and after it is
/// granted (System Settings → Privacy & Security → Screen & System Audio Recording) the next run
/// captures.
final class StoreScreenshotsUITests: GarageUITestCase {
    static let outputVariable = "GARAGE_STORE_SCREENSHOTS"
    static let windowSize = CGSize(width: 1440, height: 900)
    /// The small preset embedding model: a quick download, and enough to show hybrid search.
    static let embeddingModel = "mxbai-embed-xsmall"
    static let query = "who kept the lighthouse during the storm"
    /// The captured size in pixels: `windowSize` at 2×, a Mac App Store size on any display.
    static let pixelSize = CGSize(width: 2880, height: 1800)

    private var appearance = "light"
    private var outputFolder: URL!

    override var additionalLaunchArguments: [String] {
        [
            "--appearance", appearance,
            "--window-size", "\(Int(Self.windowSize.width))x\(Int(Self.windowSize.height))",
        ]
    }

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment[Self.outputVariable] ?? ""
        try XCTSkipIf(path.isEmpty, "Set \(Self.outputVariable) to 1 or a folder to take the App Store screenshots.")
        outputFolder = Self.writableFolder(for: path)
        // Ask before the run rather than after minutes of ingest and embedding: the grant is needed
        // for every capture, and the runner has to be relaunched once it is given.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw CaptureError.noScreenRecordingPermission
        }
        XCTContext.runActivity(named: "Screenshots go to \(outputFolder.path)") { _ in }
        NSLog("StoreScreenshotsUITests: writing to %@", outputFolder.path)
        try super.setUpWithError()
        // One page that fails to load should not cost the rest of the set.
        continueAfterFailure = true
    }

    func testLightScreenshots() throws {
        appearance = "light"
        try takeScreenshots()
    }

    func testDarkScreenshots() throws {
        appearance = "dark"
        try takeScreenshots()
    }

    /// The folder named by `path`, or `store-screenshots` in the runner's temporary folder when
    /// `path` is `1` or names a folder the sandboxed runner cannot create or write.
    static func writableFolder(for path: String) -> URL {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("store-screenshots", isDirectory: true)
        var candidates = [fallback]
        if path != "1" {
            candidates.insert(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true), at: 0)
        }
        for folder in candidates {
            let probe = folder.appendingPathComponent(".write-probe")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                return folder
            } catch {
                NSLog("StoreScreenshotsUITests: cannot write to %@: %@", folder.path, "\(error)")
            }
        }
        return fallback
    }

    // MARK: - The run

    private func takeScreenshots() throws {
        try launchApp()
        waitForBackend()
        try sizeWindow()

        try ingestFixtureCorpus()
        registerAndEmbed()

        open(section: "search")
        runSearch()
        capture("01-search")

        open(section: "documents")
        XCTAssertTrue(
            element(text: FixtureCorpus.lighthouse.title).waitForExistence(timeout: 30),
            "Documents does not list the fixture corpus"
        )
        settle()
        capture("02-documents")

        open(section: "status")
        settle()
        capture("03-status")

        open(section: "mcp")
        _ = waitUntil(timeout: 60) { self.element(identifier: "mcp.stop").exists }
        settle()
        capture("04-mcp-server")

        open(section: "sources")
        settle()
        capture("05-sources")

        open(section: "models")
        settle()
        capture("06-models")
    }

    /// Registers the small embedding model from the Models page and embeds the corpus with it, so
    /// the Search page shows hybrid results. The model downloads on first use.
    private func registerAndEmbed() {
        open(section: "models")
        let manageEmbedding = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manageEmbedding.waitForExistence(timeout: 15), "the Models page has no Embedding card")
        click(manageEmbedding)

        let add = element(identifier: "models.add.\(Self.embeddingModel)")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "the Embedding tab does not offer \(Self.embeddingModel)")
        XCTAssertTrue(waitForEnabled(add), "Register \(Self.embeddingModel) stayed disabled")
        click(add)
        XCTAssertTrue(
            element(identifier: "models.row.\(Self.embeddingModel)").waitForExistence(timeout: 60),
            "\(Self.embeddingModel) did not appear among the registered models"
        )

        // Embed All sits on the Overall segment.
        let segments = element(identifier: "models.tab").radioButtons
        if segments.count > 0 {
            segments.element(boundBy: 0).click()
        }
        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 60), "Embed All stayed disabled with a registered model")
        click(embedAll)
        // Embedding runs until the button is offered again.
        _ = waitUntil(timeout: 5) { !embedAll.isEnabled }
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 900), "embedding the fixture corpus did not finish")
    }

    /// Runs the query and waits for ranked results. The shot is still taken when none come, so
    /// the run shows what the page said instead, and the failure quotes it.
    private func runSearch() {
        let field = element(identifier: "search.query")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no search field")
        // The plain-style field only takes focus when the click lands on its text area.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeText(Self.query + "\n")

        // The table's rank column is not reliably exposed as text; the first result's title and the
        // inspector (which opens on the first result) carry identifiers.
        let firstTitle = element(identifier: "search.result.1.title")
        let detail = element(identifier: "search.detail.title")
        let failed = element(identifier: "search.error")
        let empty = element(text: "No Results Found")
        _ = waitUntil(timeout: 120) { firstTitle.exists || detail.exists || failed.exists || empty.exists }
        if failed.exists {
            XCTFail("the search failed: \(shownText(of: failed))")
        } else if empty.exists {
            XCTFail("the query returned no results: \"\(Self.query)\"")
        } else {
            XCTAssertTrue(firstTitle.exists || detail.exists, "the search did not finish")
        }
        settle()
    }

    // MARK: - Window and capture

    /// Checks the main window opened at exactly `windowSize` points (`--window-size`). If it did not,
    /// falls back to moving it to the top left of its screen and dragging its bottom-right corner.
    private func sizeWindow(file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "no main window", file: file, line: line)
        if waitUntil(timeout: 5, { window.frame.size == Self.windowSize }) { return }

        // Title bar to just below the menu bar, near the left edge.
        let frame = window.frame
        let grab = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2, dy: 12))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40 - frame.minX + frame.width / 2, dy: 40 - frame.minY + 12))
        grab.press(forDuration: 0.3, thenDragTo: target)

        // A few passes: the window may clamp or snap the first drag.
        for _ in 0..<4 {
            let current = window.frame
            if current.size == Self.windowSize { break }
            let corner = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: current.width - 2, dy: current.height - 2))
            let goal = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: Self.windowSize.width - 2, dy: Self.windowSize.height - 2))
            corner.press(forDuration: 0.3, thenDragTo: goal)
        }
        XCTAssertEqual(
            window.frame.size,
            Self.windowSize,
            "the window did not reach \(Int(Self.windowSize.width)) × \(Int(Self.windowSize.height)) points; is the display big enough?",
            file: file,
            line: line
        )
    }

    /// Gives the page a moment to finish animating and loading before it is captured.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    /// Captures the main window as `<name>-<appearance>.png` in the output folder and as a kept
    /// attachment.
    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.size, Self.windowSize, "the window changed size before \(name)", file: file, line: line)
        let fileName = "\(name)-\(appearance)"

        let image: CGImage
        do {
            image = try captureWindow()
        } catch {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "\(fileName)-screen"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("could not capture the window for \(name): \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            CGSize(width: image.width, height: image.height),
            Self.pixelSize,
            "\(fileName) is \(image.width) × \(image.height) pixels",
            file: file,
            line: line
        )
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(fileName) as PNG", file: file, line: line)
            return
        }

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = outputFolder.appendingPathComponent(fileName).appendingPathExtension("png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)", file: file, line: line)
        }
        XCTContext.runActivity(named: "\(fileName): \(image.width) × \(image.height) pixels") { _ in }
    }

    enum CaptureError: Error, CustomStringConvertible {
        case noScreenRecordingPermission
        case noWindow([String])
        case timedOut
        case noContext

        var description: String {
            switch self {
            case .noScreenRecordingPermission:
                "The test runner needs Screen Recording permission to capture the window. Grant it and run again."
            case let .noWindow(windows):
                "no Garage window of the screenshot size among \(windows)"
            case .timedOut:
                "ScreenCaptureKit did not answer"
            case .noContext:
                "could not make a bitmap to flatten the capture"
            }
        }
    }

    /// Renders Garage's main window by itself, without its shadow, at `pixelSize`, flattened onto
    /// the appearance's neutral grey.
    private func captureWindow() throws -> CGImage {
        let bundleIdentifier = Self.bundleIdentifier
        let windowSize = Self.windowSize
        let pixelSize = Self.pixelSize
        let captured = try waitForAsync { () async throws -> CGImage in
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleIdentifier && $0.windowLayer == 0
            }
            guard let target = windows.first(where: { $0.frame.size == windowSize }) else {
                throw CaptureError.noWindow(windows.map { "\($0.title ?? "untitled") \($0.frame)" })
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            configuration.scalesToFit = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        return try flattened(captured)
    }

    /// Draws `image` over an opaque neutral grey (light or dark to suit the page), so the rounded
    /// corners carry no transparency.
    private func flattened(_ image: CGImage) throws -> CGImage {
        let width = Int(Self.pixelSize.width)
        let height = Int(Self.pixelSize.height)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw CaptureError.noContext }
        let grey: CGFloat = appearance == "dark" ? 0.16 : 0.92
        context.setFillColor(CGColor(gray: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CaptureError.noContext }
        return result
    }

    /// Runs `body` and waits for its result on the test's thread.
    private func waitForAsync<T: Sendable>(
        timeout: TimeInterval = 30,
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let done = expectation(description: "async capture")
        let box = ResultBox<T>()
        Task.detached {
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            done.fulfill()
        }
        guard XCTWaiter().wait(for: [done], timeout: timeout) == .completed, let result = box.result else {
            throw CaptureError.timedOut
        }
        return try result.get()
    }
}

/// Carries a detached task's result back to the waiting test; the expectation orders the write
/// before the read.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
