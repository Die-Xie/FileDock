import AppKit
import SwiftUI

let hubWorkspaceDragType = NSPasteboard.PasteboardType("local.diexie.filedock.workspace-reorder")
let hubWorkspaceDragDidEnd = Notification.Name("HubWorkspaceDragDidEnd")

struct HubWorkspaceDragPayload: Equatable {
    let id: UUID
    let workspaceID: UUID
}

enum HubWorkspaceDragData {
    static func takesMouseDown(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .leftMouseDown && !modifiers.contains(.control)
    }

    static func takesHitTest(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, localDragActive: Bool) -> Bool {
        if takesMouseDown(type, modifiers: modifiers) { return true }
        guard localDragActive else { return false }
        // Native destination discovery can run with an AppKit-defined event or
        // the final mouseUp, rather than the source's mouseDragged event.
        switch type {
        case .leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel: return false
        default: return true
        }
    }

    static func contains(_ point: NSPoint, bounds: NSRect, visibleRect: NSRect) -> Bool {
        bounds.intersection(visibleRect).contains(point)
    }

    static func shouldBegin(distance: CGFloat, clickCount: Int) -> Bool {
        clickCount == 1 && distance.isFinite && distance >= 5
    }

    static func insertionAfter(_ point: NSPoint, bounds: NSRect) -> Bool {
        point.x >= bounds.midX
    }

    static func pasteboardItem(for payload: HubWorkspaceDragPayload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString("\(payload.id.uuidString)|\(payload.workspaceID.uuidString)", forType: hubWorkspaceDragType)
        return item
    }
}

/// The private pasteboard token is useful only with the actual local source and
/// its still-bound native session. External or stale lookalike data is rejected.
@MainActor
enum HubWorkspaceDragState {
    private(set) static var current: HubWorkspaceDragPayload?
    private static weak var source: AnyObject?
    private static var pasteboard: NSPasteboard?
    private static var pasteboardChangeCount: Int?
    static var isDragging: Bool { current != nil }

    static func begin(_ payload: HubWorkspaceDragPayload, source: AnyObject) {
        current = payload
        self.source = source
        pasteboard = nil
        pasteboardChangeCount = nil
    }

    static func bind(pasteboard: NSPasteboard, source: AnyObject, for id: UUID) {
        guard current?.id == id, self.source === source else { return }
        self.pasteboard = pasteboard
        pasteboardChangeCount = pasteboard.changeCount
    }

    static func localPayload(source: AnyObject?, pasteboard: NSPasteboard) -> HubWorkspaceDragPayload? {
        guard let current, let source, self.source === source,
              self.pasteboard === pasteboard,
              pasteboard.changeCount == pasteboardChangeCount,
              let items = pasteboard.pasteboardItems, items.count == 1,
              items[0].types == [hubWorkspaceDragType],
              items[0].string(forType: hubWorkspaceDragType) == "\(current.id.uuidString)|\(current.workspaceID.uuidString)" else { return nil }
        return current
    }

    static func end(_ id: UUID, source: AnyObject) {
        guard current?.id == id, self.source === source else { return }
        current = nil
        self.source = nil
        pasteboard = nil
        pasteboardChangeCount = nil
        NotificationCenter.default.post(name: hubWorkspaceDragDidEnd, object: nil)
    }
}

/// Native dispatch avoids SwiftUI Button/ScrollView gesture competition. The
/// underlying Button keeps its accessibility action and context menu.
@MainActor
struct HubWorkspaceDragBridge: NSViewRepresentable {
    var workspaceID: UUID
    var title: String
    var onSelect: @MainActor () -> Void
    var onReorder: @MainActor (_ sourceID: UUID, _ targetID: UUID, _ after: Bool) -> Void
    var onDragStateChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WorkspaceDragView {
        let view = WorkspaceDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WorkspaceDragView, context: Context) {
        view.workspaceID = workspaceID
        view.title = title
        view.onSelect = onSelect
        view.onReorder = onReorder
        view.onDragStateChanged = onDragStateChanged
    }

    static func dismantleNSView(_ view: WorkspaceDragView, coordinator: ()) { view.cancelPendingInteraction() }

    @MainActor
    final class WorkspaceDragView: NSView, NSDraggingSource {
        var workspaceID = UUID()
        var title = ""
        var onSelect: (@MainActor () -> Void)?
        var onReorder: (@MainActor (UUID, UUID, Bool) -> Void)?
        var onDragStateChanged: (@MainActor (Bool) -> Void)?
        private struct Press {
            let event: NSEvent
            let workspaceID: UUID
        }
        private var press: Press?
        private var activeID: UUID?
        private var activeSession: NSDraggingSession?
        private var activeCompletion: (@MainActor (Bool) -> Void)?
        private var bypassHitTesting = false
        private(set) var insertionAfter: Bool? { didSet { needsDisplay = true } }
        // A reorder can dismantle its source before AppKit ends the session.
        private static var activeSource: WorkspaceDragView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([hubWorkspaceDragType])
            NotificationCenter.default.addObserver(self, selector: #selector(clearInsertion), name: hubWorkspaceDragDidEnd, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !bypassHitTesting, !isHiddenOrHasHiddenAncestor else { return nil }
            if let event = NSApp?.currentEvent {
                // A registered native destination must remain discoverable
                // during our own drag. Ordinary scrolling/context clicks pass.
                guard HubWorkspaceDragData.takesHitTest(event.type, modifiers: event.modifierFlags,
                                                        localDragActive: HubWorkspaceDragState.isDragging) else { return nil }
            }
            let localPoint = convert(point, from: superview)
            return HubWorkspaceDragData.contains(localPoint, bounds: bounds, visibleRect: visibleRect) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelPendingInteraction() }
        }

