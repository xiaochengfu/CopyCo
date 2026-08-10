import AppKit
import Foundation
import XCTest
@testable import CopyCo
@testable import CopyCoCore

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
    func testDestinationActivationYieldsBeforeRequestingActivationAndUsesObservedFrontmostState() async {
        let destination = NSRunningApplication.current
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
    func testDestinationActivationFailsWhenDestinationNeverBecomesFrontmost() async {
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

        let activationResult = await activator.activate(NSRunningApplication.current)
        XCTAssertFalse(activationResult)
        XCTAssertEqual(frontmostChecks, 3)
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
}
