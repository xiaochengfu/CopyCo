import AppKit
import ApplicationServices
import CopyCoCore
import Foundation

enum PasteResult: Sendable, Equatable {
    case pasted
    case copiedOnly
    case failed(message: String)
}

struct DestinationFocusSnapshot: Sendable {
    let workspaceApplication: NSRunningApplication?
    let workspacePID: pid_t?
    let axPID: pid_t?
    let acceptsTextInput: Bool?

    func validates(processIdentifier: pid_t) -> Bool {
        guard let workspaceApplication,
              workspaceApplication.processIdentifier == processIdentifier,
              !workspaceApplication.isTerminated else {
            return false
        }
        return processIdentifier > 0
            && workspacePID == processIdentifier
            && axPID == processIdentifier
            && acceptsTextInput != false
    }

    var validatedApplication: NSRunningApplication? {
        guard let workspaceApplication,
              validates(processIdentifier: workspaceApplication.processIdentifier) else {
            return nil
        }
        return workspaceApplication
    }
}

enum PasteEventPhase: Sendable, Equatable {
    case keyDown
    case keyUp

    var isKeyDown: Bool { self == .keyDown }
}

struct PasteboardRestoreRepresentation: Sendable, Equatable {
    let itemIndex: Int
    let uti: String
    let data: Data
}

@MainActor
final class DestinationApplicationActivator {
    private let yieldActivation: (NSRunningApplication) -> Void
    private let requestActivation: (NSRunningApplication) -> Bool
    private let frontmostProcessIdentifier: () -> pid_t?
    private let sleep: (Duration) async -> Void
    private let maximumAttempts: Int
    private let pollInterval: Duration

    init(
        yieldActivation: @escaping (NSRunningApplication) -> Void = { NSApp.yieldActivation(to: $0) },
        requestActivation: @escaping (NSRunningApplication) -> Bool = { $0.activate(from: .current, options: []) },
        frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        sleep: @escaping (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) },
        maximumAttempts: Int = 40,
        pollInterval: Duration = .milliseconds(25)
    ) {
        self.yieldActivation = yieldActivation
        self.requestActivation = requestActivation
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.sleep = sleep
        self.maximumAttempts = maximumAttempts
        self.pollInterval = pollInterval
    }

    func activate(_ application: NSRunningApplication) async -> Bool {
        guard !Task.isCancelled else { return false }
        if frontmostProcessIdentifier() == application.processIdentifier {
            return true
        }

        yieldActivation(application)
        _ = requestActivation(application)

        for _ in 0..<maximumAttempts {
            guard !Task.isCancelled else { return false }
            if frontmostProcessIdentifier() == application.processIdentifier {
                return true
            }
            await sleep(pollInterval)
        }
        return false
    }
}

@MainActor
final class PasteCoordinator {
    private let historyStore: HistoryStore
    private let pasteboard: NSPasteboard
    private let isAccessibilityTrusted: () -> Bool
    private let destinationActivator: DestinationApplicationActivator
    private let focusReader: @MainActor () -> DestinationFocusSnapshot
    private let isApplicationTerminated: @MainActor (NSRunningApplication) -> Bool
    private let eventPoster: @MainActor (pid_t) -> Bool
    private let focusMaximumAttempts: Int
    private let focusPollInterval: Duration
    private let focusSleep: (Duration) async -> Void

