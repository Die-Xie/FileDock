import AppKit
import SwiftUI

@MainActor private final class ReorderProbeApplication: NSApplication {
 var injectedEvent: NSEvent?
 override var currentEvent: NSEvent? { injectedEvent ?? super.currentEvent }
}

@main struct NativeReorderRoutingTests {
 @MainActor static func main() async throws {
  let app = ReorderProbeApplication.shared as! ReorderProbeApplication
  let fm = FileManager.default
  let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-ReorderProbe-\(UUID())")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let files = ["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }
  for f in files { try Data("fixture".utf8).write(to: f) }
  for reference in [false, true] {
   for mode in [HubViewMode.grid, .list, .columns] {
    for delayMS in [0, 40] {
    let model = makeTestModel(storageURL: root.appendingPathComponent("config-\(reference)-\(mode)-\(delayMS).json"))
    let contexts = ["Probe A", "Probe B", "Probe C"].map { name in
      Workspace(name: name, mode: reference ? .references : .folder, rootPath: reference ? nil : root.path,
          referencePaths: reference ? files.map(\.path) : [])
    }
    model.workspaces = contexts
    model.settings.qqMusicEnabled = false
    model.settings.favoriteShortcutEnabled = false; model.settings.recentShortcutEnabled = false
    model.settings.stagingEnabled = false; model.settings.airDropEnabled = false
    for context in contexts { model.selectWorkspace(context.id) }
    model.selectWorkspace(contexts[0].id)
    for _ in 0..<500 where model.directoryLoading { try await Task.sleep(nanoseconds: 5_000_000) }
    model.viewMode = mode
    model.settings.groupsEnabled = false
    model.setManualEntryOrder(true)
    let presentation = HubPresentationState(); presentation.previewVisible = true
    var feedbackHistory: [HubFileDropFeedback?] = []
    let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: HubQQMusicController(), onSettings: {}, onClose: {},
        onFileDropFeedbackChanged: { feedbackHistory.append($0) }))
    let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 900,height: 500), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    settle(host)
    let original = model.visibleEntries.filter { files.contains($0.url) }.map(\.url)
    precondition(original.count == 3, "The three fixtures must be visible")
    let moving = original.last!, before = original.first!
    let views = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }
    guard let targetCell = views.first(where: { $0.entryURL == before }),
          let source = views.first(where: { $0.entryURL == moving }) else { fatalError("Missing source or target cell") }
    let destinationViews = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
    precondition(destinationViews.count == 1 && descendants(host).filter { $0.registeredDraggedTypes.contains(.fileURL) }.count == 1,
                 "The real HubView must keep exactly one file URL receiver")
    let tabs = descendants(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
        .filter { contexts.map(\.id).contains($0.workspaceID) }
    precondition(tabs.count == 3)
    let tabFrames = Dictionary(uniqueKeysWithValues: tabs.map { ($0.workspaceID, $0.convert($0.bounds, to: host)) })
    let tabObjects = Dictionary(uniqueKeysWithValues: tabs.map { ($0.workspaceID, ObjectIdentifier($0)) })
    let routerFrame = destinationViews[0].convert(destinationViews[0].bounds, to: host)
    func checkStableHierarchy() {
      let current = descendants(host)
      let receivers = current.compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
      precondition(receivers.count == 1 && receivers[0] === destinationViews[0])
      precondition(current.filter { $0.registeredDraggedTypes.contains(.fileURL) }.count == 1)
      precondition(receivers[0].convert(receivers[0].bounds, to: host) == routerFrame, "Content motion cannot move its file receiver")
      let currentTabs = current.compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
          .filter { tabObjects[$0.workspaceID] != nil }
      precondition(currentTabs.count == tabs.count)
      for tab in currentTabs {
        precondition(tabObjects[tab.workspaceID] == ObjectIdentifier(tab) && tabFrames[tab.workspaceID] == tab.convert(tab.bounds, to: host),
                     "Only the selection plate may animate; native tab sources retain identity and hit frames")
      }
      precondition(current.contains { $0 === source } && current.contains { $0 === targetCell },
                   "Switching warm contexts with the same files cannot rebuild their native drag cells")
    }
    for destination in destinationViews {
      destination.currentEventType = { .leftMouseDown }
      destination.primaryMousePressed = { true }
    }
    let pressRect = targetCell.convert(targetCell.bounds, to: host)
    let pressPoint = CGPoint(x: pressRect.midX, y: pressRect.midY)
    app.injectedEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(pressPoint, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    HubLocalFilePressDispatch.begin(app.injectedEvent!)
    let dispatchedPress = app.injectedEvent!
    precondition(HubLocalFilePressDispatch.contains(dispatchedPress), "The currently dispatched local press must be recognized")
    let pressHitPoint = host.superview?.convert(pressPoint, from: host) ?? pressPoint
    precondition(host.hitTest(pressHitPoint) === targetCell,
                 "A delayed local mouseDown must reach the file cell, reference=\(reference), mode=\(mode)")
    app.injectedEvent = nil
    try await Task.sleep(nanoseconds: 10_000_000)
    precondition(!HubLocalFilePressDispatch.contains(dispatchedPress), "The dispatch mark must expire so a retained event cannot block Finder")
    for destination in destinationViews { destination.currentEventType = { .leftMouseDragged } }
    for context in [contexts[1], contexts[2], contexts[0]] {
      model.selectWorkspace(context.id)
      host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
      checkStableHierarchy()
    }
    if delayMS > 0 { try await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000) }
    host.layoutSubtreeIfNeeded(); checkStableHierarchy()
    let board = NSPasteboard.withUniqueName(), id = UUID()
    let payload = HubFileDragPayload(id: id, context: .init(workspaceID: model.selectedWorkspaceID, directory: model.currentURL), urls: [moving])
    HubFileDragState.begin(payload, source: source)
    board.writeObjects([HubFileDragData.pasteboardItem(for: moving, sessionID: id)])
    defer { HubFileDragState.end(id); board.releaseGlobally() }
    host.layoutSubtreeIfNeeded()
    let targetRect = targetCell.convert(targetCell.bounds, to: host)
    let point = mode == .grid ? CGPoint(x: targetRect.minX + 2, y: targetRect.midY) : CGPoint(x: targetRect.midX, y: targetRect.minY + 2)
    let hitPoint = host.superview?.convert(point, from: host) ?? point
    guard let hit = host.hitTest(hitPoint) as? HubNativeFileDropBridge.DestinationView else { fatalError("Reorder target hit wrong view (reference=\(reference), mode=\(mode), hit=\(String(describing: host.hitTest(hitPoint))))") }
    let info = ProbeDragInfo(board: board, source: source, window: window)
    info.draggingLocation = host.convert(point, to: nil)
    precondition(hit.draggingEntered(info).isEmpty, "Unbound local source must not be treated as an external drag")
    HubFileDragState.bind(pasteboard: board, for: id)
    precondition(hit.draggingUpdated(info) == .move, "The same drag must recover once its pasteboard is bound, reference=\(reference) mode=\(mode)")
    guard let firstFeedback = feedbackHistory.last ?? nil else { preconditionFailure("An immediate native update must supply its insertion geometry") }
    if mode == .grid {
      precondition(abs(firstFeedback.rect.minY - (targetRect.minY + 5)) < 0.51,
                   "Grid insertion guidance must follow the currently drawn/native target, including a reveal translation")
    } else {
      precondition(abs(firstFeedback.rect.midY - targetRect.minY) < 0.51,
                   "List/column insertion guidance must follow the currently drawn/native target, including a reveal translation")
    }
    host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
    guard let feedback = feedbackHistory.last ?? nil else { preconditionFailure("SwiftUI must retain insertion feedback after binding and redraw") }
    precondition(feedback.action == .reorder && feedback.insertion && feedback.rect.width > 0 && feedback.rect.height > 0,
                 "A successful reorder hover must show a nonempty insertion line")
    if mode == .grid { precondition(feedback.rect.width == 2 && feedback.rect.height > 2) }
    else { precondition(feedback.rect.height == 2 && feedback.rect.width > 2) }
    let hitAfterFeedback = host.hitTest(hitPoint)
    precondition(hitAfterFeedback === hit, "The native reorder target must survive its own feedback update")
    precondition(hit.prepareForDragOperation(info) && hit.performDragOperation(info), "Reorder must accept the drop")
    settle(host)
    let final = model.visibleEntries.filter { files.contains($0.url) }.map(\.url)
    precondition(final.first == moving, "Moving last before first must change visible order: ref=\(reference) mode=\(mode), before=\(original), after=\(final)")
    guard let provider = NSItemProvider(contentsOf: moving) else { preconditionFailure("A local file provider must be available") }
    precondition(HubFileDragState.localPayload(for: [provider]) != nil, "Fallback must authenticate the original local session")
    model.errorMessage = nil
    precondition(!host.rootView.receiveDrop([provider], destination: model.currentURL),
                 "Content fallback without a reliable insertion location must reject local reorder")
    precondition(model.errorMessage != nil && model.visibleEntries.filter { files.contains($0.url) }.map(\.url) == final,
                 "A rejected fallback must explain itself without silently moving the file")
    if !reference && mode == .grid {
      model.errorMessage = nil; model.setColorLabelFilter(.orange)
      precondition(host.rootView.receiveDrop([provider], destination: model.currentURL), "Filtered fallback still applies the selected label")
      for _ in 0..<500 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
      precondition(FileEntry(url: moving).labelNumber == 7 && model.fileOrderURLs.filter { files.contains($0) } == final,
                   "Color-only fallback must preserve file order")
    }
    HubFileDragState.end(id)
    }
   }
  }
  print("PASS: actual HubView keeps one stable file receiver and fixed native header/cell hit frames through warm A/B/C switches, then routes local reorders at 0/40ms in folder/reference grid, list and columns")
  print("LIMIT: 0ms is the first reconciled UI turn with no deliberate delay; hidden callback tests do not measure rendered animation timing")
 }
 @MainActor static func settle(_ view: NSView) { for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) } }
 @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
@MainActor private final class ProbeDragInfo: NSObject, NSDraggingInfo {
 var draggingDestinationWindow: NSWindow?
 var draggingSourceOperationMask: NSDragOperation = [.move, .copy]
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
 init(board: NSPasteboard, source: Any?, window: NSWindow) { draggingPasteboard = board; draggingSource = source; draggingDestinationWindow = window }
 func slideDraggedImage(to screenPoint: NSPoint) {}
 nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
 func resetSpringLoading() {}
 func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
