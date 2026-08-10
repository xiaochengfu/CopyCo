import Foundation
import XCTest
@testable import CopyCoCore

final class HistoryStoreTests: XCTestCase {
    func testItemsAreReturnedNewestFirstAfterInsertion() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let older = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("old".utf8))
        let newer = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("new".utf8))

        try store.insert(older)
        try store.insert(newer)

        XCTAssertEqual(store.items().map(\.id), [newer.id, older.id])
    }

    func testDeleteRemovesTheItemAndItsPayload() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let item = makeItem(payload: Data("delete me".utf8))
        try store.insert(item)
        let storedItem = try XCTUnwrap(store.items().first)
        let payloadURL = try XCTUnwrap(storedItem.representations.first).payloadURL(relativeTo: rootURL)

        try store.delete(id: item.id)

        XCTAssertTrue(store.items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    func testRemoveAllClearsItemsAndPayloadFiles() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        try store.insert(makeItem(payload: Data("first".utf8)))
        try store.insert(makeItem(payload: Data("second".utf8)))

        try store.removeAll()

        XCTAssertTrue(store.items().isEmpty)
        XCTAssertEqual(try payloadFileCount(in: rootURL), 0)
    }

    func testEvictsOldestItemWhenCountReaches51() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let baseDate = Date(timeIntervalSince1970: 1_000)
        var insertedIDs: [UUID] = []

        for offset in 0 ... 50 {
            let item = makeItem(
                createdAt: baseDate.addingTimeInterval(TimeInterval(offset)),
                payload: Data(("payload-" + String(offset)).utf8)
            )
            insertedIDs.append(item.id)
            try store.insert(item)
        }

        XCTAssertEqual(store.items().count, 50)
        XCTAssertFalse(store.items().contains(where: { $0.id == insertedIDs[0] }))
        XCTAssertEqual(store.items().first?.id, insertedIDs[50])
    }

    func testEvictsOldestItemsWhenByteLimitIsExceeded() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL, limits: HistoryLimits(maxItems: 10, maxBytes: 5, maxInlineBytes: 5))
        let first = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data([1, 2, 3]))
        let second = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data([4, 5, 6]))

        try store.insert(first)
        try store.insert(second)

        XCTAssertEqual(store.items().map(\.id), [second.id])
        XCTAssertEqual(store.items().first?.totalBytes, 3)
    }

    func testRejectsABackdatedItemInsteadOfEvictingItAtTheCountLimit() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL, limits: HistoryLimits(maxItems: 1, maxBytes: 10, maxInlineBytes: 10))
        let retainedItem = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data([1]))
        let backdatedItem = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data([2]))
        try store.insert(retainedItem)

        XCTAssertThrowsError(try store.insert(backdatedItem)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .itemExceedsLimits)
        }
        XCTAssertEqual(store.items().map(\.id), [retainedItem.id])
        XCTAssertEqual(try payloadFileCount(in: rootURL), 1)
    }

    func testLoadDiscardsAnEntryWhosePayloadFileIsMissing() throws {
        let rootURL = try makeTemporaryDirectory()
        let writer = HistoryStore(rootURL: rootURL)
        let item = makeItem(payload: Data("persisted".utf8))
        try writer.insert(item)
        let payloadURL = try XCTUnwrap(writer.items().first?.representations.first?.payloadURL(relativeTo: rootURL))
        try FileManager.default.removeItem(at: payloadURL)

        let reader = HistoryStore(rootURL: rootURL)
        try reader.load()

        XCTAssertTrue(reader.items().isEmpty)
    }

    func testLoadPreservesMalformedIndexAsTimestampedRecoveryFileAndReclaimsOrphans() throws {
        let rootURL = try makeTemporaryDirectory()
        let payloadURL = rootURL.appendingPathComponent("orphan.bin")
        try Data("payload".utf8).write(to: payloadURL)
        let indexURL = rootURL.appendingPathComponent("index.json")
        try Data("{ not valid JSON".utf8).write(to: indexURL)

        let store = HistoryStore(rootURL: rootURL)
        try store.load()

        XCTAssertTrue(store.items().isEmpty)
        // With no valid index, the orphaned payload is reclaimed instead of
        // leaking on disk forever.
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter { $0.hasPrefix("History.corrupt.") && $0.hasSuffix(".json") }
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent(recoveryFiles[0])),
            Data("{ not valid JSON".utf8)
        )
    }

    func testStoredRepresentationDecodesOldIndexesWithItemIndexZero() throws {
        let representation = try JSONDecoder().decode(
            StoredRepresentation.self,
            from: Data("{\"uti\":\"public.utf8-plain-text\",\"fileName\":\"item.bin\",\"byteCount\":4}".utf8)
        )

        XCTAssertEqual(representation.itemIndex, 0)
    }

    func testReloadPreservesGroupedRepresentationIndices() throws {
        let rootURL = try makeTemporaryDirectory()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let item = ClipboardItem(
            kind: .richText,
            preview: "Rich text",
            representations: [
                StoredRepresentation(uti: "public.utf8-plain-text", itemIndex: 0, byteCount: first.count, payload: first),
                StoredRepresentation(uti: "public.utf8-plain-text", itemIndex: 1, byteCount: second.count, payload: second),
                StoredRepresentation(uti: "public.rtf", itemIndex: 1, byteCount: second.count, payload: second)
            ],
            totalBytes: first.count + second.count * 2
        )
        let writer = HistoryStore(rootURL: rootURL)
        try writer.insert(item)

        let reader = HistoryStore(rootURL: rootURL)
        try reader.load()

        XCTAssertEqual(reader.items().first?.representations.map(\.itemIndex), [0, 1, 1])
    }

    func testUpdatingLimitsEvictsOldestRetainedItems() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let older = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("old".utf8))
        let newer = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("new".utf8))
        try store.insert(older)
        try store.insert(newer)

        try store.updateLimits(HistoryLimits(maxItems: 1, maxBytes: 10, maxInlineBytes: 10))

        XCTAssertEqual(store.items().map(\.id), [newer.id])
        XCTAssertEqual(store.limits.maxItems, 1)
    }

    func testInsertingExistingContentPromotesTheOriginalRecord() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let original = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("same".utf8))
        let other = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("other".utf8))
        try store.insert(original)
        try store.insert(other)

        let recopied = makeItem(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 3),
            payload: Data("same".utf8),
            sourceBundleID: "com.example.new-source",
            sourceName: "New Source"
        )
        try store.insert(recopied)

        let promoted = try XCTUnwrap(store.items().first)
        XCTAssertEqual(store.items().count, 2)
        XCTAssertEqual(promoted.id, original.id)
        XCTAssertEqual(promoted.createdAt, recopied.createdAt)
        XCTAssertEqual(promoted.sourceBundleID, recopied.sourceBundleID)
        XCTAssertEqual(promoted.sourceName, recopied.sourceName)

        try store.setPinned(id: original.id, pinned: true)
        let pinnedRecopy = makeItem(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 4),
            payload: Data("same".utf8),
            sourceBundleID: "com.example.pinned-source",
            sourceName: "Pinned Source"
        )
        try store.insert(pinnedRecopy)

        let pinned = try XCTUnwrap(store.items().first)
        XCTAssertEqual(pinned.id, original.id)
        XCTAssertEqual(pinned.createdAt, pinnedRecopy.createdAt)
        XCTAssertEqual(pinned.sourceName, pinnedRecopy.sourceName)
        XCTAssertTrue(pinned.isPinned)

        let reloaded = HistoryStore(rootURL: rootURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.items().first?.id, original.id)
        XCTAssertEqual(reloaded.items().first?.createdAt, pinnedRecopy.createdAt)
    }

    func testInsertingExistingContentPromotesLegacyRecordWithoutFingerprint() throws {
        let rootURL = try makeTemporaryDirectory()
        let original = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("legacy".utf8))
        let writer = HistoryStore(rootURL: rootURL)
        try writer.insert(original)

        let indexURL = rootURL.appendingPathComponent("index.json")
        var index = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]]
        )
        index[0].removeValue(forKey: "contentFingerprint")
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)

        let store = HistoryStore(rootURL: rootURL)
        try store.load()
        let recopied = makeItem(
            createdAt: Date(timeIntervalSince1970: 2),
            payload: Data("legacy".utf8),
            sourceName: "Legacy Source"
        )
        try store.insert(recopied)

        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.items().first?.id, original.id)
        XCTAssertEqual(store.items().first?.createdAt, recopied.createdAt)
        XCTAssertEqual(store.items().first?.sourceName, recopied.sourceName)
        XCTAssertEqual(store.items().first?.contentFingerprint?.count, 64)
    }

    func testPinnedItemsSortBeforeUnpinnedItemsAndPersistAcrossReload() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let older = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("old".utf8))
        let newer = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("new".utf8))
        try store.insert(older)
        try store.insert(newer)

        try store.setPinned(id: older.id, pinned: true)

        XCTAssertEqual(store.items().map(\.id), [older.id, newer.id])
        let pinnedItem = try XCTUnwrap(store.items().first)
        XCTAssertTrue(pinnedItem.isPinned)

        let reloaded = HistoryStore(rootURL: rootURL)
        try reloaded.load()
        XCTAssertEqual(reloaded.items().map(\.id), [older.id, newer.id])
        let reloadedPinnedItem = try XCTUnwrap(reloaded.items().first)
        XCTAssertTrue(reloadedPinnedItem.isPinned)
    }

    func testPinningMoreThanThreeItemsFailsWithoutChangingTheFourthItem() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let items = try (0 ..< 4).map { index in
            let item = makeItem(createdAt: Date(timeIntervalSince1970: TimeInterval(index)), payload: Data([UInt8(index)]))
            try store.insert(item)
            return item
        }

        for item in items.prefix(3) {
            try store.setPinned(id: item.id, pinned: true)
        }

        XCTAssertThrowsError(try store.setPinned(id: items[3].id, pinned: true)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .pinLimitReached)
        }
        XCTAssertEqual(store.items().filter { $0.isPinned }.count, 3)
        let fourthItem = try XCTUnwrap(store.items().first(where: { $0.id == items[3].id }))
        XCTAssertFalse(fourthItem.isPinned)
    }

    func testInsertingAPinnedItemAfterThreePinnedItemsFails() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let pinnedItems = try (0 ..< 3).map { index in
            let item = makeItem(createdAt: Date(timeIntervalSince1970: TimeInterval(index)), payload: Data([UInt8(index)]))
            try store.insert(item)
            try store.setPinned(id: item.id, pinned: true)
            return item
        }
        let fourth = ClipboardItem(
            kind: .text,
            preview: "fourth",
            isPinned: true,
            representations: [StoredRepresentation(uti: "public.utf8-plain-text", byteCount: 1, payload: Data([4]))],
            totalBytes: 1
        )

        XCTAssertThrowsError(try store.insert(fourth)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .pinLimitReached)
        }
        XCTAssertEqual(store.items().filter { $0.isPinned }.map(\.id), pinnedItems.reversed().map(\.id))
    }

    func testLegacyClipboardItemWithoutPinnedFieldDefaultsToUnpinned() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"kind":"text","preview":"legacy","sourceBundleID":null,"sourceName":null,"representations":[],"totalBytes":0}
        """
        let item = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))

        XCTAssertFalse(item.isPinned)
    }

    func testUpdateLimitsNeverEvictsPinnedItems() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let older = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("old".utf8))
        let newer = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("new".utf8))
        try store.insert(older)
        try store.insert(newer)
        try store.setPinned(id: older.id, pinned: true)
        try store.setPinned(id: newer.id, pinned: true)

        XCTAssertThrowsError(try store.updateLimits(HistoryLimits(maxItems: 1, maxBytes: 10, maxInlineBytes: 10))) { error in
            XCTAssertEqual(error as? HistoryStoreError, .pinnedItemsExceedLimits)
        }
        // Nothing was evicted or unpinned; limits unchanged.
        XCTAssertEqual(store.items().map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.items().filter(\.isPinned).count, 2)
        XCTAssertEqual(store.limits.maxItems, 50)
    }

    func testUpdateLimitsEvictsUnpinnedItemsBeforePinnedOnes() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        let pinned = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("pinned".utf8))
        let second = makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("second".utf8))
        let third = makeItem(createdAt: Date(timeIntervalSince1970: 3), payload: Data("third".utf8))
        try store.insert(pinned)
        try store.insert(second)
        try store.insert(third)
        try store.setPinned(id: pinned.id, pinned: true)

        try store.updateLimits(HistoryLimits(maxItems: 2, maxBytes: 100, maxInlineBytes: 100))

        XCTAssertEqual(store.items().map(\.id), [pinned.id, third.id])
        XCTAssertTrue(store.items().first?.isPinned ?? false)
    }

    func testInsertingAPinnedItemCannotEvictAnExistingPinnedItem() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL, limits: HistoryLimits(maxItems: 1, maxBytes: 100, maxInlineBytes: 100))
        let existing = makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("existing".utf8))
        try store.insert(existing)
        try store.setPinned(id: existing.id, pinned: true)

        let incomingPinned = ClipboardItem(
            kind: .text,
            preview: "incoming pinned",
            isPinned: true,
            representations: [StoredRepresentation(uti: "public.utf8-plain-text", byteCount: 1, payload: Data([1]))],
            totalBytes: 1
        )

        XCTAssertThrowsError(try store.insert(incomingPinned)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .pinnedItemsExceedLimits)
        }
        XCTAssertEqual(store.items().map(\.id), [existing.id])
        XCTAssertTrue(store.items().first?.isPinned ?? false)
    }

    func testLoadRemovesOrphanedPayloadFilesAfterCorruptIndex() throws {
        let rootURL = try makeTemporaryDirectory()
        let orphanURL = rootURL.appendingPathComponent("orphan.bin")
        try Data("orphaned payload".utf8).write(to: orphanURL)
        let indexURL = rootURL.appendingPathComponent("index.json")
        try Data("{ not valid JSON".utf8).write(to: indexURL)

        let store = HistoryStore(rootURL: rootURL)
        try store.load()

        XCTAssertTrue(store.items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter { $0.hasPrefix("History.corrupt.") && $0.hasSuffix(".json") }
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    func testLoadDropsItemWhosePayloadFileNameEscapesTheStoreRoot() throws {
        let rootURL = try makeTemporaryDirectory()
        let indexURL = rootURL.appendingPathComponent("index.json")
        let json = """
        [
          {"id":"00000000-0000-0000-0000-000000000001","createdAt":1,"kind":"text","preview":"escape","sourceBundleID":null,"sourceName":null,"representations":[{"uti":"public.utf8-plain-text","fileName":"../escape.bin","itemIndex":0,"byteCount":4}],"totalBytes":4},
          {"id":"00000000-0000-0000-0000-000000000002","createdAt":2,"kind":"text","preview":"fine","sourceBundleID":null,"sourceName":null,"representations":[{"uti":"public.utf8-plain-text","fileName":"valid.bin","itemIndex":0,"byteCount":4}],"totalBytes":4}
        ]
        """
        try Data(json.utf8).write(to: indexURL)
        try Data("fine".utf8).write(to: rootURL.appendingPathComponent("valid.bin"))

        let store = HistoryStore(rootURL: rootURL)
        try store.load()

        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.items().first?.preview, "fine")
    }

    func testItemsSnapshotVersionsIncreaseMonotonically() throws {
        let rootURL = try makeTemporaryDirectory()
        let store = HistoryStore(rootURL: rootURL)
        try store.insert(makeItem(createdAt: Date(timeIntervalSince1970: 1), payload: Data("first".utf8)))

        let first = store.itemsSnapshot()
        let second = store.itemsSnapshot()
        try store.insert(makeItem(createdAt: Date(timeIntervalSince1970: 2), payload: Data("second".utf8)))
        let third = store.itemsSnapshot()

        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id))
        XCTAssertGreaterThan(second.version, first.version)
        XCTAssertGreaterThan(third.version, second.version)
        XCTAssertEqual(third.items.count, 2)
    }

    private func makeItem(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        payload: Data,
        sourceBundleID: String? = "com.example.tests",
        sourceName: String? = "Tests"
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            createdAt: createdAt,
            kind: .text,
            preview: "test item",
            sourceBundleID: sourceBundleID,
            sourceName: sourceName,
            representations: [
                StoredRepresentation(
                    uti: "public.utf8-plain-text",
                    fileName: "",
                    byteCount: payload.count,
                    payload: payload
                )
            ],
            totalBytes: payload.count
        )
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

    private func payloadFileCount(in rootURL: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bin" }
            .count
    }
}