        override func mouseDown(with event: NSEvent) {
            cancelPendingInteraction()
            guard HubWorkspaceDragData.takesMouseDown(event.type, modifiers: event.modifierFlags) else {
                forwardContextEvent(event)
                return
            }
            guard let window, event.window === window, NSApp.modalWindow == nil,
                  window.attachedSheet == nil, Self.activeSource == nil,
                  HubWorkspaceDragData.contains(convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect) else { return }
            window.makeFirstResponder(self)
            press = Press(event: event, workspaceID: workspaceID)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press, press.workspaceID == workspaceID, Self.activeSource == nil else { return }
            let distance = hypot(event.locationInWindow.x - press.event.locationInWindow.x, event.locationInWindow.y - press.event.locationInWindow.y)
            guard distance >= 5 else { return }
            self.press = nil
            guard HubWorkspaceDragData.shouldBegin(distance: distance, clickCount: press.event.clickCount) else { return }
            let payload = HubWorkspaceDragPayload(id: UUID(), workspaceID: workspaceID)
            activeID = payload.id
            activeCompletion = onDragStateChanged
            Self.activeSource = self
            HubWorkspaceDragState.begin(payload, source: self)
            activeCompletion?(true)
            // Reordering must preserve the selected workspace, its navigation
            // and search even when a drag is canceled. Selection is click-only.
            let preview = dragPreview()
            let point = convert(press.event.locationInWindow, from: nil)
            let item = NSDraggingItem(pasteboardWriter: HubWorkspaceDragData.pasteboardItem(for: payload))
            item.setDraggingFrame(NSRect(x: point.x - preview.size.width / 2, y: point.y - preview.size.height / 2,
                                        width: preview.size.width, height: preview.size.height), contents: preview)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            activeSession = session
            HubWorkspaceDragState.bind(pasteboard: session.draggingPasteboard, source: self, for: payload.id)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            guard let press else { super.mouseUp(with: event); return }
            self.press = nil
            guard activeID == nil, press.workspaceID == workspaceID,
                  HubWorkspaceDragData.contains(convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect) else { return }
            onSelect?()
        }

        override func rightMouseDown(with event: NSEvent) { forwardContextEvent(event) }

        private func forwardContextEvent(_ event: NSEvent) {
            guard let root = window?.contentView else { return }
            bypassHitTesting = true
            defer { bypassHitTesting = false }
            let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let target = root.hitTest(point), target !== self else { return }
            if event.type == .rightMouseDown { target.rightMouseDown(with: event) }
            else if event.type == .leftMouseDown { target.mouseDown(with: event) }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            guard activeSession == nil || activeSession === session else { return }
            if let activeID { HubWorkspaceDragState.bind(pasteboard: session.draggingPasteboard, source: self, for: activeID) }
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard activeSession === session, let id = activeID else { return }
            activeID = nil
            activeSession = nil
            press = nil
            let completion = activeCompletion
            activeCompletion = nil
            if Self.activeSource === self { Self.activeSource = nil }
            HubWorkspaceDragState.end(id, source: self)
            completion?(false)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDestination(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDestination(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
        override func draggingEnded(_ sender: NSDraggingInfo) { clearInsertion() }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearInsertion() }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { destinationPayload(sender) != nil }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let payload = destinationPayload(sender) else { clearInsertion(); return false }
            let after = HubWorkspaceDragData.insertionAfter(convert(sender.draggingLocation, from: nil), bounds: bounds)
            clearInsertion()
            guard let onReorder else { return false }
            onReorder(payload.workspaceID, workspaceID, after)
            return true
        }

        private func destinationPayload(_ sender: NSDraggingInfo) -> HubWorkspaceDragPayload? {
            guard !isHiddenOrHasHiddenAncestor, sender.draggingSourceOperationMask.contains(.move),
                  let source = sender.draggingSource as? WorkspaceDragView,
                  let payload = HubWorkspaceDragState.localPayload(source: source, pasteboard: sender.draggingPasteboard),
                  payload.workspaceID != workspaceID,
                  HubWorkspaceDragData.contains(convert(sender.draggingLocation, from: nil), bounds: bounds, visibleRect: visibleRect) else { return nil }
            return payload
        }

        private func updateDestination(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard destinationPayload(sender) != nil else { clearInsertion(); return [] }
            if let event = NSApp?.currentEvent, event.type == .leftMouseDragged { _ = autoscroll(with: event) }
            insertionAfter = HubWorkspaceDragData.insertionAfter(convert(sender.draggingLocation, from: nil), bounds: bounds)
            return .move
        }

        @objc private func clearInsertion() { insertionAfter = nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let insertionAfter else { return }
            NSColor.controlAccentColor.setFill()
            let edge = insertionAfter ? bounds.maxX - 2 : bounds.minX
            NSBezierPath(roundedRect: NSRect(x: edge, y: bounds.minY + 5, width: 2,
                                           height: max(0, bounds.height - 10)), xRadius: 1, yRadius: 1).fill()
        }

        private func dragPreview() -> NSImage {
            let size = NSSize(width: max(100, min(260, bounds.width)), height: 42)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: NSRect(x: 12, y: 11, width: size.width - 24, height: 20),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                     .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            image.unlockFocus()
            return image
        }

        func cancelPendingInteraction() {
            press = nil
            clearInsertion()
            // An active native session survives source view replacement and is
            // cleared only by its matching AppKit completion, including cancel.
        }
    }
}
