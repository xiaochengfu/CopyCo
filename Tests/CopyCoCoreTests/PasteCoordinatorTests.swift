import AppKit
import Foundation
import XCTest
@testable import CopyCo
@testable import CopyCoCore

@MainActor
private final class PasteEventRecorder {
    var processIdentifiers: [pid_t] = []
}

final class PasteCoordinatorTests: XCTestCase {
    @MainActor
    func testGroupsRepeatedUTIsByOriginalPasteboardItemIndex() {
        let grouped = PasteCoordinator.groupedRepresentations([
            .init(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("first".utf8)),
            .init(itemIndex: 1, uti: "public.utf8-plain-text", data: Data("second".utf8)),
            .init(itemIndex: 1, uti: "public.rtf", data: Data("{\\rtf1 second}".utf8))
        ])

        XCTAssertEqual(grouped.map(\.count), [1, 2])
        XCTAssertEqual(grouped[0].map(\.uti), ["public.utf8-plain-text"])
        XCTAssertEqual(grouped[1].map(\.uti), ["public.utf8-plain-text", "public.rtf"])
    }

    @MainActor
    func testPastesOnlyWhenAnExistingDestinationIsActuallyFrontmost() {
        XCTAssertFalse(PasteCoordinator.shouldSendPaste(hasDestination: false, destinationIsFrontmost: false))
        XCTAssertTrue(PasteCoordinator.shouldSendPaste(hasDestination: true, destinationIsFrontmost: true))
        XCTAssertFalse(PasteCoordinator.shouldSendPaste(hasDestination: true, destinationIsFrontmost: false))
    }

    @MainActor
    func testDestinationActivationYieldsBeforeRequestingActivationAndUsesObservedFrontmostState() async throws {
        let destination = try runningApplication()
        var calls: [String] = []
        var frontmostProcessIdentifier: pid_t?
        let activator = DestinationApplicationActivator(
            yieldActivation: { application in
                XCTAssertEqual(application.processIdentifier, destination.processIdentifier)
                calls.append("yield")
            },
            requestActivation: { application in
                XCTAssertEqual(calls, ["yield"])
                calls.append("activate")
                frontmostProcessIdentifier = application.processIdentifier
                return false
            },
            frontmostProcessIdentifier: { frontmostProcessIdentifier },
            sleep: { _ in }
        )

        let activationResult = await activator.activate(destination)
        XCTAssertTrue(activationResult)
        XCTAssertEqual(calls, ["yield", "activate"])
    }

    @MainActor
    func testDestinationActivationFailsWhenDestinationNeverBecomesFrontmost() async throws {
        var frontmostChecks = 0
        let activator = DestinationApplicationActivator(
            yieldActivation: { _ in },
            requestActivation: { _ in false },
            frontmostProcessIdentifier: {
                frontmostChecks += 1
                return nil
            },
            sleep: { _ in },
            maximumAttempts: 3
        )

        let activationResult = await activator.activate(try runningApplication())
        XCTAssertFalse(activationResult)
        XCTAssertEqual(frontmostChecks, 4)
    }

    @MainActor
    func testDestinationActivationSkipsRequestsWhenDestinationIsAlreadyFrontmost() async throws {
        let destination = try runningApplication()
        var calls: [String] = []
        let activator = DestinationApplicationActivator(
            yieldActivation: { _ in calls.append("yield") },
            requestActivation: { _ in
                calls.append("activate")
                return true
            },
            frontmostProcessIdentifier: { destination.processIdentifier },
            sleep: { _ in }
        )

        let activationResult = await activator.activate(destination)
        XCTAssertTrue(activationResult)
        XCTAssertEqual(calls, [])
    }

    @MainActor
    func testPasteRejectsSplitWorkspaceAndAccessibilityTargets() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let coordinator = try makeTargetedCoordinator(
            snapshots: [
                DestinationFocusSnapshot(
                    workspaceApplication: destination,
                    workspacePID: targetPID,
                    axPID: targetPID + 1,
                    acceptsTextInput: true
                )
            ],
            recorder: recorder
        )

