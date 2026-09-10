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

    func testPendingPasteKeepsArmedItemWhenFocusSnapshotIsInvalid() throws {
        let destination = try runningApplication()
        let item = makeTextItem("retry me")
        var session = PendingPasteSession()
        _ = arm(item: item, session: &session)
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
        let destination = try runningApplication()
        let item = makeTextItem("only once")
        var session = PendingPasteSession()
        _ = arm(item: item, session: &session)
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

    func testPendingPasteOnlyClearsItemAfterSuccessfulPaste() throws {
        let destination = try runningApplication()
        let focus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier,
            acceptsTextInput: true
        )
        let item = makeTextItem("completion")
        var session = PendingPasteSession()

        _ = arm(item: item, session: &session)
        let failedSubmission = try XCTUnwrap(session.beginSubmission(using: focus))
        XCTAssertTrue(session.finishSubmission(.failed(message: "focus moved"), generation: failedSubmission.generation))
        XCTAssertEqual(session.phase, .armed)
        XCTAssertEqual(session.item?.id, item.id)

        let copiedOnlySubmission = try XCTUnwrap(session.beginSubmission(using: focus))
        XCTAssertTrue(session.finishSubmission(.copiedOnly, generation: copiedOnlySubmission.generation))
        XCTAssertEqual(session.phase, .armed)
        XCTAssertEqual(session.item?.id, item.id)

        let pastedSubmission = try XCTUnwrap(session.beginSubmission(using: focus))
        XCTAssertTrue(session.finishSubmission(.pasted, generation: pastedSubmission.generation))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.item)
    }

    func testCancelledRestoreGenerationCannotRearmPendingPaste() {
        let item = makeTextItem("cancelled restore")
        var session = PendingPasteSession()
        let staleGeneration = session.beginCopying(item: item)
        XCTAssertTrue(session.beginRestoring(generation: staleGeneration))

        session.cancel()

        XCTAssertFalse(session.arm(generation: staleGeneration))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.item)
    }

    func testCancelledCopyCompletionCannotRestoreOrReplaceANewerSession() {
        let oldItem = makeTextItem("old copy")
        let newItem = makeTextItem("new copy")
        var session = PendingPasteSession()
        let oldGeneration = session.beginCopying(item: oldItem)
        session.cancel()
        let newGeneration = session.beginCopying(item: newItem)

        XCTAssertFalse(session.beginRestoring(generation: oldGeneration))
        XCTAssertEqual(session.phase, .copying)
        XCTAssertEqual(session.item?.id, newItem.id)
        XCTAssertTrue(session.beginRestoring(generation: newGeneration))
    }

    func testStaleSubmissionCompletionCannotMutateANewerSubmission() throws {
        let destination = try runningApplication()
        let focus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier,
            acceptsTextInput: true
        )
        let oldItem = makeTextItem("old submission")
        let newItem = makeTextItem("new submission")
        var session = PendingPasteSession()
        _ = arm(item: oldItem, session: &session)
        let oldSubmission = try XCTUnwrap(session.beginSubmission(using: focus))
        session.cancel()
        _ = arm(item: newItem, session: &session)
        let newSubmission = try XCTUnwrap(session.beginSubmission(using: focus))

        XCTAssertFalse(session.finishSubmission(.pasted, generation: oldSubmission.generation))
        XCTAssertEqual(session.phase, .submitting)
        XCTAssertEqual(session.item?.id, newItem.id)
        XCTAssertTrue(session.finishSubmission(.failed(message: "retry"), generation: newSubmission.generation))
        XCTAssertEqual(session.phase, .armed)
    }

    func testArmedTimeoutCannotExpireASubmittingSession() throws {
        let destination = try runningApplication()
        let focus = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: destination.processIdentifier,
            axPID: destination.processIdentifier,
            acceptsTextInput: true
        )
        let item = makeTextItem("timeout boundary")
        var session = PendingPasteSession()
        let generation = arm(item: item, session: &session)
        XCTAssertTrue(session.shouldExpire(generation: generation))

        XCTAssertNotNil(session.beginSubmission(using: focus))

        XCTAssertFalse(session.shouldExpire(generation: generation))
        XCTAssertEqual(session.phase, .submitting)
    }

    private func arm(item: ClipboardItem, session: inout PendingPasteSession) -> Int {
        let generation = session.beginCopying(item: item)
        XCTAssertTrue(session.beginRestoring(generation: generation))
        XCTAssertTrue(session.arm(generation: generation))
        return generation
    }

    private func runningApplication() throws -> NSRunningApplication {
        try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier > 0 && !$0.isTerminated
            }
        )
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
