import AppKit

struct HubPanelResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)
    static let all: Self = [.left, .right, .bottom, .top]
}

enum HubPanelResizeAnchor: Equatable { case oppositeEdge, topCenter, topLeft, topRight, bottomLeft, bottomRight }

enum HubPanelResizeGeometry {
    static func edges(at point: CGPoint, in bounds: CGRect, band: CGFloat = 5, radius: CGFloat = 21) -> HubPanelResizeEdges {
        guard point.x.isFinite, point.y.isFinite, valid(bounds), band.isFinite, band > 0,
              bounds.insetBy(dx: -2, dy: -2).contains(point) else { return [] }
        let r = radius.isFinite ? min(max(0, radius), bounds.width / 2, bounds.height / 2) : 0
        let qx = abs(point.x - bounds.midX) - bounds.width / 2 + r
        let qy = abs(point.y - bounds.midY) - bounds.height / 2 + r
        let distance = sqrt(pow(max(qx, 0), 2) + pow(max(qy, 0), 2)) + min(max(qx, qy), 0) - r
        guard distance >= -band, distance <= 2 else { return [] }
        var edges: HubPanelResizeEdges = []
        if point.x <= bounds.minX + max(band, r) { edges.insert(.left) }
        if point.x >= bounds.maxX - max(band, r) { edges.insert(.right) }
        if point.y <= bounds.minY + max(band, r) { edges.insert(.bottom) }
        if point.y >= bounds.maxY - max(band, r) { edges.insert(.top) }
        return edges
    }

