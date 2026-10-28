import AppKit
import SwiftUI

/// Only filename text owns tracking regions; this overlay never participates in
/// clicks, dragging or drop targeting. There is one shared popup and no polling.
struct HubFileNameTooltip: NSViewRepresentable {
    let name: String
    let displayName: String
    let fontSize: CGFloat
    let lines: Int
    var enabled = true

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        if view.name != name || view.displayName != displayName || view.fontSize != fontSize || view.lines != lines || view.enabled != enabled {
            HubFileNamePopup.shared.hide(owner: view)
        }
        view.name = name; view.displayName = displayName; view.fontSize = fontSize; view.lines = lines; view.enabled = enabled
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { HubFileNamePopup.shared.hide(owner: view) }

    static func isTruncated(_ name: String, fontSize: CGFloat, lines: Int, size: NSSize) -> Bool {
        guard !name.isEmpty, size.width > 0, size.height > 0 else { return false }
        let storage = NSTextStorage(string: name, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        let range = layout.glyphRange(for: container)
        if NSMaxRange(range) < layout.numberOfGlyphs { return true }
        var truncated = false
        layout.enumerateLineFragments(forGlyphRange: range) { _, _, _, glyphs, stop in
            if layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphs.location).location != NSNotFound {
                truncated = true; stop.pointee = true
            }
        }
        return truncated || layout.usedRect(for: container).height > size.height + 1
    }

    final class TrackingView: NSView {
        var name = ""
        var displayName = ""
        var fontSize: CGFloat = 12
        var lines = 1
        var enabled = true
        private var tracking: NSTrackingArea?
        private var trackedRect: NSRect?
        private struct Measurement: Equatable {
            let name: String
            let fontSize: CGFloat
            let lines: Int
            let size: NSSize
        }
        private var measurement: Measurement?
        private var truncated = false
        var hoverRect: NSRect { bounds.intersection(visibleRect) }
        var needsHint: Bool {
            let key = Measurement(name: displayName, fontSize: fontSize, lines: lines, size: bounds.size)
            if measurement != key {
                truncated = HubFileNameTooltip.isTruncated(displayName, fontSize: fontSize, lines: lines, size: bounds.size)
                measurement = key
            }
            return enabled && truncated
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // NSHostingView may report a visibleRect larger than this overlay's
            // bounds. inVisibleRect would then track the entire file browser.
            let rect = hoverRect
            guard trackedRect != rect || tracking == nil else { return }
            if let tracking { removeTrackingArea(tracking) }
            tracking = nil
            if !rect.isEmpty {
                let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp], owner: self)
                addTrackingArea(area); tracking = area
            }
            HubFileNamePopup.shared.hide(owner: self)
            trackedRect = rect
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // Movement is required both for pointer-following and recovery
                // when SwiftUI creates a tracking region beneath the pointer.
                window.acceptsMouseMovedEvents = true
            } else { HubFileNamePopup.shared.hide(owner: self) }
        }
        override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
        override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
        private func updateHover(with event: NSEvent) {
            guard event.window === window, !isHiddenOrHasHiddenAncestor,
                  hoverRect.contains(convert(event.locationInWindow, from: nil)),
                  NSEvent.pressedMouseButtons == 0, needsHint else {
                HubFileNamePopup.shared.hide(owner: self); return
            }
            // A layout/refresh can replace a tracking region beneath a stationary
            // pointer. A subsequent move must recover without requiring re-entry.
            if HubFileNamePopup.shared.contains(owner: self) { HubFileNamePopup.shared.move(owner: self) }
            else { HubFileNamePopup.shared.schedule(owner: self) }
        }
        override func mouseExited(with event: NSEvent) { HubFileNamePopup.shared.hide(owner: self) }

    }
}

@MainActor
final class HubFileNamePopup {
    static let shared = HubFileNamePopup()
    private weak var owner: HubFileNameTooltip.TrackingView?
    private var generation = UUID()
    private var pending: DispatchWorkItem?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        return panel
    }()

    func schedule(owner view: HubFileNameTooltip.TrackingView) {
        dismiss()
        owner = view
        let ticket = generation
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, self.generation == ticket else { return }
            guard let view, self.owner === view, view.enabled,
                  let window = view.window, window.isVisible, NSApp.isActive,
                  NSEvent.pressedMouseButtons == 0 else { self.dismiss(); return }
            self.pending = nil
            let text = NSTextField(wrappingLabelWithString: view.name)
            text.font = .systemFont(ofSize: 12); text.textColor = .labelColor
            let width = min(480, max(40, text.attributedStringValue.size().width))
            let height = text.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
            let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width + 18, height: height + 12))
            background.material = .popover; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 6
            text.frame = NSRect(x: 9, y: 6, width: width, height: height)
            background.addSubview(text)
            self.panel.contentView = background
            self.panel.setContentSize(background.frame.size)
            self.panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            window.addChildWindow(self.panel, ordered: .above)
            self.position()
            self.panel.orderFront(nil)
        }
        pending = work
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            self?.dismiss(); return event
        }
        if let window = view.window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    func contains(owner view: HubFileNameTooltip.TrackingView) -> Bool { owner === view }
    func move(owner view: HubFileNameTooltip.TrackingView) {
        guard owner === view else { return }
        if NSEvent.pressedMouseButtons != 0 { dismiss() } else if panel.isVisible { position() }
    }
    func hide(owner view: HubFileNameTooltip.TrackingView) { if owner === view { dismiss() } }
    private func position() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { dismiss(); return }
        let frame = screen.visibleFrame.insetBy(dx: 4, dy: 4), size = panel.frame.size
        let x = min(max(pointer.x + 14, frame.minX), max(frame.minX, frame.maxX - size.width))
        var y = pointer.y - size.height - 14
        if y < frame.minY { y = pointer.y + 20 }
        y = min(max(y, frame.minY), max(frame.minY, frame.maxY - size.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    private func dismiss() {
        generation = UUID()
        pending?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil); owner = nil
    }
}

extension View {
    func fileNameTooltip(_ name: String, displayName: String? = nil, fontSize: CGFloat, lines: Int = 1, enabled: Bool = true) -> some View {
        overlay { HubFileNameTooltip(name: name, displayName: displayName ?? name, fontSize: fontSize, lines: lines, enabled: enabled) }
    }
}
