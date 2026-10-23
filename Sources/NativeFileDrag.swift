import AppKit
import SwiftUI
import UniformTypeIdentifiers

let hubFileDragType = UTType(exportedAs: "com.filedock.replica.file-drag-context")
let hubFileDragDidEnd = Notification.Name("HubFileDragDidEnd")
let hubWindowDragWillBegin = Notification.Name("HubWindowDragWillBegin")

struct HubFileDragContext: Equatable {
    let workspaceID: UUID?
    let directory: URL?

    init(workspaceID: UUID?, directory: URL?) {
        self.workspaceID = workspaceID
        self.directory = directory?.standardizedFileURL
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.directory?.path == rhs.directory?.path
    }
}

struct HubFileDragPayload {
    let id: UUID
    let context: HubFileDragContext
    let urls: [URL]
}

enum HubFileDragData {
    static func takesMouseDown(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .leftMouseDown && !modifiers.contains(.control)
    }

    static func contains(_ point: NSPoint, bounds: NSRect, visibleRect: NSRect) -> Bool {
        // SwiftUI may report the hosting ancestor's clip rect in this view's
        // coordinates. It is not necessarily constrained to the cell itself.
        bounds.intersection(visibleRect).contains(point)
    }

    static func urls(for entry: URL, selection: [URL]) -> [URL] {
        let entry = entry.standardizedFileURL
        let candidates = selection.contains(where: { $0.isFileURL && $0.standardizedFileURL.path == entry.path }) ? selection : [entry]
        var seen = Set<String>()
        return candidates.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    static func pasteboardItem(for url: URL, sessionID: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // One real URL per pasteboard item supports Finder and other apps,
        // including multiple selected files. No promises or temporary copies.
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(sessionID.uuidString, forType: NSPasteboard.PasteboardType(hubFileDragType.identifier))
        return item
    }

    static func shouldReorder(_ payload: HubFileDragPayload, in context: HubFileDragContext) -> Bool {
        context.workspaceID != nil && payload.context == context
    }
}

@MainActor
enum HubFileDragState {
    private(set) static var current: HubFileDragPayload?
    private static var draggingPasteboard: NSPasteboard?
    private static var pasteboardChangeCount: Int?
    static var isDragging: Bool { current != nil }

    static func begin(_ payload: HubFileDragPayload) {
        current = payload
        draggingPasteboard = nil
        pasteboardChangeCount = nil
    }

    /// Bind only the real source session's pasteboard, never the general or a
    /// globally guessed drag pasteboard. The ID also rejects stale callbacks.
    static func bind(pasteboard: NSPasteboard, for id: UUID) {
        guard current?.id == id else { return }
        draggingPasteboard = pasteboard
        pasteboardChangeCount = pasteboard.changeCount
    }

    static func end(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        draggingPasteboard = nil
        pasteboardChangeCount = nil
        NotificationCenter.default.post(name: hubFileDragDidEnd, object: nil)
    }

    static func localPayload(for providers: [NSItemProvider]) -> HubFileDragPayload? {
        // SwiftUI filters the custom UTI out of its NSItemProviders. Validate
        // the still-active native session's actual pasteboard instead. A plain
        // file provider alone must never turn an external drop into a reorder.
        guard let current, !current.urls.isEmpty,
              let draggingPasteboard,
              draggingPasteboard.changeCount == pasteboardChangeCount,
              providers.count == current.urls.count,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
              let items = draggingPasteboard.pasteboardItems,
              items.count == current.urls.count else { return nil }
        let tokenType = NSPasteboard.PasteboardType(hubFileDragType.identifier)
        for (item, expectedURL) in zip(items, current.urls) {
            guard item.string(forType: tokenType) == current.id.uuidString,
                  let text = item.string(forType: .fileURL),
                  let url = URL(string: text), url.isFileURL,
                  url.standardizedFileURL.path == expectedURL.standardizedFileURL.path else { return nil }
        }
        return current
    }
}

/// A native cell responder starts dragging during normal AppKit dispatch.
/// Context menus, scrolling and drop targeting pass through to SwiftUI.
@MainActor
struct HubFileDragBridge: NSViewRepresentable {
    var entryURL: URL
    var context: HubFileDragContext
    var selectedURLs: @MainActor () -> [URL]
    var selectEntry: @MainActor () -> Void
    var onClick: @MainActor (NSEvent.ModifierFlags) -> Void
    var onOpen: @MainActor () -> Void

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.entryURL = entryURL
        view.dragContext = self.context
        view.selectedURLs = selectedURLs
        view.selectEntry = selectEntry
        view.onClick = onClick
        view.onOpen = onOpen
    }

    static func dismantleNSView(_ view: FileDragView, coordinator: ()) { view.cancelPendingInteraction() }

