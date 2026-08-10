import AppKit
import ApplicationServices
import CopyCoCore
import Foundation

enum PasteResult: Sendable, Equatable {
    case pasted
    case copiedOnly
    case failed(message: String)
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
        yieldActivation(application)
        _ = requestActivation(application)

        for _ in 0..<maximumAttempts {
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

    init(
        historyStore: HistoryStore,
        pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: @escaping () -> Bool = AccessibilityPermission.isTrusted,
        destinationActivator: DestinationApplicationActivator = DestinationApplicationActivator()
    ) {
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.destinationActivator = destinationActivator
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
        let destinationIsFrontmost = await destinationActivator.activate(application)
        guard Self.shouldSendPaste(hasDestination: true, destinationIsFrontmost: destinationIsFrontmost) else {
            return .failed(message: "Copied to the clipboard, but the destination application could not be activated.")
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return .failed(message: "Unable to create the paste keyboard event.")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }

    static func groupedRepresentations(_ representations: [PasteboardRestoreRepresentation]) -> [[PasteboardRestoreRepresentation]] {
        let groups = Dictionary(grouping: representations, by: \.itemIndex)
        return groups.keys.sorted().compactMap { groups[$0] }
    }

    static func shouldSendPaste(hasDestination: Bool, destinationIsFrontmost: Bool) -> Bool {
        return hasDestination && destinationIsFrontmost
    }

    /// Checks whether the frontmost application's focused element accepts text
    /// input (i.e. Command-V can paste into it). Returns `nil` when the check
    /// is inconclusive — no Accessibility permission, API errors — so callers
    /// can proceed as before.
    ///
    /// Must be called while the target application is still frontmost (before
    /// the panel activates CopyCo), because AX focus only exists for the
    /// frontmost application.
    static func frontmostApplicationAcceptsTextInput() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplication: CFTypeRef?
        let applicationError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplication
        )
        guard applicationError == .success, let applicationElement = focusedApplication else {
            return nil
        }

        var focusedUIElement: CFTypeRef?
        let uiElementError = AXUIElementCopyAttributeValue(
            applicationElement as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedUIElement
        )
        guard uiElementError == .success, let focusedElement = focusedUIElement else {
            return nil
        }

        // Text inputs expose a selected-text range; non-editable elements
        // (buttons, file lists, static text, the desktop) do not.
        var selectionRange: CFTypeRef?
        let selectionError = AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionRange
        )
        switch selectionError {
        case .success:
            return true
        case .attributeUnsupported, .noValue:
            return false
        default:
            return nil
        }
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
