import AppKit
import XCTest
@testable import CopyCo
@testable import CopyCoCore

final class AppStateTests: XCTestCase {
    @MainActor
    func testSavedHistoryLimitsAreNormalizedBeforeTheyAreReappliedAtLaunch() {
        let limits = AppState.historyLimits(historyLimit: 3, historySizeLimitMB: 2)

        XCTAssertEqual(limits.maxItems, 3)
        XCTAssertEqual(limits.maxBytes, 2 * 1024 * 1024)
        XCTAssertEqual(limits.maxInlineBytes, 2 * 1024 * 1024)
    }

    @MainActor
    func testHistoryLimitsClampToSupportedRanges() {
        let below = AppState.historyLimits(historyLimit: 0, historySizeLimitMB: 0)
        XCTAssertEqual(below.maxItems, 1)
        XCTAssertEqual(below.maxBytes, 1 * 1024 * 1024)

        let above = AppState.historyLimits(historyLimit: 900, historySizeLimitMB: 2_000)
        XCTAssertEqual(above.maxItems, 500)
        XCTAssertEqual(above.maxBytes, 1_024 * 1024 * 1024)
    }

    func testDefaultHistoryLimitsUseProductDefaults() {
        XCTAssertEqual(HistoryLimits.default.maxItems, 50)
        XCTAssertEqual(HistoryLimits.default.maxBytes, 500 * 1024 * 1024)
    }

    @MainActor
    func testSavedHistoryLimitsAreClampedWhenAppStateStarts() throws {
        let suiteName = "CopyCoHistoryLimitClampTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(900, forKey: "CopyCo.historyLimit")
        defaults.set(2_000, forKey: "CopyCo.historySizeLimitMB")
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoHistoryLimitClampTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())

        let appState = AppState(
            historyStore: historyStore,
            pasteboardCapture: pasteboardCapture,
            pasteCoordinator: pasteCoordinator,
            defaults: defaults
        )

        XCTAssertEqual(appState.historyLimit, 500)
        XCTAssertEqual(appState.historySizeLimitMB, 1_024)
    }

    @MainActor
    func testHistoryStoragePathReflectsStoreRootURL() throws {
        let suiteName = "CopyCoStoragePathTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoStoragePathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())
        let appState = AppState(historyStore: historyStore, pasteboardCapture: pasteboardCapture, pasteCoordinator: pasteCoordinator, defaults: defaults)

        XCTAssertEqual(appState.historyStoragePath, rootURL.path)
    }

    @MainActor
    func testLanguageSelectionIsPersisted() throws {
        let suiteName = "CopyCoAppStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoAppStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())
        let appState = AppState(historyStore: historyStore, pasteboardCapture: pasteboardCapture, pasteCoordinator: pasteCoordinator, defaults: defaults)

        appState.setLanguage(.simplifiedChinese)

        XCTAssertEqual(appState.language, .simplifiedChinese)
        XCTAssertEqual(defaults.string(forKey: "CopyCo.language"), CopyCoLanguage.simplifiedChinese.rawValue)
    }

    @MainActor
    func testAccessibilityPermissionRefreshUpdatesState() throws {
        let suiteName = "CopyCoAccessibilityRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoAccessibilityRefreshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var trusted = false
        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())
        let appState = AppState(
            historyStore: historyStore,
            pasteboardCapture: pasteboardCapture,
            pasteCoordinator: pasteCoordinator,
            defaults: defaults,
            accessibilityTrustProvider: { trusted }
        )

        XCTAssertFalse(appState.accessibilityTrusted)
        trusted = true
        appState.refreshAccessibilityTrust()
        XCTAssertTrue(appState.accessibilityTrusted)
    }

    @MainActor
    func testTogglePinUsesLatestStoredStateWhenCallerHasStaleSnapshot() {
        let requestedItem = ClipboardItem(kind: .text, preview: "item", representations: [], totalBytes: 0)
        var currentItem = requestedItem
        currentItem.isPinned = true

        XCTAssertFalse(
            AppState.desiredPinnedState(for: requestedItem, currentItems: [currentItem])
        )

        currentItem.isPinned = false
        XCTAssertTrue(
            AppState.desiredPinnedState(for: requestedItem, currentItems: [currentItem])
        )
    }

    @MainActor
    func testLegacyExcludedBundleIDsMigrateAndSelectionUpdatesPrivacySettings() throws {
        let suiteName = "CopyCoExcludedApplicationMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("com.example.One, com.example.Two", forKey: "CopyCo.excludedBundleIDs")
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoExcludedApplicationMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())
        let appState = AppState(
            historyStore: historyStore,
            pasteboardCapture: pasteboardCapture,
            pasteCoordinator: pasteCoordinator,
            defaults: defaults,
            applicationCatalog: StubApplicationCatalog(values: [])
        )

        XCTAssertEqual(appState.excludedBundleIDs, ["com.example.One", "com.example.Two"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "CopyCo.excludedBundleIDs"),
            ["com.example.One", "com.example.Two"]
        )

        appState.setExcluded(true, for: "com.example.Three")
        XCTAssertTrue(pasteboardCapture.currentPrivacySettings.excludedBundleIDs.contains("com.example.Three"))

        appState.setExcluded(false, for: "com.example.One")
        XCTAssertFalse(appState.excludedBundleIDs.contains("com.example.One"))
    }

    @MainActor
    func testInstalledApplicationsLoadFromInjectedCatalog() async throws {
        let suiteName = "CopyCoInstalledApplicationLoadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CopyCoInstalledApplicationLoadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let chrome = InstalledApplication(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            url: URL(fileURLWithPath: "/Applications/Chrome.app")
        )

        let historyStore = HistoryStore(rootURL: rootURL)
        let pasteboardCapture = PasteboardCapture(pasteboard: pasteboardCaptureTestPasteboard())
        let pasteCoordinator = PasteCoordinator(historyStore: historyStore, pasteboard: pasteboardCaptureTestPasteboard())
        let appState = AppState(
            historyStore: historyStore,
            pasteboardCapture: pasteboardCapture,
            pasteCoordinator: pasteCoordinator,
            defaults: defaults,
            applicationCatalog: StubApplicationCatalog(values: [chrome])
        )

        await appState.loadInstalledApplications()

        XCTAssertEqual(appState.installedApplications, [chrome])
        XCTAssertFalse(appState.isLoadingInstalledApplications)
        XCTAssertNil(appState.installedApplicationsError)
    }

    private func pasteboardCaptureTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("CopyCoAppStateTests-Paste-\(UUID().uuidString)"))
    }
}

private struct StubApplicationCatalog: InstalledApplicationDiscovering {
    let values: [InstalledApplication]

    func applications() async throws -> [InstalledApplication] {
        values
    }
}
