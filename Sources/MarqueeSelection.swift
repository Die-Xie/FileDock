import AppKit
import SwiftUI

struct HubFileSelectionBoundsKey: PreferenceKey {
    static var defaultValue: [URL: Anchor<CGRect>] = [:]
    static func reduce(value: inout [URL: Anchor<CGRect>], nextValue: () -> [URL: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func fileSelectionBounds(_ url: URL) -> some View {
        anchorPreference(key: HubFileSelectionBoundsKey.self, value: .bounds) { [url: $0] }
            .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.item(url): $0] }
    }

    @MainActor func marqueeFileSelection(context: HubFileDragContext, selection: Set<URL>,
                                         setSelection: @escaping (Set<URL>) -> Void) -> some View {
        overlayPreferenceValue(HubFileSelectionBoundsKey.self) { anchors in
            GeometryReader { geometry in
                HubMarqueeSelectionBridge(context: context, frames: anchors.mapValues { geometry[$0] },
                                          selection: selection, setSelection: setSelection)
            }
        }
    }
}

enum HubMarqueeSelectionMath {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func selected(in rectangle: CGRect, frames: [URL: CGRect], baseline: Set<URL>,
                         modifiers: NSEvent.ModifierFlags) -> Set<URL> {
        let hits = Set(frames.compactMap { url, frame in
            frame.intersection(rectangle).isEmpty ? nil : url
        })
        if modifiers.contains(.command) { return baseline.symmetricDifference(hits) }
        if modifiers.contains(.shift) { return baseline.union(hits) }
        return hits
    }
}

@MainActor
enum HubMarqueeSelectionState {
    static weak var activeView: HubMarqueeSelectionBridge.SelectionView?
    static var isSelecting: Bool { activeView != nil }
    static func cancel() { activeView?.endSelection(restore: true) }
}

/// Only blank left presses belong to this responder. File cells, context menus,
/// scrollbars and native drop destinations keep their normal event routing.
@MainActor
struct HubMarqueeSelectionBridge: NSViewRepresentable {
    var context: HubFileDragContext
    var frames: [URL: CGRect]
    var selection: Set<URL>
    var setSelection: (Set<URL>) -> Void

    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) {
        view.configure(context: self.context, frames: frames, selection: selection, setSelection: setSelection)
    }
    static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.endSelection(restore: false) }

    final class SelectionView: NSView {
        private var context: HubFileDragContext?
        private(set) var frames: [URL: CGRect] = [:]
        private var selection: Set<URL> = []
        private var setSelection: ((Set<URL>) -> Void)?
        private var bypassHitTesting = false
        private struct Gesture {
            var start: CGPoint
            var point: CGPoint
            var baseline: Set<URL>
            var modifiers: NSEvent.ModifierFlags
            var dragging = false
        }
        private var gesture: Gesture?
        private(set) var selectionRectangle: CGRect?

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func configure(context: HubFileDragContext, frames: [URL: CGRect], selection: Set<URL>,
                       setSelection: @escaping (Set<URL>) -> Void) {
            if self.context != context { endSelection(restore: false) }
            self.context = context
            self.frames = frames.filter { _, frame in
                !frame.isEmpty && !frame.isInfinite && !frame.isNull &&
                    frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            }
            self.selection = selection
            self.setSelection = setSelection
        }

        func acceptsBlankPoint(_ point: NSPoint) -> Bool {
            !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(point) &&
                !frames.values.contains(where: { $0.contains(point) })
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !bypassHitTesting, !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging else { return nil }
            if let event = NSApp?.currentEvent,
               !HubFileDragData.takesMouseDown(event.type, modifiers: event.modifierFlags) { return nil }
            let local = convert(point, from: superview)
            guard acceptsBlankPoint(local) else { return nil }
            // This overlay is outside SwiftUI's NSScrollView. Let its actual
            // scrollers retain clicks instead of guessing their current width.
            if let root = window?.contentView {
                bypassHitTesting = true
                defer { bypassHitTesting = false }
                let rootPoint = root.superview?.convert(convert(local, to: nil), from: nil) ?? convert(local, to: nil)
                var underlying = root.hitTest(rootPoint)
                while let view = underlying {
                    if view is NSScroller { return nil }
                    underlying = view.superview
                }
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard event.window === window, let window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  HubFileDragData.takesMouseDown(event.type, modifiers: event.modifierFlags) else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard acceptsBlankPoint(point) else { return }
            window.makeFirstResponder(self)
            beginSelection(at: point, modifiers: event.modifierFlags)
        }

        func beginSelection(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
            endSelection(restore: false)
            guard acceptsBlankPoint(point) else { return }
            HubMarqueeSelectionState.cancel()
            gesture = Gesture(start: point, point: point, baseline: selection, modifiers: modifiers)
            HubMarqueeSelectionState.activeView = self
            if modifiers.intersection([.command, .shift]).isEmpty { publish([]) }
        }

        override func mouseDragged(with event: NSEvent) { updateSelection(to: convert(event.locationInWindow, from: nil)) }

        func updateSelection(to point: CGPoint) {
            guard var gesture, point.x.isFinite, point.y.isFinite else { return }
            gesture.point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                                    y: min(max(point.y, bounds.minY), bounds.maxY))
            gesture.dragging = gesture.dragging || hypot(point.x - gesture.start.x, point.y - gesture.start.y) >= 3
            self.gesture = gesture
            guard gesture.dragging else { return }
            let rect = HubMarqueeSelectionMath.rectangle(from: gesture.start, to: gesture.point)
            selectionRectangle = rect
            publish(HubMarqueeSelectionMath.selected(in: rect, frames: frames, baseline: gesture.baseline, modifiers: gesture.modifiers))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            updateSelection(to: convert(event.locationInWindow, from: nil))
            endSelection(restore: false)
        }

        override func cancelOperation(_ sender: Any?) { endSelection(restore: true) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { endSelection(restore: false) }
        }

        func endSelection(restore: Bool) {
            let baseline = gesture?.baseline
            gesture = nil
            selectionRectangle = nil
            if HubMarqueeSelectionState.activeView === self { HubMarqueeSelectionState.activeView = nil }
            if restore, let baseline { publish(baseline) }
            needsDisplay = true
        }

        private func publish(_ urls: Set<URL>) {
            guard selection != urls else { return }
            selection = urls
            setSelection?(urls)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let selectionRectangle else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            selectionRectangle.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(rect: selectionRectangle.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }
}
