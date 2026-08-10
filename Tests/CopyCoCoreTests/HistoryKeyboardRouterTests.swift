import XCTest
import CopyCoCore
@testable import CopyCo

final class HistoryKeyboardRouterTests: XCTestCase {
    @MainActor
    func testSelectionMovesThroughFilteredIdentifiersWithArrowKeys() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let identifiers = [first, second, third]

        XCTAssertEqual(
            HistoryKeyboardRouter.nextSelection(current: nil, in: identifiers, direction: .down),
            first
        )
        XCTAssertEqual(
            HistoryKeyboardRouter.nextSelection(current: first, in: identifiers, direction: .down),
            second
        )
        XCTAssertEqual(
            HistoryKeyboardRouter.nextSelection(current: second, in: identifiers, direction: .up),
            first
        )
        XCTAssertEqual(
            HistoryKeyboardRouter.nextSelection(current: third, in: identifiers, direction: .down),
            third
        )
    }

    @MainActor
    func testUpdateCanResetSelectionToFirstItemWhenPanelIsShown() {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.update(items: [first, second])
        router.selection = second.id

        router.update(items: [first, second], resetSelection: true)

        XCTAssertEqual(router.selection, first.id)
    }

    @MainActor
    func testPreparingForPresentationAlwaysRequestsImmediateTopScroll() throws {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)

        router.prepareForPresentation(items: [first, second])
        let firstRequest = try XCTUnwrap(router.scrollRequest)
        XCTAssertEqual(firstRequest.target, first.id)
        XCTAssertEqual(firstRequest.alignment, .top)
        XCTAssertFalse(firstRequest.animated)

        router.prepareForPresentation(items: [first, second])
        let secondRequest = try XCTUnwrap(router.scrollRequest)
        XCTAssertEqual(router.selection, first.id)
        XCTAssertGreaterThan(secondRequest.sequence, firstRequest.sequence)
        XCTAssertEqual(secondRequest.target, first.id)
        XCTAssertEqual(secondRequest.alignment, .top)
        XCTAssertFalse(secondRequest.animated)
    }

    @MainActor
    func testPreparingForPresentationRequestsSearchFocusAndSelectsFirstItemEveryTime() {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)

        router.prepareForPresentation(items: [first, second])
        let firstRequest = router.searchFocusRequestSequence
        router.selection = second.id

        router.prepareForPresentation(items: [first, second])

        XCTAssertEqual(router.selection, first.id)
        XCTAssertGreaterThan(router.searchFocusRequestSequence, firstRequest)
    }

    @MainActor
    func testPreparingEmptyPresentationClearsStaleScrollRequest() {
        let router = HistoryKeyboardRouter()
        let item = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        router.prepareForPresentation(items: [item])
        XCTAssertNotNil(router.scrollRequest)

        router.prepareForPresentation(items: [])

        XCTAssertNil(router.selection)
        XCTAssertNil(router.scrollRequest)

        router.prepareForPresentation(items: [item])
        router.update(items: [])
        XCTAssertNil(router.scrollRequest)
    }

    @MainActor
    func testPresentationGateRevealsOnlyAfterMatchingScrollRequestIsHandled() {
        var gate = HistoryPanelPresentationGate()

        XCTAssertFalse(gate.begin(requestSequence: 4))
        XCTAssertFalse(gate.handle(sequence: 3))
        XCTAssertTrue(gate.handle(sequence: 4))
        XCTAssertFalse(gate.handle(sequence: 4))

        XCTAssertFalse(gate.begin(requestSequence: 8))
        XCTAssertTrue(gate.handle(sequence: 9))
        XCTAssertTrue(gate.begin(requestSequence: nil))
    }

    @MainActor
    func testVerticalNavigationRequestsAnimatedNearestScrollOnlyWhenSelectionMoves() throws {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.update(items: [first, second])

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 125, characters: "↓")))
        let movedRequest = try XCTUnwrap(router.scrollRequest)
        XCTAssertEqual(movedRequest.target, second.id)
        XCTAssertEqual(movedRequest.alignment, .nearest)
        XCTAssertTrue(movedRequest.animated)

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 125, characters: "↓")))
        XCTAssertEqual(router.scrollRequest, movedRequest)
    }

    @MainActor
    func testDeleteKeysAreRoutedAsHistoryDeletion() {
        XCTAssertEqual(HistoryKeyboardRouter.command(for: 51), .delete)
        XCTAssertEqual(HistoryKeyboardRouter.command(for: 117), .delete)
    }

    @MainActor
    func testSpaceTogglesPinAndEnterStillPastes() throws {
        let router = HistoryKeyboardRouter()
        let item = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        router.update(items: [item])
        var pinToggled = false
        var pasted = false
        router.onTogglePin = { selected in
            pinToggled = selected.id == item.id
        }
        router.onPaste = { selected in
            pasted = selected.id == item.id
        }

        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertTrue(router.route(space))
        XCTAssertTrue(router.route(enter))
        XCTAssertTrue(pinToggled)
        XCTAssertTrue(pasted)
        XCTAssertEqual(HistoryKeyboardRouter.command(for: 36), .paste)
        XCTAssertEqual(HistoryKeyboardRouter.command(for: 49), .togglePin)
    }

    @MainActor
    func testDeletingMiddleItemSelectsTheNextItem() {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        let third = ClipboardItem(kind: .text, preview: "third", representations: [], totalBytes: 0)
        router.update(items: [first, second, third])
        router.selection = second.id
        router.prepareForDeletion(of: second)

        router.update(items: [first, third])

        XCTAssertEqual(router.selection, third.id)
    }

    @MainActor
    func testDeletingLastItemSelectsPreviousAndDeletingOnlyItemClearsSelection() {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.update(items: [first, second])
        router.selection = second.id
        router.prepareForDeletion(of: second)
        router.update(items: [first])
        XCTAssertEqual(router.selection, first.id)

        router.prepareForDeletion(of: first)
        router.update(items: [])
        XCTAssertNil(router.selection)
    }

    @MainActor
    func testDeleteKeyPreparesSelectionMigrationBeforeCallingDeleteHandler() throws {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.update(items: [first, second])
        router.selection = first.id
        var deletedID: ClipboardItem.ID?
        router.onDelete = { deletedID = $0.id }

        let deleteEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: 51
        ))

        XCTAssertTrue(router.route(deleteEvent))
        XCTAssertEqual(deletedID, first.id)
        router.update(items: [second])
        XCTAssertEqual(router.selection, second.id)
    }

    @MainActor
    func testRightAndLeftTraverseContentDeleteAndPinTargets() throws {
        let router = HistoryKeyboardRouter()
        let item = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        router.update(items: [item])
        XCTAssertEqual(router.focusTarget, .content)

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 124, characters: "→")))
        XCTAssertEqual(router.focusTarget, .delete)
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 124, characters: "→")))
        XCTAssertEqual(router.focusTarget, .pin)
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 123, characters: "←")))
        XCTAssertEqual(router.focusTarget, .delete)
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 123, characters: "←")))
        XCTAssertEqual(router.focusTarget, .content)
    }

    @MainActor
    func testEnterDispatchesToTheFocusedContentDeleteOrPinAction() throws {
        let router = HistoryKeyboardRouter()
        let item = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        router.update(items: [item])
        var pasted = false
        var deleted = false
        var pinned = false
        router.onPaste = { _ in pasted = true }
        router.onDelete = { _ in deleted = true }
        router.onTogglePin = { _ in pinned = true }

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertTrue(pasted)
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 124, characters: "→")))
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertTrue(deleted)
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 124, characters: "→")))
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 36, characters: "\r")))
        XCTAssertTrue(pinned)
    }

    @MainActor
    func testVerticalMovementResetsActionFocusToContent() throws {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.update(items: [first, second])
        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 124, characters: "→")))
        XCTAssertEqual(router.focusTarget, .delete)

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 125, characters: "↓")))
        XCTAssertEqual(router.selection, second.id)
        XCTAssertEqual(router.focusTarget, .content)
    }

    @MainActor
    func testSearchFieldKeepsEditingShortcutsButAllowsHistoryNavigation() {
        let editingCommands: [HistoryKeyboardRouter.Command] = [.delete, .togglePin, .left, .right]
        let historyCommands: [HistoryKeyboardRouter.Command] = [.up, .down, .paste, .dismiss]

        for command in editingCommands {
            XCTAssertFalse(HistoryKeyboardRouter.shouldRoute(command: command, searchFieldFocused: true))
        }
        for command in historyCommands {
            XCTAssertTrue(HistoryKeyboardRouter.shouldRoute(command: command, searchFieldFocused: true))
        }
        for command in editingCommands + historyCommands {
            XCTAssertTrue(HistoryKeyboardRouter.shouldRoute(command: command, searchFieldFocused: false))
        }
    }

    @MainActor
    func testVerticalNavigationNotifiesSearchFocusToResign() throws {
        let router = HistoryKeyboardRouter()
        let item = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        router.update(items: [item])
        var resigned = false
        router.onSelectionNavigation = { resigned = true }

        XCTAssertTrue(router.route(try makeKeyEvent(keyCode: 125, characters: "↓")))
        XCTAssertTrue(resigned)
    }

    @MainActor
    func testRefocusSearchRequestsFocusWithoutTouchingSelectionOrScroll() {
        let router = HistoryKeyboardRouter()
        let first = ClipboardItem(kind: .text, preview: "first", representations: [], totalBytes: 0)
        let second = ClipboardItem(kind: .text, preview: "second", representations: [], totalBytes: 0)
        router.prepareForPresentation(items: [first, second])
        let focusSequence = router.searchFocusRequestSequence
        router.selection = second.id

        router.refocusSearch()

        XCTAssertEqual(router.selection, second.id)
        XCTAssertEqual(router.scrollRequest?.target, first.id)
        XCTAssertGreaterThan(router.searchFocusRequestSequence, focusSequence)
    }

    @MainActor
    func testTypingDetectionReturnsPlainPrintableKeysButNotShortcuts() throws {
        // Plain letters return typing to the search field.
        XCTAssertTrue(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 0, characters: "a")
        ))
        XCTAssertTrue(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 0, characters: "A", modifierFlags: [.shift])
        ))
        // Command/Option/Control shortcuts must not be hijacked.
        XCTAssertFalse(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 0, characters: "a", modifierFlags: [.command])
        ))
        XCTAssertFalse(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 0, characters: "a", modifierFlags: [.option])
        ))
        XCTAssertFalse(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 0, characters: "a", modifierFlags: [.control])
        ))
        // Control characters (Escape, Tab, Return) are not typing input.
        XCTAssertFalse(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 53, characters: "\u{1B}")
        ))
        XCTAssertFalse(HistoryPanelController.shouldReturnTypingToSearch(
            try makeKeyEvent(keyCode: 36, characters: "\r")
        ))
    }

    @MainActor
    func testPanelRestoresOnlyForActionablePasteFailure() {
        XCTAssertFalse(HistoryPanelController.shouldRestorePanel(after: .pasted))
        XCTAssertFalse(HistoryPanelController.shouldRestorePanel(after: .copiedOnly))
        XCTAssertTrue(HistoryPanelController.shouldRestorePanel(after: .failed(message: "failed")))
    }

    @MainActor
    func testSuccessfulPasteDoesNotReactivateDestinationWhenPanelCloses() {
        XCTAssertFalse(HistoryPanelController.shouldRestorePreviousApplication(after: .pasted))
        XCTAssertTrue(HistoryPanelController.shouldRestorePreviousApplication(after: .copiedOnly))
        XCTAssertTrue(HistoryPanelController.shouldRestorePreviousApplication(after: .failed(message: "failed")))
    }

    @MainActor
    func testHistoryPanelHidesWhenCopyCoLosesFocus() {
        XCTAssertTrue(HistoryPanelController.hidesOnDeactivate)
    }

    private func makeKeyEvent(keyCode: UInt16, characters: String, modifierFlags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
