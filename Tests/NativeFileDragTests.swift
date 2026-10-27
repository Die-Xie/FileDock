import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct NativeFileDragTests {
    @MainActor static func main() {
        let first = URL(fileURLWithPath: "/drag-fixture/报告 A.txt")
        let second = URL(fileURLWithPath: "/drag-fixture/B.pdf")
        let folder = URL(fileURLWithPath: "/drag-fixture/folder")
        let remote = URL(string: "https://example.invalid/file.txt")!
        precondition(HubFileDragData.sourceOperations(for: .outsideApplication, canTrash: true).contains(.delete))
        precondition(!HubFileDragData.sourceOperations(for: .withinApplication, canTrash: true).contains(.delete))
        precondition(!HubFileDragData.sourceOperations(for: .outsideApplication, canTrash: false).contains(.delete))
        var trashed: [[URL]] = []
        for operation: NSDragOperation in [[], .copy, .move, .link, [.copy, .delete]] {
            let completion = HubFileDragCompletion(urls: [first, second], onTrash: { trashed.append($0) })
            completion.finish(operation: operation)
            completion.finish(operation: .delete)
            precondition(trashed.isEmpty, "Cancellation, successful moves/copies and ambiguous flags must never delete the source")
        }
        let completion = HubFileDragCompletion(urls: [first, second], onTrash: { trashed.append($0) })
        completion.finish(operation: .delete); completion.finish(operation: .delete)
        precondition(trashed == [[first, second]], "Trash completion must use the captured full batch and run exactly once")
        let cancelled = HubFileDragCompletion(urls: [folder], onTrash: { trashed.append($0) })
        cancelled.cancel(); cancelled.finish(operation: .delete)
        precondition(trashed.count == 1, "Abandoned native sessions cannot act on a late deletion callback")
        precondition(HubFileDragData.urls(for: first, selection: []) == [first])
        precondition(HubFileDragData.urls(for: first, selection: [second, folder]) == [first],
                     "Dragging an unselected entry must not drag an unrelated selection")
        precondition(HubFileDragData.urls(for: second, selection: [first, second, folder]) == [first, second, folder],
                     "Dragging any selected entry preserves the complete ordered selection")
        precondition(HubFileDragData.urls(for: first, selection: [first, URL(fileURLWithPath: "/drag-fixture/child/../报告 A.txt"), second, remote]) == [first, second])
        precondition(HubFileDragData.urls(for: remote, selection: []).isEmpty)

        let cellBounds = NSRect(x: 0, y: 0, width: 100, height: 100)
        let oversizedVisibleRect = NSRect(x: -234.5, y: -223, width: 900, height: 337)
        precondition(HubFileDragData.contains(NSPoint(x: 50, y: 50), bounds: cellBounds, visibleRect: oversizedVisibleRect))
        precondition(!HubFileDragData.contains(NSPoint(x: 280, y: 50), bounds: cellBounds, visibleRect: oversizedVisibleRect),
                     "An oversized SwiftUI visibleRect must not arm neighboring file cells")
        precondition(!HubFileDragData.contains(NSPoint(x: -10, y: 50), bounds: cellBounds, visibleRect: oversizedVisibleRect))
        let clippedVisibleRect = NSRect(x: 0, y: 40, width: 100, height: 60)
        precondition(!HubFileDragData.contains(NSPoint(x: 50, y: 20), bounds: cellBounds, visibleRect: clippedVisibleRect))
        precondition(HubFileDragData.contains(NSPoint(x: 50, y: 60), bounds: cellBounds, visibleRect: clippedVisibleRect))
        precondition(!HubFileDragData.contains(NSPoint(x: 50, y: 50), bounds: cellBounds, visibleRect: .zero))

        let sessionID = UUID()
        let items = [first, second, folder].map { HubFileDragData.pasteboardItem(for: $0, sessionID: sessionID) }
        precondition(items.count == 3)
        for (item, url) in zip(items, [first, second, folder]) {
            precondition(item.types.contains(.fileURL))
            precondition(item.string(forType: .fileURL).flatMap(URL.init(string:)) == url,
                         "Every native drag item must export its actual file URL, including Unicode and spaces")
            precondition(item.string(forType: NSPasteboard.PasteboardType(hubFileDragType.identifier)) == sessionID.uuidString)
        }

        let workspaceID = UUID()
        let context = HubFileDragContext(workspaceID: workspaceID, directory: URL(fileURLWithPath: "/drag-fixture"))
        let payload = HubFileDragPayload(id: sessionID, context: context, urls: [first, second])
        precondition(payload.folderURLs == nil)
        let kinds = HubFileDragPayload(id: sessionID, context: context, urls: [first, folder],
            folderURLs: [URL(fileURLWithPath: "/drag-fixture/child/../folder")])
        precondition(kinds.folderURLs == [folder], "Folder hints normalize once at source capture, independently of destination snapshots")
        precondition(HubFileDragData.shouldReorder(payload, in: context))
        precondition(HubFileDragData.shouldReorder(payload, in: HubFileDragContext(workspaceID: workspaceID, directory: URL(fileURLWithPath: "/drag-fixture/sub/.."))))
        precondition(!HubFileDragData.shouldReorder(payload, in: HubFileDragContext(workspaceID: UUID(), directory: context.directory)))
        precondition(!HubFileDragData.shouldReorder(payload, in: HubFileDragContext(workspaceID: workspaceID, directory: folder)))
        let references = HubFileDragContext(workspaceID: workspaceID, directory: nil)
        precondition(HubFileDragData.shouldReorder(HubFileDragPayload(id: sessionID, context: references, urls: [folder]), in: references))
        precondition(!HubFileDragData.shouldReorder(payload, in: references))
        let absentWorkspace = HubFileDragContext(workspaceID: nil, directory: nil)
        precondition(!HubFileDragData.shouldReorder(HubFileDragPayload(id: sessionID, context: absentWorkspace, urls: [first]), in: absentWorkspace))

        let localProvider = NSItemProvider()
        localProvider.registerDataRepresentation(forTypeIdentifier: hubFileDragType.identifier, visibility: .ownProcess) { completion in
            completion(Data(sessionID.uuidString.utf8), nil)
            return nil
        }
        let ordinaryProviders = [first, second].map { NSItemProvider(object: $0 as NSURL) }
        let textProvider = NSItemProvider(object: "unrelated text" as NSString)
        var endedNotifications = 0
        let endObserver = NotificationCenter.default.publisher(for: hubFileDragDidEnd).sink { notification in
            precondition(notification.object == nil && notification.userInfo == nil,
                         "Clearing drop highlights must not publish dragged file data")
            endedNotifications += 1
        }
        defer { endObserver.cancel() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func writeItems(_ values: [NSPasteboardItem]) {
            pasteboard.clearContents()
            precondition(pasteboard.writeObjects(values))
        }
        func validItems(id: UUID = sessionID) -> [NSPasteboardItem] {
            [first, second].map { HubFileDragData.pasteboardItem(for: $0, sessionID: id) }
        }
        writeItems(validItems())
        precondition(HubFileDragState.localPayload(for: [localProvider]) == nil,
                     "A private type alone must not create a local drag session")
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil)
        HubFileDragState.begin(payload)
        precondition(HubFileDragState.isDragging)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "An armed source without an actual session pasteboard must not accept a drop")
        HubFileDragState.bind(pasteboard: pasteboard, for: UUID())
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil)
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders)?.urls == [first, second],
                     "SwiftUI's file-only providers must resolve through the real native pasteboard tokens")
        precondition(HubFileDragState.localPayload(for: [localProvider]) == nil)
        precondition(HubFileDragState.localPayload(for: []) == nil)
        precondition(HubFileDragState.localPayload(for: [ordinaryProviders[0]]) == nil,
                     "A different provider count must not be treated as the active native drag")
        precondition(HubFileDragState.localPayload(for: [ordinaryProviders[0], textProvider]) == nil)

        writeItems(validItems())
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "Replacing the pasteboard invalidates its session binding even if its contents look identical")
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) != nil)

        let mixedTokens = validItems()
        mixedTokens[1].setString(UUID().uuidString, forType: NSPasteboard.PasteboardType(hubFileDragType.identifier))
        writeItems(mixedTokens)
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "Every native item must belong to the same session")
        let changedURL = validItems()
        changedURL[0].setString(folder.absoluteString, forType: .fileURL)
        writeItems(changedURL)
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "Matching tokens must not accept a different set of file URLs")
        let missingToken = NSPasteboardItem()
        missingToken.setString(second.absoluteString, forType: .fileURL)
        writeItems([HubFileDragData.pasteboardItem(for: first, sessionID: sessionID), missingToken])
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil)

        writeItems(validItems())
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        HubFileDragState.end(UUID())
        precondition(HubFileDragState.isDragging, "A stale completion must not clear another session")
        precondition(endedNotifications == 0)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) != nil)
        HubFileDragState.end(sessionID)
        precondition(!HubFileDragState.isDragging)
        precondition(endedNotifications == 1, "Completing or canceling the active drag must clear destination highlights")
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "A completed session cannot reuse surviving pasteboard tokens")

        let nextID = UUID()
        HubFileDragState.begin(HubFileDragPayload(id: nextID, context: context, urls: [first, second]))
        HubFileDragState.bind(pasteboard: pasteboard, for: sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) == nil,
                     "A stale source callback must not bind its pasteboard to a newer session")
        writeItems(validItems(id: nextID))
        HubFileDragState.bind(pasteboard: pasteboard, for: nextID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) != nil)
        HubFileDragState.end(sessionID)
        precondition(HubFileDragState.localPayload(for: ordinaryProviders) != nil)
        precondition(endedNotifications == 1, "A stale completion must not clear the current drag's highlight")
        HubFileDragState.end(nextID)
        precondition(endedNotifications == 2)

        let sourceView = HubFileDragBridge.FileDragView()
        precondition(!sourceView.mouseDownCanMoveWindow)
        precondition(sourceView.acceptsFirstResponder, "Clicking a file must be able to move focus out of search")
        precondition(sourceView.acceptsFirstMouse(for: nil))
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sourceView.frame = NSRect(x: 20, y: 30, width: 100, height: 100)
        parentView.addSubview(sourceView)
        precondition(sourceView.hitTest(NSPoint(x: 60, y: 70)) === sourceView,
                     "The native overlay must receive file mouseDown in its superview coordinate system")
        precondition(sourceView.hitTest(NSPoint(x: 10, y: 70)) == nil)
        precondition(sourceView.hitTest(NSPoint(x: 150, y: 70)) == nil)
        sourceView.isHidden = true
        precondition(sourceView.hitTest(NSPoint(x: 60, y: 70)) == nil)
        sourceView.isHidden = false
        sourceView.interactionEnabled = false
        precondition(sourceView.hitTest(NSPoint(x: 60, y: 70)) == nil,
                     "Inline filename editing must receive text clicks instead of starting a file drag")
        sourceView.interactionEnabled = true
        _ = NSApplication.shared
        let sourcePanel = NSPanel(contentRect: parentView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        sourcePanel.isReleasedWhenClosed = false
        sourcePanel.contentView = parentView
        let outgoing = HubFileDragPayload(id: UUID(), context: context, urls: [first, second])
        writeItems(validItems(id: outgoing.id))
        HubFileDragState.begin(outgoing, source: sourceView)
        HubFileDragState.bind(pasteboard: pasteboard, for: outgoing.id)
        sourcePanel.ignoresMouseEvents = true
        sourcePanel.orderOut(nil)
        HubFileDragState.reconcile(mousePressed: true, now: 100)
        let surviving = HubFileDragState.localPayload(source: sourceView, pasteboard: pasteboard)
        precondition(surviving?.id == outgoing.id && surviving?.urls == outgoing.urls,
                     "Hiding the source panel must retain the authenticated file URLs and drag identity until release")
        precondition(sourceView.window === sourcePanel && HubFileDragState.isDragging)
        HubFileDragState.end(outgoing.id)
        sourcePanel.contentView = nil; sourcePanel.close()
        precondition(HubFileDragData.takesMouseDown(.leftMouseDown, modifiers: []))
        precondition(HubFileDragData.takesMouseDown(.leftMouseDown, modifiers: [.command, .shift]))
        precondition(!HubFileDragData.takesMouseDown(.leftMouseDown, modifiers: .control),
                     "Control-click must retain normal SwiftUI context-menu dispatch")
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .leftMouseUp] {
            precondition(!HubFileDragData.takesMouseDown(type, modifiers: []),
                         "Only initial left mouseDown may hit the overlay; context menus, scrolling and drop targeting pass through")
        }
        let handle = HubWindowDragHandle.DragHandleView()
        precondition(!handle.mouseDownCanMoveWindow, "Only explicit performDrag in the header starts a window drag")

        print("PASS: single/multiple file selection, real per-item URL pasteboard data, clipped responder hit regions, context-menu/scroll/drop pass-through, workspace/directory isolation, authenticated native pasteboard lifecycle and SwiftUI-filtered providers")
        print("LIMIT: Native pointer drag initiation, Finder drops and header hit regions require UI verification; tests perform no file mutations or visible window operations")
    }
}
