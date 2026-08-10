import AppKit
import CopyCoCore
import SwiftUI

struct HistoryPanelPresentationGate {
    private var pendingSequence: Int?

    mutating func begin(requestSequence: Int?) -> Bool {
        pendingSequence = requestSequence
        return requestSequence == nil
    }

    mutating func handle(sequence: Int) -> Bool {
        guard let pending = pendingSequence, sequence >= pending else { return false }
        pendingSequence = nil
        return true
    }
}

/// Why the two-phase paste flow was started (or restarted).
enum PendingPasteReason: Equatable {
    case noTextCursor
    case noDestination
}

@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let hidesOnDeactivate = true
    /// How long an armed two-phase paste waits for the user to place the
    /// cursor before it cancels itself.
    static let pendingPasteTimeout: Duration = .seconds(60)
    private static let guidanceBannerDuration: Duration = .seconds(8)

    private let appState: AppState
    private let keyboardRouter = HistoryKeyboardRouter()
    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private weak var previouslyFrontmostApplication: NSRunningApplication?
    private var isPasting = false
    private var restorePreviousApplicationOnClose = true
    private var isSearchFieldFocused = false
    private var presentationGate = HistoryPanelPresentationGate()
    private var pendingPasteItem: ClipboardItem?
    private var pendingPasteTask: Task<Void, Never>?
    private var guidanceBanner: NSPanel?
    private var guidanceBannerTask: Task<Void, Never>?
    /// Called right before the history panel is presented, so the app can
    /// clear the way (e.g. hide the settings window) and keep the panel as the
    /// only visible window.
    var onPanelWillPresent: (() -> Void)?
    /// Called when the history panel closes.
    var onPanelDidClose: (() -> Void)?
    /// Whether the destination application had a text-input focus when the
    /// panel was summoned. `nil` = unknown (no Accessibility permission or the
    /// check failed); the paste proceeds as before in that case.
    private var pasteTargetAcceptsTextInput: Bool?

    init(appState: AppState) { self.appState = appState }

    func show() {
        cancelPendingPaste(clearingStatus: true)
        let wasVisible = panel?.isVisible == true
        if !wasVisible {
            previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
            // Snapshot the destination's text-input focus BEFORE the panel
            // activates CopyCo: AX focus only exists for the frontmost app, and
            // pasting into a non-editable focus (desktop, file list) silently
            // does nothing.
            pasteTargetAcceptsTextInput = PasteCoordinator.frontmostApplicationAcceptsTextInput()
        }
        appState.pasteDestination = previouslyFrontmostApplication
        let panel = panel ?? makePanel()
        let revealImmediately: Bool
        if wasVisible {
            // Every invocation defaults the selection to the first item,
            // matching a fresh open. The in-progress search text is preserved:
            // prepareForPresentation does not touch it, only the selection.
            keyboardRouter.prepareForPresentation(items: appState.filteredItems)
            revealImmediately = true
            _ = presentationGate.begin(requestSequence: nil)
        } else {
            appState.resetHistorySearch()
            keyboardRouter.prepareForPresentation(items: appState.filteredItems)
            revealImmediately = presentationGate.begin(requestSequence: keyboardRouter.scrollRequest?.sequence)
        }
        panel.alphaValue = revealImmediately ? 1 : 0
        installKeyMonitorIfNeeded()
        onPanelWillPresent?()
        present(panel)
    }

    func dismiss(restorePreviousApplication: Bool = true) {
        cancelPendingPaste(clearingStatus: true)
        _ = presentationGate.begin(requestSequence: nil)
        panel?.alphaValue = 1
        restorePreviousApplicationOnClose = restorePreviousApplication
        panel?.orderOut(nil)
        panel?.close()
    }

    func beginPaste(item: ClipboardItem) {
        guard !isPasting else { return }
        let destination = appState.pasteDestination
        let hasLiveDestination = destination.map { !$0.isTerminated } ?? false
        // Pre-flight: when the destination has no text-input focus (desktop,
        // file browser, no focused field) or is missing, switch to the
        // two-phase flow: prepare the clipboard, guide the user to place the
        // cursor in the target app, then press the global hot key again to
        // complete the paste. A blind Command-V into a non-editable focus
        // silently does nothing.
        if Self.shouldBeginPendingPaste(
            acceptsTextInput: pasteTargetAcceptsTextInput,
            hasLiveDestination: hasLiveDestination
        ) {
            beginPendingPaste(item: item)
            return
        }
        isPasting = true
        panel?.orderOut(nil)
        appState.paste(item: item) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPasting = false
                if Self.shouldRestorePanel(after: result) {
                    // Refresh the failure message when the panel comes back so
                    // the reason is visible for its full duration (activation
                    // can take up to a second before the failure is known).
                    if case let .failed(message) = result {
                        self.appState.showNotice(message)
                    }
                    if let panel = self.panel {
                        self.present(panel)
                    }
                } else {
                    self.dismiss(restorePreviousApplication: Self.shouldRestorePreviousApplication(after: result))
                }
            }
        }
    }

    /// Handles a global-hot-key press while a two-phase paste is armed.
    /// Returns `true` when the pending state consumed the press; `false` when
    /// the caller should show the history panel as usual.
    func handlePendingPasteHotKey() -> Bool {
        guard let item = pendingPasteItem else { return false }
        // A global hot key does not activate CopyCo, so the destination app is
        // still frontmost at this instant — the AX focus check is live and
        // accurate (unlike the snapshot taken when the panel was summoned).
        if !Self.shouldCompletePendingPaste(
            acceptsTextInput: PasteCoordinator.frontmostApplicationAcceptsTextInput()
        ) {
            showPendingPasteGuidance(reason: .noTextCursor)
            return true
        }
        cancelPendingPaste(clearingStatus: true)
        appState.paste(item: item, to: NSWorkspace.shared.frontmostApplication)
        return true
    }

    func cancelPendingPaste(clearingStatus: Bool = true) {
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        pendingPasteItem = nil
        hideGuidanceBanner()
        if clearingStatus {
            appState.showPersistentStatus(nil)
        }
    }

    /// The preflight decision: enter the two-phase flow when the destination
    /// has no text-input focus or is missing entirely.
    static func shouldBeginPendingPaste(acceptsTextInput: Bool?, hasLiveDestination: Bool) -> Bool {
        acceptsTextInput == false || !hasLiveDestination
    }

    /// Whether a second hot-key press should complete the pending paste.
    /// `nil` (inconclusive Accessibility check) proceeds as a best effort.
    static func shouldCompletePendingPaste(acceptsTextInput: Bool?) -> Bool {
        acceptsTextInput != false
    }

    static func pendingPasteReason(hasLiveDestination: Bool, acceptsTextInput: Bool?) -> PendingPasteReason {
        hasLiveDestination ? .noTextCursor : .noDestination
    }

    static func shouldRestorePanel(after result: PasteResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    static func shouldRestorePreviousApplication(after result: PasteResult) -> Bool {
        if case .pasted = result { return false }
        return true
    }

    func updateLanguage() {
        panel?.title = CopyCoCopy(language: appState.language).historyTitle
    }

    func windowWillClose(_ notification: Notification) {
        let application = restorePreviousApplicationOnClose ? previouslyFrontmostApplication : nil
        restorePreviousApplicationOnClose = true
        previouslyFrontmostApplication = nil
        appState.pasteDestination = nil
        application?.activate(options: [])
        onPanelDidClose?()
    }

    private func beginPendingPaste(item: ClipboardItem) {
        guard !isPasting else { return }
        isPasting = true
        appState.copy(item: item) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPasting = false
                switch result {
                case .copiedOnly:
                    // The panel may have been dismissed while the clipboard
                    // write was in flight; the content is already on the
                    // pasteboard, so do not arm a flow the user abandoned.
                    guard self.panel?.isVisible == true else { return }
                    self.armPendingPaste(item: item)
                    self.panel?.orderOut(nil)
                    self.restoreTargetApplication()
                    let hasLiveDestination = self.appState.pasteDestination.map { !$0.isTerminated } ?? false
                    self.showPendingPasteGuidance(
                        reason: Self.pendingPasteReason(
                            hasLiveDestination: hasLiveDestination,
                            acceptsTextInput: self.pasteTargetAcceptsTextInput
                        )
                    )
                case let .failed(message):
                    self.appState.showNotice(message)
                case .pasted:
                    break
                }
            }
        }
    }

    private func armPendingPaste(item: ClipboardItem) {
        pendingPasteTask?.cancel()
        pendingPasteItem = item
        pendingPasteTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pendingPasteTimeout)
            guard !Task.isCancelled else { return }
            self?.cancelPendingPaste()
        }
    }

    private func showPendingPasteGuidance(reason: PendingPasteReason) {
        guard let item = pendingPasteItem else { return }
        // Every guidance pass extends the window, so the flow stays alive
        // while the user is actively trying to place the cursor.
        armPendingPaste(item: item)
        let copy = CopyCoCopy(language: appState.language)
        let hotKey = appState.hotKeyConfiguration.displayName
        let message = reason == .noDestination
            ? copy.pendingPasteNoDestinationHint(hotKey: hotKey)
            : copy.pendingPasteReadyHint(hotKey: hotKey)
        showGuidanceBanner(message)
        appState.showPersistentStatus(message)
    }

    private func restoreTargetApplication() {
        guard let destination = appState.pasteDestination, !destination.isTerminated else { return }
        NSApp.yieldActivation(to: destination)
        destination.activate(from: .current, options: [])
    }

    private func showGuidanceBanner(_ message: String) {
        hideGuidanceBanner()
        let banner = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        banner.level = .floating
        banner.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        banner.isOpaque = false
        banner.backgroundColor = .clear
        banner.hidesOnDeactivate = false
        // Click-through so the user can immediately click the paste position
        // in the target app underneath the banner.
        banner.ignoresMouseEvents = true
        let hostingView = NSHostingView(rootView: GuidanceBannerView(message: message))
        hostingView.frame = banner.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        banner.contentView?.addSubview(hostingView)
        positionGuidanceBanner(banner)
        banner.orderFrontRegardless()
        guidanceBanner = banner
        guidanceBannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.guidanceBannerDuration)
            guard !Task.isCancelled else { return }
            self?.hideGuidanceBanner()
        }
    }

    private func hideGuidanceBanner() {
        guidanceBannerTask?.cancel()
        guidanceBannerTask = nil
        guidanceBanner?.orderOut(nil)
        guidanceBanner = nil
    }

    private func positionGuidanceBanner(_ banner: NSPanel) {
        let frame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        banner.setFrameOrigin(NSPoint(x: frame.midX - banner.frame.width / 2, y: frame.minY + 16))
    }

    private func makePanel() -> NSPanel {
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: HistoryPanelSizing.minimumHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = CopyCoCopy(language: appState.language).historyTitle
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = Self.hidesOnDeactivate
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: HistoryPanelView(
            appState: appState,
            keyboardRouter: keyboardRouter,
            onPaste: { [weak self] item in self?.beginPaste(item: item) },
            onHeightChange: { [weak self] count in self?.updatePanelHeight(for: count) },
            onSearchFocusChange: { [weak self] focused in self?.isSearchFieldFocused = focused },
            onScrollRequestHandled: { [weak self] sequence in self?.revealPanel(afterHandling: sequence) }
        ))
        self.panel = panel
        return panel
    }

    private func updatePanelHeight(for itemCount: Int) {
        guard let panel else { return }
        let height = HistoryPanelSizing.height(
            itemCount: itemCount,
            rowHeight: 56,
            rowSpacing: 6,
            listVerticalPadding: 4,
            headerHeight: 64,
            footerHeight: 32,
            maxHeight: 420
        )
        panel.setContentSize(NSSize(width: 600, height: height))
        position(panel)
    }

    private func position(_ panel: NSPanel) {
        let frame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let y = max(frame.minY + 12, frame.midY + 90 - panel.frame.height / 2)
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: y))
    }

    private func present(_ panel: NSPanel) {
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func revealPanel(afterHandling sequence: Int) {
        guard presentationGate.handle(sequence: sequence), let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.alphaValue = 1
    }

    private func installKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            if let command = HistoryKeyboardRouter.command(for: event.keyCode) {
                if !HistoryKeyboardRouter.shouldRoute(command: command, searchFieldFocused: self.isSearchFieldFocused) {
                    return event
                }
                return self.keyboardRouter.route(event) ? nil : event
            }
            // List mode (search field not focused, e.g. after Up/Down): a plain
            // printable key returns typing to the search field. The field is
            // made first responder synchronously so THIS keystroke lands in it
            // (no lost characters, IME composition works normally).
            if !self.isSearchFieldFocused, Self.shouldReturnTypingToSearch(event) {
                self.returnTypingToSearch()
            }
            return event
        }
        keyboardRouter.onPaste = { [weak self] item in self?.beginPaste(item: item) }
        keyboardRouter.onTogglePin = { [weak self] item in self?.appState.togglePin(item: item) }
        keyboardRouter.onDismiss = { [weak self] in self?.dismiss() }
    }

    /// A key that should return typing focus to the search field: a printable
    /// character without command/option/control modifiers (shift is allowed).
    static func shouldReturnTypingToSearch(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let characters = event.characters,
              !characters.isEmpty else {
            return false
        }
        return characters.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
    }

    private func returnTypingToSearch() {
        // Keep SwiftUI's focus state in sync…
        keyboardRouter.refocusSearch()
        // …and make the search field first responder synchronously so the
        // event being dispatched right now reaches the text field.
        guard let panel, let textField = Self.searchTextField(in: panel.contentView) else { return }
        panel.makeFirstResponder(textField)
    }

    /// Finds the search field inside the SwiftUI hierarchy: the editable text
    /// field in the top region of the panel (row labels are non-editable and
    /// sit below it).
    private static func searchTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.frame.minY < 80 {
            return textField
        }
        for subview in view.subviews {
            if let found = searchTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}

private final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Transient click-through banner used by the two-phase paste flow to tell the
/// user where to place the cursor and which key completes the paste.
private struct GuidanceBannerView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.9)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
