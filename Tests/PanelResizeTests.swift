import AppKit

@main struct PanelResizeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let logical = CGRect(x: -900, y: -400, width: 900, height: 500)
        let minimum = CGSize(width: 600, height: 300), maximum = CGSize(width: 1600, height: 1100)
        precondition(HubPanelResizeGeometry.edges(at: CGPoint(x: logical.minX, y: logical.minY), in: logical).isEmpty, "Transparent rounded corners must not resize")
        precondition(HubPanelResizeGeometry.edges(at: CGPoint(x: logical.minX + 6, y: logical.minY + 6), in: logical) == [.left, .bottom])
        precondition(HubPanelResizeGeometry.edges(at: CGPoint(x: logical.midX, y: logical.midY), in: logical).isEmpty)
        precondition(HubPanelResizeGeometry.edges(at: CGPoint(x: logical.minX - 20, y: logical.midY), in: logical).isEmpty)
        let floating = HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: -40, y: -30), edges: [.left, .bottom], anchor: .oppositeEdge, minimum: minimum, maximum: maximum)
        precondition(floating.maxX == logical.maxX && floating.maxY == logical.maxY && floating.size == CGSize(width: 940, height: 530))
        let notch = HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: 40, y: -30), edges: [.right, .bottom], anchor: .topCenter, minimum: minimum, maximum: maximum)
        precondition(notch.midX == logical.midX && notch.maxY == logical.maxY && notch.size == CGSize(width: 980, height: 530))
        for (anchor, x, y) in [(HubPanelResizeAnchor.topLeft, logical.minX, logical.maxY), (.topRight, logical.maxX, logical.maxY), (.bottomLeft, logical.minX, logical.minY), (.bottomRight, logical.maxX, logical.minY)] {
            let frame = HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: 70, y: 80), edges: [.right, .top], anchor: anchor, minimum: minimum, maximum: maximum)
            precondition((anchor == .topLeft || anchor == .bottomLeft ? frame.minX : frame.maxX) == x)
            precondition((anchor == .topLeft || anchor == .topRight ? frame.maxY : frame.minY) == y)
        }
        let large = HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: 1e20, y: -1e20), edges: [.right, .bottom], anchor: .topCenter, minimum: minimum, maximum: maximum)
        precondition(large.size == maximum && large.midX == logical.midX && large.maxY == logical.maxY)
        let small = HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: -1e20, y: 1e20), edges: [.right, .bottom], anchor: .oppositeEdge, minimum: minimum, maximum: maximum)
        precondition(small.size == minimum && small.minX == logical.minX && small.maxY == logical.maxY)
        precondition(HubPanelResizeGeometry.frame(initial: logical, delta: CGPoint(x: CGFloat.nan, y: 0), edges: [.right], anchor: .topCenter, minimum: minimum, maximum: maximum) == logical)
        interaction()
        cursorTracking()
        print("PASS: logical-edge hit routing, native-canvas offsets, negative display origins, anchored/opposite-edge bounds, size limits, cancel, lost mouse-up and teardown lifecycle")
        print("PASS: passive cursor tracking uses the same inner 5pt/corner geometry, allowed edges, clipping, drag exclusion and native-cursor restoration")
        print("LIMIT: hidden host receives direct test events; actual WindowServer edge dragging requires installed UI validation")
    }

    @MainActor private static func cursorTracking() {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 920, height: 512), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HubPanelResizeHandle(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = handle
        defer { handle.clearCursor(); window.contentView = nil; window.close() }
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        let body = CGRect(x: 26, y: 12, width: 868, height: 500)
        handle.logicalBounds = body
        var allowed: HubPanelResizeEdges = [.left, .right, .bottom], pressed = false, policyReads = 0
        handle.cursorAllowedEdges = { policyReads += 1; return allowed }
        handle.mousePressed = { pressed }
        handle.updateTrackingAreas()
        handle.updateTrackingAreas()
        let tracking = handle.trackingAreas.filter { $0.owner === handle }
        precondition(window.acceptsMouseMovedEvents && tracking.count == 1)
        precondition(tracking[0].options.contains([.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect]) && !tracking[0].options.contains(.enabledDuringMouseDrag))
        let edge = CGPoint(x: body.maxX - 5, y: body.midY), center = CGPoint(x: body.midX, y: body.midY)
        for _ in 0..<250 { precondition(handle.cursorEdges(at: center).isEmpty) }
        precondition(policyReads == 0, "Ordinary movement over content cannot traverse modal/editing resize policy")
        precondition(handle.cursorEdges(at: edge) == [.right], "An inner 5pt edge must show the resize cursor")
        precondition(handle.cursorEdges(at: CGPoint(x: edge.x - 0.1, y: edge.y)).isEmpty, "Interior controls beyond the hit band retain their cursor")
        precondition(handle.cursorEdges(at: CGPoint(x: body.midX, y: body.maxY - 1)).isEmpty, "An anchored top edge must not promise resizing")
        precondition(handle.cursorEdges(at: CGPoint(x: body.maxX - 7, y: body.minY + 7)) == [.right, .bottom], "Rounded corner cursor and resize geometry must agree")
        precondition(handle.cursorEdges(at: body.origin).isEmpty && handle.cursorEdges(at: CGPoint(x: 1, y: body.midY)).isEmpty)
        func moved(_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        }
        NSCursor.iBeam.set()
        handle.mouseMoved(with: moved(edge))
        precondition(NSCursor.current !== NSCursor.iBeam, "Passive tracking must update the current cursor without claiming hover hit testing")
        handle.currentEvent = { moved(edge) }
        precondition(handle.hitTest(edge) == nil && handle.registeredDraggedTypes.isEmpty)
        handle.mouseMoved(with: moved(center))
        precondition(NSCursor.current === NSCursor.iBeam, "Leaving the band restores the prior native cursor")
        handle.mouseMoved(with: moved(edge))
        NSCursor.pointingHand.set()
        handle.mouseMoved(with: moved(center))
        precondition(NSCursor.current === NSCursor.pointingHand, "A native control that already changed the cursor must retain ownership")
        allowed = [.bottom]
        precondition(handle.cursorEdges(at: edge).isEmpty)
        allowed = .all; pressed = true
        precondition(handle.cursorEdges(at: edge).isEmpty, "An external file drag must retain its drag cursor")
        pressed = false
        handle.mouseMoved(with: moved(edge))
        handle.clearCursor()
        let restored = NSCursor.current
        let deadline = Date().addingTimeInterval(0.02)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        precondition(NSCursor.current === restored, "A deferred cursor update cannot reappear after a clear/exit")
        handle.mouseMoved(with: moved(edge))
        window.close()
        precondition(NSCursor.current === restored, "Closing without a resize session still clears a hover cursor")

        let container = NSView(frame: handle.frame)
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container
        container.addSubview(clip); clip.documentView = handle
        precondition(!handle.visibleRect.contains(edge) && handle.cursorEdges(at: edge).isEmpty, "Clipped edges cannot advertise resize outside the visible view")
    }

    @MainActor private static func interaction() {
        let initial = CGRect(x: 100, y: 200, width: 900, height: 500)
        let outer = HubNotchMotion.extensionWindowFrame(for: initial, enabled: true)
        let window = NSWindow(contentRect: outer, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HubPanelResizeHandle(frame: CGRect(origin: .zero, size: outer.size))
        window.contentView = handle
        defer { window.contentView = nil; window.close() }
        handle.logicalBounds = HubNotchMotion.extensionRestingBounds(in: handle.bounds, enabled: true)
        var allowed = true, begins = 0, ends = 0
        var injected: NSEvent?
        handle.currentEvent = { injected }
        handle.configuration = { _ in
            allowed ? HubPanelResizeConfiguration(frame: HubNotchMotion.extensionRestingBounds(in: window.frame, enabled: true), anchor: .topCenter) : nil
        }
        handle.didBegin = { begins += 1 }
        handle.didEnd = { ends += 1 }
        handle.resizeFrame = { frame in
            window.setFrame(HubNotchMotion.extensionWindowFrame(for: frame, enabled: true), display: false)
            handle.logicalBounds = HubNotchMotion.extensionRestingBounds(in: handle.bounds, enabled: true)
        }
        func event(_ type: NSEvent.EventType, at screenPoint: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func currentFrame() -> CGRect { HubNotchMotion.extensionRestingBounds(in: window.frame, enabled: true) }
        func begin() -> CGPoint {
            let frame = currentFrame(), point = CGPoint(x: frame.maxX - 6, y: frame.minY + 6)
            injected = event(.leftMouseDown, at: point)
            let local = window.convertPoint(fromScreen: point)
            precondition(handle.hitTest(local) === handle)
            handle.mouseDown(with: injected!)
            precondition(handle.isResizing && HubPanelResizeState.isResizing)
            return point
        }
        let point = CGPoint(x: initial.maxX - 6, y: initial.minY + 6)
        injected = nil
        precondition(handle.hitTest(window.convertPoint(fromScreen: point)) == nil, "A hit-test probe without a mouse press must pass through")
        precondition(handle.registeredDraggedTypes.isEmpty, "The resize handle must not compete with native file drop destinations")
        injected = event(.leftMouseDragged, at: point)
        precondition(handle.hitTest(window.convertPoint(fromScreen: point)) == nil, "External dragging cannot claim a resize edge")
        injected = event(.leftMouseDown, at: point, flags: .control)
        precondition(handle.hitTest(window.convertPoint(fromScreen: point)) == nil)
        injected = event(.leftMouseDown, at: point); allowed = false
        precondition(handle.hitTest(window.convertPoint(fromScreen: point)) == nil, "Modal/file-drag policy can reject a local press")
        allowed = true
        var start = begin()
        handle.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y - 20)))
        precondition(currentFrame().size == CGSize(width: 960, height: 520) && currentFrame().midX == initial.midX && currentFrame().maxY == initial.maxY)
        handle.mouseUp(with: event(.leftMouseUp, at: start))
        precondition(begins == 1 && ends == 1 && !HubPanelResizeState.isResizing)
        let beforeCancel = currentFrame()
        start = begin()
        handle.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y - 20)))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        handle.keyDown(with: escape)
        precondition(currentFrame() == beforeCancel && begins == 2 && ends == 2)
        _ = begin(); handle.reconcile(mousePressed: false); handle.reconcile(mousePressed: false)
        precondition(begins == 3 && ends == 3 && !handle.isResizing)
        _ = begin(); window.contentView = nil
        precondition(begins == 4 && ends == 4 && !HubPanelResizeState.isResizing)
        window.contentView = handle
        _ = begin(); window.close()
        precondition(begins == 5 && ends == 5 && !HubPanelResizeState.isResizing, "Closing a retained window must end the resize without waiting for mouse up")
    }
}
