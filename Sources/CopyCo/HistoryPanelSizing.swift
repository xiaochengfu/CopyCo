import CoreGraphics

enum HistoryPanelSizing {
    static let minimumHeight: CGFloat = 170
    /// The empty state (icon + title + description) is ~120 pt tall; the
    /// default 170 pt panel leaves only ~110 pt below the search field and
    /// clips the description text. Give the empty state its own taller panel.
    static let emptyStateHeight: CGFloat = 210

    static func height(
        itemCount: Int,
        rowHeight: CGFloat,
        rowSpacing: CGFloat = 0,
        listVerticalPadding: CGFloat = 0,
        headerHeight: CGFloat,
        footerHeight: CGFloat = 0,
        maxHeight: CGFloat
    ) -> CGFloat {
        let rows = max(0, itemCount)
        guard rows > 0 else { return emptyStateHeight }
        let spacingHeight = CGFloat(max(0, rows - 1)) * rowSpacing
        let paddingHeight = listVerticalPadding * 2
        let listHeight = CGFloat(rows) * rowHeight + spacingHeight + paddingHeight
        return min(maxHeight, max(minimumHeight, headerHeight + footerHeight + listHeight))
    }
}
