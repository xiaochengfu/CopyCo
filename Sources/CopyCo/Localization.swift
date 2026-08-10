import Foundation
import CopyCoCore

enum CopyCoLanguage: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case english
    case simplifiedChinese

    func resolve(systemLanguages: [String] = Locale.preferredLanguages) -> CopyCoLanguage {
        guard self == .system else { return self }
        let prefersSimplifiedChinese = systemLanguages.contains { language in
            let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
            return normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg")
        }
        return prefersSimplifiedChinese ? .simplifiedChinese : .english
    }
}

struct CopyCoCopy: Sendable {
    let language: CopyCoLanguage

    init(language: CopyCoLanguage, systemLanguages: [String] = Locale.preferredLanguages) {
        self.language = language.resolve(systemLanguages: systemLanguages)
    }

    var settingsTitle: String { language == .simplifiedChinese ? "CopyCo 设置" : "CopyCo Settings" }
    var historyTitle: String { language == .simplifiedChinese ? "CopyCo 历史记录" : "CopyCo History" }

    var languageSection: String { language == .simplifiedChinese ? "语言" : "Language" }
    var languageLabel: String { language == .simplifiedChinese ? "语言" : "Language" }

    func languageName(_ option: CopyCoLanguage) -> String {
        switch (language, option) {
        case (.system, .system): "System"
        case (.simplifiedChinese, .system): "跟随系统"
        case (.english, .system): "System"
        case (_, .english): "English"
        case (_, .simplifiedChinese): "简体中文"
        }
    }

    var recordingSection: String { language == .simplifiedChinese ? "记录" : "Recording" }
    var pauseClipboardHistory: String { language == .simplifiedChinese ? "暂停剪贴板历史" : "Pause clipboard history" }
    var excludedApplications: String { language == .simplifiedChinese ? "排除的应用" : "Excluded applications" }
    var chooseApplications: String { language == .simplifiedChinese ? "选择应用…" : "Choose Applications…" }
    func selectedApplicationsCount(_ count: Int) -> String {
        language == .simplifiedChinese ? "已选择 \(count) 个" : "\(count) selected"
    }
    var searchApplications: String { language == .simplifiedChinese ? "搜索应用" : "Search applications" }
    var loadingApplications: String { language == .simplifiedChinese ? "正在加载应用…" : "Loading applications…" }
    var noMatchingApplications: String { language == .simplifiedChinese ? "没有匹配的应用" : "No matching applications" }
    var noExcludedApplications: String {
        language == .simplifiedChinese ? "尚未排除任何应用" : "No applications are excluded"
    }
    var excludedApplicationsHelp: String {
        language == .simplifiedChinese
            ? "来自所选应用的新复制内容不会保存到历史记录。"
            : "New clipboard content from selected applications will not be saved to history."
    }
    var retry: String { language == .simplifiedChinese ? "重试" : "Retry" }
    var removeApplication: String { language == .simplifiedChinese ? "移除应用" : "Remove application" }
    var done: String { language == .simplifiedChinese ? "完成" : "Done" }

    var shortcutSection: String { language == .simplifiedChinese ? "快捷键" : "Shortcut" }
    var shortcutTitle: String { language == .simplifiedChinese ? "历史面板快捷键" : "History panel shortcut" }
    var shortcutHelp: String {
        language == .simplifiedChinese
            ? "点击按钮后按下组合键，新快捷键会立即生效。"
            : "Press the button, then press a modifier key combination. The new shortcut takes effect immediately."
    }
    var pressKeys: String { language == .simplifiedChinese ? "请按下按键…" : "Press keys…" }
    var cancel: String { language == .simplifiedChinese ? "取消" : "Cancel" }

    var historyLimitsSection: String { language == .simplifiedChinese ? "历史记录限制" : "History limits" }

    var storageSection: String { language == .simplifiedChinese ? "存储位置" : "Storage" }
    var revealInFinder: String { language == .simplifiedChinese ? "在 Finder 中显示" : "Show in Finder" }
    func keepItems(_ count: Int) -> String {
        language == .simplifiedChinese ? "最多保留 \(count) 条" : "Keep up to \(count) items"
    }
    func useMegabytes(_ count: Int) -> String {
        language == .simplifiedChinese ? "最多使用 \(count) MB" : "Use up to \(count) MB"
    }
    var applyHistoryLimits: String { language == .simplifiedChinese ? "应用历史记录限制" : "Apply history limits" }
    var pinItem: String { language == .simplifiedChinese ? "置顶" : "Pin item" }
    var unpinItem: String { language == .simplifiedChinese ? "取消置顶" : "Unpin item" }
    var deleteItem: String { language == .simplifiedChinese ? "删除记录" : "Delete item" }

