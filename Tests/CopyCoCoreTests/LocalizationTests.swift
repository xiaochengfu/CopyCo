import XCTest
@testable import CopyCo

final class LocalizationTests: XCTestCase {
    func testSimplifiedChinesePreferredLanguageResolvesToChinese() {
        XCTAssertEqual(CopyCoLanguage.system.resolve(systemLanguages: ["zh-Hans-CN", "en-US"]), .simplifiedChinese)
    }

    func testNonChinesePreferredLanguageResolvesToEnglish() {
        XCTAssertEqual(CopyCoLanguage.system.resolve(systemLanguages: ["fr-FR", "en-US"]), .english)
    }

    func testCopyContainsTranslatedSettingsAndMenuLabels() {
        XCTAssertEqual(CopyCoCopy(language: .english).settingsTitle, "CopyCo Settings")
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).settingsTitle, "CopyCo 设置")
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).shortcutTitle, "历史面板快捷键")
    }

    func testCopyContainsAccessibilityWarningCopy() {
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).accessibilityWarningTitle, "自动粘贴尚未启用")
        XCTAssertEqual(CopyCoCopy(language: .english).accessibilityWarningTitle, "Automatic Paste Is Not Enabled")
        XCTAssertFalse(CopyCoCopy(language: .simplifiedChinese).accessibilityWarningMessage.isEmpty)
        XCTAssertFalse(CopyCoCopy(language: .english).accessibilityWarningMessage.isEmpty)
    }

    func testKeyboardHintIncludesPinAndDeleteShortcuts() {
        XCTAssertTrue(CopyCoCopy(language: .simplifiedChinese).keyboardHint.contains("空格置顶/取消置顶"))
        XCTAssertTrue(CopyCoCopy(language: .simplifiedChinese).keyboardHint.contains("←→ 操作"))
        XCTAssertTrue(CopyCoCopy(language: .simplifiedChinese).keyboardHint.contains("Delete 删除"))
        XCTAssertTrue(CopyCoCopy(language: .english).keyboardHint.contains("Space Pin/Unpin"))
        XCTAssertTrue(CopyCoCopy(language: .english).keyboardHint.contains("←→ Actions"))
        XCTAssertTrue(CopyCoCopy(language: .english).keyboardHint.contains("Delete Remove"))
    }

    func testCopyContainsStorageLocationStrings() {
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).storageSection, "存储位置")
        XCTAssertEqual(CopyCoCopy(language: .english).storageSection, "Storage")
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).revealInFinder, "在 Finder 中显示")
        XCTAssertEqual(CopyCoCopy(language: .english).revealInFinder, "Show in Finder")
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).clearAllHistoryConfirmationTitle, "清空全部历史记录？")
        XCTAssertEqual(CopyCoCopy(language: .english).clearAllHistoryConfirmationTitle, "Clear All History?")
        XCTAssertFalse(CopyCoCopy(language: .simplifiedChinese).clearAllHistoryConfirmationMessage.isEmpty)
        XCTAssertFalse(CopyCoCopy(language: .english).clearAllHistoryConfirmationMessage.isEmpty)
    }

    func testCopyContainsPendingPasteHints() {
        let copy = CopyCoCopy(language: .simplifiedChinese)
        XCTAssertEqual(
            copy.pendingPasteReadyHint(hotKey: "⌥⌘C"),
            "内容已就绪：请点击要粘贴的位置，然后按 ⌥⌘C 完成粘贴（或直接按 ⌘V）"
        )
        XCTAssertTrue(copy.pendingPasteReadyHint(hotKey: "⌥⌘C").contains("⌥⌘C"))
        XCTAssertTrue(copy.pendingPasteStillNeedsCursorHint(hotKey: "⌥⌘C").contains("光标"))
        XCTAssertTrue(copy.pendingPasteNoDestinationHint(hotKey: "⌥⌘C").contains("切换"))
        XCTAssertTrue(copy.pendingPasteSecureInputHint().contains("⌘V"))

        let english = CopyCoCopy(language: .english)
        XCTAssertTrue(english.pendingPasteReadyHint(hotKey: "⌥⌘C").contains("⌥⌘C"))
        XCTAssertTrue(english.pendingPasteStillNeedsCursorHint(hotKey: "⌥⌘C").contains("No text cursor"))
        XCTAssertTrue(english.pendingPasteNoDestinationHint(hotKey: "⌥⌘C").contains("Switch"))
        XCTAssertTrue(english.pendingPasteSecureInputHint().contains("⌘V"))
    }

    func testCopyContainsSecureInputAndPrivacySkipMessages() {
        let chinese = CopyCoCopy(language: .simplifiedChinese)
        XCTAssertTrue(chinese.secureInputShortcutUnavailable(hotKey: "⌥⌘C").contains("密码"))
        XCTAssertTrue(chinese.secureInputShortcutRestored(hotKey: "⌥⌘C").contains("⌥⌘C"))
        XCTAssertFalse(chinese.skippedConcealedClipboardItem.isEmpty)
        XCTAssertFalse(chinese.skippedExcludedClipboardSource.isEmpty)

        let english = CopyCoCopy(language: .english)
        XCTAssertTrue(english.secureInputShortcutUnavailable(hotKey: "⌥⌘C").contains("Password"))
        XCTAssertTrue(english.secureInputShortcutRestored(hotKey: "⌥⌘C").contains("⌥⌘C"))
        XCTAssertTrue(english.skippedConcealedClipboardItem.lowercased().contains("concealed"))
        XCTAssertTrue(english.skippedExcludedClipboardSource.lowercased().contains("password"))
    }

    func testEmptyHistoryDescriptionUsesConfiguredHotKey() {
        let simplified = CopyCoCopy(language: .simplifiedChinese)
        XCTAssertTrue(simplified.emptyHistoryDescription(hotKey: "⌥⇧V").contains("⌥⇧V"))
        XCTAssertFalse(simplified.emptyHistoryDescription(hotKey: "⌥⇧V").contains("⌥⌘C"))

        let english = CopyCoCopy(language: .english)
        XCTAssertTrue(english.emptyHistoryDescription(hotKey: "⌥⇧V").contains("⌥⇧V"))
        XCTAssertFalse(english.emptyHistoryDescription(hotKey: "⌥⇧V").contains("⌥⌘C"))
    }

    func testCopyContainsHistoryItemActionLabels() {
        XCTAssertEqual(CopyCoCopy(language: .simplifiedChinese).deleteItem, "删除记录")
        XCTAssertEqual(CopyCoCopy(language: .english).deleteItem, "Delete item")
    }

    func testCopyContainsExcludedApplicationPickerLabels() {
        let chinese = CopyCoCopy(language: .simplifiedChinese)
        XCTAssertEqual(chinese.excludedApplications, "排除的应用")
        XCTAssertEqual(chinese.chooseApplications, "选择应用…")
        XCTAssertEqual(chinese.selectedApplicationsCount(2), "已选择 2 个")
        XCTAssertEqual(chinese.searchApplications, "搜索应用")
        XCTAssertFalse(chinese.noExcludedApplications.isEmpty)
        XCTAssertFalse(chinese.excludedApplicationsHelp.isEmpty)

        let english = CopyCoCopy(language: .english)
        XCTAssertEqual(english.excludedApplications, "Excluded applications")
        XCTAssertEqual(english.chooseApplications, "Choose Applications…")
        XCTAssertEqual(english.selectedApplicationsCount(2), "2 selected")
        XCTAssertFalse(english.noMatchingApplications.isEmpty)
        XCTAssertFalse(english.retry.isEmpty)
        XCTAssertFalse(english.removeApplication.isEmpty)
    }

    func testHistoryCountDistinguishesTotalAndFilteredItems() {
        let chinese = CopyCoCopy(language: .simplifiedChinese)
        XCTAssertEqual(chinese.historyItemCount(156), "共 156 条")
        XCTAssertEqual(chinese.filteredHistoryItemCount(12, total: 156), "12 / 156 条")

        let english = CopyCoCopy(language: .english)
        XCTAssertEqual(english.historyItemCount(1), "1 item")
        XCTAssertEqual(english.historyItemCount(156), "156 items")
        XCTAssertEqual(english.filteredHistoryItemCount(1, total: 1), "1 of 1 item")
        XCTAssertEqual(english.filteredHistoryItemCount(12, total: 156), "12 of 156 items")
    }
}
