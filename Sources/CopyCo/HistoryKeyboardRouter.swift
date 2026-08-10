import AppKit
import Combine
import CopyCoCore

@MainActor
final class HistoryKeyboardRouter: ObservableObject {
    enum ScrollAlignment: Equatable {
        case top
        case nearest
    }

    struct ScrollRequest: Equatable {
        let sequence: Int
        let target: ClipboardItem.ID
        let alignment: ScrollAlignment
        let animated: Bool
    }

    enum FocusTarget: Equatable {
        case content
        case delete
        case pin
    }

    enum Direction {
        case up
        case down
    }

    enum Command: Equatable {
        case up
        case down
        case left
        case right
        case paste
        case togglePin
        case delete
        case dismiss
    }

    @Published var selection: ClipboardItem.ID?
    @Published var focusTarget: FocusTarget = .content
    @Published private(set) var scrollRequest: ScrollRequest?
    @Published private(set) var searchFocusRequestSequence = 0

    private var items: [ClipboardItem] = []
    private var pendingDeletion: (id: ClipboardItem.ID, index: Int)?
    private var nextScrollRequestSequence = 0
    var onPaste: ((ClipboardItem) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onSelectionNavigation: (() -> Void)?

    func update(items: [ClipboardItem], resetSelection: Bool = false) {
        if resetSelection {
            prepareForPresentation(items: items)
            return
        }
        self.items = items
        let identifiers = items.map(\.id)
        if let pendingDeletion {
            if identifiers.contains(pendingDeletion.id) {
                self.pendingDeletion = nil
            } else {
                selection = identifiers.isEmpty ? nil : identifiers[min(pendingDeletion.index, identifiers.count - 1)]
                self.pendingDeletion = nil
                focusTarget = .content
            }
        } else if selection == nil || !identifiers.contains(selection!) {
            selection = identifiers.first
            focusTarget = .content
        }
        if identifiers.isEmpty {
            scrollRequest = nil
        }
    }

    func prepareForPresentation(items: [ClipboardItem]) {
        searchFocusRequestSequence += 1
        self.items = items
        pendingDeletion = nil
        selection = items.first?.id
        focusTarget = .content
        if let selection {
            requestScroll(to: selection, alignment: .top, animated: false)
        } else {
            scrollRequest = nil
        }
    }

    /// Requests search-field focus. Used when the search field lost focus (for
    /// example after Up/Down switched to list mode) and the user starts typing
    /// again: typing automatically returns to the search field.
    func refocusSearch() {
        searchFocusRequestSequence += 1
    }

    func prepareForDeletion(of item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        pendingDeletion = (item.id, index)
    }

    func route(_ event: NSEvent) -> Bool {
        guard let command = Self.command(for: event.keyCode) else { return false }
        switch command {
        case .up:
            moveSelection(direction: .up)
            focusTarget = .content
            onSelectionNavigation?()
            return true
        case .down:
            moveSelection(direction: .down)
            focusTarget = .content
            onSelectionNavigation?()
            return true
        case .left:
            guard selectedItem != nil else { return false }
            focusTarget = Self.previousFocusTarget(from: focusTarget)
            return true
        case .right:
            guard selectedItem != nil else { return false }
            focusTarget = Self.nextFocusTarget(from: focusTarget)
            return true
        case .paste:
            guard let item = selectedItem else { return false }
            switch focusTarget {
            case .content:
                onPaste?(item)
            case .delete:
                prepareForDeletion(of: item)
                onDelete?(item)
            case .pin:
                onTogglePin?(item)
            }
            return true
        case .togglePin:
            guard let item = selectedItem else { return false }
            onTogglePin?(item)
            return true
        case .delete:
            guard let item = selectedItem else { return false }
            prepareForDeletion(of: item)
            onDelete?(item)
            return true
        case .dismiss:
            onDismiss?()
            return true
        }
    }

    static func command(for keyCode: UInt16) -> Command? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .paste
        case 49: .togglePin
        case 51, 117: .delete
        case 53: .dismiss
        default: nil
        }
    }

    static func shouldRoute(command: Command, searchFieldFocused: Bool) -> Bool {
        guard searchFieldFocused else { return true }
        switch command {
        case .left, .right, .togglePin, .delete:
            return false
        case .up, .down, .paste, .dismiss:
            return true
        }
    }

    static func nextSelection(current: ClipboardItem.ID?, in identifiers: [ClipboardItem.ID], direction: Direction) -> ClipboardItem.ID? {
        guard !identifiers.isEmpty else { return nil }
        guard let current, let index = identifiers.firstIndex(of: current) else {
            return direction == .down ? identifiers.first : identifiers.last
        }
        switch direction {
        case .up:
            return identifiers[max(0, index - 1)]
        case .down:
            return identifiers[min(identifiers.count - 1, index + 1)]
        }
    }

    static func nextFocusTarget(from target: FocusTarget) -> FocusTarget {
        switch target {
        case .content: .delete
        case .delete: .pin
        case .pin: .pin
        }
    }

    static func previousFocusTarget(from target: FocusTarget) -> FocusTarget {
        switch target {
        case .content: .content
        case .delete: .content
        case .pin: .delete
        }
    }

    private var selectedItem: ClipboardItem? {
        items.first { $0.id == selection }
    }

    private func moveSelection(direction: Direction) {
        let next = Self.nextSelection(current: selection, in: items.map(\.id), direction: direction)
        guard next != selection else { return }
        selection = next
        if let next {
            requestScroll(to: next, alignment: .nearest, animated: true)
        }
    }

    private func requestScroll(to target: ClipboardItem.ID, alignment: ScrollAlignment, animated: Bool) {
        nextScrollRequestSequence += 1
        scrollRequest = ScrollRequest(
            sequence: nextScrollRequestSequence,
            target: target,
            alignment: alignment,
            animated: animated
        )
    }
}
