import Foundation
import XCTest
@testable import CopyCoCore

final class HistorySearchTests: XCTestCase {
    func testSearchFindsTextBeyondTheTruncatedPreview() {
        let longText = String(repeating: "word ", count: 400) + "needle-at-the-end"
        let item = ClipboardItem(
            kind: .text,
            preview: String(longText.prefix(240)),
            representations: [],
            totalBytes: 0,
            fullText: longText
        )

        let matches = HistorySearch.filter([item], query: "needle-at-the-end")

        XCTAssertEqual(matches.map(\.id), [item.id])
    }

    func testSearchFallsBackToPreviewWhenFullTextIsMissing() {
        let item = ClipboardItem(
            kind: .text,
            preview: "visible preview text",
            representations: [],
            totalBytes: 0
        )

        XCTAssertEqual(HistorySearch.filter([item], query: "visible").map(\.id), [item.id])
        XCTAssertTrue(HistorySearch.filter([item], query: "nowhere").isEmpty)
    }

    func testSearchMatchesChineseTextAcrossInterveningWhitespace() {
        let item = ClipboardItem(
            kind: .text,
            preview: "剪贴板 历史记录",
            representations: [],
            totalBytes: 0
        )

        let matches = HistorySearch.filter([item], query: "剪贴板历史")

        XCTAssertEqual(matches.map(\.id), [item.id])
    }

    func testSearchMatchesPunctuationSeparatedChineseText() {
        let item = ClipboardItem(
            kind: .text,
            preview: "会议纪要：上周进度",
            representations: [],
            totalBytes: 0,
            fullText: "产品 方案 讨论 结论"
        )

        XCTAssertEqual(HistorySearch.filter([item], query: "产品方案").map(\.id), [item.id])
        XCTAssertEqual(HistorySearch.filter([item], query: "会议纪要").map(\.id), [item.id])
    }

    func testSearchIgnoresCaseAndTrimsTheQuery() {
        let item = ClipboardItem(
            kind: .text,
            preview: "CopyCo Release Notes",
            representations: [],
            totalBytes: 0,
            fullText: "beta 2 announcement"
        )

        XCTAssertEqual(HistorySearch.filter([item], query: "  copyco  ").map(\.id), [item.id])
        XCTAssertEqual(HistorySearch.filter([item], query: "BETA").map(\.id), [item.id])
    }
}
