import AppKit

enum CopyCoStatusItemIcon {
    private static let size = NSSize(width: 18, height: 18)

    /// Renders through a drawing handler so the bitmap is created at the
    /// backing scale (crisp on Retina) instead of a fixed 1x lockFocus bitmap.
    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let outer = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 15),
                xRadius: 5.5,
                yRadius: 5.5
            )
            let inner = NSBezierPath(
                roundedRect: NSRect(x: 5.5, y: 5, width: 14, height: 8),
                xRadius: 3.5,
                yRadius: 3.5
            )
            outer.append(inner)
            outer.windingRule = .evenOdd

            NSColor.white.setFill()
            outer.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CopyCo"
        return image
    }
}
