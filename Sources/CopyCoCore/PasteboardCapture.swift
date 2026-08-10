import AppKit
import Foundation

/// Polls the general pasteboard and emits supported clipboard payloads once.
public final class PasteboardCapture: @unchecked Sendable {
    public struct Representation: Sendable, Equatable {
        public let uti: String
        public let data: Data
        public let itemIndex: Int

        public init(uti: String, data: Data, itemIndex: Int = 0) {
            self.uti = uti
            self.data = data
            self.itemIndex = itemIndex
        }
    }

    struct SourceAttribution: Sendable, Equatable {
        let bundleID: String?
        let name: String?
    }

    public enum Rejection: Sendable, Equatable {
        case noSupportedRepresentations
        case payloadExceedsInlineLimit
    }

    public struct Extraction: Sendable {
        public let item: ClipboardItem?
        public let fingerprint: String?
        public let rejection: Rejection?

        fileprivate init(item: ClipboardItem?, fingerprint: String?, rejection: Rejection?) {
            self.item = item
            self.fingerprint = fingerprint
            self.rejection = rejection
        }
    }

    public static let maximumInlineBytes = 25 * 1024 * 1024

    public var onItem: @Sendable (ClipboardItem) -> Void {
        get {
            lock.lock()
            defer { lock.unlock() }
            return itemHandler
        }
        set {
            lock.lock()
            itemHandler = newValue
            lock.unlock()
        }
    }

