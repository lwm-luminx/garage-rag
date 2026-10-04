import XCTest
@testable import GarageApp

final class EqualHeightGridTests: XCTestCase {

    func testTheAssistantsWidthHoldsThreeColumns() {
        // About 620 pt is left at the assistant's width (FirstRunSelectDataPage).
        XCTAssertEqual(EqualHeightGrid.columnCount(width: 620, minimum: 190, spacing: 12), 3)
        XCTAssertEqual(EqualHeightGrid.columnCount(width: 591, minimum: 190, spacing: 12), 2)
        XCTAssertEqual(EqualHeightGrid.columnCount(width: 100, minimum: 190, spacing: 12), 1)
    }

    func testColumnsShareTheWidthUpToTheirMaximum() {
        // Three columns share what the two gaps leave: (620 - 2 × 12) / 3.
        XCTAssertEqual(EqualHeightGrid.columnWidth(width: 620, count: 3, spacing: 12, maximum: 320), 596.0 / 3, accuracy: 0.001)
        XCTAssertEqual(EqualHeightGrid.columnWidth(width: 2000, count: 1, spacing: 12, maximum: 320), 320)
    }

    func testEveryTileInARowTakesTheTallestHeight() {
        XCTAssertEqual(EqualHeightGrid.rowHeights([60, 84, 72, 50, 90], columns: 3), [84, 90])
        XCTAssertEqual(EqualHeightGrid.rowHeights([], columns: 3), [])
    }
}
