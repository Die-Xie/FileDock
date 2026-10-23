import Foundation
import CoreGraphics

@main struct CornerPlacementTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let usable = CGRect(x: 0, y: 64, width: 1440, height: 798)
        let size = CGSize(width: 900, height: 480)
        let corners = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
        for corner in corners {
            let placement = check(corner, screen: screen, usable: usable, size: size)
            precondition(placement.bodyFrame.size == size)
            let body = placement.bodyFrame
            if corner.hasSuffix("Left") { near(body.minX, usable.minX + 8) }
            else { near(body.maxX, usable.maxX - 8) }
            if corner.hasPrefix("top") { near(body.maxY, usable.maxY - 8) }
            else { near(body.minY, usable.minY + 8) }
            let corridor = placement.keepAliveFrame
            precondition(corridor.width <= 54 && corridor.height <= 118,
                         "The bridge from a physical corner must remain local, rather than extending over the whole edge")
            precondition(!corridor.contains(CGPoint(x: body.midX, y: body.midY)),
                         "The keep-alive corridor does not replace the root's separate panel hit test")
            let opposite = CGPoint(x: corner.hasSuffix("Left") ? screen.maxX - 1 : screen.minX + 1,
                                   y: corner.hasPrefix("top") ? screen.maxY - 1 : screen.minY + 1)
            precondition(!corridor.contains(opposite), "The other end of the screen edge is not a keep-alive region")
        }

        // Side Dock and negative-coordinate displays use their own visible area.
        let external = screen.offsetBy(dx: -1920, dy: -350)
        for leftDock in [true, false] {
            let sideDock = CGRect(x: external.minX + (leftDock ? 86 : 0), y: external.minY,
                                  width: external.width - 86, height: external.height - 38)
            for corner in corners {
                let p = check(corner, screen: external, usable: sideDock, size: size)
                precondition(p.keepAliveFrame.width <= 140 && p.keepAliveFrame.height <= 92)
            }
        }
        // A small display clamps the body rather than placing its lower edge offscreen.
        let small = CGRect(x: -250, y: 100, width: 420, height: 240)
        for corner in corners {
            let p = check(corner, screen: small, usable: small, size: CGSize(width: 1800, height: 1200))
            near(p.bodyFrame.width, 404); near(p.bodyFrame.height, 224)
        }
        let tiny = CGRect(x: -1, y: -2, width: 10, height: 8)
        for corner in corners { _ = check(corner, screen: tiny, usable: tiny, size: .zero) }
        let minimum = check("topLeft", screen: screen, usable: usable, size: CGSize(width: -100, height: 1))
        near(minimum.bodyFrame.width, 600); near(minimum.bodyFrame.height, 300)
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            let fallback = check("bottomRight", screen: screen, usable: usable, size: CGSize(width: value, height: value))
            precondition(fallback.bodyFrame.size == CGSize(width: 900, height: 480))
        }
        let huge = check("topRight", screen: screen, usable: usable,
                         size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        near(huge.bodyFrame.width, usable.width - 16); near(huge.bodyFrame.height, usable.height - 16)
        precondition(HubCornerPlacement.make(corner: "notch", screenFrame: screen, visibleFrame: usable, requestedSize: size) == nil)
        precondition(HubCornerPlacement.make(corner: "unknown", screenFrame: screen, visibleFrame: usable, requestedSize: size) == nil)
        precondition(HubCornerPlacement.make(corner: "topLeft", screenFrame: screen,
                     visibleFrame: usable.offsetBy(dx: 1, dy: 0), requestedSize: size) == nil)
        let invalid: [CGRect] = [.zero, CGRect(x: 0, y: 0, width: -20, height: 20),
            CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
            CGRect(x: 0, y: CGFloat.infinity, width: 20, height: 20),
            CGRect(x: 0, y: 0, width: 20, height: CGFloat.infinity),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 20)]
        for frame in invalid {
            precondition(HubCornerPlacement.make(corner: "topLeft", screenFrame: frame, visibleFrame: usable, requestedSize: size) == nil)
            precondition(HubCornerPlacement.make(corner: "topLeft", screenFrame: screen, visibleFrame: frame, requestedSize: size) == nil)
        }
        print("PASS: all four corner placements, Dock gaps, negative displays, small screens and local keep-alive corridors")
    }

    private static func near(_ lhs: CGFloat, _ rhs: CGFloat) { precondition(abs(lhs - rhs) < 0.001) }

    private static func check(_ corner: String, screen: CGRect, usable: CGRect, size: CGSize) -> HubCornerPlacement {
        guard let placement = HubCornerPlacement.make(corner: corner, screenFrame: screen, visibleFrame: usable, requestedSize: size) else {
            preconditionFailure("Valid corner geometry unexpectedly failed")
        }
        let body = placement.bodyFrame, corridor = placement.keepAliveFrame
        precondition(body.width > 0 && body.height > 0 && usable.contains(body))
        precondition(screen.contains(corridor))
        let left = corner.hasSuffix("Left"), top = corner.hasPrefix("top")
        let triggerCenter = CGPoint(x: left ? screen.minX + min(18, screen.width) / 2 : screen.maxX - min(18, screen.width) / 2,
                                    y: top ? screen.maxY - min(12, screen.height) / 2 : screen.minY + min(12, screen.height) / 2)
        let entryWidth = min(32, body.width - 2 * min(14, body.width / 4))
        let entryHeight = min(32, body.height - 2 * min(14, body.height / 4))
        let entryCenter = CGPoint(x: left ? body.minX + min(14, body.width / 4) + entryWidth / 2 : body.maxX - min(14, body.width / 4) - entryWidth / 2,
                                  y: top ? body.maxY - min(14, body.height / 4) - entryHeight / 2 : body.minY + min(14, body.height / 4) + entryHeight / 2)
        precondition(corridor.contains(triggerCenter) && corridor.contains(entryCenter))
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let point = CGPoint(x: triggerCenter.x + (entryCenter.x - triggerCenter.x) * t,
                                y: triggerCenter.y + (entryCenter.y - triggerCenter.y) * t)
            precondition(corridor.contains(point), "Moving from trigger to panel corner must not cross a dismissal gap")
        }
        return placement
    }
}
