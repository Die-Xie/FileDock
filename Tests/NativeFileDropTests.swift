import AppKit
import UniformTypeIdentifiers

@main struct NativeFileDropTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let a = URL(fileURLWithPath: "/native-drop/A.svg"), b = URL(fileURLWithPath: "/native-drop/B.bundle")
        let id = UUID(), source = NSObject()
        let payload = HubFileDragPayload(id: id, context: .init(workspaceID: UUID(), directory: nil), urls: [a, b])
        board.writeObjects([a, b].map { HubFileDragData.pasteboardItem(for: $0, sessionID: id) })
        precondition(HubNativeFileDropData.urls(from: board) == [a, b])
        HubFileDragState.begin(payload, source: source)
        HubFileDragState.bind(pasteboard: board, for: id)
        precondition(HubFileDragState.localPayload(source: source, pasteboard: board)?.urls == [a, b])
        precondition(HubFileDragState.localPayload(source: NSObject(), pasteboard: board) == nil)
        precondition(HubFileDragState.localPayload(source: nil, pasteboard: board) == nil)
        HubFileDragState.reconcile(mousePressed: true, now: 0)
        HubFileDragState.reconcile(mousePressed: false, now: 1)
        HubFileDragState.reconcile(mousePressed: false, now: 1.2)
        precondition(HubFileDragState.isDragging, "Allow the source's release callback to finish normally")
        HubFileDragState.reconcile(mousePressed: true, now: 1.3)
        HubFileDragState.reconcile(mousePressed: false, now: 2)
        HubFileDragState.reconcile(mousePressed: false, now: 2.7)
        precondition(!HubFileDragState.isDragging, "An abandoned source must not disable later Finder/favorite drops or icon refresh")
        let next = HubFileDragPayload(id: UUID(), context: payload.context, urls: [a])
        HubFileDragState.begin(next, source: source)
        HubFileDragState.end(id)
        precondition(HubFileDragState.current?.id == next.id, "Late completion must not end a newer session")
        HubFileDragState.end(next.id)
        board.clearContents(); board.writeObjects([a as NSURL, b as NSURL])
        precondition(HubNativeFileDropData.urls(from: board) == [a, b], "Finder needs no private token")
        precondition(HubFileDragState.localPayload(source: source, pasteboard: board) == nil)
        board.clearContents()
        let item = NSPasteboardItem(); item.setString("https://example.invalid/A.svg", forType: .fileURL)
        board.writeObjects([item])
        precondition(HubNativeFileDropData.urls(from: board).isEmpty)
        for event in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .scrollWheel] {
            precondition(!HubNativeFileDropData.takesHitTest(type: event, mousePressed: true, fileDrag: true, workspaceDrag: false))
        }
        precondition(HubNativeFileDropData.takesHitTest(type: .leftMouseDragged, mousePressed: true, fileDrag: false, workspaceDrag: false))
        precondition(!HubNativeFileDropData.takesHitTest(type: .leftMouseDragged, mousePressed: true, fileDrag: false, workspaceDrag: true))
        // Exercise the actual destination callbacks, including a spring-loaded
        // context change while one AppKit drag/pasteboard stays alive.
        board.clearContents(); board.writeObjects([HubFileDragData.pasteboardItem(for: a, sessionID: id)])
        let live = HubFileDragPayload(id: id, context: payload.context, urls: [a])
        HubFileDragState.begin(live, source: source); HubFileDragState.bind(pasteboard: board, for: id)
        let destination = HubNativeFileDropBridge.DestinationView(frame: NSRect(x: 0, y: 0, width: 600, height: 350))
        let info = DropInfoFixture(board: board, source: source)
        var selectedTarget = "source", receivedTarget = "", events = 0
        destination.contains = { $0.x < 500 }
        destination.operation = { _, urls, payload, copy in
            precondition(urls == [a] && payload?.id == id); events += 1
            return copy ? .copy : .move
        }
        destination.receive = { urls, payload, _, copy in
            precondition(urls == [a] && payload?.id == id && !copy)
            receivedTarget = selectedTarget; return true
        }
        precondition(destination.draggingEntered(info) == .move)
        selectedTarget = "target"
        precondition(destination.draggingUpdated(info) == .move)
        precondition(destination.prepareForDragOperation(info))
        precondition(destination.performDragOperation(info) && receivedTarget == "target")
        precondition(events >= 3)
        info.draggingSourceOperationMask = .copy
        var copyProposed = false
        destination.operation = { _, _, _, copy in copyProposed = copy; return copy ? .copy : .move }
        precondition(destination.draggingUpdated(info) == .copy && copyProposed, "Copy-only sources must also display copy feedback")
        info.draggingLocation = CGPoint(x: 550, y: 10)
        precondition(destination.draggingUpdated(info).isEmpty)
        HubFileDragState.end(id)
        let tab = UUID(), hidden = UUID()
        let regions: [HubFileDropRegion: CGRect] = [
            .content: CGRect(x: 0, y: 50, width: 600, height: 300),
            .workspace(tab): CGRect(x: 80, y: 0, width: 100, height: 40),
            .tabViewport(tab): CGRect(x: 0, y: 0, width: 120, height: 40),
            .workspace(hidden): CGRect(x: 130, y: 0, width: 100, height: 40),
            .tabViewport(hidden): CGRect(x: 0, y: 0, width: 120, height: 40),
            .staging: CGRect(x: 500, y: 0, width: 36, height: 32)]
        precondition(HubFileDropRegion.at(CGPoint(x: 90, y: 20), in: regions) == .workspace(tab))
        precondition(HubFileDropRegion.at(CGPoint(x: 150, y: 20), in: regions) == nil, "Clipped tab geometry must never intercept another control")
        precondition(HubFileDropRegion.at(CGPoint(x: 520, y: 20), in: regions) == .staging)
        precondition(HubFileDropRegion.at(CGPoint(x: 50, y: 100), in: regions) == .content)
        precondition(HubFileDropRegion.at(CGPoint(x: 50, y: 400), in: regions) == nil)
        let c = URL(fileURLWithPath: "/native-drop/C.txt")
        let content = CGRect(x: 0, y: 50, width: 600, height: 300)
        let cells = [a: CGRect(x: 10, y: 60, width: 90, height: 100), b: CGRect(x: 110, y: 60, width: 90, height: 100), c: CGRect(x: 210, y: 60, width: 90, height: 100)]
        let beforeB = HubFileInsertionSlot.resolve(at: CGPoint(x: 115, y: 100), frames: cells, order: [a, b, c], content: content, horizontal: false)!
        precondition(beforeB.before == b && beforeB.rect.width == 2)
        let afterB = HubFileInsertionSlot.resolve(at: CGPoint(x: 195, y: 100), frames: cells, order: [a, b, c], content: content, horizontal: false)!
        precondition(afterB.before == c && afterB.rect.width == 2)
        let tail = HubFileInsertionSlot.resolve(at: CGPoint(x: 590, y: 200), frames: cells, order: [a, b, c], content: content, horizontal: false)!
        precondition(tail.before == nil)
        let excludingB = HubFileInsertionSlot.resolve(at: CGPoint(x: 195, y: 100), frames: cells, order: [a, b, c], content: content, horizontal: false, excluding: [b])!
        precondition(excludingB.before != b)
        let list = [a: CGRect(x: 0, y: 60, width: 600, height: 30), b: CGRect(x: 0, y: 91, width: 600, height: 30)]
        let row = HubFileInsertionSlot.resolve(at: CGPoint(x: 40, y: 92), frames: list, order: [a, b], content: content, horizontal: true)!
        precondition(row.before == b && row.rect.height == 2)
        print("PASS: native multi-URL/SVG/Finder data, exact source authentication, stale release recovery, late callback isolation and click/scroll/workspace pass-through")
    }
}

@MainActor private final class DropInfoFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.move, .copy]
    var draggingLocation = NSPoint(x: 10, y: 10)
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
