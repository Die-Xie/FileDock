import Foundation
import CoreGraphics

/// Tracks the pin acquired by detaching, separately from the user's own pin.
/// Programmatic placement, resizing and cursor-position presentation do not
/// call didDetach/didAttach; only a real drag and a top attachment do.
struct HubWindowAttachmentPolicy {
    private(set) var automaticallyPinned = false

    @discardableResult
    mutating func didDetach(currentlyPinned: Bool) -> Bool {
        // Repeated move notifications must not turn our own pin into a manual
        // one. A pre-existing user pin never becomes owned by this policy.
        if !currentlyPinned { automaticallyPinned = true }
        return true
    }

    mutating func didChangePin(_ pinned: Bool) {
        // Cancelling the automatic pin hands control back to the user. A
        // later manual re-pin must survive reattachment.
        if !pinned { automaticallyPinned = false }
    }

    @discardableResult
    mutating func didAttach(currentlyPinned: Bool) -> Bool {
        let result = automaticallyPinned ? false : currentlyPinned
        automaticallyPinned = false
        return result
    }

    /// Call at the end of a genuine header drag, never during mouse movement.
    /// A detached NSWindow is constrained below the menu bar, so its reachable
    /// attachment edge is the visible frame's top rather than the screen top.
    static func shouldReattach(frame: NSRect, screenVisibleFrame: NSRect, sourceWidth: CGFloat) -> Bool {
        guard valid(frame), valid(screenVisibleFrame) else { return false }
        let width = sourceWidth.isFinite && sourceWidth > 0 && sourceWidth <= screenVisibleFrame.width
            ? sourceWidth : min(186, screenVisibleFrame.width)
        let horizontalTolerance = max(48, width / 2)
        let horizontalDistance = abs(frame.midX - screenVisibleFrame.midX)
        let verticalDistance = abs(frame.maxY - screenVisibleFrame.maxY)
        return horizontalDistance.isFinite && verticalDistance.isFinite &&
            verticalDistance <= 24 && horizontalDistance <= horizontalTolerance
    }

    private static func valid(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.size.width.isFinite && frame.size.height.isFinite &&
            frame.size.width > 0 && frame.size.height > 0 &&
            frame.maxX.isFinite && frame.maxY.isFinite && frame.midX.isFinite
    }
}
