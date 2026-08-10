import Foundation

/// Filters history items using the same fields shown in the history panel.
public enum HistorySearch {
    public static func filter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return items }

        // Fallback matcher for scripts without inter-word spaces (e.g. Chinese):
        // "剪贴板历史" still matches "剪贴板 历史" after both sides lose spacing.
        let queryWithoutSpacing = withoutSpacing(trimmedQuery)

        return items.filter { item in
            let haystack = [item.preview, item.fullText ?? "", item.sourceName ?? "", item.kind.rawValue]
                .joined(separator: " ")
            if haystack.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            guard !queryWithoutSpacing.isEmpty else { return false }
            return withoutSpacing(haystack).localizedCaseInsensitiveContains(queryWithoutSpacing)
        }
    }

    private static func withoutSpacing(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}
