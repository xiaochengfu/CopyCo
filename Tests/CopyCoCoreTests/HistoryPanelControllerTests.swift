import Foundation
import XCTest
@testable import CopyCo
@testable import CopyCoCore

@MainActor
final class HistoryPanelControllerTests: XCTestCase {
    func testPendingPasteStartsWhenDestinationHasNoTextInputOrIsMissing() {
        XCTAssertTrue(HistoryPanelController.shouldBeginPendingPaste(acceptsTextInput: false, hasLiveDestination: true))
        XCTAssertTrue(HistoryPanelController.shouldBeginPendingPaste(acceptsTextInput: true, hasLiveDestination: false))
        XCTAssertTrue(HistoryPanelController.shouldBeginPendingPaste(acceptsTextInput: false, hasLiveDestination: false))
        XCTAssertFalse(HistoryPanelController.shouldBeginPendingPaste(acceptsTextInput: true, hasLiveDestination: true))
        XCTAssertFalse(HistoryPanelController.shouldBeginPendingPaste(acceptsTextInput: nil, hasLiveDestination: true))
    }

    func testPendingPasteCompletesUnlessTextInputIsExplicitlyMissing() {
        XCTAssertTrue(HistoryPanelController.shouldCompletePendingPaste(acceptsTextInput: true))
        XCTAssertTrue(HistoryPanelController.shouldCompletePendingPaste(acceptsTextInput: nil))
        XCTAssertFalse(HistoryPanelController.shouldCompletePendingPaste(acceptsTextInput: false))
    }

    func testPendingPasteReasonPrefersDestinationProblem() {
        XCTAssertEqual(
            HistoryPanelController.pendingPasteReason(hasLiveDestination: false, acceptsTextInput: true),
            .noDestination
        )
        XCTAssertEqual(
            HistoryPanelController.pendingPasteReason(hasLiveDestination: false, acceptsTextInput: false),
            .noDestination
        )
        XCTAssertEqual(
            HistoryPanelController.pendingPasteReason(hasLiveDestination: true, acceptsTextInput: false),
            .noTextCursor
        )
    }
}
