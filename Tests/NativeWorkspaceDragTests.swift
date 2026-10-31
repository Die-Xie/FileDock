import AppKit
import Combine
import SwiftUI

@main
struct NativeWorkspaceDragTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        precondition(HubWorkspaceDragData.takesMouseDown(.leftMouseDown, modifiers: []))
        precondition(HubWorkspaceDragData.takesMouseDown(.leftMouseDown, modifiers: [.command, .shift]))
        precondition(!HubWorkspaceDragData.takesMouseDown(.leftMouseDown, modifiers: .control))
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .leftMouseUp] {
            precondition(!HubWorkspaceDragData.takesMouseDown(type, modifiers: []), "Only an ordinary initial left press starts workspace tracking")
        }
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp, .appKitDefined, .applicationDefined] {
            precondition(!HubWorkspaceDragData.takesHitTest(type, modifiers: [], localDragActive: false))
            precondition(HubWorkspaceDragData.takesHitTest(type, modifiers: [], localDragActive: true), "Native destination lookup must remain possible through tracking and the final release")
        }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp, .scrollWheel] {
            precondition(!HubWorkspaceDragData.takesHitTest(type, modifiers: [], localDragActive: true))
        }
        precondition(!HubWorkspaceDragData.takesHitTest(.leftMouseDown, modifiers: .control, localDragActive: true))
        precondition(!HubWorkspaceDragData.takesHitTest(nil, modifiers: [], localDragActive: false),
                     "Eventless file destination discovery must pass through reorder overlays")
        precondition(HubWorkspaceDragData.takesHitTest(nil, modifiers: [], localDragActive: true))
        precondition(!HubWorkspaceDragData.shouldBegin(distance: 4.99, clickCount: 1))
        precondition(HubWorkspaceDragData.shouldBegin(distance: 5, clickCount: 1))
        precondition(!HubWorkspaceDragData.shouldBegin(distance: 8, clickCount: 2))
        precondition(!HubWorkspaceDragData.shouldBegin(distance: .infinity, clickCount: 1))
        precondition(!HubWorkspaceDragData.shouldBegin(distance: .nan, clickCount: 1))

        let bounds = NSRect(x: 0, y: 0, width: 100, height: 40)
        let oversizedClip = NSRect(x: -200, y: -100, width: 900, height: 400)
        precondition(HubWorkspaceDragData.contains(NSPoint(x: 50, y: 20), bounds: bounds, visibleRect: oversizedClip))
        precondition(!HubWorkspaceDragData.contains(NSPoint(x: 180, y: 20), bounds: bounds, visibleRect: oversizedClip))
        precondition(!HubWorkspaceDragData.contains(NSPoint(x: 50, y: 20), bounds: bounds, visibleRect: .zero))
        let partialClip = NSRect(x: 30, y: 0, width: 70, height: 40)
        precondition(!HubWorkspaceDragData.contains(NSPoint(x: 20, y: 20), bounds: bounds, visibleRect: partialClip))
        precondition(HubWorkspaceDragData.contains(NSPoint(x: 40, y: 20), bounds: bounds, visibleRect: partialClip))
        precondition(!HubWorkspaceDragData.insertionAfter(NSPoint(x: 49, y: 20), bounds: bounds))
        precondition(HubWorkspaceDragData.insertionAfter(NSPoint(x: 50, y: 20), bounds: bounds))
        precondition(HubWorkspaceDragData.insertionAfter(NSPoint(x: 80, y: 20), bounds: bounds))

        let source = HubWorkspaceDragBridge.WorkspaceDragView(frame: bounds)
        let otherSource = HubWorkspaceDragBridge.WorkspaceDragView(frame: bounds)
        precondition(!source.mouseDownCanMoveWindow)
        precondition(source.acceptsFirstResponder && source.acceptsFirstMouse(for: nil))
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        source.frame.origin = NSPoint(x: 20, y: 20)
        parent.addSubview(source)
        precondition(source.hitTest(NSPoint(x: 50, y: 40)) == nil, "An idle overlay must not intercept an external file drag")
        let geometrySession = HubWorkspaceDragPayload(id: UUID(), workspaceID: source.workspaceID)
        HubWorkspaceDragState.begin(geometrySession, source: source)
        precondition(source.hitTest(NSPoint(x: 50, y: 40)) === source)
        precondition(source.hitTest(NSPoint(x: 10, y: 40)) == nil)
        precondition(source.hitTest(NSPoint(x: 150, y: 40)) == nil)
        source.isHidden = true
        precondition(source.hitTest(NSPoint(x: 50, y: 40)) == nil)
        source.isHidden = false
        parent.isHidden = true
        precondition(source.hitTest(NSPoint(x: 50, y: 40)) == nil)
        parent.isHidden = false
        let clippedParent = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        clippedParent.clipsToBounds = true
        source.removeFromSuperview()
        source.frame = NSRect(x: 30, y: 0, width: 100, height: 40)
        clippedParent.addSubview(source)
        precondition(source.hitTest(NSPoint(x: 60, y: 20)) === source)
        precondition(source.hitTest(NSPoint(x: 95, y: 20)) == nil, "A tab clipped by its strip viewport cannot become a hidden target")
        source.cancelPendingInteraction()
        HubWorkspaceDragState.end(geometrySession.id, source: source)
        precondition(!HubWorkspaceDragState.isDragging)
        precondition(source.insertionAfter == nil)

        let pasteboard = NSPasteboard.withUniqueName()
        let otherPasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); otherPasteboard.releaseGlobally() }
        let first = HubWorkspaceDragPayload(id: UUID(), workspaceID: UUID())
        var notifications = 0
        let subscription = NotificationCenter.default.publisher(for: hubWorkspaceDragDidEnd).sink { notification in
            precondition(notification.object == nil && notification.userInfo == nil, "Drag completion must not expose workspace metadata")
            notifications += 1
        }
        defer { subscription.cancel() }
        func write(_ payload: HubWorkspaceDragPayload, to destination: NSPasteboard = pasteboard) {
            destination.clearContents()
            precondition(destination.writeObjects([HubWorkspaceDragData.pasteboardItem(for: payload)]))
        }
        write(first)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        HubWorkspaceDragState.begin(first, source: source)
        precondition(HubWorkspaceDragState.isDragging)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil, "Arming without a native pasteboard binding cannot authorize a drop")
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: otherSource, for: first.id)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: UUID())
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == first)
        precondition(HubWorkspaceDragState.localPayload(source: otherSource, pasteboard: pasteboard) == nil)
        precondition(HubWorkspaceDragState.localPayload(source: nil, pasteboard: pasteboard) == nil)
        write(first, to: otherPasteboard)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: otherPasteboard) == nil, "A lookalike private token on another pasteboard must not authorize a reorder")
        write(first)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil, "Changing pasteboard contents invalidates its native binding")
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == first)
        let wrongWorkspace = HubWorkspaceDragPayload(id: first.id, workspaceID: UUID())
        write(wrongWorkspace)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        let mixedItem = HubWorkspaceDragData.pasteboardItem(for: first)
        mixedItem.setString("file:///unexpected", forType: .fileURL)
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([mixedItem]))
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([HubWorkspaceDragData.pasteboardItem(for: first), HubWorkspaceDragData.pasteboardItem(for: first)]))
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        write(first)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        source.cancelPendingInteraction()
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == first, "Dismantling during a reorder must not discard the active native session")
        HubWorkspaceDragState.end(UUID(), source: source)
        HubWorkspaceDragState.end(first.id, source: otherSource)
        precondition(HubWorkspaceDragState.isDragging && notifications == 0)
        HubWorkspaceDragState.end(first.id, source: source)
        precondition(!HubWorkspaceDragState.isDragging && notifications == 1)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        HubWorkspaceDragState.end(first.id, source: source)
        precondition(notifications == 1, "Duplicate or stale completion must not post a second drag end")

        let second = HubWorkspaceDragPayload(id: UUID(), workspaceID: UUID())
        HubWorkspaceDragState.begin(second, source: otherSource)
        write(second)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: first.id)
        HubWorkspaceDragState.end(first.id, source: source)
        precondition(HubWorkspaceDragState.isDragging && notifications == 1)
        precondition(HubWorkspaceDragState.localPayload(source: otherSource, pasteboard: pasteboard) == nil)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: otherSource, for: second.id)
        precondition(HubWorkspaceDragState.localPayload(source: otherSource, pasteboard: pasteboard) == second)
        HubWorkspaceDragState.end(second.id, source: otherSource)
        precondition(!HubWorkspaceDragState.isDragging && notifications == 2)

        // A native source can disappear during a SwiftUI rebuild without its
        // completion callback. Only a sustained release may clear that state.
        let abandoned = HubWorkspaceDragPayload(id: UUID(), workspaceID: UUID())
        HubWorkspaceDragState.begin(abandoned, source: source)
        write(abandoned)
        HubWorkspaceDragState.bind(pasteboard: pasteboard, source: source, for: abandoned.id)
        HubWorkspaceDragState.reconcile(mousePressed: true, now: 10)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: 11)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: 11.3)
        precondition(HubWorkspaceDragState.isDragging && notifications == 2)
        HubWorkspaceDragState.reconcile(mousePressed: true, now: 11.4)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: 12)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: 12.7)
        precondition(!HubWorkspaceDragState.isDragging && notifications == 3)
        precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: pasteboard) == nil)
        HubWorkspaceDragState.end(abandoned.id, source: source)
        precondition(notifications == 3, "A late AppKit completion cannot repeat cleanup")

        let newer = HubWorkspaceDragPayload(id: UUID(), workspaceID: UUID())
        HubWorkspaceDragState.begin(newer, source: otherSource)
        HubWorkspaceDragState.end(abandoned.id, source: source)
        HubWorkspaceDragState.reconcile(mousePressed: true, now: 20)
        precondition(HubWorkspaceDragState.current == newer && notifications == 3,
                     "An old completion must not end a newer active drag")
        HubWorkspaceDragState.end(newer.id, source: otherSource)
        precondition(!HubWorkspaceDragState.isDragging && notifications == 4)

        testAbandonedRealSource()
        precondition(notifications == 6, "Each recovered native source sends exactly one end notification")
        testDomainsAndDestinations()
        testClicksAndPreview()
        print("PASS: workspace/shortcut domain isolation, native destination lifecycle, file drag pass-through, midpoint insertion, click-only selection, preview, private pasteboard authentication, stale callbacks and released-session recovery")
        print("LIMIT: Real pointer dragging, native destination routing, edge autoscroll and animated tab reorder require UI verification; tests create no visible windows or files")
    }

    @MainActor private static func testAbandonedRealSource() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HubWorkspaceDragBridge.WorkspaceDragView(frame: NSRect(x: 0, y: 0, width: 30, height: 32))
        window.contentView!.addSubview(view)
        var phases = [Bool]()
        view.onDragStateChanged = { phases.append($0) }
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: 12), to: nil),
                modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func start() {
            view.mouseDown(with: event(.leftMouseDown, x: 5))
            view.mouseDragged(with: event(.leftMouseDragged, x: 15))
        }
        start()
        precondition(HubWorkspaceDragState.isDragging && phases == [true], "A native source session must start")
        HubWorkspaceDragState.reconcile(mousePressed: false, now: now)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: now + 0.7)
        precondition(!HubWorkspaceDragState.isDragging && phases == [true, false], "Recovery clears the real source and completion")
        start()
        precondition(HubWorkspaceDragState.isDragging && phases == [true, false, true], "An abandoned source must not block a later drag")
        HubWorkspaceDragState.reconcile(mousePressed: false, now: now + 1)
        HubWorkspaceDragState.reconcile(mousePressed: false, now: now + 1.7)
        precondition(!HubWorkspaceDragState.isDragging && phases == [true, false, true, false])
        precondition(!window.isVisible, "The native source test must not show a window")
    }

    @MainActor private static func testDomainsAndDestinations() {
        let bounds = NSRect(x: 0, y: 0, width: 30, height: 32)
        for domain in [HubWorkspaceDragDomain.workspace, .shortcut] {
            let source = HubWorkspaceDragBridge.WorkspaceDragView(frame: bounds)
            let target = HubWorkspaceDragBridge.WorkspaceDragView(frame: bounds)
            source.domain = domain; target.domain = domain
            let targetID = target.workspaceID
            var selects = 0
            var reordered: [(UUID, UUID, Bool)] = []
            source.onSelect = { selects += 1 }; target.onSelect = { selects += 1 }
            target.onReorder = { reordered.append(($0, $1, $2)) }
            let payload = HubWorkspaceDragPayload(id: UUID(), workspaceID: source.workspaceID, domain: domain)
            let board = NSPasteboard.withUniqueName()
            defer { HubWorkspaceDragState.end(payload.id, source: source); board.releaseGlobally() }
            func write(_ item: HubWorkspaceDragPayload) {
                board.clearContents()
                precondition(board.writeObjects([HubWorkspaceDragData.pasteboardItem(for: item)]))
                HubWorkspaceDragState.bind(pasteboard: board, source: source, for: payload.id)
            }
            HubWorkspaceDragState.begin(payload, source: source)
            write(payload)
            precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: board) == payload)
            let info = WorkspaceDropInfoFixture(board: board, source: source)
            info.draggingLocation = target.convert(NSPoint(x: 6, y: 16), to: nil)
            precondition(target.hitTest(NSPoint(x: 6, y: 16)) === target)
            precondition(target.draggingEntered(info) == .move && target.insertionAfter == false)
            precondition(target.prepareForDragOperation(info) && selects == 0 && reordered.isEmpty)

            target.domain = domain == .workspace ? .shortcut : .workspace
            precondition(target.draggingUpdated(info).isEmpty && target.insertionAfter == nil)
            precondition(!target.prepareForDragOperation(info) && !target.performDragOperation(info),
                         "Workspace tabs and fixed shortcuts must never accept each other's reorder")
            precondition(target.hitTest(NSPoint(x: 6, y: 16)) == nil)
            target.domain = domain
            let forgedDomain = HubWorkspaceDragPayload(id: payload.id, workspaceID: payload.workspaceID,
                domain: domain == .workspace ? .shortcut : .workspace)
            write(forgedDomain)
            precondition(HubWorkspaceDragState.localPayload(source: source, pasteboard: board) == nil,
                         "The domain must be authenticated together with the source/session/item identity")
            precondition(target.draggingEntered(info).isEmpty && !target.performDragOperation(info))
            write(payload)
            target.workspaceID = payload.workspaceID
            precondition(target.draggingEntered(info).isEmpty, "Self drops must not reorder")
            target.workspaceID = targetID
            info.draggingSourceOperationMask = .copy
            precondition(target.draggingEntered(info).isEmpty, "Reordering cannot consume a copy-only file source")
            info.draggingSourceOperationMask = .move
            target.isHidden = true
            precondition(target.draggingEntered(info).isEmpty)
            target.isHidden = false
            info.draggingLocation = target.convert(NSPoint(x: 29, y: 16), to: nil)
            precondition(target.draggingUpdated(info) == .move && target.insertionAfter == true)
            precondition(target.performDragOperation(info))
            precondition(reordered.count == 1 && reordered[0].0 == payload.workspaceID && reordered[0].1 == targetID && reordered[0].2)
            precondition(selects == 0 && target.insertionAfter == nil,
                         "An icon reorder must never activate the underlying AirDrop or workspace click action")
            precondition(target.draggingEntered(info) == .move)
            target.draggingExited(info)
            precondition(target.insertionAfter == nil)
            precondition(target.draggingEntered(info) == .move)
            target.concludeDragOperation(info)
            precondition(target.insertionAfter == nil)
            precondition(target.draggingEntered(info) == .move)
            HubWorkspaceDragState.end(payload.id, source: source)
            precondition(target.insertionAfter == nil && !target.performDragOperation(info), "Ending a session invalidates every outstanding target")

            board.clearContents()
            board.writeObjects([URL(fileURLWithPath: "/workspace-reorder-fixture.svg") as NSURL])
            info.draggingSource = nil
            precondition(target.hitTest(NSPoint(x: 6, y: 16)) == nil)
            precondition(target.draggingEntered(info).isEmpty && !target.prepareForDragOperation(info) && !target.performDragOperation(info),
                         "Finder files belong to the file receivers, not the shortcut reorder overlay")
            precondition(reordered.count == 1 && selects == 0)
        }
    }

    @MainActor private static func testClicksAndPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HubWorkspaceDragBridge.WorkspaceDragView(frame: NSRect(x: 0, y: 0, width: 30, height: 32))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        window.contentView = root; root.addSubview(view)
        view.domain = .shortcut; view.symbol = "star"; view.title = "收藏"
        var selections = 0
        view.onSelect = { selections += 1 }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: 10, y: 12), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        precondition(selections == 1 && !HubWorkspaceDragState.isDragging, "Ordinary clicks retain their original button action")
        view.mouseDown(with: event(.leftMouseDown))
        view.domain = .workspace
        view.mouseUp(with: event(.leftMouseUp))
        precondition(selections == 1, "A view changing domains during a press cannot invoke the replacement action")
        view.domain = .shortcut
        precondition(view.dragPreview().size == NSSize(width: 42, height: 42), "Shortcut drag previews use the supplied glyph")
        view.symbol = nil
        precondition(view.dragPreview().size.width == 100, "A missing glyph retains a readable title preview")
        precondition(view.frame.size == NSSize(width: 30, height: 32), "Drag artwork must not change the actual control's hit area")
        precondition(!window.isVisible, "Tests must not present a window")
    }
}

@MainActor private final class WorkspaceDropInfoFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?) { draggingPasteboard = board; draggingSource = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
