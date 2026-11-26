import XCTest
@testable import CopyCo

final class FocusedElementTextInputTests: XCTestCase {
    func testSecureTextFieldAcceptsPasteEvenWhenSelectionProbeIsUnsupported() {
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: "AXSecureTextField",
                selection: .selectionUnsupported
            ),
            true
        )
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: "AXSecureTextField",
                selection: .selectionUnavailable
            ),
            true
        )
    }

    func testOrdinaryTextRolesAcceptPasteWithoutSelectionSupport() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(
                FocusedElementTextInput.acceptsTextInput(
                    role: role,
                    selection: .selectionUnsupported
                ),
                true,
                "Expected \(role) to remain a paste target"
            )
        }
    }

    func testNonTextRoleWithUnsupportedSelectionIsNotAPasteTarget() {
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: "AXButton",
                selection: .selectionUnsupported
            ),
            false
        )
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: nil,
                selection: .selectionUnsupported
            ),
            false
        )
    }

    func testExplicitlyNonEditableElementIsRejectedEvenForTextRoles() {
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: "AXTextField",
                isEditable: false,
                selection: .supportsSelection
            ),
            false
        )
    }

    func testSelectionSuccessStillAcceptsWithoutRecognizedRole() {
        XCTAssertEqual(
            FocusedElementTextInput.acceptsTextInput(
                role: "AXCustomText",
                selection: .supportsSelection
            ),
            true
        )
    }

    func testFailedSelectionProbeStaysInconclusiveWithoutTextRole() {
        XCTAssertNil(
            FocusedElementTextInput.acceptsTextInput(
                role: nil,
                selection: .probeFailed
            )
        )
    }
}
