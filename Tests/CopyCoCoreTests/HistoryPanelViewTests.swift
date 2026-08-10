import AppKit
import SwiftUI
import XCTest
@testable import CopyCo

final class HistoryPanelViewTests: XCTestCase {
    func testMetadataLabelsSeparateSourceFromContentKind() {
        XCTAssertEqual(
            HistoryMetadataLabels.make(sourceName: "Google Chrome", kind: "富文本"),
            ["Google Chrome", "·", "富文本"]
        )
        XCTAssertEqual(
            HistoryMetadataLabels.make(sourceName: nil, kind: "文本"),
            ["文本"]
        )
    }

    @MainActor
    func testWideImageThumbnailDoesNotDrawOutsideItsFixedSlot() throws {
        let wideImage = NSImage(size: NSSize(width: 200, height: 40), flipped: false) { bounds in
            NSColor.systemRed.setFill()
            bounds.fill()
            return true
        }
        let content = ZStack {
            Color.green
            HistoryThumbnail(image: wideImage, symbolName: "photo")
        }
        .frame(width: 100, height: 60)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 100, height: 60)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let outside = try deviceRGBColor(in: bitmap, viewPoint: CGPoint(x: 5, y: 30), viewSize: hostingView.bounds.size)
        let inside = try deviceRGBColor(in: bitmap, viewPoint: CGPoint(x: 50, y: 30), viewSize: hostingView.bounds.size)

        XCTAssertGreaterThan(outside.greenComponent, outside.redComponent)
        XCTAssertGreaterThan(inside.redComponent, inside.greenComponent)
    }

    private func deviceRGBColor(in bitmap: NSBitmapImageRep, viewPoint: CGPoint, viewSize: CGSize) throws -> NSColor {
        let pixelX = Int(viewPoint.x * CGFloat(bitmap.pixelsWide) / viewSize.width)
        let pixelY = Int(viewPoint.y * CGFloat(bitmap.pixelsHigh) / viewSize.height)
        let color = try XCTUnwrap(bitmap.colorAt(x: pixelX, y: pixelY))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    }
}
