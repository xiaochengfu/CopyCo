import XCTest
@testable import CopyCo

final class AccessibilityOnboardingTests: XCTestCase {
    func testPromptAppearsOnlyForUntrustedFirstLaunch() {
        XCTAssertTrue(AccessibilityOnboarding.shouldPresent(isTrusted: false, hasShownPrompt: false))
        XCTAssertFalse(AccessibilityOnboarding.shouldPresent(isTrusted: false, hasShownPrompt: true))
        XCTAssertFalse(AccessibilityOnboarding.shouldPresent(isTrusted: true, hasShownPrompt: false))
    }
}
