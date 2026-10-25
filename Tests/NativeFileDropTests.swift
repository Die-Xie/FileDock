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
        board.clearContents()
        let invalidMixedItem = NSPasteboardItem()
        invalidMixedItem.setString("https://example.invalid/A.svg", forType: .fileURL)
        board.writeObjects([HubFileDragData.pasteboardItem(for: a, sessionID: id), invalidMixedItem])
        precondition(HubNativeFileDropData.urls(from: board).isEmpty,
                     "A mixed invalid selection must be rejected rather than silently sharing its valid subset")
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
        testAirDropDestinations()
        print("PASS: native multi-URL/SVG/Finder data, exact source authentication, stale release recovery, AirDrop target lifecycle and click/scroll/workspace pass-through")
    }

    @MainActor private static func testAirDropDestinations() {
        let svg = URL(fileURLWithPath: "/native-drop/original.svg")
        let folder = URL(fileURLWithPath: "/native-drop/original-folder", isDirectory: true)
        let files = [svg, folder]
        precondition(HubFileDropPlan.airDrop(urls: [], allowed: true) == nil)
        precondition(HubFileDropPlan.airDrop(urls: files, allowed: false) == nil)
        precondition(HubFileDropPlan.airDrop(urls: [URL(string: "https://example.invalid/file.svg")!], allowed: true) == nil)
        precondition(HubFileDropPlan.airDrop(urls: [URL(string: "file://remote-host/shared/file.svg")!], allowed: true) == nil)
        let limit = (0..<1000).map { URL(fileURLWithPath: "/native-drop/item-\($0)") }
        precondition(HubFileDropPlan.airDrop(urls: limit, allowed: true)?.action == .airDrop)
        precondition(HubFileDropPlan.airDrop(urls: limit + [svg], allowed: true) == nil)

        let airDropFrame = CGRect(x: 440, y: 0, width: 30, height: 32)
        let workspace = UUID()
        let regions: [HubFileDropRegion: CGRect] = [
            .airDrop: airDropFrame,
            .workspace(workspace): CGRect(x: 400, y: 0, width: 100, height: 40),
            .staging: CGRect(x: 460, y: 0, width: 30, height: 32),
            .content: CGRect(x: 0, y: 20, width: 600, height: 330)]
        precondition(HubFileDropRegion.at(CGPoint(x: 465, y: 25), in: regions) == .airDrop,
                     "AirDrop must win even when a stale tab/staging/content frame overlaps its control")
        precondition(HubFileDropRegion.at(CGPoint(x: 455, y: 10), in: regions.filter { $0.key != .airDrop }) != .airDrop,
                     "A disabled, removed AirDrop control cannot retain an active hit region")

        for isLocal in [false, true] {
            let board = NSPasteboard.withUniqueName()
            let source = NSObject(), id = UUID()
            if isLocal {
                let payload = HubFileDragPayload(id: id, context: .init(workspaceID: workspace, directory: folder), urls: files)
                board.writeObjects(files.map { HubFileDragData.pasteboardItem(for: $0, sessionID: id) })
                HubFileDragState.begin(payload, source: source)
                HubFileDragState.bind(pasteboard: board, for: id)
            } else { board.writeObjects(files.map { $0 as NSURL }) }
            defer { HubFileDragState.end(id); board.releaseGlobally() }

            let destination = HubNativeFileDropBridge.DestinationView(frame: CGRect(x: 0, y: 0, width: 600, height: 350))
            let info = DropInfoFixture(board: board, source: isLocal ? source : nil)
            info.draggingLocation = destination.convert(CGPoint(x: 455, y: 10), to: nil)
            var allowed = true
            var feedback: HubFileDropFeedback?
            var received: [[URL]] = []
            var exits = 0
            destination.contains = { HubFileDropRegion.at($0, in: regions) != nil }
            destination.operation = { point, urls, payload, _ in
                precondition((payload != nil) == isLocal)
                guard HubFileDropRegion.at(point, in: regions) == .airDrop,
                      let plan = HubFileDropPlan.airDrop(urls: urls, allowed: allowed) else {
                    feedback = nil; return []
                }
                precondition(plan.action == .airDrop && plan.directory == nil && plan.workspaceID == nil && plan.slot == nil,
                             "AirDrop must not supply a reorder, staging, folder move or insertion destination")
                feedback = HubFileDropFeedback(rect: airDropFrame, title: plan.title, count: urls.count,
                                               action: plan.action, insertion: false)
                return .copy
            }
            destination.exited = { feedback = nil; exits += 1 }
            destination.receive = { urls, payload, point, _ in
                guard HubFileDropRegion.at(point, in: regions) == .airDrop,
                      HubFileDropPlan.airDrop(urls: urls, allowed: allowed) != nil else { return false }
                precondition((payload != nil) == isLocal)
                received.append(urls)
                return true
            }
            precondition(destination.draggingEntered(info) == .copy)
            precondition(feedback?.rect == airDropFrame && feedback?.insertion == false)
            precondition(feedback?.prompt == "松开以通过 AirDrop 发送 2 项")
            precondition(destination.draggingUpdated(info) == .copy && received.isEmpty,
                         "Hovering an AirDrop target must never submit files or open sharing UI")
            precondition(destination.prepareForDragOperation(info) && received.isEmpty)
            precondition(destination.performDragOperation(info) && received == [files],
                         "Finder and local SVG/directory drops must retain their original file URLs")
            precondition(feedback == nil && exits > 0, "Successful drops clear highlighting before presentation")

            allowed = false
            precondition(destination.draggingUpdated(info).isEmpty && feedback == nil)
            precondition(!destination.prepareForDragOperation(info) && !destination.performDragOperation(info))
            precondition(received.count == 1, "Disabling AirDrop or starting file work must reject a pending drop")
            allowed = true
            info.draggingSourceOperationMask = .move
            precondition(destination.draggingUpdated(info).isEmpty && !destination.performDragOperation(info),
                         "An AirDrop receiver must never accept a move-only source or remove source files")
            info.draggingSourceOperationMask = .copy
            precondition(destination.draggingUpdated(info) == .copy)
            info.draggingLocation = destination.convert(CGPoint(x: 550, y: 10), to: nil)
            precondition(destination.draggingUpdated(info).isEmpty && feedback == nil)
            info.draggingLocation = destination.convert(CGPoint(x: 455, y: 10), to: nil)
            precondition(destination.draggingEntered(info) == .copy)
            destination.draggingExited(info)
            precondition(feedback == nil)
            precondition(destination.draggingEntered(info) == .copy)
            destination.draggingEnded(info)
            precondition(feedback == nil)
            precondition(destination.draggingEntered(info) == .copy)
            HubNativeFileDropBridge.dismantleNSView(destination, coordinator: ())
            precondition(feedback == nil && received.count == 1)
        }
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
