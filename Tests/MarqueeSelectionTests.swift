import AppKit
import SwiftUI

@main
struct MarqueeSelectionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let first = URL(fileURLWithPath: "/test/alpha.txt")
        let second = URL(fileURLWithPath: "/test/beta.txt")
        let other = URL(fileURLWithPath: "/test/elsewhere.txt")
        let frames = [first: CGRect(x: 20, y: 20, width: 35, height: 35),
                      second: CGRect(x: 70, y: 20, width: 35, height: 35)]
        let view = HubMarqueeSelectionBridge.SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        parent.addSubview(view)
        let context = HubFileDragContext(workspaceID: UUID(), directory: URL(fileURLWithPath: "/test"))
        var selection: Set<URL> = [other]
        var changes = 0
        func configure(_ current: HubFileDragContext = context) {
            view.configure(context: current, frames: frames, selection: selection) { selection = $0; changes += 1 }
        }
        configure()
        precondition(!view.mouseDownCanMoveWindow && view.isFlipped)
        precondition(view.acceptsBlankPoint(CGPoint(x: 5, y: 5)))
        precondition(!view.acceptsBlankPoint(CGPoint(x: 25, y: 25)), "File cells must retain their native drag responder")
        precondition(!view.acceptsBlankPoint(CGPoint(x: 205, y: 25)))
        view.beginSelection(at: CGPoint(x: 5, y: 5), modifiers: [])
        precondition(selection.isEmpty && HubMarqueeSelectionState.isSelecting)
        view.updateSelection(to: CGPoint(x: 60, y: 60))
        precondition(selection == [first])
        view.updateSelection(to: CGPoint(x: 110, y: 60))
        precondition(selection == [first, second])
        let before = changes
        view.updateSelection(to: CGPoint(x: 110, y: 60))
        precondition(changes == before, "Identical drag updates must not republish the selected set")
        HubMarqueeSelectionState.cancel()
        precondition(selection == [other] && view.selectionRectangle == nil && !HubMarqueeSelectionState.isSelecting,
                     "Escape restores the selection captured before blank mouseDown")

        configure()
        view.beginSelection(at: CGPoint(x: 110, y: 60), modifiers: .shift)
        view.updateSelection(to: CGPoint(x: 5, y: 5))
        precondition(selection == [first, second, other], "Reverse-direction Shift drag adds to the baseline")
        view.endSelection(restore: false)
        configure()
        view.beginSelection(at: CGPoint(x: 5, y: 5), modifiers: .command)
        view.updateSelection(to: CGPoint(x: 60, y: 60))
        precondition(selection == [second, other], "Command drag toggles hits relative to the original selection")
        view.endSelection(restore: false)

        configure()
        view.beginSelection(at: CGPoint(x: 5, y: 5), modifiers: [])
        view.updateSelection(to: CGPoint(x: 1000, y: 1000))
        precondition(view.selectionRectangle?.maxX == 200 && view.selectionRectangle?.maxY == 120,
                     "The rectangle remains inside the file viewport when dragging beyond its edge")
        precondition(selection == [first, second])
        selection = []
        configure(HubFileDragContext(workspaceID: UUID(), directory: nil))
        precondition(!HubMarqueeSelectionState.isSelecting && selection.isEmpty,
                     "Changing location ends the old gesture without restoring a different workspace's selection")
        view.updateSelection(to: CGPoint(x: 50, y: 50))
        precondition(selection.isEmpty)

        parent.clipsToBounds = true
        parent.frame.size.width = 80
        precondition(!view.acceptsBlankPoint(CGPoint(x: 130, y: 80)), "Clipped regions must not start an invisible marquee")
        precondition(HubMarqueeSelectionMath.selected(in: CGRect(x: 0, y: 0, width: 20, height: 20),
            frames: frames, baseline: [], modifiers: []).isEmpty, "Touching an edge without overlap does not select an item")
        view.removeFromSuperview()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 500))
        root.addSubview(scroll)
        let overlay = HubMarqueeSelectionBridge.SelectionView(frame: root.bounds)
        root.addSubview(overlay)
        overlay.configure(context: context, frames: [:], selection: [], setSelection: { _ in })
        scroll.tile()
        let scroller = scroll.verticalScroller!
        let scrollerPoint = scroller.convert(CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: root)
        precondition(overlay.hitTest(scrollerPoint) == nil, "The real scroll bar beneath the overlay must keep its mouse clicks")
        let blankPoint = overlay.convert(CGPoint(x: 10, y: 10), to: root)
        precondition(overlay.hitTest(blankPoint) === overlay, "Native blank hit-testing must find the marquee responder")
        precondition(!window.isVisible, "Native hit-routing tests must not display a window")
        print("PASS: blank-only marquee, forward/reverse intersections, additive/toggle selection, escape restoration, bounded viewport, no duplicate publications and location isolation")
        print("LIMIT: Native blank-drag routing and file-drag coexistence require pointer verification; tests do not generate user input")
    }
}
