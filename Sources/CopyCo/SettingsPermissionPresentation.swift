import Foundation

enum SettingsPermissionPresentation {
    static func shouldShowWarning(isTrusted: Bool) -> Bool {
        !isTrusted
    }
}