    var privacySection: String { language == .simplifiedChinese ? "隐私" : "Privacy" }
    var accessibilityGranted: String { language == .simplifiedChinese ? "已获得辅助功能权限" : "Accessibility permission granted" }
    var accessibilityNeeded: String {
        language == .simplifiedChinese ? "需要辅助功能权限才能自动粘贴" : "Accessibility permission is needed to paste automatically"
    }
    var accessibilityOnboardingTitle: String {
        language == .simplifiedChinese ? "需要辅助功能权限" : "Accessibility Permission Needed"
    }
    var accessibilityOnboardingMessage: String {
        language == .simplifiedChinese
            ? "CopyCo 需要辅助功能权限，才能把选中的历史内容粘贴到当前光标位置。现在打开系统设置授权吗？"
            : "CopyCo needs Accessibility permission to paste the selected history item at the current cursor. Open System Settings now?"
    }
    var accessibilityOnboardingLater: String { language == .simplifiedChinese ? "稍后" : "Later" }
    var accessibilityWarningTitle: String {
        language == .simplifiedChinese ? "自动粘贴尚未启用" : "Automatic Paste Is Not Enabled"
    }
    var accessibilityWarningMessage: String {
        language == .simplifiedChinese
            ? "请授予辅助功能权限，否则选择历史记录后只能复制，无法自动粘贴到光标位置。"
            : "Grant Accessibility permission to paste selected history items at the current cursor. Without it, CopyCo can only copy the item."
    }
    var openAccessibilitySettings: String { language == .simplifiedChinese ? "打开辅助功能设置" : "Open Accessibility Settings" }
    var refreshPermissionStatus: String { language == .simplifiedChinese ? "刷新权限状态" : "Refresh permission status" }
    var clearAllHistory: String { language == .simplifiedChinese ? "清空全部历史记录" : "Clear All History" }
    var clearAllHistoryConfirmationTitle: String {
        language == .simplifiedChinese ? "清空全部历史记录？" : "Clear All History?"
    }
    var clearAllHistoryConfirmationMessage: String {
        language == .simplifiedChinese
            ? "此操作将永久删除所有历史记录，无法撤销。"
            : "This permanently deletes all history items and cannot be undone."
    }

    var searchHistory: String { language == .simplifiedChinese ? "搜索历史记录" : "Search history" }
    var noClipboardHistory: String { language == .simplifiedChinese ? "暂无剪贴板历史" : "No clipboard history" }
    var noMatchingHistory: String { language == .simplifiedChinese ? "没有匹配的历史记录" : "No matching history" }
    func emptyHistoryDescription(hotKey: String) -> String {
        language == .simplifiedChinese
            ? "复制文本、图片、文件或链接，然后按 \(hotKey) 打开历史记录。"
            : "Copy text, images, files, or links, then press \(hotKey) to open history."
    }
    var tryDifferentSearch: String { language == .simplifiedChinese ? "请尝试其他搜索词。" : "Try a different search term." }
    var paused: String { language == .simplifiedChinese ? "已暂停" : "Paused" }
    var keyboardHint: String {
        language == .simplifiedChinese
            ? "↑↓ 选择 · ←→ 操作 · 空格置顶/取消置顶 · Delete 删除 · 回车粘贴 · Esc 关闭"
            : "↑↓ Select · ←→ Actions · Space Pin/Unpin · Delete Remove · Return Paste · Esc Close"
    }
    func historyItemCount(_ count: Int) -> String {
        if language == .simplifiedChinese { return "共 \(count) 条" }
        return "\(count) \(count == 1 ? "item" : "items")"
    }
    func filteredHistoryItemCount(_ filteredCount: Int, total: Int) -> String {
        if language == .simplifiedChinese { return "\(filteredCount) / \(total) 条" }
        return "\(filteredCount) of \(total) \(total == 1 ? "item" : "items")"
    }
    func itemKind(_ kind: ClipboardItem.Kind) -> String {
        switch (language, kind) {
        case (_, .text): language == .simplifiedChinese ? "文本" : "Text"
        case (_, .richText): language == .simplifiedChinese ? "富文本" : "Rich Text"
        case (_, .image): language == .simplifiedChinese ? "图片" : "Image"
        case (_, .file): language == .simplifiedChinese ? "文件" : "File"
        case (_, .url): language == .simplifiedChinese ? "链接" : "Link"
        case (_, .unknown): language == .simplifiedChinese ? "其他" : "Other"
        }
    }

