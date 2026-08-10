import CopyCoCore
import Foundation

struct HistoryPreview: Equatable, Sendable {
    let text: String
    let imageData: Data?
}

/// Bounded, thread-safe preview cache. Without the cache the history panel's
/// per-row `previews` dictionary would grow without bound — every visited row
/// could pin up to 25 MiB of image payload in memory. `NSCache` evicts
/// automatically under memory pressure and enforces the configured limits.
final class HistoryPreviewProvider: @unchecked Sendable {
    private let rootURL: URL
    private let cache: NSCache<NSString, HistoryPreviewBox>

    init(historyStore: HistoryStore) {
        rootURL = historyStore.rootURL
        let cache = NSCache<NSString, HistoryPreviewBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 128 * 1024 * 1024
        self.cache = cache
    }

    func preview(for item: ClipboardItem) async -> HistoryPreview {
        let key = item.id.uuidString as NSString
        if let boxed = cache.object(forKey: key) {
            return boxed.value
        }
        let rootURL = self.rootURL
        let value = await Task.detached(priority: .utility) {
            Self.makePreview(for: item, rootURL: rootURL)
        }.value
        let box = HistoryPreviewBox(value)
        cache.setObject(box, forKey: key, cost: max(1, value.imageData?.count ?? value.text.count))
        return value
    }

    static func isPlaceholder(_ preview: String, kind: ClipboardItem.Kind) -> Bool {
        let normalized = preview.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        switch kind {
        case .text: return normalized == "text" || normalized == "文本"
        case .richText: return normalized == "rich text" || normalized == "富文本"
        case .image: return normalized == "image" || normalized == "图片"
        case .file: return normalized == "file" || normalized == "文件"
        case .url: return normalized == "url" || normalized == "链接"
        case .unknown: return normalized == "clipboard item" || normalized == "其他"
        }
    }

    static func normalizedText(_ value: String, maxLength: Int = 240) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maxLength, maxLength > 1 else { return collapsed }

        var words: [Substring] = []
        var length = 0
        for word in collapsed.split(separator: " ") {
            let nextLength = length + (words.isEmpty ? 0 : 1) + word.count
            guard nextLength < maxLength else { break }
            words.append(word)
            length = nextLength
        }
        if words.isEmpty {
            return String(collapsed.prefix(maxLength - 1)) + "…"
        }
        return words.joined(separator: " ") + "…"
    }

    private static func makePreview(for item: ClipboardItem, rootURL: URL) -> HistoryPreview {
        let representations = item.representations.compactMap { representation -> PasteboardCapture.Representation? in
            let data = representation.payload ?? (try? Data(contentsOf: representation.payloadURL(relativeTo: rootURL)))
            guard let data else { return nil }
            return PasteboardCapture.Representation(uti: representation.uti, data: data, itemIndex: representation.itemIndex)
        }
        let text = isPlaceholder(item.preview, kind: item.kind)
            ? PasteboardCapture.preview(for: representations, kind: item.kind)
            : normalizedText(item.preview)
        let imageData = item.kind == .image
            ? representations.first(where: { Self.imageUTIs.contains($0.uti) })?.data
            : nil
        return HistoryPreview(text: normalizedText(text), imageData: imageData)
    }

    private static let imageUTIs = [
        "public.png", "public.jpeg", "public.tiff",
        "com.compuserve.gif", "public.heic", "com.microsoft.bmp"
    ]
}

/// NSCache requires class values; this box wraps the value-type preview.
private final class HistoryPreviewBox {
    let value: HistoryPreview

    init(_ value: HistoryPreview) {
        self.value = value
    }
}
