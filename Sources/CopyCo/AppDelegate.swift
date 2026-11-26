import AppKit
import Carbon.HIToolbox
import CopyCoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let historyStore: HistoryStore
    private let pasteboardCapture = PasteboardCapture()
    private let globalHotKey = GlobalHotKey()
    private let secureEventInputMonitor = SecureEventInputMonitor()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindow: NSWindow?
    private var settingsWasVisibleBeforePanel = false
    private var isSecureEventInputActive = false
    /// True while the Secure Event Input status message is owned by CopyCo so
    /// leaving a password field can clear or replace it without clobbering
    /// unrelated notices.
    private var showingSecureInputStatus = false
    private var lastPrivacySkipNoticeAt: Date?
    private lazy var pasteCoordinator = PasteCoordinator(historyStore: historyStore)
    private lazy var appState = AppState(
        historyStore: historyStore,
        pasteboardCapture: pasteboardCapture,
        pasteCoordinator: pasteCoordinator
    )
    private lazy var historyPanelController = HistoryPanelController(appState: appState)

    init(historyStore: HistoryStore = HistoryStore()) {
        self.historyStore = historyStore
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = CopyCoStatusItemIcon.make()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "CopyCo"
        self.statusItem = statusItem
        configureStatusMenu(for: statusItem)
        appState.onOpenSettings = { [weak self] in self?.showSettings() }
        appState.onStatusMessageChanged = { [weak self] message in self?.updateStatusItem(message: message) }
        appState.onHotKeyConfigurationChanged = { [weak self] configuration in
            self?.registerGlobalHotKey(configuration)
        }
        appState.onLanguageChanged = { [weak self] _ in
            self?.applyLocalization()
        }
        historyPanelController.onPanelWillPresent = { [weak self] in
            self?.hideSettingsWhileHistoryPanelShows()
        }
        historyPanelController.onPanelDidClose = { [weak self] in
            self?.restoreSettingsAfterHistoryPanel()
        }
        applyLocalization()
        appState.loadHistory()

        let historyStore = historyStore
        pasteboardCapture.onItem = { [weak appState, historyStore] item in
            do {
                try historyStore.insert(item)
                let snapshot = historyStore.itemsSnapshot()
                Task { @MainActor [weak appState] in
                    appState?.refreshHistorySnapshot(snapshot.items, version: snapshot.version)
                }
            } catch {
                NSLog("CopyCo could not save clipboard item: \(error.localizedDescription)")
                Task { @MainActor [weak appState] in
                    guard let appState else { return }
                    appState.showNotice(CopyCoCopy(language: appState.language).unableToSaveClipboardItem)
                }
            }
        }
        pasteboardCapture.onRejection = { [weak appState] rejection, _ in
            guard rejection == .payloadExceedsInlineLimit else { return }
            Task { @MainActor [weak appState] in
                guard let appState else { return }
                appState.showNotice(CopyCoCopy(language: appState.language).skippedLargeClipboardItem)
            }
        }
        pasteboardCapture.onPrivacySkip = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.announcePrivacySkip(reason)
            }
        }
        pasteboardCapture.start()

        secureEventInputMonitor.onChange = { [weak self] enabled in
            Task { @MainActor [weak self] in
                self?.handleSecureEventInputChange(enabled)
            }
        }
        secureEventInputMonitor.start()

        registerGlobalHotKey(appState.hotKeyConfiguration)
        DispatchQueue.main.async { [weak self] in
            self?.presentAccessibilityOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboardCapture.stop()
        secureEventInputMonitor.stop()
        globalHotKey.unregister()
        statusItem = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.refreshAccessibilityTrust()
    }

    @objc private func showHistoryPanel() {
        historyPanelController.show()
    }

    @objc private func togglePauseFromMenu() {
        appState.togglePause()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let copy = CopyCoCopy(language: appState.language)
        menu.item(withTag: 2)?.title = appState.isPaused ? copy.resumeRecording : copy.pauseRecording
    }

    private func configureStatusMenu(for statusItem: NSStatusItem) {
        let copy = CopyCoCopy(language: appState.language)
        let menu = NSMenu()
        menu.delegate = self
        let noticeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        noticeItem.tag = 1
        noticeItem.isHidden = true
        menu.addItem(noticeItem)
        let historyItem = NSMenuItem(title: copy.showHistory, action: #selector(showHistoryPanel), keyEquivalent: "")
        historyItem.tag = 3
        menu.addItem(historyItem)
        let pauseItem = NSMenuItem(title: copy.pauseRecording, action: #selector(togglePauseFromMenu), keyEquivalent: "")
        pauseItem.tag = 2
        menu.addItem(pauseItem)
        let settingsItem = NSMenuItem(title: copy.settingsMenu, action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.tag = 4
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: copy.quitCopyCo, action: #selector(quit), keyEquivalent: "q")
        quitItem.tag = 5
        menu.addItem(quitItem)
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        statusMenu = menu
    }

    @objc private func showSettingsFromMenu() {
        showSettings()
    }

    private func updateStatusItem(message: String?) {
        statusItem?.button?.toolTip = message
        guard let noticeItem = statusMenu?.item(withTag: 1) else { return }
        noticeItem.title = message ?? ""
        noticeItem.isHidden = message == nil
    }

    private func registerGlobalHotKey(_ configuration: HotKeyConfiguration) {
        globalHotKey.unregister()
        do {
            try globalHotKey.register(
                keyCode: configuration.keyCode,
                modifiers: configuration.modifiers
            ) { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A pending two-phase paste consumes the hot key first:
                    // the destination app is still frontmost at this instant,
                    // so the text-input focus can be re-checked accurately.
                    if !self.historyPanelController.handlePendingPasteHotKey() {
                        await self.pasteboardCapture.captureNow()
                        let snapshot = self.historyStore.itemsSnapshot()
                        self.appState.refreshHistorySnapshot(snapshot.items, version: snapshot.version)
                        self.showHistoryPanel()
                    }
                }
            }
        } catch {
            NSLog("CopyCo could not register global hot key \(configuration.displayName): \(error.localizedDescription)")
            appState.showNotice(CopyCoCopy(language: appState.language).shortcutUnavailable(configuration.displayName))
        }
    }

    /// Secure Event Input (password fields) suppresses Carbon hot-key delivery.
    /// CopyCo never disables it. The hot key works again after the user leaves
    /// the field; meanwhile the menu-bar "Show History" path still works.
    private func handleSecureEventInputChange(_ enabled: Bool) {
        let wasEnabled = isSecureEventInputActive
        isSecureEventInputActive = enabled
        let copy = CopyCoCopy(language: appState.language)
        let hotKey = appState.hotKeyConfiguration.displayName

        if enabled {
            showingSecureInputStatus = true
            appState.showPersistentStatus(copy.secureInputShortcutUnavailable(hotKey: hotKey))
            historyPanelController.refreshPendingPasteGuidanceForSecureInputChange()
            return
        }

        historyPanelController.refreshPendingPasteGuidanceForSecureInputChange()
        if showingSecureInputStatus {
            showingSecureInputStatus = false
            appState.showPersistentStatus(nil)
        }
        if wasEnabled {
            // After leaving the password field, Carbon delivers the hot key
            // again — tell the user instead of auto-opening the panel.
            appState.showNotice(copy.secureInputShortcutRestored(hotKey: hotKey))
        }
    }

    private func announcePrivacySkip(_ reason: PrivacyFilter.Reason) {
        // Pause skips are intentional user actions; do not toast them.
        guard reason != .paused else { return }
        let now = Date()
        if let lastPrivacySkipNoticeAt, now.timeIntervalSince(lastPrivacySkipNoticeAt) < 2 {
            return
        }
        lastPrivacySkipNoticeAt = now
        let copy = CopyCoCopy(language: appState.language)
        switch reason {
        case .concealedOrTransient:
            appState.showNotice(copy.skippedConcealedClipboardItem)
        case .excludedSource:
            appState.showNotice(copy.skippedExcludedClipboardSource)
        case .paused:
            break
        }
        // Transient notices clear the status after two seconds; restore the
        // Secure Event Input hint if the password field is still focused.
        guard isSecureEventInputActive else { return }
        let hotKey = appState.hotKeyConfiguration.displayName
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2100))
            guard let self, self.isSecureEventInputActive else { return }
            self.showingSecureInputStatus = true
            self.appState.showPersistentStatus(
                CopyCoCopy(language: self.appState.language).secureInputShortcutUnavailable(hotKey: hotKey)
            )
        }
    }

    private func applyLocalization() {
        let copy = CopyCoCopy(language: appState.language)
        menuNeedsUpdate(statusMenu ?? NSMenu())
        statusMenu?.item(withTag: 3)?.title = copy.showHistory
        statusMenu?.item(withTag: 4)?.title = copy.settingsMenu
        statusMenu?.item(withTag: 5)?.title = copy.quitCopyCo
        settingsWindow?.title = copy.settingsTitle
        historyPanelController.updateLanguage()
    }

    private func showSettings() {
        historyPanelController.dismiss(restorePreviousApplication: false)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = CopyCoCopy(language: appState.language).settingsTitle
        window.contentViewController = NSHostingController(rootView: SettingsView(appState: appState))
        window.setContentSize(NSSize(width: 600, height: 680))
        window.minSize = NSSize(width: 600, height: 680)
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keeps the history panel as the only visible CopyCo window while it is
    /// shown: a coexisting settings window steals keyboard focus (so Escape
    /// cannot dismiss the panel) and blocks click-away dismissal.
    private func hideSettingsWhileHistoryPanelShows() {
        guard let settingsWindow, settingsWindow.isVisible else { return }
        settingsWasVisibleBeforePanel = true
        settingsWindow.orderOut(nil)
    }

    /// Brings the settings window back when the history panel closes, but only
    /// while CopyCo is still active (Escape / paste-failure paths). When the
    /// user clicked away, do not yank the settings window to the front.
    private func restoreSettingsAfterHistoryPanel() {
        guard settingsWasVisibleBeforePanel else { return }
        settingsWasVisibleBeforePanel = false
        guard NSApp.isActive else { return }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentAccessibilityOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        guard AccessibilityOnboarding.shouldPresent(
            isTrusted: appState.accessibilityTrusted,
            hasShownPrompt: defaults.bool(forKey: AccessibilityOnboarding.promptShownKey)
        ) else { return }

        defaults.set(true, forKey: AccessibilityOnboarding.promptShownKey)
        let copy = CopyCoCopy(language: appState.language)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.accessibilityOnboardingTitle
        alert.informativeText = copy.accessibilityOnboardingMessage
        alert.addButton(withTitle: copy.openAccessibilitySettings)
        alert.addButton(withTitle: copy.accessibilityOnboardingLater)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.openAccessibilitySettings()
        }
    }
}
