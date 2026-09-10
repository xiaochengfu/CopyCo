import AppKit
import ApplicationServices
import Combine
import CopyCoCore
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let historyLimitRange = 1...500
    static let historySizeLimitMBRange = 1...1_024

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var filteredItems: [ClipboardItem] = []
    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published var isPaused: Bool
    @Published var statusMessage: String?
    @Published var accessibilityTrusted: Bool
    @Published private(set) var excludedBundleIDs: Set<String>
    @Published private(set) var installedApplications: [InstalledApplication] = []
    @Published private(set) var isLoadingInstalledApplications = false
    @Published private(set) var installedApplicationsError: String?
    @Published var historyLimit: Int
    @Published var historySizeLimitMB: Int
    @Published var hotKeyConfiguration: HotKeyConfiguration
    @Published var language: CopyCoLanguage

    var onOpenSettings: (() -> Void)?
    var onStatusMessageChanged: ((String?) -> Void)?
    var onHotKeyConfigurationChanged: ((HotKeyConfiguration) -> Void)?
    var onLanguageChanged: ((CopyCoLanguage) -> Void)?
    var pasteDestination: NSRunningApplication?

    private let historyStore: HistoryStore
    private let pasteboardCapture: PasteboardCapture
    private let pasteCoordinator: PasteCoordinator
    private let defaults: UserDefaults
    private let applicationCatalog: any InstalledApplicationDiscovering
    private let accessibilityTrustProvider: () -> Bool
    private lazy var previewProvider = HistoryPreviewProvider(historyStore: historyStore)
    private var searchTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var hasLoadedInstalledApplications = false
    private var lastAppliedSnapshotVersion: Int64 = 0

    /// Absolute path of the folder where history items are stored on disk.
    var historyStoragePath: String { historyStore.rootURL.path }

    /// Reveals the history storage folder in Finder, creating it if needed.
    func revealHistoryStorageInFinder() {
        let url = historyStore.rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    init(
        historyStore: HistoryStore,
        pasteboardCapture: PasteboardCapture,
        pasteCoordinator: PasteCoordinator,
        defaults: UserDefaults = .standard,
        applicationCatalog: any InstalledApplicationDiscovering = InstalledApplicationCatalog(),
        accessibilityTrustProvider: @escaping () -> Bool = AccessibilityPermission.isTrusted
    ) {
        self.historyStore = historyStore
        self.pasteboardCapture = pasteboardCapture
        self.pasteCoordinator = pasteCoordinator
        self.defaults = defaults
        self.applicationCatalog = applicationCatalog
        self.accessibilityTrustProvider = accessibilityTrustProvider
        let privacySettings = pasteboardCapture.currentPrivacySettings
        isPaused = defaults.object(forKey: Keys.isPaused) as? Bool ?? privacySettings.isPaused
        let loadedExcludedBundleIDs = Self.loadExcludedBundleIDs(
            defaults: defaults,
            fallback: privacySettings.excludedBundleIDs
        )
        excludedBundleIDs = loadedExcludedBundleIDs
        let savedHistoryLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? historyStore.limits.maxItems
        historyLimit = Self.clamped(savedHistoryLimit, to: Self.historyLimitRange)
        let savedHistorySizeLimitMB = defaults.object(forKey: Keys.historySizeLimitMB) as? Int
            ?? max(1, historyStore.limits.maxBytes / Self.bytesPerMegabyte)
        historySizeLimitMB = Self.clamped(savedHistorySizeLimitMB, to: Self.historySizeLimitMBRange)
        let savedKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int
        let savedModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int
        hotKeyConfiguration = savedKeyCode.flatMap { keyCode in
            savedModifiers.map { HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: UInt32($0)) }
        } ?? .default
        language = defaults.string(forKey: Keys.language)
            .flatMap(CopyCoLanguage.init(rawValue:))
            ?? .system
        accessibilityTrusted = accessibilityTrustProvider()
        defaults.set(loadedExcludedBundleIDs.sorted(), forKey: Keys.excludedBundleIDs)
        pasteboardCapture.updatePrivacySettings(isPaused: isPaused, excludedBundleIDs: loadedExcludedBundleIDs)
    }

    deinit { searchTask?.cancel(); statusTask?.cancel() }

    func loadHistory() {
        let historyStore = historyStore
        let limits = Self.historyLimits(historyLimit: historyLimit, historySizeLimitMB: historySizeLimitMB)
        Task.detached(priority: .utility) { [weak self, historyStore] in
            let result = Result { () throws -> ([ClipboardItem], Int64) in
                try historyStore.load()
                // Only rewrite the index when the persisted limits actually
                // changed; launching with unchanged limits must not rewrite.
                if historyStore.limits != limits {
                    try historyStore.updateLimits(limits)
                }
                return historyStore.itemsSnapshot()
            }
            await MainActor.run { self?.applySnapshot(result, successMessage: nil) }
        }
    }

    func record(_ item: ClipboardItem) {
        let historyStore = historyStore
        Task.detached(priority: .utility) { [weak self, historyStore] in
            let result = Result { () throws -> ([ClipboardItem], Int64) in
                try historyStore.insert(item)
                return historyStore.itemsSnapshot()
            }
            await MainActor.run { self?.applySnapshot(result, successMessage: nil) }
        }
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        defaults.set(paused, forKey: Keys.isPaused)
        pasteboardCapture.updatePrivacySettings(isPaused: paused)
        let copy = CopyCoCopy(language: language)
        showStatus(paused ? copy.clipboardHistoryPaused : copy.clipboardHistoryResumed)
    }

    func setExcluded(_ excluded: Bool, for bundleIdentifier: String) {
        if excluded {
            excludedBundleIDs.insert(bundleIdentifier)
        } else {
            excludedBundleIDs.remove(bundleIdentifier)
        }
        defaults.set(excludedBundleIDs.sorted(), forKey: Keys.excludedBundleIDs)
        pasteboardCapture.updatePrivacySettings(excludedBundleIDs: excludedBundleIDs)
    }

    func loadInstalledApplications() async {
        guard !isLoadingInstalledApplications, !hasLoadedInstalledApplications else { return }
        isLoadingInstalledApplications = true
        installedApplicationsError = nil
        do {
            installedApplications = InstalledApplicationCatalog.normalized(
                try await applicationCatalog.applications()
            )
            hasLoadedInstalledApplications = true
        } catch {
            installedApplicationsError = error.localizedDescription
        }
        isLoadingInstalledApplications = false
    }

    func updateHotKeyConfiguration(_ configuration: HotKeyConfiguration) {
        hotKeyConfiguration = configuration
        defaults.set(Int(configuration.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(configuration.modifiers), forKey: Keys.hotKeyModifiers)
        onHotKeyConfigurationChanged?(configuration)
        showStatus(CopyCoCopy(language: language).shortcutChanged(configuration.displayName))
    }

    func setLanguage(_ language: CopyCoLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: Keys.language)
        onLanguageChanged?(language)
        let copy = CopyCoCopy(language: language)
        showStatus(copy.languageChanged(copy.languageName(language)))
    }

    func applyHistoryLimits() {
        let limits = Self.historyLimits(historyLimit: historyLimit, historySizeLimitMB: historySizeLimitMB)
        let maxItems = limits.maxItems
        let maxBytes = limits.maxBytes
        let historyStore = historyStore
        Task.detached(priority: .utility) { [weak self, historyStore] in
            let result = Result { () throws -> ([ClipboardItem], Int64) in
                try historyStore.updateLimits(limits)
                return historyStore.itemsSnapshot()
            }
            await MainActor.run {
                guard let self else { return }
                // Persist the new limits only when the store accepted them:
                // a rejected change (e.g. pinned items can't fit) must not
                // appear as saved settings.
                switch result {
                case .success:
                    self.historyLimit = maxItems
                    self.historySizeLimitMB = max(1, maxBytes / Self.bytesPerMegabyte)
                    self.defaults.set(maxItems, forKey: Keys.historyLimit)
                    self.defaults.set(self.historySizeLimitMB, forKey: Keys.historySizeLimitMB)
                    self.applySnapshot(result, successMessage: CopyCoCopy(language: self.language).historyLimitsUpdated)
                case .failure:
                    self.applySnapshot(result, successMessage: nil)
                }
            }
        }
    }

    func delete(item: ClipboardItem) { mutateHistory(successMessage: CopyCoCopy(language: language).itemRemoved) { try $0.delete(id: item.id) } }
    func clearAll() { mutateHistory(successMessage: CopyCoCopy(language: language).historyCleared) { try $0.removeAll() } }

    static func desiredPinnedState(for item: ClipboardItem, currentItems: [ClipboardItem]) -> Bool {
        let latestItem = currentItems.first { $0.id == item.id } ?? item
        return !latestItem.isPinned
    }

    func togglePin(item: ClipboardItem) {
        let shouldPin = Self.desiredPinnedState(for: item, currentItems: items)
        let copy = CopyCoCopy(language: language)
        let historyStore = historyStore
        Task.detached(priority: .utility) { [weak self, historyStore] in
            let result = Result { () throws -> ([ClipboardItem], Int64) in
                try historyStore.setPinned(id: item.id, pinned: shouldPin)
                return historyStore.itemsSnapshot()
            }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case let .success(snapshot):
                    self.applySnapshot(.success(snapshot), successMessage: shouldPin ? copy.itemPinned : copy.itemUnpinned)
                case let .failure(error):
                    if (error as? HistoryStoreError) == .pinLimitReached {
                        self.showNotice(copy.pinLimitReached)
                    } else {
                        self.showStatus(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Writes the item to the system pasteboard without activating a
    /// destination or synthesizing Command-V. Used by the two-phase paste
    /// flow to prepare the content before the user places the cursor.
    func copy(item: ClipboardItem, completion: @escaping (PasteResult) -> Void = { _ in }) {
        Task { [weak self] in
            guard let self else { return }
            let result = pasteCoordinator.copy(item: item)
            if case let .failed(message) = result {
                showStatus(message)
            }
            completion(result)
        }
    }

    func destinationFocusSnapshot() -> DestinationFocusSnapshot {
        pasteCoordinator.destinationFocusSnapshot()
    }

    func activatePasteDestination(_ destination: NSRunningApplication) async -> Bool {
        await pasteCoordinator.activateDestination(destination)
    }

    /// Pastes only to the explicitly supplied application. Callers must never
    /// pass a failed focus lookup through a nil fallback that can silently
    /// select a different frontmost application.
    func paste(item: ClipboardItem, to destination: NSRunningApplication, completion: @escaping (PasteResult) -> Void = { _ in }) {
        Task { [weak self] in
            guard let self else { return }
            let result = await pasteCoordinator.paste(item: item, to: destination)
            accessibilityTrusted = accessibilityTrustProvider()
            switch result {
            case .pasted: showStatus(CopyCoCopy(language: language).pasted)
            case .copiedOnly: showStatus(CopyCoCopy(language: language).copiedOnly)
            case let .failed(message): showStatus(message)
            }
            completion(result)
        }
    }

    func openSettings() { onOpenSettings?() }
    func resetHistorySearch() {
        searchText = ""
        applySearchFilter()
    }

    /// Applies a snapshot captured with `HistoryStore.itemsSnapshot()`.
    /// Snapshots whose store version is older than the last applied one are
    /// dropped so a stale read can never roll the UI back in time.
    func refreshHistorySnapshot(_ snapshot: [ClipboardItem], version: Int64) {
        guard version > lastAppliedSnapshotVersion else { return }
        lastAppliedSnapshotVersion = version
        items = snapshot
        applySearchFilter()
    }

    func loadPreview(for item: ClipboardItem) async -> HistoryPreview {
        await previewProvider.preview(for: item)
    }
    func showNotice(_ message: String) { showStatus(message) }
    /// Shows a status message that stays until explicitly cleared (unlike
    /// `showStatus`, which auto-dismisses after two seconds).
    func showPersistentStatus(_ message: String?) {
        statusTask?.cancel()
        statusMessage = message
        onStatusMessageChanged?(message)
    }
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    func refreshAccessibilityTrust() { accessibilityTrusted = accessibilityTrustProvider() }

    private func mutateHistory(successMessage: String, _ mutation: @escaping @Sendable (HistoryStore) throws -> Void) {
        let historyStore = historyStore
        Task.detached(priority: .utility) { [weak self, historyStore] in
            let result = Result { () throws -> ([ClipboardItem], Int64) in
                try mutation(historyStore)
                return historyStore.itemsSnapshot()
            }
            await MainActor.run { self?.applySnapshot(result, successMessage: successMessage) }
        }
    }

    private func applySnapshot(_ result: Result<([ClipboardItem], Int64), Error>, successMessage: String?) {
        switch result {
        case let .success((snapshot, version)):
            guard version > lastAppliedSnapshotVersion else { return }
            lastAppliedSnapshotVersion = version
            items = snapshot
            applySearchFilter()
            if let successMessage { showStatus(successMessage) }
        case let .failure(error):
            if (error as? HistoryStoreError) == .pinnedItemsExceedLimits {
                showStatus(CopyCoCopy(language: language).pinnedItemsExceedLimits)
            } else {
                showStatus(error.localizedDescription)
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.applySearchFilter()
        }
    }

    private func applySearchFilter() {
        filteredItems = HistorySearch.filter(items, query: searchText)
    }

    private func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        onStatusMessageChanged?(message)
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
            self?.onStatusMessageChanged?(nil)
        }
    }

    static func historyLimits(historyLimit: Int, historySizeLimitMB: Int) -> HistoryLimits {
        let maxItems = clamped(historyLimit, to: historyLimitRange)
        let maxSizeLimitMB = clamped(historySizeLimitMB, to: historySizeLimitMBRange)
        let maxBytes = maxSizeLimitMB * bytesPerMegabyte
        return HistoryLimits(
            maxItems: maxItems,
            maxBytes: maxBytes,
            maxInlineBytes: min(PasteboardCapture.maximumInlineBytes, maxBytes)
        )
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func loadExcludedBundleIDs(defaults: UserDefaults, fallback: Set<String>) -> Set<String> {
        if let storedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) {
            return Set(storedBundleIDs.filter { !$0.isEmpty })
        }
        if let legacyValue = defaults.string(forKey: Keys.excludedBundleIDs) {
            return Set(
                legacyValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        return fallback
    }

    private enum Keys {
        static let isPaused = "CopyCo.isPaused"
        static let excludedBundleIDs = "CopyCo.excludedBundleIDs"
        static let historyLimit = "CopyCo.historyLimit"
        static let historySizeLimitMB = "CopyCo.historySizeLimitMB"
        static let hotKeyCode = "CopyCo.hotKeyCode"
        static let hotKeyModifiers = "CopyCo.hotKeyModifiers"
        static let language = "CopyCo.language"
    }
    private static let bytesPerMegabyte = 1024 * 1024
}
