import Carbon.HIToolbox
import XCTest
@testable import CopyCo

final class HotKeyConfigurationTests: XCTestCase {
    func testDefaultShortcutRemainsOptionCommandC() {
        XCTAssertEqual(HotKeyConfiguration.default.keyCode, 8)
        XCTAssertEqual(HotKeyConfiguration.default.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(HotKeyConfiguration.default.displayName, "⌥⌘C")
    }

    func testKeyNameUsesReadableSpecialKeyLabels() {
        XCTAssertEqual(HotKeyConfiguration.keyName(for: 36), "↩")
        XCTAssertEqual(HotKeyConfiguration.keyName(for: 126), "↑")
    }
}
