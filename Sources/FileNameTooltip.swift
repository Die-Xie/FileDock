import AppKit
import SwiftUI

/// Filename text registers passive hover regions without participating in
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
        HubFileNameHoverRouter.shared.register(view)
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { HubFileNameHoverRouter.shared.unregister(view) }

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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { HubFileNameHoverRouter.shared.register(self) }
            else { HubFileNameHoverRouter.shared.unregister(self) }
        }

    }
}

/// The cell supplies the pointer region; its text view still supplies the real
/// truncation measurement. Icon and padding hover never change the file layout.
struct HubFileNameHoverArea: NSViewRepresentable {
    let name: String
    var enabled = true
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {
        if view.name != name || view.enabled != enabled {
            if let label = view.label { HubFileNamePopup.shared.hide(owner: label) }
            view.label = nil
        }
        view.name = name; view.enabled = enabled
        HubFileNameHoverRouter.shared.register(view)
    }
    static func dismantleNSView(_ view: AreaView, coordinator: ()) { HubFileNameHoverRouter.shared.unregister(view) }
    final class AreaView: NSView {
        var name = ""
        var enabled = true
        weak var label: HubFileNameTooltip.TrackingView?
        var hoverRect: NSRect { bounds.intersection(visibleRect) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { HubFileNameHoverRouter.shared.register(self) }
            else { HubFileNameHoverRouter.shared.unregister(self) }
        }
        func contains(_ label: HubFileNameTooltip.TrackingView) -> Bool {
            label.window === window && label.name == name && !label.isHiddenOrHasHiddenAncestor &&
                bounds.contains(convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), from: label))
        }
    }
}

