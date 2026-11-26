import XCTest
@testable import CopyCo

final class SecureEventInputTests: XCTestCase {
    func testTransitionPublishesOnlyWhenValueChanges() {
        XCTAssertNil(SecureEventInputMonitor.transition(previous: nil, current: false))
        XCTAssertEqual(SecureEventInputMonitor.transition(previous: nil, current: true), true)
        XCTAssertEqual(SecureEventInputMonitor.transition(previous: false, current: true), true)
        XCTAssertNil(SecureEventInputMonitor.transition(previous: true, current: true))
        XCTAssertEqual(SecureEventInputMonitor.transition(previous: true, current: false), false)
    }

    func testIsEnabledUsesInjectedProbe() {
        XCTAssertTrue(SecureEventInput.isEnabled(probe: { true }))
        XCTAssertFalse(SecureEventInput.isEnabled(probe: { false }))
    }
}
