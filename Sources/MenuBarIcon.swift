import AppKit

/// An 18pt template mark: a folder resting in a dock. AppKit supplies menu-bar
/// contrast; the path remains crisp at either backing scale without a gear badge.
@MainActor enum FileDockMenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 3, y: 6))
            folder.line(to: NSPoint(x: 3, y: 13))
            folder.curve(to: NSPoint(x: 4.5, y: 14.5), controlPoint1: NSPoint(x: 3, y: 14), controlPoint2: NSPoint(x: 3.5, y: 14.5))
            folder.line(to: NSPoint(x: 7, y: 14.5))
            folder.line(to: NSPoint(x: 8.5, y: 12.5))
            folder.line(to: NSPoint(x: 13.5, y: 12.5))
            folder.curve(to: NSPoint(x: 15, y: 11), controlPoint1: NSPoint(x: 14.5, y: 12.5), controlPoint2: NSPoint(x: 15, y: 12))
            folder.line(to: NSPoint(x: 15, y: 6))
            folder.line(to: NSPoint(x: 3, y: 6))
            folder.lineWidth = 1.4; folder.lineJoinStyle = .round; folder.lineCapStyle = .round; folder.stroke()
            let dock = NSBezierPath()
            dock.move(to: NSPoint(x: 2, y: 5))
            dock.line(to: NSPoint(x: 2, y: 3.5))
            dock.curve(to: NSPoint(x: 3, y: 2), controlPoint1: NSPoint(x: 2, y: 2.5), controlPoint2: NSPoint(x: 2, y: 2))
            dock.line(to: NSPoint(x: 15, y: 2))
            dock.curve(to: NSPoint(x: 16, y: 3.5), controlPoint1: NSPoint(x: 16, y: 2), controlPoint2: NSPoint(x: 16, y: 2.5))
            dock.line(to: NSPoint(x: 16, y: 5))
            dock.lineWidth = 1.4; dock.lineJoinStyle = .round; dock.lineCapStyle = .round; dock.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FileDock"
        return image
    }
}
