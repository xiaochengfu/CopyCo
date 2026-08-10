import AppKit
import XCTest
@testable import CopyCo

final class StatusItemIconTests: XCTestCase {
    func testStatusItemIconIsTemplateSizedAndNamed() {
        let image = CopyCoStatusItemIcon.make()

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "CopyCo")
    }
}
