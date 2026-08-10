import ApplicationServices

enum AccessibilityPermission {
    static func isTrusted() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