/// Receive movement before hit testing. SwiftUI may suppress tracking-area
/// callbacks on a hit-test-transparent representable underneath a drag overlay.
/// One app-local monitor routes to visible text regions; no timer or global tap.
@MainActor
final class HubFileNameHoverRouter: NSObject {
    static let shared = HubFileNameHoverRouter()
    private final class Region {
        weak var view: HubFileNameTooltip.TrackingView?
        init(_ view: HubFileNameTooltip.TrackingView) { self.view = view }
    }
    private final class Area {
        weak var view: HubFileNameHoverArea.AreaView?
        init(_ view: HubFileNameHoverArea.AreaView) { self.view = view }
    }
    @MainActor private final class WindowRegion {
        weak var window: NSWindow?
        weak var root: NSView?
        let tracking: NSTrackingArea
        init(window: NSWindow, root: NSView, owner: AnyObject) {
            self.window = window; self.root = root
            tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: owner)
            root.addTrackingArea(tracking)
        }
    }
    private var regions: [ObjectIdentifier: Region] = [:]
    private var areas: [ObjectIdentifier: Area] = [:]
    private var windows: [ObjectIdentifier: WindowRegion] = [:]
    private var monitor: Any?
    private var deactivation: NSObjectProtocol?

    func register(_ view: HubFileNameTooltip.TrackingView) {
        guard let window = view.window else { return }
        if regions[ObjectIdentifier(view)]?.view !== view { regions[ObjectIdentifier(view)] = Region(view) }
        register(window)
    }
    func register(_ view: HubFileNameHoverArea.AreaView) {
        guard let window = view.window else { return }
        if areas[ObjectIdentifier(view)]?.view !== view { areas[ObjectIdentifier(view)] = Area(view) }
        register(window)
    }
    private func register(_ window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        if let root = window.contentView, windows[ObjectIdentifier(window)]?.root !== root {
            if let old = windows[ObjectIdentifier(window)] { old.root?.removeTrackingArea(old.tracking) }
            windows[ObjectIdentifier(window)] = WindowRegion(window: window, root: root, owner: self)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
                self?.handle(event); return event
            }
            deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HubFileNamePopup.shared.dismiss() }
            }
        }
    }
    func unregister(_ view: HubFileNameTooltip.TrackingView) {
        regions.removeValue(forKey: ObjectIdentifier(view))
        HubFileNamePopup.shared.hide(owner: view)
        pruneWindows()
    }
    func unregister(_ view: HubFileNameHoverArea.AreaView) {
        areas.removeValue(forKey: ObjectIdentifier(view))
        if let label = view.label { HubFileNamePopup.shared.hide(owner: label) }
        view.label = nil
        pruneWindows()
    }
    private func pruneWindows() {
        let liveWindows = Set((regions.values.compactMap { $0.view?.window } + areas.values.compactMap { $0.view?.window }).map(ObjectIdentifier.init))
        for id in Array(windows.keys) where !liveWindows.contains(id) {
            if let old = windows.removeValue(forKey: id) { old.root?.removeTrackingArea(old.tracking) }
        }
        if regions.isEmpty && areas.isEmpty {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let deactivation { NotificationCenter.default.removeObserver(deactivation) }; deactivation = nil
        }
    }
    @objc func mouseEntered(with event: NSEvent) { handle(event) }
    @objc func mouseExited(with event: NSEvent) { handle(event) }
    func handle(_ event: NSEvent) {
        guard let window = event.window, NSEvent.pressedMouseButtons == 0 else { HubFileNamePopup.shared.dismiss(); return }
        let area = areas.values.first { item in
            guard let view = item.view else { return false }
            return view.window === window && view.enabled && !view.isHiddenOrHasHiddenAncestor &&
                view.hoverRect.contains(view.convert(event.locationInWindow, from: nil))
        }?.view
        let match: HubFileNameTooltip.TrackingView?
        if let area {
            if area.label.map({ !area.contains($0) }) ?? false { area.label = nil }
            if area.label == nil {
                area.label = regions.values.first { item in item.view.map { area.contains($0) } ?? false }?.view
            }
            match = area.label
        } else {
            match = regions.values.first { region in
                guard let view = region.view else { return false }
                return view.window === window && view.enabled && !view.isHiddenOrHasHiddenAncestor &&
                    view.hoverRect.contains(view.convert(event.locationInWindow, from: nil))
            }?.view
        }
        guard let match, match.needsHint else { HubFileNamePopup.shared.dismiss(); return }
        if HubFileNamePopup.shared.contains(owner: match) { HubFileNamePopup.shared.move(owner: match) }
        else { HubFileNamePopup.shared.schedule(owner: match) }
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
            self.prepareContent(view.name)
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
    var contentSize: NSSize { panel.contentView?.bounds.size ?? .zero }
    func prepareContent(_ name: String) {
        let text = NSTextField(wrappingLabelWithString: name)
        text.font = .systemFont(ofSize: 12); text.textColor = .labelColor
        let width = min(480, max(40, ceil(text.attributedStringValue.size().width)))
        let height = max(16, ceil(text.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height))
        let size = NSSize(width: width + 18, height: height + 12)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 6
        text.frame = NSRect(x: 9, y: 6, width: width, height: height)
        background.addSubview(text)
        panel.contentView = background
        // Installing a content view resizes it to the window's existing size
        // (initially zero). Keep the measured size before that assignment.
        panel.setContentSize(size)
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
    func dismiss() {
        guard owner != nil || pending != nil || monitor != nil || resignObserver != nil || panel.isVisible else { return }
        generation = UUID()
        pending?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil); owner = nil
    }
}

extension View {
    func fileNameHoverArea(_ name: String, enabled: Bool = true) -> some View {
        overlay { HubFileNameHoverArea(name: name, enabled: enabled) }
    }
    func fileNameTooltip(_ name: String, displayName: String? = nil, fontSize: CGFloat, lines: Int = 1, enabled: Bool = true) -> some View {
        overlay { HubFileNameTooltip(name: name, displayName: displayName ?? name, fontSize: fontSize, lines: lines, enabled: enabled) }
    }
}