    init(
        historyStore: HistoryStore,
        pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: @escaping () -> Bool = AccessibilityPermission.isTrusted,
        destinationActivator: DestinationApplicationActivator = DestinationApplicationActivator(),
        focusReader: @escaping @MainActor () -> DestinationFocusSnapshot = PasteCoordinator.readDestinationFocusSnapshot,
        isApplicationTerminated: @escaping @MainActor (NSRunningApplication) -> Bool = { $0.isTerminated },
        eventPoster: @escaping @MainActor (pid_t) -> Bool = { processIdentifier in
            PasteCoordinator.postPasteEventPair(processIdentifier: processIdentifier)
        },
        focusMaximumAttempts: Int = 40,
        focusPollInterval: Duration = .milliseconds(25),
        focusSleep: @escaping (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.destinationActivator = destinationActivator
        self.focusReader = focusReader
        self.isApplicationTerminated = isApplicationTerminated
        self.eventPoster = eventPoster
        self.focusMaximumAttempts = focusMaximumAttempts
        self.focusPollInterval = focusPollInterval
        self.focusSleep = focusSleep
    }

    /// Writes an item's payloads to the pasteboard without activating a
    /// destination or synthesizing Command-V. Returns `.copiedOnly` on success
    /// so callers can tell "content is ready" apart from a completed paste.
    func copy(item: ClipboardItem) -> PasteResult {
        let representations: [PasteboardRestoreRepresentation]
        do {
            representations = try item.representations.map { representation in
                let data: Data
                if let payload = representation.payload {
                    data = payload
                } else {
                    data = try Data(contentsOf: representation.payloadURL(relativeTo: historyStore.rootURL))
                }
                return PasteboardRestoreRepresentation(itemIndex: representation.itemIndex, uti: representation.uti, data: data)
            }
        } catch {
            return .failed(message: "Unable to restore clipboard data: \(error.localizedDescription)")
        }

        guard !representations.isEmpty else {
            return .failed(message: "The selected history item has no clipboard data.")
        }

        // Refuse to clobber the user's current clipboard with a stale file
        // reference: check source-file existence before writing anything.
        if Self.hasMissingFileURL(in: representations) {
            return .failed(message: "The source file for this history item is no longer available.")
        }

        let pasteboardItems = Self.groupedRepresentations(representations).map { group -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for representation in group {
                pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti))
            }
            return pasteboardItem
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            return .failed(message: "Unable to write clipboard data to the pasteboard.")
        }
        return .copiedOnly
    }

    /// Restores an item to the pasteboard and only synthesizes Command-V after
    /// Accessibility access has explicitly been granted by the user.
    func paste(item: ClipboardItem, to application: NSRunningApplication?) async -> PasteResult {
        switch copy(item: item) {
        case .copiedOnly:
            break
        case let .failed(message):
            return .failed(message: message)
        case .pasted:
            return .pasted
        }

        guard isAccessibilityTrusted() else {
            return .copiedOnly
        }

        guard let application else {
            return .failed(message: "Copied to the clipboard, but there is no destination application to paste into.")
        }
        let targetPID = application.processIdentifier
        guard Self.isValidDestination(
            processIdentifier: targetPID,
            isTerminated: isApplicationTerminated(application)
        ) else {
            return .failed(message: "Copied to the clipboard, but the destination application is no longer available.")
        }
        let destinationIsFrontmost = await destinationActivator.activate(application)
        guard Self.shouldSendPaste(hasDestination: true, destinationIsFrontmost: destinationIsFrontmost) else {
            return .failed(message: "Copied to the clipboard, but the destination application could not be activated.")
        }

        guard await waitForReadyFocus(application: application) else {
            let snapshot = focusReader()
            Self.logFocusMismatch(stage: "readiness", intendedPID: targetPID, snapshot: snapshot)
            return .failed(message: "Copied to the clipboard, but the destination text field is no longer focused.")
        }

        let finalSnapshot = focusReader()
        guard Self.isValidDestination(
            processIdentifier: targetPID,
            isTerminated: isApplicationTerminated(application)
        ), finalSnapshot.validates(processIdentifier: targetPID) else {
            Self.logFocusMismatch(stage: "delivery", intendedPID: targetPID, snapshot: finalSnapshot)
            return .failed(message: "Copied to the clipboard, but focus moved to another application before paste.")
        }

        guard eventPoster(targetPID) else {
            return .failed(message: "Unable to create the paste keyboard event.")
        }
        return .pasted
    }

    func destinationFocusSnapshot() -> DestinationFocusSnapshot {
        focusReader()
    }

    func activateDestination(_ application: NSRunningApplication) async -> Bool {
        await destinationActivator.activate(application)
    }

    static func groupedRepresentations(_ representations: [PasteboardRestoreRepresentation]) -> [[PasteboardRestoreRepresentation]] {
        let groups = Dictionary(grouping: representations, by: \.itemIndex)
        return groups.keys.sorted().compactMap { groups[$0] }
    }

    static func shouldSendPaste(hasDestination: Bool, destinationIsFrontmost: Bool) -> Bool {
        return hasDestination && destinationIsFrontmost
    }

    static func isValidDestination(processIdentifier: pid_t, isTerminated: Bool) -> Bool {
        processIdentifier > 0 && !isTerminated
    }

    /// Captures Workspace and Accessibility focus as one validation unit.
    /// Workspace is read before and after the AX calls; a change invalidates
    /// the snapshot rather than combining observations from two applications.
    static func readDestinationFocusSnapshot() -> DestinationFocusSnapshot {
        let workspaceApplication = NSWorkspace.shared.frontmostApplication
        let workspacePIDBefore = workspaceApplication?.processIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplication: CFTypeRef?
        let applicationError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplication
        )
        var axPID: pid_t?
        var acceptsTextInput: Bool?
        if applicationError == .success, let focusedApplication {
            let applicationElement = focusedApplication as! AXUIElement
            var processIdentifier: pid_t = 0
            if AXUIElementGetPid(applicationElement, &processIdentifier) == .success {
                axPID = processIdentifier
            }

            var focusedUIElement: CFTypeRef?
            let uiElementError = AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedUIElement
            )
            if uiElementError == .success, let focusedUIElement {
                var selectionRange: CFTypeRef?
                let selectionError = AXUIElementCopyAttributeValue(
                    focusedUIElement as! AXUIElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    &selectionRange
                )
                switch selectionError {
                case .success:
                    acceptsTextInput = true
                case .attributeUnsupported, .noValue:
                    acceptsTextInput = false
                default:
                    acceptsTextInput = nil
                }
            }
        }

        let workspacePIDAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard workspacePIDBefore == workspacePIDAfter else {
            return DestinationFocusSnapshot(
                workspaceApplication: nil,
                workspacePID: nil,
                axPID: axPID,
                acceptsTextInput: acceptsTextInput
            )
        }
        return DestinationFocusSnapshot(
            workspaceApplication: workspaceApplication,
            workspacePID: workspacePIDBefore,
            axPID: axPID,
            acceptsTextInput: acceptsTextInput
        )
    }

    private func waitForReadyFocus(application: NSRunningApplication) async -> Bool {
        let processIdentifier = application.processIdentifier
        for attempt in 0..<focusMaximumAttempts {
            guard !Task.isCancelled else { return false }
            guard Self.isValidDestination(
                processIdentifier: processIdentifier,
                isTerminated: isApplicationTerminated(application)
            ) else { return false }
            if focusReader().validates(processIdentifier: processIdentifier) {
                return true
            }
            if attempt + 1 < focusMaximumAttempts {
                await focusSleep(focusPollInterval)
            }
        }
        return false
    }

    static func postPasteEventPair(
        processIdentifier: pid_t,
        makeEvent: (PasteEventPhase) -> CGEvent? = { phase in
            CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: phase.isKeyDown)
        },
        postEvent: (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) }
    ) -> Bool {
        guard isValidDestination(processIdentifier: processIdentifier, isTerminated: false),
              let keyDown = makeEvent(.keyDown),
              let keyUp = makeEvent(.keyUp) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        postEvent(keyDown, processIdentifier)
        postEvent(keyUp, processIdentifier)
        return true
    }

    private static func logFocusMismatch(
        stage: String,
        intendedPID: pid_t,
        snapshot: DestinationFocusSnapshot
    ) {
        let workspacePID = snapshot.workspacePID.map(String.init) ?? "nil"
        let axPID = snapshot.axPID.map(String.init) ?? "nil"
        NSLog(
            "CopyCo paste focus mismatch stage=%@ intendedPID=%d workspacePID=%@ axPID=%@",
            stage,
            intendedPID,
            workspacePID,
            axPID
        )
    }

    private static func hasMissingFileURL(in representations: [PasteboardRestoreRepresentation]) -> Bool {
        representations.contains { representation in
            guard representation.uti == "public.file-url",
                  let value = String(data: representation.data, encoding: .utf8),
                  let url = URL(string: value),
                  url.isFileURL else {
                return false
            }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }
}
