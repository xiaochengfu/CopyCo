import AppKit
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

    func testPendingPasteKeepsArmedItemWhenFocusSnapshotIsInvalid() {
        let destination = NSRunningApplication.current
        let item = makeTextItem("retry me")
        var session = PendingPasteSession()
        let generation = session.beginRestoring(item: item)
        XCTAssertTrue(session.arm(generation: generation))
        let splitFocus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier + 1,
            acceptsTextInput: true
        )

        XCTAssertNil(session.beginSubmission(using: splitFocus))
        XCTAssertEqual(session.phase, .armed)
        XCTAssertEqual(session.item?.id, item.id)
    }

    func testPendingPasteSubmittingStatePreventsDuplicateHotKeySubmission() throws {
        let destination = NSRunningApplication.current
        let item = makeTextItem("only once")
        var session = PendingPasteSession()
        let generation = session.beginRestoring(item: item)
        XCTAssertTrue(session.arm(generation: generation))
        let focus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier,
            acceptsTextInput: nil
        )

        let first = try XCTUnwrap(session.beginSubmission(using: focus))
        XCTAssertEqual(first.item.id, item.id)
        XCTAssertEqual(first.application.processIdentifier, destination.processIdentifier)
        XCTAssertNil(session.beginSubmission(using: focus))
        XCTAssertEqual(session.phase, .submitting)
    }

    func testPendingPasteOnlyClearsItemAfterSuccessfulPaste() {
        let destination = NSRunningApplication.current
        let focus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier,
            acceptsTextInput: true
        )
        let item = makeTextItem("completion")
        var session = PendingPasteSession()

        var generation = session.beginRestoring(item: item)
        XCTAssertTrue(session.arm(generation: generation))
        XCTAssertNotNil(session.beginSubmission(using: focus))
        session.finishSubmission(.failed(message: "focus moved"))
        XCTAssertEqual(session.phase, .armed)
        XCTAssertEqual(session.item?.id, item.id)

        XCTAssertNotNil(session.beginSubmission(using: focus))
        session.finishSubmission(.copiedOnly)
        XCTAssertEqual(session.phase, .armed)
        XCTAssertEqual(session.item?.id, item.id)

        XCTAssertNotNil(session.beginSubmission(using: focus))
        session.finishSubmission(.pasted)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.item)

        generation = session.beginRestoring(item: item)
        XCTAssertGreaterThan(generation, 0)
    }

    func testCancelledRestoreGenerationCannotRearmPendingPaste() {
        let item = makeTextItem("cancelled restore")
        var session = PendingPasteSession()
        let staleGeneration = session.beginRestoring(item: item)

        session.cancel()

        XCTAssertFalse(session.arm(generation: staleGeneration))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.item)
    }

    private func makeTextItem(_ text: String) -> ClipboardItem {
        let data = Data(text.utf8)
        return ClipboardItem(
            kind: .text,
            preview: text,
            representations: [
                StoredRepresentation(
                    uti: "public.utf8-plain-text",
                    byteCount: data.count,
                    payload: data
                )
            ],
            totalBytes: data.count
        )
    }
}