    @MainActor
    final class FileDragView: NSView, NSDraggingSource {
        var entryURL = URL(fileURLWithPath: "/")
        var dragContext = HubFileDragContext(workspaceID: nil, directory: nil)
        var selectedURLs: (@MainActor () -> [URL])?
        var selectEntry: (@MainActor () -> Void)?
        var onClick: (@MainActor (NSEvent.ModifierFlags) -> Void)?
        var onOpen: (@MainActor () -> Void)?
        private struct Press {
            let event: NSEvent
            let entryURL: URL
            let payload: HubFileDragPayload
        }
        private var press: Press?
        private var activeID: UUID?
        private var bypassHitTesting = false
        // Keep the source alive if a successful internal reorder recreates its
        // SwiftUI cell before AppKit sends the dragging-session completion.
        private static var activeSource: FileDragView?

        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !bypassHitTesting, !isHiddenOrHasHiddenAncestor else { return nil }
            // Right-click, Control-click, scrolling and native drop targeting
            // retain their normal SwiftUI event dispatch. AppKit delivers later
            // drag/up events to the view that accepted the initial mouseDown.
            if let event = NSApp?.currentEvent,
               !HubFileDragData.takesMouseDown(event.type, modifiers: event.modifierFlags) { return nil }
            let localPoint = convert(point, from: superview)
            return HubFileDragData.contains(localPoint, bounds: bounds, visibleRect: visibleRect) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelPendingInteraction() }
        }

        override func mouseDown(with event: NSEvent) {
            cancelPendingInteraction()
            guard HubFileDragData.takesMouseDown(event.type, modifiers: event.modifierFlags) else {
                forwardContextEvent(event)
                return
            }
            guard let window, event.window === window, NSApp.modalWindow == nil,
                  window.attachedSheet == nil, Self.activeSource == nil,
                  HubFileDragData.contains(convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect) else { return }
            window.makeFirstResponder(self)
            let payload = HubFileDragPayload(id: UUID(), context: dragContext, urls: HubFileDragData.urls(for: entryURL, selection: selectedURLs?() ?? []))
            press = Press(event: event, entryURL: entryURL, payload: payload)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press, press.payload.context == dragContext,
                  press.entryURL == entryURL, !press.payload.urls.isEmpty, Self.activeSource == nil else { return }
            let distance = hypot(event.locationInWindow.x - press.event.locationInWindow.x, event.locationInWindow.y - press.event.locationInWindow.y)
            guard distance >= 5 else { return }
            self.press = nil
            // Moving the second press of a double-click cancels opening; it
            // must not remain pending until the pointer returns to this cell.
            guard press.event.clickCount == 1 else { return }
            selectEntry?()
            let payload = press.payload
            activeID = payload.id
            Self.activeSource = self
            HubFileDragState.begin(payload)
            let point = convert(press.event.locationInWindow, from: nil)
            let items = payload.urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: HubFileDragData.pasteboardItem(for: url, sessionID: payload.id))
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 40, height: 40)
                let offset = CGFloat(min(index, 5)) * 3
                item.setDraggingFrame(NSRect(x: point.x - 20 + offset, y: point.y - 20 - offset, width: 40, height: 40), contents: icon)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            HubFileDragState.bind(pasteboard: session.draggingPasteboard, for: payload.id)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .stack
        }

        override func mouseUp(with event: NSEvent) {
            guard let press else { super.mouseUp(with: event); return }
            // Clear before calling into SwiftUI: a column click can navigate
            // immediately and dismantle this cell.
            self.press = nil
            guard activeID == nil, press.payload.context == dragContext, press.entryURL == entryURL,
                  HubFileDragData.contains(convert(event.locationInWindow, from: nil), bounds: bounds, visibleRect: visibleRect) else { return }
            if press.event.clickCount == 2 { onOpen?() }
            else if press.event.clickCount == 1 { onClick?(press.event.modifierFlags) }
        }

        override func rightMouseDown(with event: NSEvent) { forwardContextEvent(event) }

        private func forwardContextEvent(_ event: NSEvent) {
            // Normally hitTest passes context-menu events through. This fallback
            // preserves the original event type if AppKit sends one directly.
            guard let root = window?.contentView else { return }
            bypassHitTesting = true
            defer { bypassHitTesting = false }
            let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let target = root.hitTest(point), target !== self else { return }
            if event.type == .rightMouseDown { target.rightMouseDown(with: event) }
            else if event.type == .leftMouseDown { target.mouseDown(with: event) }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link] }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            if let activeID { HubFileDragState.bind(pasteboard: session.draggingPasteboard, for: activeID) }
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let activeID { HubFileDragState.end(activeID) }
            activeID = nil
            press = nil
            if Self.activeSource === self { Self.activeSource = nil }
        }

        func cancelPendingInteraction() {
            press = nil
        }
    }
}

/// Placed only in genuine header blank space.
/// Interactive tabs, toolbar buttons and file content never overlap this view.
struct HubWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ view: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard event.type == .leftMouseDown, NSApp.modalWindow == nil,
                  let window, window.attachedSheet == nil, !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging else { return }
            NotificationCenter.default.post(name: hubWindowDragWillBegin, object: window)
            window.performDrag(with: event)
        }
    }
}
