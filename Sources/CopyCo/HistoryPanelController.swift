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

struct PendingPasteSession {
    enum Phase: Equatable {
        case idle
        case copying
        case restoring
        case armed
        case submitting
    }

    private(set) var phase: Phase = .idle
    private(set) var item: ClipboardItem?
    private(set) var generation = 0

    var consumesHotKey: Bool { phase != .idle }

    mutating func beginCopying(item: ClipboardItem) -> Int {
        generation &+= 1
        self.item = item
        phase = .copying
        return generation
    }

    @discardableResult
    mutating func beginRestoring(generation: Int) -> Bool {
        guard self.generation == generation, phase == .copying, item != nil else {
            return false
        }
        phase = .restoring
        return true
    }

    @discardableResult
    mutating func arm(generation: Int) -> Bool {
        guard self.generation == generation, phase == .restoring, item != nil else {
            return false
        }
        phase = .armed
        return true
    }

    mutating func beginSubmission(
        using snapshot: DestinationFocusSnapshot
    ) -> (item: ClipboardItem, application: NSRunningApplication, generation: Int)? {
        guard phase == .armed,
              let item,
              let application = snapshot.validatedApplication else {
            return nil
        }
        phase = .submitting
        return (item, application, generation)
    }

    @discardableResult
    mutating func finishSubmission(_ result: PasteResult, generation: Int) -> Bool {
        guard self.generation == generation, phase == .submitting else {
            return false
        }
        if case .pasted = result {
            self.generation &+= 1
            item = nil
            phase = .idle
        } else {
            phase = .armed
        }
        return true
    }

    func shouldExpire(generation: Int) -> Bool {
        self.generation == generation && phase == .armed && item != nil
    }

    mutating func cancel() {
        generation &+= 1
        item = nil
        phase = .idle
    }
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
    private var pendingPasteSession = PendingPasteSession()
    private var pendingPasteTask: Task<Void, Never>?
    private var pendingRestoreTask: Task<Void, Never>?
    private var activePasteTask: Task<Void, Never>?
    private var pasteOperationGeneration = 0
    private var guidanceBanner: NSPanel?
    private var guidanceBannerTask: Task<Void, Never>?
    /// Called right before the history panel is presented, so the app can
    /// clear the way (e.g. hide the settings window) and keep the panel as the
    /// only visible window.
    var onPanelWillPresent: (() -> Void)?
    /// Called when the history panel closes.
    var onPanelDidClose: (() -> Void)?
    /// Workspace and Accessibility identity observed immediately before the
    /// panel was shown. Keeping the values together prevents mixing focus from
    /// one application with a later Workspace frontmost result.
    private var pasteTargetFocusSnapshot: DestinationFocusSnapshot?

    init(appState: AppState) { self.appState = appState }

