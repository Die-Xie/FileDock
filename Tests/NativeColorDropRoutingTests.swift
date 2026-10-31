import AppKit
import SwiftUI

@main struct NativeColorDropRoutingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-UnifiedColorRoute-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let model = makeTestModel(storageURL: root.appendingPathComponent("settings.json"))
        model.addWorkspace(name: "Folder", mode: .folder, urls: [destination])
        model.settings.switchDelay = 0
        let state = HubPresentationState(); state.previewVisible = true
        let music = HubQQMusicController()
        func content() -> HubView { HubView(model: model, presentation: state, music: music, onSettings: {}, onClose: {}) }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for trial in 0..<3 {
            model.setColorLabelFilter(.orange)
            if trial == 1 { window.setContentSize(NSSize(width: 900, height: 520)); host.rootView = content() }
            settle(host)
            let receivers = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
            precondition(receivers.count == 1, "All native file URL entry points must share one receiver after resize/rebuild")
            let router = receivers[0]
            precondition(router.identifier?.rawValue == "FileDockUnifiedFileDropRouter" && router.bounds.size == host.bounds.size)
            let registered = descendants(host).filter { $0.registeredDraggedTypes.contains(.fileURL) || $0.registeredDraggedTypes.contains(HubNativeFileDropData.legacyFiles) }
            precondition(registered.count == 1 && registered[0] === router,
                         "No SwiftUI, color-button or secondary overlay may register another file URL destination")
            let y = router.bounds.height - 21
            let xs = stride(from: CGFloat(0), to: router.bounds.width, by: 1).filter { router.contains(CGPoint(x: $0, y: y)) }
            precondition(xs.count == 8 * 28, "Color targets include their full padded hit area")
            let blue = CGPoint(x: xs.min()! + 4 * 28 + 14, y: y)
            precondition(router.contains(CGPoint(x: xs.min()! + 4 * 28 + 2, y: y + 11)))
            router.currentEventType = { .leftMouseDragged }; router.primaryMousePressed = { true }
            router.currentEventIsLocalPress = { false }
            let hostPoint = host.convert(blue, from: router)
            do {
                for event in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .rightMouseUp, .scrollWheel] {
                    router.currentEventType = { event }
                    precondition(host.hitTest(host.convert(hostPoint, to: host.superview)) === router,
                                 "A quick Finder re-entry cannot depend on NSApp's retained event timestamp")
                }
            }
            // The same view yields ordinary local clicks, even if delivery is slow.
            router.currentEventIsLocalPress = { true }; router.currentEventType = { .leftMouseDown }
            precondition(!(host.hitTest(host.convert(hostPoint, to: host.superview)) is HubNativeFileDropBridge.DestinationView))
            router.currentEventIsLocalPress = { false }; router.currentEventType = { .leftMouseDragged }
            let item = source.appendingPathComponent("external-\(trial).txt")
            try Data("external".utf8).write(to: item)
            var editable = item, red = URLResourceValues(); red.labelNumber = 6; try editable.setResourceValues(red)
            board.clearContents(); precondition(board.writeObjects([item as NSURL]))
            let info = ExternalDraggingInfo(board: board, window: window)
            info.draggingSourceOperationMask = trial == 2 ? .copy : .move
            info.draggingLocation = router.convert(blue, to: nil)
            let operation: NSDragOperation = trial == 2 ? .copy : .move
            precondition(router.draggingEntered(info) == operation && router.draggingUpdated(info) == operation)
            settle(host)
            precondition(descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first === router,
                         "Feedback repaint cannot replace the active destination")
            router.currentEventType = { .leftMouseUp }; router.primaryMousePressed = { false }
            precondition(host.hitTest(host.convert(hostPoint, to: host.superview)) === router)
            precondition(router.prepareForDragOperation(info) && router.performDragOperation(info))
            try await wait(model)
            let output = destination.appendingPathComponent(item.lastPathComponent)
            precondition(fm.fileExists(atPath: item.path) == (trial == 2) && FileEntry(url: output).labelNumber == 4,
                         "Use the actual blue drop target and the source operation mask, regardless of orange filter")
            if trial != 2 {
                precondition(model.undoLastFileDrop()); try await wait(model)
                precondition(fm.fileExists(atPath: item.path) && !fm.fileExists(atPath: output.path) && FileEntry(url: item).labelNumber == 6)
            }
            router.currentEventType = { .mouseMoved }
            precondition(!(host.hitTest(host.convert(hostPoint, to: host.superview)) is HubNativeFileDropBridge.DestinationView))
        }
        settle(host)
        let router = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first!
        let y = router.bounds.height - 21
        let xs = stride(from: CGFloat(0), to: router.bounds.width, by: 1).filter { router.contains(CGPoint(x: $0, y: y)) }
        let blue = CGPoint(x: xs.min()! + 4 * 28 + 14, y: y)
        let staleReceive = router.receive!
        let untouched = source.appendingPathComponent("untouched.txt"); try Data("keep".utf8).write(to: untouched)
        model.settings.colorLabelFilterEnabled = false
        precondition(!staleReceive([untouched], nil, blue, false))
        settle(host)
        precondition(descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.count == 1,
                     "Hiding colors does not add/remove the shared file destination")
        model.settings.colorLabelFilterEnabled = true
        state.previewVisible = false
        precondition(!staleReceive([untouched], nil, blue, false))
        state.previewVisible = true
        let ticket = HubImportActivity.begin()!
        precondition(!staleReceive([untouched], nil, blue, false)); HubImportActivity.end(ticket)
        precondition(fm.fileExists(atPath: untouched.path) && FileEntry(url: untouched).labelNumber == 0)
        print("PASS: one registered native file destination, direct Finder color drops, quick retained-event re-entry, ordinary clicks, padded colors, mask/undo, resize/rebuild and stale rejection")
        print("LIMIT: Hidden host callbacks do not reproduce WindowServer destination selection or actual cursor motion")
    }
    @MainActor static func wait(_ model: HubModel) async throws {
        for _ in 0..<1000 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0)
    }
    @MainActor static func settle(_ view: NSView) {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class ExternalDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, window: NSWindow) { draggingPasteboard = board; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
