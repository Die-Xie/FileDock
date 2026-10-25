import AppKit
import SwiftUI

struct HubShortcutReorderPlan: Equatable {
    let targetID: UUID
    let after: Bool
    let insertionIndex: Int
    let isNoOp: Bool
    let marker: CGRect
}

/// Frames and points share the root overlay's flipped coordinates. Frames must
/// already be clipped to their header viewport by the caller.
enum HubShortcutReorderGeometry {
    private static func visibleFrames(_ frames: [UUID: CGRect], in bounds: CGRect) -> [(id: UUID, frame: CGRect)] {
        guard usable(bounds) else { return [] }
        return frames.compactMap { id, frame in
            guard usable(frame) else { return nil }
            let visible = frame.intersection(bounds)
            return usable(visible) ? (id, visible) : nil
        }.sorted {
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func plan(frames: [UUID: CGRect], bounds: CGRect, point: CGPoint, sourceID: UUID,
                     dropBounds: [CGRect] = [], orderedIDs: [UUID] = []) -> HubShortcutReorderPlan? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let visible = visibleFrames(frames, in: bounds)
        var seen = Set<UUID>()
        let order = (orderedIDs.isEmpty ? visible.map(\.id) : orderedIDs).filter { seen.insert($0).inserted }
        guard let sourceIndex = order.firstIndex(of: sourceID) else { return nil }
        let validIDs = Set(order)
        let limits = dropBounds.isEmpty ? [bounds] : dropBounds.filter(usable).map { $0.intersection(bounds) }.filter(usable)
        var items: [(id: UUID, frame: CGRect)] = []
        var activeLimit = bounds
        for limit in limits where limit.contains(point) {
            let candidates = visible.compactMap { item -> (id: UUID, frame: CGRect)? in
                guard validIDs.contains(item.id) else { return nil }
                let frame = item.frame.intersection(limit)
                return usable(frame) ? (item.id, frame) : nil
            }
            guard let first = candidates.first else { continue }
            let union = candidates.dropFirst().reduce(first.frame) { $0.union($1.frame) }
            if union.insetBy(dx: -32, dy: -6).intersection(limit).contains(point) {
                items = candidates
                activeLimit = limit
                break
            }
        }
        guard let first = items.first, let last = items.last else { return nil }
        let union = items.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let boundary = items.firstIndex(where: { point.x < $0.frame.midX }) ?? items.count
        let sourceBeforeBoundary = items.prefix(boundary).contains { $0.id == sourceID }
        let visibleInsertionIndex = boundary - (sourceBeforeBoundary ? 1 : 0)
        let remaining = items.filter { $0.id != sourceID }
        let targetID: UUID
        let after: Bool
        if visibleInsertionIndex < remaining.count {
            targetID = remaining[visibleInsertionIndex].id
            after = false
        } else {
            targetID = remaining.last?.id ?? sourceID
            after = true
        }
        let targetIndex = order.firstIndex(of: targetID) ?? sourceIndex
        let insertionIndex = remaining.isEmpty ? sourceIndex : targetIndex - (sourceIndex < targetIndex ? 1 : 0) + (after ? 1 : 0)
        let isNoOp = insertionIndex == sourceIndex
        let markerX: CGFloat
        if boundary == 0 { markerX = first.frame.minX - 2 }
        else if boundary == items.count { markerX = last.frame.maxX + 2 }
        else { markerX = (items[boundary - 1].frame.maxX + items[boundary].frame.minX) / 2 }
        let centerX = min(activeLimit.maxX - 1, max(activeLimit.minX + 1, markerX))
        let marker = CGRect(x: centerX - 1, y: union.minY + min(5, union.height / 4),
                            width: 2, height: max(1, union.height - min(10, union.height / 2))).intersection(activeLimit)
        return HubShortcutReorderPlan(targetID: targetID, after: after, insertionIndex: insertionIndex,
                                      isNoOp: isNoOp, marker: marker)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
    }
}

/// One persistent destination per domain covers each tab/shortcut strip,
/// including gaps and end insertion positions. Only the active domain registers
/// its private type; file drags and the other reorder domain pass through.
@MainActor struct HubShortcutReorderDropBridge: NSViewRepresentable {
    var frames: [UUID: CGRect]
    var domain: HubWorkspaceDragDomain = .shortcut
    var enabled = true
    var dropBounds: [CGRect] = []
    var orderedIDs: [UUID] = []
    var onHover: (@MainActor (UUID) -> Void)? = nil
    var onReorder: @MainActor (UUID, UUID, Bool) -> Void

