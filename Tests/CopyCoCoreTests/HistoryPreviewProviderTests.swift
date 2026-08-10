import Foundation
import XCTest
@testable import CopyCo
@testable import CopyCoCore

final class HistoryPreviewProviderTests: XCTestCase {
    func testPlaceholderDetectionRecognizesLegacyRichTextAndImageLabels() {
        XCTAssertTrue(HistoryPreviewProvider.isPlaceholder("Rich text", kind: .richText))
        XCTAssertTrue(HistoryPreviewProvider.isPlaceholder("Image", kind: .image))
        XCTAssertFalse(HistoryPreviewProvider.isPlaceholder("Meeting notes", kind: .richText))
    }

    func testNormalizedTextCollapsesWhitespaceAndTruncatesLongValues() {
        let result = HistoryPreviewProvider.normalizedText("  one\n two   three  ", maxLength: 10)

        XCTAssertEqual(result, "one two…")
    }

    @MainActor
    func testPreviewRebuildsLegacyRichTextFromPersistedPlainText() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let payload = Data("Legacy plain text".utf8)
        let item = ClipboardItem(
            kind: .richText,
            preview: "Rich text",
            representations: [StoredRepresentation(
                uti: "public.utf8-plain-text",
                fileName: "legacy.bin",
                byteCount: payload.count
            )],
            totalBytes: payload.count
        )
        try payload.write(to: rootURL.appendingPathComponent("legacy.bin"))

        let provider = HistoryPreviewProvider(historyStore: HistoryStore(rootURL: rootURL))
        let preview = await provider.preview(for: item)

        XCTAssertEqual(preview.text, "Legacy plain text")
    }

    @MainActor
    func testCachedPreviewSurvivesPayloadDeletion() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoPreviewCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let payload = Data("Cached preview text".utf8)
        let item = ClipboardItem(
            kind: .text,
            preview: "Cached preview text",
            representations: [StoredRepresentation(
                uti: "public.utf8-plain-text",
                fileName: "cached.bin",
                byteCount: payload.count
            )],
            totalBytes: payload.count
        )
        try payload.write(to: rootURL.appendingPathComponent("cached.bin"))

        let provider = HistoryPreviewProvider(historyStore: HistoryStore(rootURL: rootURL))
        let first = await provider.preview(for: item)
        XCTAssertEqual(first.text, "Cached preview text")

        // A cache hit must not touch the disk: deleting the payload file and
        // asking again must still return the cached preview.
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("cached.bin"))
        let second = await provider.preview(for: item)

        XCTAssertEqual(second.text, "Cached preview text")
    }
}
