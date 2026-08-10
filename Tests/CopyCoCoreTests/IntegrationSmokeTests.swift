import Foundation
import XCTest
@testable import CopyCoCore

final class IntegrationSmokeTests: XCTestCase {
    func testTemporaryStoreSupportsReloadSearchDeleteAndClear() throws {
        let rootURL = try makeTemporaryDirectory()
        let writer = HistoryStore(rootURL: rootURL)
        let releaseNotes = makeItem(
            createdAt: Date(timeIntervalSince1970: 1),
            preview: "CopyCo release notes",
            payload: "release fixture"
        )
        let shoppingList = makeItem(
            createdAt: Date(timeIntervalSince1970: 2),
            preview: "Shopping list",
            payload: "shopping fixture"
        )

        try writer.insert(releaseNotes)
        try writer.insert(shoppingList)

        let reloadedStore = HistoryStore(rootURL: rootURL)
        try reloadedStore.load()
        let reloadedItems = reloadedStore.items()
        XCTAssertEqual(reloadedItems.map(\.id), [shoppingList.id, releaseNotes.id])

        let matchingItems = HistorySearch.filter(reloadedItems, query: " release ")
        XCTAssertEqual(matchingItems.map(\.id), [releaseNotes.id])

        try reloadedStore.delete(id: shoppingList.id)
        XCTAssertEqual(reloadedStore.items().map(\.id), [releaseNotes.id])

        try reloadedStore.removeAll()

        XCTAssertTrue(reloadedStore.items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("\(shoppingList.id.uuidString)-0.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("\(releaseNotes.id.uuidString)-0.bin").path))
    }

    private func makeItem(createdAt: Date, preview: String, payload: String) -> ClipboardItem {
        let data = Data(payload.utf8)
        return ClipboardItem(
            createdAt: createdAt,
            kind: .text,
            preview: preview,
            sourceBundleID: "com.copyco.tests",
            sourceName: "CopyCo Tests",
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

    private func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyCoIntegrationSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}
