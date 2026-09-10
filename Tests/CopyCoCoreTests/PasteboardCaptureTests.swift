import AppKit
import Foundation
import XCTest
@testable import CopyCoCore

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class PasteboardCaptureTests: XCTestCase {
    func testCaptureNowRecordsABAWithoutWaitingForTimerAndPromotesOriginalA() async throws {
        let pasteboard = NSPasteboard(name: .init("CopyCoCoreTests-Immediate-\(UUID().uuidString)"))
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let capture = PasteboardCapture(
            pasteboard: pasteboard,
            queue: DispatchQueue(label: "com.copyco.tests.capture.immediate")
        )
        capture.onItem = { item in
            try? store.insert(item)
        }
        capture.start()
        defer { capture.stop() }

        write("A", to: pasteboard)
        await capture.captureNow()
        let originalAID = try XCTUnwrap(store.itemsSnapshot().items.first?.id)

        write("B", to: pasteboard)
        await capture.captureNow()

        write("A", to: pasteboard)
        await capture.captureNow()

        let snapshot = store.itemsSnapshot().items
        XCTAssertEqual(snapshot.map(\.preview), ["A", "B"])
        XCTAssertEqual(snapshot.first?.id, originalAID)
    }

    func testCaptureNowDoesNotRedeliverAChangeAlreadyObservedByTimer() async throws {
        let pasteboard = NSPasteboard(name: .init("CopyCoCoreTests-Barrier-\(UUID().uuidString)"))
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let capture = PasteboardCapture(
            pasteboard: pasteboard,
            queue: DispatchQueue(label: "com.copyco.tests.capture.barrier")
        )
        let callbackDelivered = DispatchSemaphore(value: 0)
        let callbackCount = CallbackCounter()
        capture.onItem = { item in
            try? store.insert(item)
            callbackCount.increment()
            callbackDelivered.signal()
        }
        capture.start()
        defer { capture.stop() }

        write("single change", to: pasteboard)
        XCTAssertEqual(callbackDelivered.wait(timeout: .now() + 2), .success)

        await capture.captureNow()

        XCTAssertEqual(callbackCount.value(), 1)
        XCTAssertEqual(store.itemsSnapshot().items.map(\.preview), ["single change"])
    }

    func testExtractClassifiesRichTextAheadOfPlainTextAndPreservesItemIndices() {
        let extraction = PasteboardCapture.extract(
            representations: [
                .init(uti: "public.url", data: Data("https://example.com".utf8)),
                .init(uti: "public.file-url", data: Data("file:///tmp/report.pdf".utf8)),
                .init(uti: "public.tiff", data: Data([0x49, 0x49, 0x2A, 0x00])),
                .init(uti: "public.rtf", data: Data("{\\rtf1 Rich}".utf8)),
                .init(uti: "public.utf8-plain-text", data: Data("Plain text".utf8))
            ],
            sourceBundleID: "com.example.source",
            sourceName: "Source"
        )

        let item = try! XCTUnwrap(extraction.item)
        XCTAssertEqual(item.kind, .richText)
        XCTAssertEqual(item.preview, "Plain text")
        XCTAssertEqual(item.sourceBundleID, "com.example.source")
        XCTAssertEqual(item.sourceName, "Source")
        XCTAssertEqual(item.representations.map(\.uti), [
            "public.url", "public.file-url", "public.tiff", "public.rtf", "public.utf8-plain-text"
        ])
        XCTAssertEqual(item.representations.map(\.itemIndex), [0, 0, 0, 0, 0])
        XCTAssertEqual(item.totalBytes, 67)
    }

    func testExtractRetainsRepeatedUTIsInTheirOriginalPasteboardItemGroups() throws {
        let extraction = PasteboardCapture.extract(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("first".utf8), itemIndex: 0),
            .init(uti: "public.utf8-plain-text", data: Data("second".utf8), itemIndex: 1),
            .init(uti: "public.rtf", data: Data("{\\rtf1 second}".utf8), itemIndex: 1)
        ])

        let item = try XCTUnwrap(extraction.item)
        XCTAssertEqual(item.kind, .richText)
        XCTAssertEqual(item.representations.map(\.uti), ["public.utf8-plain-text", "public.utf8-plain-text", "public.rtf"])
        XCTAssertEqual(item.representations.map(\.itemIndex), [0, 1, 1])
    }

    func testSourceAttributionPrefersPasteboardSourceOverPreviouslyObservedApplication() {
        let attribution = PasteboardCapture.sourceAttribution(
            pasteboardSourceBundleID: "com.example.editor",
            previousFrontmostBundleID: "com.example.destination",
            previousFrontmostName: "Destination"
        )

        XCTAssertEqual(attribution.bundleID, "com.example.editor")
        XCTAssertNil(attribution.name)
    }

    func testSourceAttributionFallsBackToPreviouslyObservedApplication() {
        let attribution = PasteboardCapture.sourceAttribution(
            pasteboardSourceBundleID: nil,
            previousFrontmostBundleID: "com.example.editor",
            previousFrontmostName: "Editor"
        )

        XCTAssertEqual(attribution.bundleID, "com.example.editor")
        XCTAssertEqual(attribution.name, "Editor")
    }

    func testExtractUsesRichTextImageFileAndURLKindsWhenHigherPriorityTypesAreAbsent() {
        let cases: [(PasteboardCapture.Representation, ClipboardItem.Kind)] = [
            (.init(uti: "public.rtf", data: Data("{\\rtf1 Rich}".utf8)), .richText),
            (.init(uti: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])), .image),
            (.init(uti: "public.file-url", data: Data("file:///tmp/report.pdf".utf8)), .file),
            (.init(uti: "public.url", data: Data("https://example.com".utf8)), .url)
        ]

        for (representation, expectedKind) in cases {
            let item = try! XCTUnwrap(PasteboardCapture.extract(representations: [representation]).item)
            XCTAssertEqual(item.kind, expectedKind, "Failed for \(representation.uti)")
        }
    }

    func testExtractConvertsRTFToReadablePlainTextPreview() {
        let rtf = Data("{\\rtf1\\ansi Hello \\b world\\b0}".utf8)

        let item = try! XCTUnwrap(PasteboardCapture.extract(
            representations: [.init(uti: "public.rtf", data: rtf)]
        ).item)

        XCTAssertEqual(item.preview, "Hello world")
    }

    func testExtractConvertsHTMLToReadablePlainTextPreview() {
        let html = Data("<html><body><p>Hello <b>world</b></p></body></html>".utf8)

        let item = try! XCTUnwrap(PasteboardCapture.extract(
            representations: [.init(uti: "public.html", data: html)]
        ).item)

        XCTAssertEqual(item.preview, "Hello world")
    }

    func testExtractRejectsPayloadsOverTheInlineLimit() {
        let oversized = Data(repeating: 0xAB, count: PasteboardCapture.maximumInlineBytes + 1)

        let extraction = PasteboardCapture.extract(
            representations: [.init(uti: "public.utf8-plain-text", data: oversized)]
        )

        XCTAssertNil(extraction.item)
        XCTAssertEqual(extraction.rejection, .payloadExceedsInlineLimit)
        // The size check runs before hashing, so no fingerprint is produced
        // for payloads that are rejected anyway.
        XCTAssertNil(extraction.fingerprint)
    }

    func testExtractProducesStableFingerprintForIdenticalData() {
        let representations = [
            PasteboardCapture.Representation(uti: "public.utf8-plain-text", data: Data("same".utf8)),
            PasteboardCapture.Representation(uti: "public.rtf", data: Data("{\\rtf1 same}".utf8))
        ]

        let first = PasteboardCapture.extract(representations: representations)
        let second = PasteboardCapture.extract(representations: representations)

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint?.count, 64)
        XCTAssertEqual(first.item?.contentFingerprint, first.fingerprint)
        XCTAssertNotEqual(
            first.fingerprint,
            PasteboardCapture.extract(
                representations: [.init(uti: "public.utf8-plain-text", data: Data("different".utf8))]
            ).fingerprint
        )
    }

    func testExtractUsesTheSameTextIdentityForPlainAndPlainPlusHTMLPayloads() throws {
        let plainOnly = PasteboardCapture.extract(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("same text".utf8), itemIndex: 0)
        ])
        let plainPlusHTML = PasteboardCapture.extract(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("same text".utf8), itemIndex: 0),
            .init(uti: "public.html", data: Data("<b>same text</b>".utf8), itemIndex: 0)
        ])

        XCTAssertNotEqual(plainOnly.fingerprint, plainPlusHTML.fingerprint)
        XCTAssertEqual(plainOnly.item?.contentIdentity, plainPlusHTML.item?.contentIdentity)
        XCTAssertEqual(try XCTUnwrap(plainOnly.item?.contentIdentity).count, 64)
    }

    func testExtractRequiresPlainTextForEveryPasteboardItemBeforeBuildingTextIdentity() throws {
        let richTextOnlyItem = PasteboardCapture.extract(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("first".utf8), itemIndex: 0),
            .init(uti: "public.html", data: Data("<b>second</b>".utf8), itemIndex: 1)
        ])
        let unsupportedItem = PasteboardCapture.extract(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("first".utf8), itemIndex: 0),
            .init(uti: "com.example.unsupported", data: Data([0x01]), itemIndex: 1)
        ])

        XCTAssertNil(try XCTUnwrap(richTextOnlyItem.item).contentIdentity)
        XCTAssertNil(try XCTUnwrap(unsupportedItem.item).contentIdentity)
    }

    func testCaptureBoundaryRejectsConcealedAndTransientTypes() {
        let extraction = PasteboardCapture.extract(
            representations: [.init(uti: "public.utf8-plain-text", data: Data("secret".utf8))]
        )

        XCTAssertFalse(PasteboardCapture.shouldEmit(
            extraction: extraction,
            typeIdentifiers: ["public.utf8-plain-text", PrivacyFilter.concealedTypeIdentifier],
            sourceBundleID: "com.example.editor",
            settings: PrivacySettings()
        ))
        XCTAssertFalse(PasteboardCapture.shouldEmit(
            extraction: extraction,
            typeIdentifiers: ["public.utf8-plain-text", PrivacyFilter.transientTypeIdentifier],
            sourceBundleID: "com.example.editor",
            settings: PrivacySettings()
        ))
    }

    func testCaptureBoundaryRejectsExcludedAndPasswordManagerSources() {
        let extraction = PasteboardCapture.extract(
            representations: [.init(uti: "public.utf8-plain-text", data: Data("secret".utf8))]
        )

        XCTAssertFalse(PasteboardCapture.shouldEmit(
            extraction: extraction,
            typeIdentifiers: ["public.utf8-plain-text"],
            sourceBundleID: "com.example.private",
            settings: PrivacySettings(excludedBundleIDs: ["com.example.private"])
        ))
        XCTAssertFalse(PasteboardCapture.shouldEmit(
            extraction: extraction,
            typeIdentifiers: ["public.utf8-plain-text"],
            sourceBundleID: "com.1password.1password",
            settings: PrivacySettings()
        ))
    }

    func testCancellationBarrierRejectsStoppedOrSupersededCapture() {
        XCTAssertFalse(PasteboardCapture.shouldDeliver(
            captureGeneration: 2,
            currentGeneration: 3,
            isRunning: true
        ))
        XCTAssertFalse(PasteboardCapture.shouldDeliver(
            captureGeneration: 2,
            currentGeneration: 2,
            isRunning: false
        ))
        XCTAssertTrue(PasteboardCapture.shouldDeliver(
            captureGeneration: 2,
            currentGeneration: 2,
            isRunning: true
        ))
    }

    func testPauseStateIncludesPrivacyPauseAndStoppedCapture() {
        XCTAssertTrue(PasteboardCapture.pauseState(isRunning: false, privacyPaused: false))
        XCTAssertTrue(PasteboardCapture.pauseState(isRunning: true, privacyPaused: true))
        XCTAssertFalse(PasteboardCapture.pauseState(isRunning: true, privacyPaused: false))
    }

    func testStopWaitsWhenAnAuthorizedCallbackIsInFlight() {
        XCTAssertTrue(PasteboardCapture.shouldWaitForCallbacks(inFlightCallbacks: 1))
        XCTAssertFalse(PasteboardCapture.shouldWaitForCallbacks(inFlightCallbacks: 0))
        XCTAssertFalse(PasteboardCapture.shouldWaitForCallbacks(
            inFlightCallbacks: 1,
            isOnCaptureQueue: true
        ))
    }

    func testStopWaitsForAnInFlightCaptureCallback() {
        let pasteboard = NSPasteboard(name: .init("CopyCoCoreTests-\(UUID().uuidString)"))
        let capture = PasteboardCapture(
            pasteboard: pasteboard,
            queue: DispatchQueue(label: "com.copyco.tests.capture")
        )
        let callbackStarted = DispatchSemaphore(value: 0)
        let allowCallbackToFinish = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        capture.onItem = { _ in
            callbackStarted.signal()
            _ = allowCallbackToFinish.wait(timeout: .now() + 2)
        }
        capture.start()
        defer { capture.stop() }

        let item = NSPasteboardItem()
        item.setString("interleaving", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            capture.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)

        allowCallbackToFinish.signal()
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 2), .success)
    }

    func testStopReturnsWhenCalledFromCaptureCallback() {
        let pasteboard = NSPasteboard(name: .init("CopyCoCoreTests-Reentrant-\(UUID().uuidString)"))
        let capture = PasteboardCapture(
            pasteboard: pasteboard,
            queue: DispatchQueue(label: "com.copyco.tests.capture.reentrant")
        )
        let stopReturned = DispatchSemaphore(value: 0)
        capture.onItem = { [weak capture] _ in
            capture?.stop()
            stopReturned.signal()
        }
        capture.start()
        defer { capture.stop() }

        let item = NSPasteboardItem()
        item.setString("reentrant", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(stopReturned.wait(timeout: .now() + 2), .success)
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyCoCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}
