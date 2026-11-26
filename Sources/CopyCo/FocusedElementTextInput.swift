import Foundation

/// Classifies whether a focused Accessibility element should be treated as a
/// paste destination. Secure password fields often refuse
/// `kAXSelectedTextRangeAttribute` for privacy, so role (and optional
/// editable) checks must win over a bare "selection unsupported" result.
enum FocusedElementTextInput {
    enum SelectionProbe: Sendable, Equatable {
        case supportsSelection
        case selectionUnsupported
        case selectionUnavailable
        case probeFailed
    }

    /// AX roles that accept typed or pasted text, including password fields.
    static let textInputRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSecureTextField",
        "AXComboBox",
        "AXSearchField"
    ]

    /// - Parameters:
    ///   - role: Accessibility role string (`kAXRoleAttribute`), if available.
    ///   - isEditable: `kAXIsEditableAttribute` when the element exposes it.
    ///   - selection: Result of probing `kAXSelectedTextRangeAttribute`.
    /// - Returns: `true`/`false` when confident; `nil` when AX is inconclusive.
    static func acceptsTextInput(
        role: String?,
        isEditable: Bool? = nil,
        selection: SelectionProbe
    ) -> Bool? {
        if isEditable == false {
            return false
        }

        if let role, textInputRoles.contains(role) {
            return true
        }

        switch selection {
        case .supportsSelection:
            return true
        case .selectionUnsupported, .selectionUnavailable:
            return false
        case .probeFailed:
            return nil
        }
    }
}
