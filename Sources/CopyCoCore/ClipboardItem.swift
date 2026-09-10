import Foundation

/// A persisted clipboard entry. Representation payload bytes remain in files
/// beside the JSON index, so metadata can be loaded without loading binaries.
public struct ClipboardItem: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case text
        case richText
        case image
        case file
        case url
        case unknown
    }

    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    public let preview: String
    /// Full plain-text content for searchable kinds (text, URL, rich text).
    /// Kept in the index so search can match beyond the truncated `preview`;
    /// capped to keep the index bounded. `nil` for non-textual kinds.
    public let fullText: String?
    public let sourceBundleID: String?
    public let sourceName: String?
    public let contentFingerprint: String?
    public let contentIdentity: String?
    /// Distinguishes an explicitly absent identity from a legacy index that
    /// predates the field and may be migrated from its persisted payloads.
    let contentIdentityIsKnown: Bool
    public var isPinned: Bool
    public var representations: [StoredRepresentation]
    public var totalBytes: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        preview: String,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        contentFingerprint: String? = nil,
        contentIdentity: String? = nil,
        isPinned: Bool = false,
        representations: [StoredRepresentation],
        totalBytes: Int,
        fullText: String? = nil
    ) {
        self.init(
            id: id,
            createdAt: createdAt,
            kind: kind,
            preview: preview,
            sourceBundleID: sourceBundleID,
            sourceName: sourceName,
            contentFingerprint: contentFingerprint,
            contentIdentity: contentIdentity,
            contentIdentityIsKnown: contentIdentity != nil,
            isPinned: isPinned,
            representations: representations,
            totalBytes: totalBytes,
            fullText: fullText
        )
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        preview: String,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        contentFingerprint: String? = nil,
        contentIdentity: String? = nil,
        contentIdentityIsKnown: Bool,
        isPinned: Bool = false,
        representations: [StoredRepresentation],
        totalBytes: Int,
        fullText: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.preview = preview
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.contentFingerprint = contentFingerprint
        self.contentIdentity = contentIdentity
        self.contentIdentityIsKnown = contentIdentityIsKnown
        self.isPinned = isPinned
        self.representations = representations
        self.totalBytes = totalBytes
        self.fullText = fullText
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case kind
        case preview
        case fullText
        case sourceBundleID
        case sourceName
        case contentFingerprint
        case contentIdentity
        case isPinned
        case representations
        case totalBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        kind = try container.decode(Kind.self, forKey: .kind)
        preview = try container.decode(String.self, forKey: .preview)
        fullText = try container.decodeIfPresent(String.self, forKey: .fullText)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        contentFingerprint = try container.decodeIfPresent(String.self, forKey: .contentFingerprint)
        contentIdentityIsKnown = container.contains(.contentIdentity)
        contentIdentity = try container.decodeIfPresent(String.self, forKey: .contentIdentity)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        representations = try container.decode([StoredRepresentation].self, forKey: .representations)
        totalBytes = try container.decode(Int.self, forKey: .totalBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(preview, forKey: .preview)
        try container.encodeIfPresent(fullText, forKey: .fullText)
        try container.encode(sourceBundleID, forKey: .sourceBundleID)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(contentFingerprint, forKey: .contentFingerprint)
        if contentIdentityIsKnown {
            if let contentIdentity {
                try container.encode(contentIdentity, forKey: .contentIdentity)
            } else {
                try container.encodeNil(forKey: .contentIdentity)
            }
        }
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(representations, forKey: .representations)
        try container.encode(totalBytes, forKey: .totalBytes)
    }
}

/// Metadata for one original pasteboard representation.
///
/// `payload` is deliberately excluded from Codable storage: it exists only
/// while an item is handed to `HistoryStore.insert(_:)`.
public struct StoredRepresentation: Codable, Sendable, Equatable {
    public let uti: String
    public var fileName: String
    /// The originating `NSPasteboardItem` position. Keeping this lets restore
    /// recreate multiple items even when they contain the same UTI.
    public var itemIndex: Int
    public var byteCount: Int
    public var payload: Data?

    public init(uti: String, fileName: String = "", itemIndex: Int = 0, byteCount: Int, payload: Data? = nil) {
        self.uti = uti
        self.fileName = fileName
        self.itemIndex = itemIndex
        self.byteCount = byteCount
        self.payload = payload
    }

    public func payloadURL(relativeTo storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Guards against path traversal via a tampered index: payload file names
    /// must be plain leaf names with no path separators.
    public static func isValidPayloadFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else { return false }
        return !fileName.contains("/") && !fileName.contains("\\")
    }

    private enum CodingKeys: String, CodingKey {
        case uti
        case fileName
        case itemIndex
        case byteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uti = try container.decode(String.self, forKey: .uti)
        fileName = try container.decode(String.self, forKey: .fileName)
        itemIndex = try container.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        payload = nil
    }
}

public struct HistoryLimits: Sendable, Equatable {
    public var maxItems: Int
    public var maxBytes: Int
    public var maxInlineBytes: Int

    public init(maxItems: Int, maxBytes: Int, maxInlineBytes: Int) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.maxInlineBytes = maxInlineBytes
    }

    public static let `default` = HistoryLimits(
        maxItems: 50,
        maxBytes: 500 * 1024 * 1024,
        maxInlineBytes: 25 * 1024 * 1024
    )
}