    func makeNSView(context: Context) -> DestinationView {
        let view = DestinationView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: DestinationView, context: Context) {
        view.frames = frames
        view.domain = domain
        view.enabled = enabled
        view.dropBounds = dropBounds
        view.orderedIDs = orderedIDs
        view.onHover = onHover
        view.onReorder = onReorder
    }
    static func dismantleNSView(_ view: DestinationView, coordinator: ()) {
        view.enabled = false
        view.clearInsertion()
    }

    final class DestinationView: NSView {
        var frames: [UUID: CGRect] = [:] {
            didSet { if oldValue != frames { clearInsertion() } }
        }
        var domain: HubWorkspaceDragDomain = .shortcut {
            didSet { if oldValue != domain { clearInsertion(); updateRegistration() } }
        }
        var enabled = true { didSet { if !enabled { clearInsertion() }; updateRegistration() } }
        var dropBounds: [CGRect] = [] { didSet { if oldValue != dropBounds { clearInsertion() } } }
        var orderedIDs: [UUID] = [] { didSet { if oldValue != orderedIDs { clearInsertion() } } }
        var onHover: (@MainActor (UUID) -> Void)?
        var onReorder: (@MainActor (UUID, UUID, Bool) -> Void)?
        private(set) var insertion: HubShortcutReorderPlan? {
            didSet { if oldValue != insertion { needsDisplay = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(updateRegistration), name: hubWorkspaceDragDidBegin, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(updateRegistration), name: hubWorkspaceDragDidEnd, object: nil)
            updateRegistration()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { clearInsertion() }
        }
        @objc private func updateRegistration() {
            if enabled, HubWorkspaceDragState.current?.domain == domain {
                if registeredDraggedTypes != [hubWorkspaceDragType] { registerForDraggedTypes([hubWorkspaceDragType]) }
            } else {
                if !registeredDraggedTypes.isEmpty { unregisterDraggedTypes() }
                clearInsertion()
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, !isHiddenOrHasHiddenAncestor,
                  let active = HubWorkspaceDragState.current, active.domain == domain,
                  HubShortcutReorderGeometry.plan(frames: frames, bounds: bounds.intersection(visibleRect),
                      point: convert(point, from: superview), sourceID: active.workspaceID,
                      dropBounds: dropBounds, orderedIDs: orderedIDs) != nil else { return nil }
            return self
        }

        private func input(_ sender: NSDraggingInfo) -> (HubWorkspaceDragPayload, HubShortcutReorderPlan)? {
            guard enabled, !isHiddenOrHasHiddenAncestor,
                  sender.draggingSourceOperationMask.contains(.move),
                  let source = sender.draggingSource as? HubWorkspaceDragBridge.WorkspaceDragView,
                  !source.isHiddenOrHasHiddenAncestor,
                  let payload = HubWorkspaceDragState.localPayload(source: source, pasteboard: sender.draggingPasteboard),
                  payload.domain == domain,
                  let plan = HubShortcutReorderGeometry.plan(frames: frames, bounds: bounds.intersection(visibleRect),
                      point: convert(sender.draggingLocation, from: nil), sourceID: payload.workspaceID,
                      dropBounds: dropBounds, orderedIDs: orderedIDs) else { return nil }
            return (payload, plan)
        }
        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let (_, plan) = input(sender) else { clearInsertion(); return [] }
            insertion = plan
            onHover?(plan.targetID)
            return .move
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
        override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
        override func draggingEnded(_ sender: NSDraggingInfo) { clearInsertion() }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearInsertion() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !update(sender).isEmpty }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let (payload, plan) = input(sender) else { clearInsertion(); return false }
            clearInsertion()
            if plan.isNoOp { return true }
            guard plan.targetID != payload.workspaceID, let onReorder else { return false }
            onReorder(payload.workspaceID, plan.targetID, plan.after)
            return true
        }
        @objc func clearInsertion() { insertion = nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let insertion else { return }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: insertion.marker, xRadius: 1, yRadius: 1).fill()
        }
    }
}
