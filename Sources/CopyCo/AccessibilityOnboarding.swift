import Foundation

enum AccessibilityOnboarding {
    static let promptShownKey = "CopyCo.accessibilityPromptShown"

    static func shouldPresent(isTrusted: Bool, hasShownPrompt: Bool) -> Bool {
        !isTrusted && !hasShownPrompt
    }
}