    public var onRejection: @Sendable (Rejection, String?) -> Void {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rejectionHandler
        }
        set {
            lock.lock()
            rejectionHandler = newValue
            lock.unlock()
        }
    }

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.pauseState(isRunning: timer != nil, privacyPaused: privacySettings.isPaused)
    }

    public var currentPrivacySettings: PrivacySettings {
        lock.lock()
        defer { lock.unlock() }
        return privacySettings
    }

    /// Updates user-controlled recording settings without affecting capture
    /// history or previously recorded clipboard events.
    public func updatePrivacySettings(
        isPaused: Bool? = nil,
        excludedBundleIDs: Set<String>? = nil
    ) {
        lock.lock()
        if let isPaused {
            privacySettings.isPaused = isPaused
        }
        if let excludedBundleIDs {
            privacySettings.excludedBundleIDs = excludedBundleIDs
        }
        lock.unlock()
    }

    private let pasteboard: NSPasteboard
    private let queue: DispatchQueue
    private let queueIdentity = UUID()
    private let queueIdentityKey = DispatchSpecificKey<UUID>()
    private let lock = NSCondition()
    private var timer: DispatchSourceTimer?
    private var observedChangeCount: Int
    private var captureGeneration = 0
    private var inFlightCallbacks = 0
    private var previouslyObservedApplication: SourceAttribution?
    private var privacySettings: PrivacySettings
    private var itemHandler: @Sendable (ClipboardItem) -> Void = { _ in }
    private var rejectionHandler: @Sendable (Rejection, String?) -> Void = { _, _ in }

    public init(
        pasteboard: NSPasteboard = .general,
        queue: DispatchQueue = DispatchQueue(label: "com.copyco.pasteboard-capture", qos: .utility),
        privacySettings: PrivacySettings = PrivacySettings()
    ) {
        self.pasteboard = pasteboard
        self.queue = queue
        self.privacySettings = privacySettings
        observedChangeCount = pasteboard.changeCount
        previouslyObservedApplication = Self.frontmostApplication()
        queue.setSpecific(key: queueIdentityKey, value: queueIdentity)
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        observedChangeCount = pasteboard.changeCount
        previouslyObservedApplication = Self.frontmostApplication()
        captureGeneration &+= 1
        let generation = captureGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.captureIfChanged(generation: generation)
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop() {
        let isOnCaptureQueue = DispatchQueue.getSpecific(key: queueIdentityKey) == queueIdentity
        lock.lock()
        let timer = self.timer
        self.timer = nil
        captureGeneration &+= 1
        while Self.shouldWaitForCallbacks(
            inFlightCallbacks: inFlightCallbacks,
            isOnCaptureQueue: isOnCaptureQueue
        ) {
            lock.wait()
        }
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    public static func extract(
        representations: [Representation],
        sourceBundleID: String? = nil,
        sourceName: String? = nil
    ) -> Extraction {
        let supported = orderedSupportedRepresentations(from: representations)
        guard !supported.isEmpty else {
            return Extraction(item: nil, fingerprint: nil, rejection: .noSupportedRepresentations)
        }

        // Reject oversized payloads before hashing: computing a fingerprint for
        // a multi-hundred-MB screenshot is pure wasted CPU because the
        // rejection path does not consume it.
        let totalBytes = supported.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= maximumInlineBytes else {
            return Extraction(item: nil, fingerprint: nil, rejection: .payloadExceedsInlineLimit)
        }

        let fingerprint = fingerprint(for: supported)
        let kind = kind(for: supported)
        let item = ClipboardItem(
            kind: kind,
            preview: preview(for: supported, kind: kind),
            sourceBundleID: sourceBundleID,
            sourceName: sourceName,
            contentFingerprint: fingerprint,
            representations: supported.map {
                StoredRepresentation(uti: $0.uti, itemIndex: $0.itemIndex, byteCount: $0.data.count, payload: $0.data)
            },
            totalBytes: totalBytes,
            fullText: fullText(for: supported, kind: kind)
        )
        return Extraction(item: item, fingerprint: fingerprint, rejection: nil)
    }

    static func shouldEmit(
        extraction: Extraction,
        typeIdentifiers: Set<String>,
        sourceBundleID: String?,
        settings: PrivacySettings
    ) -> Bool {
        guard let fingerprint = extraction.fingerprint else { return false }
        return PrivacyFilter.shouldRecord(
            change: PasteboardChange(
                typeIdentifiers: typeIdentifiers,
                sourceBundleID: sourceBundleID,
                fingerprint: fingerprint
            ),
            settings: settings
        )
    }

    static func shouldDeliver(
        captureGeneration: Int,
        currentGeneration: Int,
        isRunning: Bool
    ) -> Bool {
        isRunning && captureGeneration == currentGeneration
    }

    static func pauseState(isRunning: Bool, privacyPaused: Bool) -> Bool {
        !isRunning || privacyPaused
    }

    static func shouldWaitForCallbacks(
        inFlightCallbacks: Int,
        isOnCaptureQueue: Bool = false
    ) -> Bool {
        inFlightCallbacks > 0 && !isOnCaptureQueue
    }

    private func captureIfChanged(generation: Int) {
        let currentChangeCount = pasteboard.changeCount
        let currentApplication = Self.frontmostApplication()
        lock.lock()
        guard Self.shouldDeliver(
            captureGeneration: generation,
            currentGeneration: captureGeneration,
            isRunning: timer != nil
        ) else {
            lock.unlock()
            return
        }
        let sourceApplication = previouslyObservedApplication
        previouslyObservedApplication = currentApplication
        guard currentChangeCount != observedChangeCount else {
            lock.unlock()
            return
        }
        observedChangeCount = currentChangeCount
        lock.unlock()

        let contents = Self.contents(from: pasteboard)
        let attribution = Self.sourceAttribution(
            pasteboardSourceBundleID: contents.sourceBundleID,
            previousFrontmostBundleID: sourceApplication?.bundleID,
            previousFrontmostName: sourceApplication?.name
        )
        let extraction = Self.extract(
            representations: contents.representations,
            sourceBundleID: attribution.bundleID,
            sourceName: attribution.name
        )
        guard let fingerprint = extraction.fingerprint else { return }

        lock.lock()
        guard Self.shouldDeliver(
            captureGeneration: generation,
            currentGeneration: captureGeneration,
            isRunning: timer != nil
        ), Self.shouldEmit(
            extraction: extraction,
            typeIdentifiers: contents.typeIdentifiers,
            sourceBundleID: attribution.bundleID,
            settings: privacySettings
        ) else {
            lock.unlock()
            return
        }
        let callback = itemHandler
        let rejected = rejectionHandler
        inFlightCallbacks += 1
        lock.unlock()
        if let item = extraction.item {
            callback(item)
        } else if let rejection = extraction.rejection {
            rejected(rejection, fingerprint)
        }
        lock.lock()
        inFlightCallbacks -= 1
        if inFlightCallbacks == 0 {
            lock.broadcast()
        }
        lock.unlock()
    }

    static func sourceAttribution(
        pasteboardSourceBundleID: String?,
        previousFrontmostBundleID: String?,
        previousFrontmostName: String?
    ) -> SourceAttribution {
        if let pasteboardSourceBundleID, !pasteboardSourceBundleID.isEmpty {
            return SourceAttribution(bundleID: pasteboardSourceBundleID, name: nil)
        }
        return SourceAttribution(bundleID: previousFrontmostBundleID, name: previousFrontmostName)
    }

    private static func frontmostApplication() -> SourceAttribution? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceAttribution(bundleID: application.bundleIdentifier, name: application.localizedName)
    }

    private static func contents(from pasteboard: NSPasteboard) -> (representations: [Representation], typeIdentifiers: Set<String>, sourceBundleID: String?) {
        let available = pasteboard.pasteboardItems ?? []
        let typeIdentifiers = Set(available.flatMap { $0.types.map(\.rawValue) })
        let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
        let sourceBundleID = available.compactMap { item in
            item.string(forType: sourceType)
                ?? item.data(forType: sourceType).flatMap { String(data: $0, encoding: .utf8) }
        }.first
        let representations: [Representation] = available.enumerated().flatMap { itemIndex, item -> [Representation] in
            supportedUTIs.compactMap { uti in
                let type = NSPasteboard.PasteboardType(uti)
                guard item.types.contains(type) else {
                    return nil
                }
                guard let data = item.data(forType: type) else {
                    NSLog("CopyCo could not read clipboard representation \(uti)")
                    return nil
                }
                return Representation(uti: uti, data: data, itemIndex: itemIndex)
            }
        }
        return (representations, typeIdentifiers, sourceBundleID)
    }

    private static func orderedSupportedRepresentations(from representations: [Representation]) -> [Representation] {
        representations.filter { supportedUTIs.contains($0.uti) }
    }

    private static func kind(for representations: [Representation]) -> ClipboardItem.Kind {
        guard let uti = classificationUTIs.first(where: { preferred in representations.contains { $0.uti == preferred } }) else {
            return .unknown
        }
        switch uti {
        case "public.utf8-plain-text", "public.plain-text": return .text
        case "public.rtf", "public.html": return .richText
        case "public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.heic", "com.microsoft.bmp": return .image
        case "public.file-url": return .file
        case "public.url": return .url
        default: return .unknown
        }
    }

    public static func preview(for representations: [Representation], kind: ClipboardItem.Kind) -> String {
        switch kind {
        case .text, .url:
            guard let first = representations.first(where: { ["public.utf8-plain-text", "public.plain-text", "public.url"].contains($0.uti) }) else {
                return kind.rawValue
            }
            return normalizedPreview(String(data: first.data, encoding: .utf8) ?? kind.rawValue)
        case .file:
            guard let first = representations.first(where: { $0.uti == "public.file-url" }) else { return "File" }
            return URL(string: String(data: first.data, encoding: .utf8) ?? "")?.lastPathComponent ?? "File"
        case .richText:
            if let plainText = representations.first(where: { ["public.utf8-plain-text", "public.plain-text"].contains($0.uti) }),
               let value = String(data: plainText.data, encoding: .utf8) {
                return normalizedPreview(value)
            }
            guard let richText = representations.first(where: { ["public.rtf", "public.html"].contains($0.uti) }) else {
                return "Rich text"
            }
            return normalizedPreview(attributedString(from: richText.data, uti: richText.uti)?.string ?? "Rich text")
        case .image:
            return "Image"
        case .unknown:
            return "Clipboard item"
        }
    }

    /// The full plain-text payload for searchable kinds, capped so the JSON
    /// index stays bounded. `nil` for kinds without meaningful text content.
    private static func fullText(for representations: [Representation], kind: ClipboardItem.Kind) -> String? {
        switch kind {
        case .text, .url, .richText:
            guard let plainText = representations.first(where: { ["public.utf8-plain-text", "public.plain-text"].contains($0.uti) }),
                  let value = String(data: plainText.data, encoding: .utf8) else {
                return nil
            }
            guard value.count > maximumFullTextCharacters else { return value }
            return String(value.prefix(maximumFullTextCharacters))
        case .image, .file, .unknown:
            return nil
        }
    }

    private static func attributedString(from data: Data, uti: String) -> NSAttributedString? {
        let documentType: NSAttributedString.DocumentType = uti == "public.html" ? .html : .rtf
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    private static func normalizedPreview(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 240 else { return collapsed }
        return String(collapsed.prefix(237)) + "…"
    }

    private static func fingerprint(for representations: [Representation]) -> String {
        ClipboardFingerprint.make(from: representations.map {
            ClipboardFingerprintRepresentation(uti: $0.uti, data: $0.data, itemIndex: $0.itemIndex)
        })
    }

    private static let supportedUTIs = [
        "public.utf8-plain-text", "public.plain-text",
        "public.rtf", "public.html",
        "public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.heic", "com.microsoft.bmp",
        "public.file-url", "public.url"
    ]

    private static let imageUTIs = ["public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.heic", "com.microsoft.bmp"]
    private static let classificationUTIs = [
        "public.rtf", "public.html",
        "public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.heic", "com.microsoft.bmp",
        "public.file-url", "public.url",
        "public.utf8-plain-text", "public.plain-text"
    ]
    /// Cap for `fullText` stored in the index (64 KiB of characters). Search
    /// matches beyond the 240-char preview but within this cap.
    private static let maximumFullTextCharacters = 64 * 1024
}