    static func frame(initial: CGRect, delta: CGPoint, edges: HubPanelResizeEdges,
                      anchor: HubPanelResizeAnchor, minimum: CGSize, maximum: CGSize) -> CGRect {
        guard valid(initial), delta.x.isFinite, delta.y.isFinite,
              minimum.width.isFinite, minimum.height.isFinite, maximum.width.isFinite, maximum.height.isFinite,
              minimum.width > 0, minimum.height > 0, maximum.width >= minimum.width, maximum.height >= minimum.height else { return initial }
        let dx: CGFloat = edges.contains(.right) ? delta.x : edges.contains(.left) ? -delta.x : 0
        let dy: CGFloat = edges.contains(.top) ? delta.y : edges.contains(.bottom) ? -delta.y : 0
        let width = min(maximum.width, max(minimum.width, initial.width + dx * (anchor == .topCenter ? 2 : 1)))
        let height = min(maximum.height, max(minimum.height, initial.height + dy))
        let x: CGFloat, y: CGFloat
        switch anchor {
        case .topCenter: x = initial.midX - width / 2; y = initial.maxY - height
        case .topLeft: x = initial.minX; y = initial.maxY - height
        case .topRight: x = initial.maxX - width; y = initial.maxY - height
        case .bottomLeft: x = initial.minX; y = initial.minY
        case .bottomRight: x = initial.maxX - width; y = initial.minY
        case .oppositeEdge:
            x = edges.contains(.left) ? initial.maxX - width : initial.minX
            y = edges.contains(.bottom) ? initial.maxY - height : initial.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
    }
}

struct HubPanelResizeConfiguration {
    var frame: CGRect
    var anchor: HubPanelResizeAnchor = .oppositeEdge
    var minimum = CGSize(width: 600, height: 300)
    var maximum = CGSize(width: 1600, height: 1100)
    var allowedEdges: HubPanelResizeEdges = .all
}

@MainActor enum HubPanelResizeState {
    static weak var activeHandle: HubPanelResizeHandle?
    static var isResizing: Bool { activeHandle?.isResizing == true }
}

/// Only a genuine local left press at the visible logical edge claims input.
/// It does not register any drag destination or install an event tap.
@MainActor final class HubPanelResizeHandle: NSView {
    var logicalBounds = CGRect.zero
    var cornerRadius: CGFloat = 21
    var configuration: ((NSEvent) -> HubPanelResizeConfiguration?)?
    var cursorAllowedEdges: (() -> HubPanelResizeEdges)?
    var didBegin: (() -> Void)?
    var resizeFrame: ((CGRect) -> Void)?
    var didEnd: (() -> Void)?
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    var mouseLocationInWindow: (() -> CGPoint)?
    var mousePressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private var session: (configuration: HubPanelResizeConfiguration, edges: HubPanelResizeEdges, pointer: CGPoint)?
    private weak var previousResponder: NSResponder?
    private weak var resizingWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var cursorTrackingArea: NSTrackingArea?
    private var installedCursor: NSCursor?
    private var previousCursor: NSCursor?
    private var cursorGeneration: UInt64 = 0
    private var pendingCursorRefresh: UInt64?
    private var cursors: [Int: NSCursor] = [:]
    var isResizing: Bool { session != nil }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, let event = currentEvent(), event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control), event.window === window,
              !HubPanelResizeGeometry.edges(at: convert(point, from: superview), in: logicalBounds, radius: cornerRadius).isEmpty,
              let config = configuration?(event),
              !HubPanelResizeGeometry.edges(at: convert(point, from: superview), in: logicalBounds, radius: cornerRadius).intersection(config.allowedEdges).isEmpty else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard session == nil, event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
              let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              let config = configuration?(event) else { return }
        let edges = HubPanelResizeGeometry.edges(at: convert(event.locationInWindow, from: nil), in: logicalBounds, radius: cornerRadius).intersection(config.allowedEdges)
        guard !edges.isEmpty else { return }
        session = (config, edges, window.convertPoint(toScreen: event.locationInWindow))
        resizingWindow = window
        previousResponder = window.firstResponder
        HubPanelResizeState.activeHandle = self
        window.makeFirstResponder(self)
        didBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session, let window = resizingWindow, event.window === window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        resizeFrame?(HubPanelResizeGeometry.frame(initial: session.configuration.frame,
            delta: CGPoint(x: pointer.x - session.pointer.x, y: pointer.y - session.pointer.y), edges: session.edges,
            anchor: session.configuration.anchor, minimum: session.configuration.minimum, maximum: session.configuration.maximum))
    }

    override func mouseUp(with event: NSEvent) { finish() }
    override func cancelOperation(_ sender: Any?) { cancelResize() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelResize() } }
    func reconcile(mousePressed: Bool) { if !mousePressed { finish() } }
    func cancelResize() {
        guard let session else { return }
        resizeFrame?(session.configuration.frame)
        finish()
    }
    private func finish() {
        guard session != nil else { return }
        session = nil
        if HubPanelResizeState.activeHandle === self { HubPanelResizeState.activeHandle = nil }
        if let window = resizingWindow, window.firstResponder === self { window.makeFirstResponder(previousResponder) }
        resizingWindow = nil; previousResponder = nil
        didEnd?()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            finish()
            clearCursor()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        if let window {
            window.acceptsMouseMovedEvents = true
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(); self?.clearCursor() }
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        // Tracking messages go directly to this passive owner even though
        // hover hit testing deliberately continues to reach hosted controls.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        cursorTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { updateCursor(with: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(with: event) }
    override func mouseExited(with event: NSEvent) {
        // AppKit does not guarantee enter/exit ordering when areas are rebuilt.
        // An old exit must not remove a valid hint at the current location.
        if let window, window.isVisible {
            let edges = currentCursorEdges(in: window)
            if !edges.isEmpty { installCursor(for: edges); return }
        }
        clearCursor()
    }
    override func cursorUpdate(with event: NSEvent) {
        if !updateCursor(with: event) { super.cursorUpdate(with: event) }
    }

    func cursorEdges(at point: CGPoint) -> HubPanelResizeEdges {
        guard !isHiddenOrHasHiddenAncestor, (!mousePressed() || isResizing),
              visibleRect.contains(point), bounds.contains(point) else { return [] }
        let edges = HubPanelResizeGeometry.edges(at: point, in: logicalBounds, radius: cornerRadius)
        guard !edges.isEmpty else { return [] }
        return edges.intersection(cursorAllowedEdges?() ?? [])
    }

    private func currentCursorEdges(in window: NSWindow) -> HubPanelResizeEdges {
        let point = mouseLocationInWindow?() ?? window.mouseLocationOutsideOfEventStream
        let edges = cursorEdges(at: convert(point, from: nil))
        guard !edges.isEmpty,
              NSWindow.windowNumber(at: window.convertPoint(toScreen: point), belowWindowWithWindowNumber: 0) == window.windowNumber else { return [] }
        return edges
    }

    @discardableResult private func updateCursor(with event: NSEvent) -> Bool {
        guard event.window === window, !event.modifierFlags.contains(.control) else { clearCursor(); return false }
        let point = convert(event.locationInWindow, from: nil)
        let edges = cursorEdges(at: point)
        guard !edges.isEmpty else { clearCursor(); return false }
        installCursor(for: edges)
        scheduleCursorRefresh()
        return true
    }

    private func scheduleCursorRefresh() {
        guard pendingCursorRefresh == nil else { return }
        cursorGeneration &+= 1
        let token = cursorGeneration
        pendingCursorRefresh = token
        // AppKit may update an underlying SwiftUI cursor later in this event.
        // Reassert only this still-current edge, never after an exit or drag.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.pendingCursorRefresh == token else { return }
            self.pendingCursorRefresh = nil
            guard let window, self.window === window, window.isVisible else { self.clearCursor(); return }
            let edges = self.currentCursorEdges(in: window)
            if edges.isEmpty { self.clearCursor() } else { self.installCursor(for: edges) }
        }
    }

    private func installCursor(for edges: HubPanelResizeEdges) {
        let cursor: NSCursor
        if let cached = cursors[edges.rawValue] { cursor = cached }
        else {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch edges {
                case [.left, .bottom]: position = .bottomLeft
                case [.right, .bottom]: position = .bottomRight
                case [.left, .top]: position = .topLeft
                case [.right, .top]: position = .topRight
                case .left: position = .left
                case .right: position = .right
                case .top: position = .top
                default: position = .bottom
                }
                cursor = .frameResize(position: position, directions: .all)
            } else { cursor = edges.intersection([.left, .right]).isEmpty ? .resizeUpDown : .resizeLeftRight }
            cursors[edges.rawValue] = cursor
        }
        if installedCursor == nil { previousCursor = NSCursor.current }
        installedCursor = cursor
        cursor.set()
    }

    func clearCursor() {
        cursorGeneration &+= 1
        pendingCursorRefresh = nil
        // A native text/control cursor that has already taken ownership wins.
        if let installedCursor, NSCursor.current === installedCursor { previousCursor?.set() }
        installedCursor = nil; previousCursor = nil
    }
}