    func show() {
        cancelPendingPaste(clearingStatus: true)
        let wasVisible = panel?.isVisible == true
        if !wasVisible {
            let focusSnapshot = appState.destinationFocusSnapshot()
            pasteTargetFocusSnapshot = focusSnapshot
            previouslyFrontmostApplication = focusSnapshot.workspaceApplication
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
        let hasVerifiedDestination = destination.map { destination in
            pasteTargetFocusSnapshot?.validates(
                processIdentifier: destination.processIdentifier
            ) == true
        } ?? false
        // Pre-flight: when the destination has no text-input focus (desktop,
        // file browser, no focused field) or is missing, switch to the
        // two-phase flow: prepare the clipboard, guide the user to place the
        // cursor in the target app, then press the global hot key again to
        // complete the paste. A blind Command-V into a non-editable focus
        // silently does nothing.
        if Self.shouldBeginPendingPaste(
            acceptsTextInput: pasteTargetFocusSnapshot?.acceptsTextInput,
            hasLiveDestination: hasLiveDestination && hasVerifiedDestination
        ) {
            beginPendingPaste(item: item)
            return
        }
        guard let destination else {
            beginPendingPaste(item: item)
            return
        }
        isPasting = true
        panel?.orderOut(nil)
        let operationGeneration = beginPasteOperation()
        activePasteTask = appState.paste(item: item, to: destination) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pasteOperationGeneration == operationGeneration else { return }
                self.activePasteTask = nil
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
        guard pendingPasteSession.consumesHotKey else { return false }
        guard pendingPasteSession.phase == .armed else { return true }

        // Read Workspace and AX exactly once. The validated application comes
        // from that same snapshot, so there is no AX(A)/Workspace(B) split.
        let snapshot = appState.destinationFocusSnapshot()
        guard let submission = pendingPasteSession.beginSubmission(using: snapshot) else {
            showPendingPasteGuidance(reason: .noTextCursor)
            return true
        }
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        isPasting = true
        let operationGeneration = beginPasteOperation()
        activePasteTask = appState.paste(item: submission.item, to: submission.application) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pasteOperationGeneration == operationGeneration,
                      self.pendingPasteSession.finishSubmission(
                        result,
                        generation: submission.generation
                      ) else { return }
                self.activePasteTask = nil
                self.isPasting = false
                if case .pasted = result {
                    self.cancelPendingPaste(clearingStatus: true)
                } else {
                    self.showPendingPasteGuidance(reason: .noTextCursor)
                }
            }
        }
        return true
    }

    func cancelPendingPaste(clearingStatus: Bool = true) {
        cancelActivePasteOperation()
        pendingRestoreTask?.cancel()
        pendingRestoreTask = nil
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        pendingPasteSession.cancel()
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
        cancelPendingPaste(clearingStatus: true)
        restorePreviousApplicationOnClose = true
        previouslyFrontmostApplication = nil
        appState.pasteDestination = nil
        pasteTargetFocusSnapshot = nil
        application?.activate(options: [])
        onPanelDidClose?()
    }

    private func beginPendingPaste(item: ClipboardItem) {
        guard !isPasting else { return }
        isPasting = true
        let pendingGeneration = pendingPasteSession.beginCopying(item: item)
        let operationGeneration = beginPasteOperation()
        activePasteTask = appState.copy(item: item) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pasteOperationGeneration == operationGeneration,
                      self.pendingPasteSession.generation == pendingGeneration,
                      self.pendingPasteSession.phase == .copying else { return }
                self.activePasteTask = nil
                self.isPasting = false
                switch result {
                case .copiedOnly:
                    // The panel may have been dismissed while the clipboard
                    // write was in flight; the content is already on the
                    // pasteboard, so do not arm a flow the user abandoned.
                    guard self.panel?.isVisible == true,
                          self.pendingPasteSession.beginRestoring(
                            generation: pendingGeneration
                          ) else {
                        self.pendingPasteSession.cancel()
                        return
                    }
                    self.panel?.orderOut(nil)
                    self.beginPendingRestore(generation: pendingGeneration)
                case let .failed(message):
                    self.pendingPasteSession.cancel()
                    self.appState.showNotice(message)
                case .pasted:
                    self.pendingPasteSession.cancel()
                }
            }
        }
    }

    private func refreshPendingPasteTimeout() {
        guard pendingPasteSession.phase == .armed else { return }
        let generation = pendingPasteSession.generation
        pendingPasteTask?.cancel()
        pendingPasteTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pendingPasteTimeout)
            guard !Task.isCancelled else { return }
            guard let self,
                  self.pendingPasteSession.shouldExpire(generation: generation) else { return }
            self.cancelPendingPaste()
        }
    }

    private func showPendingPasteGuidance(reason: PendingPasteReason) {
        guard pendingPasteSession.item != nil else { return }
        // Every guidance pass extends the window, so the flow stays alive
        // while the user is actively trying to place the cursor.
        refreshPendingPasteTimeout()
        let copy = CopyCoCopy(language: appState.language)
        let hotKey = appState.hotKeyConfiguration.displayName
        let message: String
        if reason == .noDestination {
            message = copy.pendingPasteNoDestinationHint(hotKey: hotKey)
        } else if SecureEventInput.isEnabled() {
            // Carbon hot keys are not delivered under Secure Event Input, so
            // steer the user to ⌘V instead of another global-shortcut press.
            message = copy.pendingPasteSecureInputHint()
        } else {
            message = copy.pendingPasteReadyHint(hotKey: hotKey)
        }
        showGuidanceBanner(message)
        appState.showPersistentStatus(message)
    }

    /// Re-evaluates pending-paste guidance after Secure Event Input changes,
    /// for example when the user leaves a password field.
    func refreshPendingPasteGuidanceForSecureInputChange() {
        guard pendingPasteSession.phase == .armed, pendingPasteSession.item != nil else { return }
        showPendingPasteGuidance(reason: .noTextCursor)
    }

    private func beginPendingRestore(generation: Int) {
        pendingRestoreTask?.cancel()
        guard let destination = appState.pasteDestination, !destination.isTerminated else {
            finishPendingRestore(generation: generation, restored: false)
            return
        }

        pendingRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await self.appState.activatePasteDestination(destination)
            guard !Task.isCancelled else { return }
            self.finishPendingRestore(generation: generation, restored: restored)
        }
    }

    private func finishPendingRestore(generation: Int, restored: Bool) {
        guard pendingPasteSession.arm(generation: generation) else { return }
        pendingRestoreTask = nil
        showPendingPasteGuidance(reason: restored ? .noTextCursor : .noDestination)
    }

    private func beginPasteOperation() -> Int {
        activePasteTask?.cancel()
        pasteOperationGeneration &+= 1
        return pasteOperationGeneration
    }

    private func cancelActivePasteOperation() {
        pasteOperationGeneration &+= 1
        activePasteTask?.cancel()
        activePasteTask = nil
        isPasting = false
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
