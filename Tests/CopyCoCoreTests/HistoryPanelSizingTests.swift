import XCTest
@testable import CopyCo

final class HistoryPanelSizingTests: XCTestCase {
    func testEmptyStateHeightFitsItsContentWithoutClipping() {
        XCTAssertEqual(
            HistoryPanelSizing.height(
                itemCount: 0,
                rowHeight: 56,
                rowSpacing: 6,
                listVerticalPadding: 4,
                headerHeight: 64,
                footerHeight: 32,
                maxHeight: 420
            ),
            210
        )
    }

    func testHeightGrowsWithRowsButCapsAtMaximum() {
        XCTAssertEqual(
            HistoryPanelSizing.height(
                itemCount: 3,
                rowHeight: 56,
                rowSpacing: 6,
                listVerticalPadding: 4,
                headerHeight: 64,
                footerHeight: 32,
                maxHeight: 420
            ),
            284
        )
        XCTAssertEqual(
            HistoryPanelSizing.height(
                itemCount: 20,
                rowHeight: 56,
                rowSpacing: 6,
                listVerticalPadding: 4,
                headerHeight: 64,
                footerHeight: 32,
                maxHeight: 420
            ),
            420
        )
    }
}
