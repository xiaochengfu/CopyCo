import Foundation

public enum HistoryStoreError: Error, LocalizedError, Sendable, Equatable {
    case missingPayload(uti: String)
    case itemExceedsLimits
    case pinLimitReached
    case pinnedItemsExceedLimits

    public var errorDescription: String? {
        switch self {
        case let .missingPayload(uti):
            return "The \(uti) clipboard representation has no payload."
        case .itemExceedsLimits:
            return "The clipboard item exceeds the configured history limits."
        case .pinLimitReached:
            return "You can pin up to 3 clipboard items."
        case .pinnedItemsExceedLimits:
            return "Pinned items do not fit within the configured history limits. Unpin an item to continue."
        }
    }
}

/// File-backed, bounded clipboard-history metadata and payload storage.
public final class HistoryStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let lock = NSLock()
    private let indexFileName = "index.json"
    private var loaded = false
    private var storedItems: [ClipboardItem] = []
    private var storedLimits: HistoryLimits
    private var snapshotVersion: Int64 = 0

    private enum DuplicateMatch {
        case exact(Int)
        case semantic(Int)
    }

    public let rootURL: URL
    public var limits: HistoryLimits {
        withLock { storedLimits }
    }

    /// Uses CopyCo's Application Support directory for the production store.
    public convenience init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(
            rootURL: applicationSupport
                .appendingPathComponent("CopyCo", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true),
            limits: .default
        )
    }

    public init(rootURL: URL, limits: HistoryLimits = .default, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        storedLimits = limits
        self.fileManager = fileManager
    }

    public func load() throws {
        try withLock {
            try loadUnlocked()
        }
    }

    public func insert(_ item: ClipboardItem) throws {
        try withLock {
            try loadIfNeededUnlocked()
            try ensureRootDirectoryExists()

            let payloadByteCount = item.representations.reduce(0) { $0 + ($1.payload?.count ?? $1.byteCount) }
            guard storedLimits.maxItems > 0,
                  payloadByteCount <= storedLimits.maxInlineBytes,
                  payloadByteCount <= storedLimits.maxBytes else {
                throw HistoryStoreError.itemExceedsLimits
            }

            let incomingFingerprintRepresentations = try fingerprintRepresentations(for: item)
            let contentFingerprint = incomingFingerprintRepresentations.isEmpty
                ? nil
                : ClipboardFingerprint.make(from: incomingFingerprintRepresentations)
            let contentIdentity = ClipboardFingerprint.textIdentity(from: incomingFingerprintRepresentations)
            if let duplicate = try duplicateMatch(
                for: item,
                fingerprint: contentFingerprint,
                contentIdentity: contentIdentity
            ) {
                switch duplicate {
                case let .exact(index):
                    let existing = storedItems[index]
                    let promoted = ClipboardItem(
                        id: existing.id,
                        createdAt: item.createdAt,
                        kind: item.kind,
                        preview: item.preview,
                        sourceBundleID: item.sourceBundleID,
                        sourceName: item.sourceName,
                        contentFingerprint: contentFingerprint,
                        contentIdentity: contentIdentity,
                        isPinned: existing.isPinned,
                        representations: existing.representations,
                        totalBytes: existing.totalBytes,
                        fullText: item.fullText ?? existing.fullText
                    )
                    var retained = storedItems
                    retained[index] = promoted
                    retained.sort(by: newestFirst)
                    try writeIndexUnlocked(retained)
                    storedItems = retained
                case let .semantic(index):
                    try replaceSemanticDuplicateUnlocked(
                        at: index,
                        with: item,
                        contentFingerprint: contentFingerprint,
                        contentIdentity: contentIdentity
                    )
                }
                return
            }

            var storedItem = ClipboardItem(
                id: item.id,
                createdAt: item.createdAt,
                kind: item.kind,
                preview: item.preview,
                sourceBundleID: item.sourceBundleID,
                sourceName: item.sourceName,
                contentFingerprint: contentFingerprint,
                contentIdentity: contentIdentity,
                isPinned: item.isPinned,
                representations: item.representations,
                totalBytes: item.totalBytes,
                fullText: item.fullText
            )
            if item.isPinned, storedItems.filter({ $0.isPinned }).count >= Self.maximumPinnedItems {
                throw HistoryStoreError.pinLimitReached
            }

            var writtenURLs: [URL] = []
            do {
                storedItem.representations = try item.representations.enumerated().map { index, representation in
                    guard let payload = representation.payload else {
                        throw HistoryStoreError.missingPayload(uti: representation.uti)
                    }

                    let fileName = "\(item.id.uuidString)-\(index).bin"
                    let payloadURL = rootURL.appendingPathComponent(fileName, isDirectory: false)
                    let temporaryURL = payloadURL.appendingPathExtension("tmp")
                    try? fileManager.removeItem(at: temporaryURL)
                    try payload.write(to: temporaryURL)
                    try fileManager.moveItem(at: temporaryURL, to: payloadURL)
                    writtenURLs.append(payloadURL)

                    return StoredRepresentation(
                        uti: representation.uti,
                        fileName: fileName,
                        itemIndex: representation.itemIndex,
                        byteCount: payload.count,
                        payload: nil
                    )
                }
            } catch {
                writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                throw error
            }
            storedItem.totalBytes = storedItem.representations.reduce(0) { $0 + $1.byteCount }

            var retained = ([storedItem] + storedItems).sorted(by: newestFirst)
            var evicted: [ClipboardItem] = []
            while retained.count > storedLimits.maxItems {
                guard let last = retained.last else { break }
                guard last.id != storedItem.id else {
                    writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                    throw HistoryStoreError.itemExceedsLimits
                }
                guard !last.isPinned else {
                    writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                    throw HistoryStoreError.pinnedItemsExceedLimits
                }
                evicted.append(retained.removeLast())
            }
            while retained.reduce(0, { $0 + $1.totalBytes }) > storedLimits.maxBytes {
                guard let last = retained.last, last.id != storedItem.id else {
                    writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                    throw HistoryStoreError.itemExceedsLimits
                }
                guard !last.isPinned else {
                    writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                    throw HistoryStoreError.pinnedItemsExceedLimits
                }
                evicted.append(retained.removeLast())
            }

            do {
                try writeIndexUnlocked(retained)
            } catch {
                writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
                throw error
            }
            evicted.forEach(removePayloadFilesUnlocked)
            storedItems = retained
        }
    }

    public func delete(id: UUID) throws {
        try withLock {
            try loadIfNeededUnlocked()
            guard let index = storedItems.firstIndex(where: { $0.id == id }) else { return }
            let removedItem = storedItems.remove(at: index)
            try writeIndexUnlocked(storedItems)
            removePayloadFilesUnlocked(removedItem)
        }
    }

    /// Pins or unpins an existing history item. Pinned items are always
    /// sorted before unpinned items and at most three may be pinned.
    public func setPinned(id: UUID, pinned: Bool) throws {
        try withLock {
            try loadIfNeededUnlocked()
            guard let index = storedItems.firstIndex(where: { $0.id == id }) else { return }
            guard storedItems[index].isPinned != pinned else { return }
            if pinned, storedItems.lazy.filter({ $0.isPinned }).count >= 3 {
                throw HistoryStoreError.pinLimitReached
            }

            var updatedItems = storedItems
            updatedItems[index].isPinned = pinned
            let sortedItems = updatedItems.sorted(by: newestFirst)
            try writeIndexUnlocked(sortedItems)
            storedItems = sortedItems
        }
    }

    public func removeAll() throws {
        try withLock {
            try loadIfNeededUnlocked()
            try writeIndexUnlocked([])
            storedItems.forEach(removePayloadFilesUnlocked)
            removeTemporaryFilesUnlocked()
            storedItems = []
        }
    }

    /// Applies new retention limits immediately, evicting oldest items as needed.
    public func updateLimits(_ limits: HistoryLimits) throws {
        try withLock {
            guard limits.maxItems > 0, limits.maxBytes > 0, limits.maxInlineBytes > 0 else {
                throw HistoryStoreError.itemExceedsLimits
            }
            try loadIfNeededUnlocked()

            var retained = storedItems.sorted(by: newestFirst)
            var evicted: [ClipboardItem] = []
            while retained.count > limits.maxItems || retained.reduce(0, { $0 + $1.totalBytes }) > limits.maxBytes {
                guard let last = retained.last else { break }
                // Pinned items are never auto-evicted: reject the limit change
                // instead of silently destroying a user-pinned entry.
                guard !last.isPinned else {
                    throw HistoryStoreError.pinnedItemsExceedLimits
                }
                evicted.append(retained.removeLast())
            }
            try writeIndexUnlocked(retained)
            evicted.forEach(removePayloadFilesUnlocked)
            storedItems = retained
            storedLimits = limits
        }
    }

    public func items() -> [ClipboardItem] {
        itemsSnapshot().items
    }

    /// Returns the current items together with a monotonically increasing
    /// snapshot version. UI layers can use the version to drop out-of-order
    /// snapshots (a snapshot read earlier in time must never overwrite a
    /// newer one even if it is delivered later).
    public func itemsSnapshot() -> (items: [ClipboardItem], version: Int64) {
        withLock {
            snapshotVersion += 1
            return (storedItems.sorted(by: newestFirst), snapshotVersion)
        }
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent(indexFileName, isDirectory: false)
    }

    private func loadIfNeededUnlocked() throws {
        if !loaded {
            try loadUnlocked()
        }
    }

    private func fingerprintRepresentations(for item: ClipboardItem) throws -> [ClipboardFingerprintRepresentation] {
        try item.representations.map { representation in
            guard let payload = representation.payload else {
                throw HistoryStoreError.missingPayload(uti: representation.uti)
            }
            return ClipboardFingerprintRepresentation(
                uti: representation.uti,
                data: payload,
                itemIndex: representation.itemIndex
            )
        }
    }

    private func duplicateMatch(
        for item: ClipboardItem,
        fingerprint: String?,
        contentIdentity: String?
    ) throws -> DuplicateMatch? {
        guard let fingerprint else { return nil }

        if let index = storedItems.firstIndex(where: { $0.contentFingerprint == fingerprint }) {
            return .exact(index)
        }

        for index in storedItems.indices where storedItems[index].contentFingerprint == nil {
            let existing = storedItems[index]
            guard representationsMatch(existing.representations, item.representations) else { continue }
            let storedRepresentations = try existing.representations.map { representation in
                ClipboardFingerprintRepresentation(
                    uti: representation.uti,
                    data: try Data(contentsOf: representation.payloadURL(relativeTo: rootURL)),
                    itemIndex: representation.itemIndex
                )
            }
            guard ClipboardFingerprint.make(from: storedRepresentations) == fingerprint else { continue }
            return .exact(index)
        }

        guard let contentIdentity else { return nil }
        if let index = storedItems.firstIndex(where: { $0.contentIdentity == contentIdentity }) {
            return .semantic(index)
        }

        for index in storedItems.indices where storedItems[index].contentIdentity == nil {
            let storedRepresentations = try storedFingerprintRepresentations(for: storedItems[index])
            guard ClipboardFingerprint.textIdentity(from: storedRepresentations) == contentIdentity else { continue }
            return .semantic(index)
        }
        return nil
    }

    private func storedFingerprintRepresentations(
        for item: ClipboardItem
    ) throws -> [ClipboardFingerprintRepresentation] {
        try item.representations.map { representation in
            ClipboardFingerprintRepresentation(
                uti: representation.uti,
                data: try Data(contentsOf: representation.payloadURL(relativeTo: rootURL)),
                itemIndex: representation.itemIndex
            )
        }
    }

    private func replaceSemanticDuplicateUnlocked(
        at duplicateIndex: Int,
        with item: ClipboardItem,
        contentFingerprint: String?,
        contentIdentity: String?
    ) throws {
        let existing = storedItems[duplicateIndex]
        let transactionID = UUID().uuidString
        let preparedRepresentations = try item.representations.enumerated().map { index, representation in
            guard let payload = representation.payload else {
                throw HistoryStoreError.missingPayload(uti: representation.uti)
            }
            return StoredRepresentation(
                uti: representation.uti,
                fileName: "\(existing.id.uuidString)-\(transactionID)-\(index).bin",
                itemIndex: representation.itemIndex,
                byteCount: payload.count,
                payload: nil
            )
        }
        let promoted = ClipboardItem(
            id: existing.id,
            createdAt: item.createdAt,
            kind: item.kind,
            preview: item.preview,
            sourceBundleID: item.sourceBundleID,
            sourceName: item.sourceName,
            contentFingerprint: contentFingerprint,
            contentIdentity: contentIdentity,
            isPinned: existing.isPinned,
            representations: preparedRepresentations,
            totalBytes: preparedRepresentations.reduce(0) { $0 + $1.byteCount },
            fullText: item.fullText ?? existing.fullText
        )

        var retained = storedItems
        retained.remove(at: duplicateIndex)
        retained.append(promoted)
        retained.sort(by: newestFirst)
        var evicted: [ClipboardItem] = []
        while retained.count > storedLimits.maxItems {
            guard let last = retained.last else { break }
            guard last.id != promoted.id else {
                throw HistoryStoreError.itemExceedsLimits
            }
            guard !last.isPinned else {
                throw HistoryStoreError.pinnedItemsExceedLimits
            }
            evicted.append(retained.removeLast())
        }
        while retained.reduce(0, { $0 + $1.totalBytes }) > storedLimits.maxBytes {
            guard let last = retained.last, last.id != promoted.id else {
                throw HistoryStoreError.itemExceedsLimits
            }
            guard !last.isPinned else {
                throw HistoryStoreError.pinnedItemsExceedLimits
            }
            evicted.append(retained.removeLast())
        }

        let writtenURLs = try writePreparedPayloadsUnlocked(
            source: item.representations,
            destinations: preparedRepresentations
        )
        do {
            try writeIndexUnlocked(retained)
        } catch {
            writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
        removePayloadFilesUnlocked(existing)
        evicted.forEach(removePayloadFilesUnlocked)
        storedItems = retained
    }

    private func writePreparedPayloadsUnlocked(
        source: [StoredRepresentation],
        destinations: [StoredRepresentation]
    ) throws -> [URL] {
        var writtenURLs: [URL] = []
        var temporaryURLs: [URL] = []
        do {
            for (representation, destination) in zip(source, destinations) {
                guard let payload = representation.payload else {
                    throw HistoryStoreError.missingPayload(uti: representation.uti)
                }
                let payloadURL = destination.payloadURL(relativeTo: rootURL)
                let temporaryURL = payloadURL.appendingPathExtension("tmp")
                temporaryURLs.append(temporaryURL)
                try payload.write(to: temporaryURL)
                try fileManager.moveItem(at: temporaryURL, to: payloadURL)
                temporaryURLs.removeLast()
                writtenURLs.append(payloadURL)
            }
            return writtenURLs
        } catch {
            temporaryURLs.forEach { try? fileManager.removeItem(at: $0) }
            writtenURLs.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
    }

    private func representationsMatch(
        _ stored: [StoredRepresentation],
        _ incoming: [StoredRepresentation]
    ) -> Bool {
        guard stored.count == incoming.count else { return false }
        return zip(stored, incoming).allSatisfy { stored, incoming in
            stored.uti == incoming.uti
                && stored.itemIndex == incoming.itemIndex
                && stored.byteCount == incoming.byteCount
        }
    }

    private func loadUnlocked() throws {
        try ensureRootDirectoryExists()
        removeTemporaryFilesUnlocked()

        guard fileManager.fileExists(atPath: indexURL.path) else {
            storedItems = []
            loaded = true
            removeOrphanedPayloadFilesUnlocked(referencedFileNames: [])
            return
        }

        let decodedItems: [ClipboardItem]
        do {
            decodedItems = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: indexURL))
        } catch {
            try preserveCorruptIndexUnlocked()
            storedItems = []
            loaded = true
            try writeIndexUnlocked([])
            // Every payload file is now unreferenced; reclaim the disk space
            // instead of leaking orphaned blobs forever.
            removeOrphanedPayloadFilesUnlocked(referencedFileNames: [])
            return
        }

        let validItems = decodedItems.filter { item in
            !item.representations.isEmpty && item.representations.allSatisfy { representation in
                StoredRepresentation.isValidPayloadFileName(representation.fileName)
                    && fileManager.fileExists(atPath: representation.payloadURL(relativeTo: rootURL).path)
            }
        }.sorted(by: newestFirst)
        var normalizedItems = validItems
        var pinnedCount = 0
        for index in normalizedItems.indices where normalizedItems[index].isPinned {
            if pinnedCount < Self.maximumPinnedItems {
                pinnedCount += 1
            } else {
                normalizedItems[index].isPinned = false
            }
        }
        normalizedItems.sort(by: newestFirst)
        storedItems = normalizedItems
        loaded = true

        let referencedFileNames = Set(
            normalizedItems.flatMap { $0.representations.map(\.fileName) }
        )
        removeOrphanedPayloadFilesUnlocked(referencedFileNames: referencedFileNames)

        if normalizedItems != decodedItems {
            try writeIndexUnlocked(normalizedItems)
        }
    }

    private func ensureRootDirectoryExists() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func writeIndexUnlocked(_ items: [ClipboardItem]) throws {
        try ensureRootDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedItems = try encoder.encode(items)
        let temporaryURL = rootURL.appendingPathComponent("\(indexFileName).tmp", isDirectory: false)
        try? fileManager.removeItem(at: temporaryURL)
        do {
            try encodedItems.write(to: temporaryURL)
            if fileManager.fileExists(atPath: indexURL.path) {
                _ = try fileManager.replaceItemAt(indexURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: indexURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func preserveCorruptIndexUnlocked() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var recoveryURL = rootURL.appendingPathComponent("History.corrupt.\(timestamp).json", isDirectory: false)
        var collision = 1
        while fileManager.fileExists(atPath: recoveryURL.path) {
            recoveryURL = rootURL.appendingPathComponent("History.corrupt.\(timestamp).\(collision).json", isDirectory: false)
            collision += 1
        }
        try fileManager.moveItem(at: indexURL, to: recoveryURL)
    }

    private func removePayloadFilesUnlocked(_ item: ClipboardItem) {
        item.representations.forEach { representation in
            try? fileManager.removeItem(at: representation.payloadURL(relativeTo: rootURL))
        }
    }

    private func removeTemporaryFilesUnlocked() {
        guard let files = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "tmp" {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Deletes payload `.bin` files that no referenced index entry points to.
    /// Called after loading so a corrupt or pruned index never leaks disk space.
    private func removeOrphanedPayloadFilesUnlocked(referencedFileNames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "bin" && !referencedFileNames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func newestFirst(_ left: ClipboardItem, _ right: ClipboardItem) -> Bool {
        if left.isPinned != right.isPinned {
            return left.isPinned
        }
        if left.createdAt == right.createdAt {
            return left.id.uuidString > right.id.uuidString
        }
        return left.createdAt > right.createdAt
    }

    private static let maximumPinnedItems = 3

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