        let result = await coordinator.paste(item: makeTextItem("split target"), to: destination)

        guard case .failed = result else {
            return XCTFail("Expected a failed paste, got \(result)")
        }
        XCTAssertEqual(recorder.processIdentifiers, [])
    }

    @MainActor
    func testPasteRejectsMissingAccessibilityTargetPID() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let coordinator = try makeTargetedCoordinator(
            snapshots: [
                DestinationFocusSnapshot(
                    workspaceApplication: destination,
                    workspacePID: targetPID,
                    axPID: nil,
                    acceptsTextInput: true
                )
            ],
            recorder: recorder
        )

        let result = await coordinator.paste(item: makeTextItem("missing AX pid"), to: destination)

        guard case .failed = result else {
            return XCTFail("Expected a failed paste, got \(result)")
        }
        XCTAssertEqual(recorder.processIdentifiers, [])
    }

    @MainActor
    func testPasteRejectsExplicitlyNonEditableFocus() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let coordinator = try makeTargetedCoordinator(
            snapshots: [
                DestinationFocusSnapshot(
                    workspaceApplication: destination,
                    workspacePID: targetPID,
                    axPID: targetPID,
                    acceptsTextInput: false
                )
            ],
            recorder: recorder
        )

        let result = await coordinator.paste(item: makeTextItem("not editable"), to: destination)

        guard case .failed = result else {
            return XCTFail("Expected a failed paste, got \(result)")
        }
        XCTAssertEqual(recorder.processIdentifiers, [])
    }

    @MainActor
    func testPasteWaitsUntilWorkspaceAndAccessibilityBothMatchTarget() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let notReady = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: targetPID,
            axPID: nil,
            acceptsTextInput: nil
        )
        let ready = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: targetPID,
            axPID: targetPID,
            acceptsTextInput: true
        )
        let coordinator = try makeTargetedCoordinator(
            snapshots: [notReady, ready, ready],
            recorder: recorder,
            focusMaximumAttempts: 2
        )

        let result = await coordinator.paste(item: makeTextItem("wait for focus"), to: destination)

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(recorder.processIdentifiers, [targetPID])
    }

    @MainActor
    func testPasteRevalidatesTargetImmediatelyBeforePosting() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let ready = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: targetPID,
            axPID: targetPID,
            acceptsTextInput: true
        )
        let changed = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: targetPID + 1,
            axPID: targetPID + 1,
            acceptsTextInput: true
        )
        let coordinator = try makeTargetedCoordinator(
            snapshots: [ready, changed],
            recorder: recorder
        )

        let result = await coordinator.paste(item: makeTextItem("final check"), to: destination)

        guard case .failed = result else {
            return XCTFail("Expected a failed paste, got \(result)")
        }
        XCTAssertEqual(recorder.processIdentifiers, [])
    }

    @MainActor
    func testPastePostsBothEventsToTheVerifiedTargetPID() async throws {
        let destination = try runningApplication()
        let targetPID = destination.processIdentifier
        let recorder = PasteEventRecorder()
        let ready = DestinationFocusSnapshot(
            workspaceApplication: destination,
            workspacePID: targetPID,
            axPID: targetPID,
            acceptsTextInput: nil
        )
        let coordinator = try makeTargetedCoordinator(
            snapshots: [ready, ready],
            recorder: recorder
        )

        let result = await coordinator.paste(item: makeTextItem("targeted paste"), to: destination)

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(recorder.processIdentifiers, [targetPID])
    }

    @MainActor
    func testPasteEventPairCreatesBothEventsBeforePostingThemToOnePID() throws {
        let targetPID = try runningApplication().processIdentifier
        var posted: [(pid_t, CGEventType)] = []

        let result = PasteCoordinator.postPasteEventPair(
            processIdentifier: targetPID,
            makeEvent: { phase in
                CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: phase == .keyDown)
            },
            postEvent: { event, pid in posted.append((pid, event.type)) }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(posted.map(\.0), [targetPID, targetPID])
        XCTAssertEqual(posted.map(\.1), [.keyDown, .keyUp])
    }

    @MainActor
    func testPasteEventPairPostsNothingWhenEitherEventCannotBeCreated() throws {
        let targetPID = try runningApplication().processIdentifier
        for failedPhase in [PasteEventPhase.keyDown, .keyUp] {
            var postedPIDs: [pid_t] = []
            let result = PasteCoordinator.postPasteEventPair(
                processIdentifier: targetPID,
                makeEvent: { phase in
                    guard phase != failedPhase else { return nil }
                    return CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: phase == .keyDown)
                },
                postEvent: { _, pid in postedPIDs.append(pid) }
            )

            XCTAssertFalse(result)
            XCTAssertEqual(postedPIDs, [])
        }
    }

    @MainActor
    func testInvalidProcessIdentifiersCannotValidateOrBecomePasteTargets() {
        let invalidSnapshot = DestinationFocusSnapshot(
            workspaceApplication: nil,
            workspacePID: 0,
            axPID: 0,
            acceptsTextInput: true
        )

        XCTAssertFalse(invalidSnapshot.validates(processIdentifier: 0))
        XCTAssertFalse(PasteCoordinator.isValidDestination(processIdentifier: 0, isTerminated: false))
        XCTAssertFalse(PasteCoordinator.isValidDestination(processIdentifier: -1, isTerminated: false))
        XCTAssertFalse(PasteCoordinator.isValidDestination(processIdentifier: 42, isTerminated: true))
        XCTAssertTrue(PasteCoordinator.isValidDestination(processIdentifier: 42, isTerminated: false))
    }

    @MainActor
    func testWithoutAccessibilityRestoresClipboardAndReturnsCopyOnly() async throws {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoPasteTests-\(UUID().uuidString)"))
        let coordinator = PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { false }
        )
        let data = Data("copy only".utf8)
        let item = ClipboardItem(
            kind: .text,
            preview: "copy only",
            representations: [StoredRepresentation(uti: "public.utf8-plain-text", byteCount: data.count, payload: data)],
            totalBytes: data.count
        )

        let result = await coordinator.paste(item: item, to: nil)

        XCTAssertEqual(result, .copiedOnly)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy only")
    }

    @MainActor
    func testCopyOnlyRoundTripRestoresOriginalPasteboardItemGroups() async throws {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoPasteGroups-\(UUID().uuidString)"))
        let coordinator = PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { false }
        )
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let richSecond = Data("{\\rtf1 second}".utf8)
        let item = ClipboardItem(
            kind: .richText,
            preview: "Rich text",
            representations: [
                StoredRepresentation(uti: "public.utf8-plain-text", itemIndex: 0, byteCount: first.count, payload: first),
                StoredRepresentation(uti: "public.utf8-plain-text", itemIndex: 1, byteCount: second.count, payload: second),
                StoredRepresentation(uti: "public.rtf", itemIndex: 1, byteCount: richSecond.count, payload: richSecond)
            ],
            totalBytes: first.count + second.count + richSecond.count
        )

        let result = await coordinator.paste(item: item, to: nil)
        XCTAssertEqual(result, .copiedOnly)
        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "first")
        XCTAssertEqual(restoredItems[1].string(forType: .string), "second")
        XCTAssertEqual(restoredItems[1].data(forType: .init("public.rtf")), richSecond)
    }

    @MainActor
    func testMissingFileURLFailsBeforeClobberingTheClipboard() async throws {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoMissingFile-\(UUID().uuidString)"))
        // Seed the pasteboard with something the user might have copied; it
        // must survive an attempted paste of a stale file reference.
        let originalClipboard = Data("user's current clipboard".utf8)
        pasteboard.clearContents()
        let seedItem = NSPasteboardItem()
        seedItem.setData(originalClipboard, forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([seedItem]))
        let changeCountBefore = pasteboard.changeCount

        let coordinator = PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { false }
        )
        let missingURL = Data("file:///tmp/copyco-does-not-exist".utf8)
        let item = ClipboardItem(
            kind: .file,
            preview: "Missing file",
            representations: [StoredRepresentation(uti: "public.file-url", byteCount: missingURL.count, payload: missingURL)],
            totalBytes: missingURL.count
        )

        let result = await coordinator.paste(item: item, to: nil)
        XCTAssertEqual(
            result,
            .failed(message: "The source file for this history item is no longer available.")
        )
        // The clipboard was left untouched: same change count, same contents.
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.string(forType: .string), "user's current clipboard")
        XCTAssertNil(pasteboard.string(forType: .init("public.file-url")))
    }

    @MainActor
    func testCopyWritesItemToPasteboardWithoutActivatingOrPasting() throws {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoCopyTests-\(UUID().uuidString)"))
        let coordinator = PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { true }
        )
        let data = Data("two-phase paste".utf8)
        let item = ClipboardItem(
            kind: .text,
            preview: "two-phase paste",
            representations: [StoredRepresentation(uti: "public.utf8-plain-text", byteCount: data.count, payload: data)],
            totalBytes: data.count
        )

        let result = coordinator.copy(item: item)

        XCTAssertEqual(result, .copiedOnly)
        XCTAssertEqual(pasteboard.string(forType: .string), "two-phase paste")
    }

    @MainActor
    func testCopyRefusesMissingFileURLWithoutTouchingPasteboard() throws {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoCopyMissingFile-\(UUID().uuidString)"))
        let coordinator = PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { true }
        )
        pasteboard.clearContents()
        let seedItem = NSPasteboardItem()
        seedItem.setData(Data("user's current clipboard".utf8), forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([seedItem]))
        let changeCountBefore = pasteboard.changeCount

        let missingURL = Data("file:///tmp/copyco-does-not-exist".utf8)
        let item = ClipboardItem(
            kind: .file,
            preview: "Missing file",
            representations: [StoredRepresentation(uti: "public.file-url", byteCount: missingURL.count, payload: missingURL)],
            totalBytes: missingURL.count
        )

        let result = coordinator.copy(item: item)

        XCTAssertEqual(
            result,
            .failed(message: "The source file for this history item is no longer available.")
        )
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.string(forType: .string), "user's current clipboard")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyCoPasteCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    @MainActor
    private func makeTargetedCoordinator(
        snapshots: [DestinationFocusSnapshot],
        recorder: PasteEventRecorder,
        focusMaximumAttempts: Int = 1
    ) throws -> PasteCoordinator {
        let rootURL = try makeTemporaryDirectory()
        let pasteboard = NSPasteboard(name: .init("CopyCoTargetedPaste-\(UUID().uuidString)"))
        let destinationPID = try XCTUnwrap(snapshots.first?.workspaceApplication?.processIdentifier)
        var remainingSnapshots = snapshots
        return PasteCoordinator(
            historyStore: HistoryStore(rootURL: rootURL),
            pasteboard: pasteboard,
            isAccessibilityTrusted: { true },
            destinationActivator: DestinationApplicationActivator(
                yieldActivation: { _ in },
                requestActivation: { _ in true },
                frontmostProcessIdentifier: { destinationPID },
                sleep: { _ in }
            ),
            focusReader: {
                if remainingSnapshots.count > 1 {
                    return remainingSnapshots.removeFirst()
                }
                return remainingSnapshots[0]
            },
            eventPoster: { pid in
                recorder.processIdentifiers.append(pid)
                return true
            },
            focusMaximumAttempts: focusMaximumAttempts,
            focusSleep: { _ in }
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

    @MainActor
    private func runningApplication() throws -> NSRunningApplication {
        try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier > 0 && !$0.isTerminated
            }
        )
    }
}
