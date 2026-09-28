import AppKit
import XCTest
@testable import GarageApp

/// The frames the main window grows to when the setup assistant closes and shrinks to when it opens.
final class MainWindowSizingTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1080)
    private let target = NSSize(width: 1100, height: 760)

    func testGrowsToTheWorkingSizeAroundTheSameCentre() throws {
        let current = NSRect(x: 400, y: 300, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertEqual(frame.size, target)
        XCTAssertEqual(frame.midX, current.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, current.midY, accuracy: 0.5)
    }

    func testNeverShrinksAWindowTheUserMadeBigger() {
        let current = NSRect(x: 100, y: 100, width: 1400, height: 900)

        XCTAssertNil(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))
    }

    func testGrowsOnlyTheShortSide() throws {
        let current = NSRect(x: 100, y: 100, width: 1300, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertEqual(frame.width, 1300)
        XCTAssertEqual(frame.height, 760)
    }

    func testStaysOnScreenNearAnEdge() throws {
        let current = NSRect(x: 1600, y: 0, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertEqual(frame.size, target)
    }

    func testFitsASmallScreen() throws {
        let small = NSRect(x: 0, y: 25, width: 1024, height: 700)
        let current = NSRect(x: 100, y: 100, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: small, target: target))

        XCTAssertEqual(frame.size, NSSize(width: 1024, height: 700))
        XCTAssertEqual(frame.origin, small.origin)
    }

    // MARK: - Sizing for the assistant

    private let assistant = NSSize(width: 920, height: 682)

    func testShrinksToTheAssistantSizeAroundTheSameCentre() throws {
        let current = NSRect(x: 200, y: 100, width: 1400, height: 900)

        let frame = try XCTUnwrap(MainWindowSizing.frameForFirstRun(current: current, visible: screen, target: assistant))

        XCTAssertEqual(frame.size, assistant)
        XCTAssertEqual(frame.midX, current.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, current.midY, accuracy: 0.5)
    }

    func testGrowsASmallerWindowToTheAssistantSize() throws {
        let current = NSRect(x: 400, y: 300, width: 760, height: 552)

        let frame = try XCTUnwrap(MainWindowSizing.frameForFirstRun(current: current, visible: screen, target: assistant))

        XCTAssertEqual(frame.size, assistant)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    func testDoesNothingWhenAlreadyAtTheAssistantSize() {
        let current = NSRect(origin: NSPoint(x: 300, y: 100), size: assistant)

        XCTAssertNil(MainWindowSizing.frameForFirstRun(current: current, visible: screen, target: assistant))
    }

    func testTheAssistantFitsASmallScreen() throws {
        let small = NSRect(x: 0, y: 25, width: 1024, height: 640)
        let current = NSRect(x: 100, y: 100, width: 760, height: 552)

        let frame = try XCTUnwrap(MainWindowSizing.frameForFirstRun(current: current, visible: small, target: assistant))

        XCTAssertEqual(frame.size, NSSize(width: 920, height: 640))
        XCTAssertGreaterThanOrEqual(frame.minY, small.minY)
    }

    func testTheAssistantSitsBetweenTheMinimumAndHalfAgain() {
        let minimum = MainWindowSizing.minimumSize
        let size = MainWindowSizing.assistantSize
        XCTAssertGreaterThan(size.width, minimum.width)
        XCTAssertGreaterThan(size.height, minimum.height)
        XCTAssertLessThan(size.width, minimum.width * 1.5)
        XCTAssertLessThan(size.height, minimum.height * 1.5)
    }

    func testReadsTheRequestedWindowSize() {
        let size = MainWindowSizing.requestedSize(in: ["Garage", "--appearance", "dark", "--window-size", "1440x900"])

        XCTAssertEqual(size, NSSize(width: 1440, height: 900))
    }

    func testIgnoresAMissingOrMalformedWindowSize() {
        XCTAssertNil(MainWindowSizing.requestedSize(in: ["Garage"]))
        XCTAssertNil(MainWindowSizing.requestedSize(in: ["Garage", "--window-size"]))
        XCTAssertNil(MainWindowSizing.requestedSize(in: ["Garage", "--window-size", "1440"]))
        XCTAssertNil(MainWindowSizing.requestedSize(in: ["Garage", "--window-size", "0x900"]))
    }
}