    var showHistory: String { language == .simplifiedChinese ? "显示历史记录" : "Show History" }
    var pauseRecording: String { language == .simplifiedChinese ? "暂停记录" : "Pause Recording" }
    var resumeRecording: String { language == .simplifiedChinese ? "恢复记录" : "Resume Recording" }
    var settingsToolbar: String { language == .simplifiedChinese ? "设置" : "Settings" }
    var settingsMenu: String { language == .simplifiedChinese ? "设置…" : "Settings…" }
    var quitCopyCo: String { language == .simplifiedChinese ? "退出 CopyCo" : "Quit CopyCo" }

    var clipboardHistoryPaused: String { language == .simplifiedChinese ? "剪贴板历史已暂停" : "Clipboard history paused" }
    var clipboardHistoryResumed: String { language == .simplifiedChinese ? "剪贴板历史已恢复" : "Clipboard history resumed" }
    func shortcutChanged(_ shortcut: String) -> String {
        language == .simplifiedChinese ? "快捷键已改为 \(shortcut)" : "Shortcut changed to \(shortcut)"
    }
    func languageChanged(_ languageName: String) -> String {
        language == .simplifiedChinese ? "语言已切换为 \(languageName)" : "Language changed to \(languageName)"
    }
    var historyLimitsUpdated: String { language == .simplifiedChinese ? "历史记录限制已更新" : "History limits updated" }
    var itemRemoved: String { language == .simplifiedChinese ? "已移除记录" : "Item removed" }
    var historyCleared: String { language == .simplifiedChinese ? "历史记录已清空" : "History cleared" }
    var itemPinned: String { language == .simplifiedChinese ? "已置顶" : "Item pinned" }
    var itemUnpinned: String { language == .simplifiedChinese ? "已取消置顶" : "Item unpinned" }
    var pinLimitReached: String { language == .simplifiedChinese ? "最多只能置顶 3 条记录" : "You can pin up to 3 items" }
    var pinnedItemsExceedLimits: String {
        language == .simplifiedChinese
            ? "置顶的记录超出新的历史记录限制，请先取消置顶"
            : "Pinned items exceed the new history limits. Unpin an item first."
    }
    var pasted: String { language == .simplifiedChinese ? "已粘贴" : "Pasted" }
    /// Guidance for the two-phase paste: content is already on the clipboard;
    /// the user places the cursor in the target app, then presses the global
    /// hot key again (or Command-V) to complete the paste.
    func pendingPasteReadyHint(hotKey: String) -> String {
        language == .simplifiedChinese
            ? "内容已就绪：请点击要粘贴的位置，然后按 \(hotKey) 完成粘贴（或直接按 ⌘V）"
            : "Content ready — click where you want to paste, then press \(hotKey) to finish (or just press ⌘V)"
    }
    /// Guidance when the user pressed the hot key again but the target still
    /// has no text-input cursor.
    func pendingPasteStillNeedsCursorHint(hotKey: String) -> String {
        language == .simplifiedChinese
            ? "还没有检测到光标：请先在目标应用中点击要粘贴的位置，再按 \(hotKey)"
            : "No text cursor found — click the paste position in the target app, then press \(hotKey) again"
    }
    /// Guidance when the destination application is missing or has quit.
    func pendingPasteNoDestinationHint(hotKey: String) -> String {
        language == .simplifiedChinese
            ? "请先切换到要粘贴的应用并点击粘贴位置，然后按 \(hotKey) 完成粘贴"
            : "Switch to the app you want to paste into, click the paste position, then press \(hotKey) to finish"
    }
    var copiedOnly: String {
        language == .simplifiedChinese
            ? "已复制到剪贴板。开启辅助功能权限后可自动粘贴。"
            : "Copied to the clipboard. Enable Accessibility to paste automatically."
    }
    var unableToSaveClipboardItem: String { language == .simplifiedChinese ? "无法保存剪贴板内容" : "Unable to save clipboard item" }
    var skippedLargeClipboardItem: String {
        language == .simplifiedChinese ? "已跳过超过 25 MB 的剪贴板内容" : "Skipped a clipboard item larger than 25 MB"
    }
    func shortcutUnavailable(_ shortcut: String) -> String {
        language == .simplifiedChinese ? "快捷键 \(shortcut) 不可用，请使用 CopyCo 菜单" : "Shortcut \(shortcut) is unavailable; use the CopyCo menu"
    }
}
