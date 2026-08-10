import XCTest
@testable import CopyCo

final class SettingsPermissionPresentationTests: XCTestCase {
    func testWarningShowsOnlyWhenAccessibilityIsUntrusted() {
        XCTAssertTrue(SettingsPermissionPresentation.shouldShowWarning(isTrusted: false))
        XCTAssertFalse(SettingsPermissionPresentation.shouldShowWarning(isTrusted: true))
    }
}
