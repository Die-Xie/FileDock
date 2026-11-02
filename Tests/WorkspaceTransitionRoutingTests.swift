import AppKit
import SwiftUI

@MainActor private final class TransitionProbeApplication: NSApplication {
    var injectedEvent: NSEvent?
    override var currentEvent: NSEvent? { injectedEvent ?? super.currentEvent }
}

/// Drives native callbacks in a hidden, real HubView. No events are posted to
/// WindowServer and all transfers remain inside disposable fixture folders.
@main struct WorkspaceTransitionRoutingTests {
    @MainActor static func main() async throws {
        let app = TransitionProbeApplication.shared as! TransitionProbeApplication
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-WorkspaceTransition-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for mode in [HubViewMode.grid, .list, .columns] {
            for delayMS in [0, 40] {
                let fixture = base.appendingPathComponent("\(mode)-\(delayMS)")
                let folders = ["Alpha", "Beta", "Gamma"].map { fixture.appendingPathComponent($0, isDirectory: true) }
                for folder in folders {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data("fixture".utf8).write(to: folder.appendingPathComponent("item.txt"))
                }
                let external = fixture.appendingPathComponent("incoming.txt")
                try Data("new destination".utf8).write(to: external)
                let model = makeTestModel(storageURL: fixture.appendingPathComponent("settings.json"))
                let workspaces = folders.map { Workspace(name: $0.lastPathComponent, rootPath: $0.path) }
                model.workspaces = workspaces
                model.settings.qqMusicEnabled = false
                model.settings.favoriteShortcutEnabled = false; model.settings.recentShortcutEnabled = false
                model.settings.stagingEnabled = false; model.settings.airDropEnabled = false
                model.settings.groupsEnabled = false
                model.settings.animationSpeed = 1
                model.viewMode = mode
                for workspace in workspaces { model.selectWorkspace(workspace.id) }
                model.selectWorkspace(workspaces[0].id)
                let presentation = HubPresentationState(); presentation.previewVisible = true
                var feedback: HubFileDropFeedback?
                var itemRegions: [HubFileDropRegion: CGRect] = [:]
                let view = HubView(model: model, presentation: presentation, music: HubQQMusicController(), onSettings: {}, onClose: {},
                    onFileDropFeedbackChanged: { feedback = $0 })
                let host = NSHostingView(rootView: view.overlayPreferenceValue(HubFileDropRegionKey.self) { anchors in
                    GeometryReader { geometry in
                        TransitionRegionProbe(regions: anchors.mapValues { geometry[$0] }, receive: { itemRegions = $0 })
                    }.allowsHitTesting(false)
                })
                let width: CGFloat = mode == .grid ? 600 : 900
                let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: width, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { presentation.previewVisible = false; window.contentView = nil; window.close() }
                settle(host)
                let initial = descendants(host)
                let routers = initial.compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
                precondition(routers.count == 1 && initial.filter { $0.registeredDraggedTypes.contains(.fileURL) }.count == 1)
                let router = routers[0], routerFrame = router.convert(router.bounds, to: host)
                let initialCell = initial.compactMap { $0 as? HubFileDragBridge.FileDragView }
                    .first { $0.entryURL.lastPathComponent == "item.txt" }!
                let itemLayoutFrame = initialCell.convert(initialCell.bounds, to: host)
                let tabIDs = Set(workspaces.map(\.id))
                let tabs = initial.compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }.filter { tabIDs.contains($0.workspaceID) }
                precondition(tabs.count == workspaces.count)
                let tabFrames = Dictionary(uniqueKeysWithValues: tabs.map { ($0.workspaceID, $0.convert($0.bounds, to: host)) })
                let tabObjects = Dictionary(uniqueKeysWithValues: tabs.map { ($0.workspaceID, ObjectIdentifier($0)) })
                func checkStableReceivers(expectInitialItems: Bool = true) {
                    let current = descendants(host)
                    let receivers = current.compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
                    precondition(receivers.count == 1 && receivers[0] === router && current.filter { $0.registeredDraggedTypes.contains(.fileURL) }.count == 1,
                        "A content transition cannot clone or replace the live file URL receiver")
                    precondition(router.convert(router.bounds, to: host) == routerFrame, "Visual content motion cannot move the file destination")
                    let currentTabs = current.compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }.filter { tabIDs.contains($0.workspaceID) }
                    precondition(currentTabs.count == tabs.count)
                    for tab in currentTabs {
                        precondition(tabObjects[tab.workspaceID] == ObjectIdentifier(tab),
                            "Retargeting cannot rebuild native tabs; mode=\(mode), delay=\(delayMS), id=\(tab.workspaceID)")
                        let before = tabFrames[tab.workspaceID]!, after = tab.convert(tab.bounds, to: host)
                        // scrollTo can align an already visible text tab by
                        // one physical pixel. Do not confuse that with motion
                        // changing hit geometry or tolerate a larger scroll.
                        let pixel = 1 / max(1, window.backingScaleFactor)
                        precondition(abs(before.minX - after.minX) <= pixel + 0.001 && abs(before.minY - after.minY) < 0.001 &&
                            abs(before.width - after.width) < 0.001 && abs(before.height - after.height) < 0.001,
                            "Retargeting cannot move native tabs; mode=\(mode), delay=\(delayMS), old=\(String(describing: tabFrames[tab.workspaceID])), new=\(tab.convert(tab.bounds, to: host))")
                    }
                    precondition(!presentation.surfaceAnimating && !presentation.layoutChanging && !presentation.defersFileRendering,
                        "Content switching must not borrow panel-animation flags that block hover or defer thumbnail rendering")
                    for cell in current.compactMap({ $0 as? HubFileDragBridge.FileDragView }) where !cell.visibleRect.isEmpty {
                        guard let anchor = itemRegions[.item(cell.entryURL)] else {
                            preconditionFailure("A visible native file cell must retain its actual drop anchor; mode=\(mode), url=\(cell.entryURL.lastPathComponent)")
                        }
                        let actual = cell.convert(cell.bounds, to: host)
                        if expectInitialItems {
                            precondition(abs(actual.minX - itemLayoutFrame.minX) < 0.001 && abs(actual.minY - itemLayoutFrame.minY) < 0.001 &&
                                abs(actual.width - itemLayoutFrame.width) < 0.001 && abs(actual.height - itemLayoutFrame.height) < 0.001,
                                "Visual-only icon/name lift must not move a file cell's native interaction frame; mode=\(mode), original=\(itemLayoutFrame), actual=\(actual)")
                        }
                        precondition(abs(actual.minX - anchor.minX) < 0.51 && abs(actual.minY - anchor.minY) < 0.51 &&
                            abs(actual.width - anchor.width) < 0.51 && abs(actual.height - anchor.height) < 0.51,
                            "Draw translation must keep native file hits and item anchors in one coordinate chain; mode=\(mode), native=\(actual), anchor=\(anchor)")
                    }
                }
                // Every switch is reconciled on the next UI turn; no animation
                // completion or artificial settling interval separates targets.
                for _ in 0..<3 {
                    for workspace in [workspaces[1], workspaces[2], workspaces[0], workspaces[2]] {
                        model.selectWorkspace(workspace.id)
                        await layoutTurn(host)
                        checkStableReceivers()
                    }
                }
                if delayMS > 0 { try await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000) }
                host.layoutSubtreeIfNeeded(); checkStableReceivers()
                precondition(model.selectedWorkspaceID == workspaces[2].id && model.currentURL?.path == folders[2].path)
                let cell = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }
                    .first { $0.entryURL.path == folders[2].appendingPathComponent("item.txt").path }!
                for localPoint in [CGPoint(x: cell.bounds.midX, y: cell.bounds.midY),
                                   CGPoint(x: cell.bounds.midX, y: cell.bounds.minY + 2),
                                   CGPoint(x: cell.bounds.midX, y: cell.bounds.maxY - 2)] {
                    let point = cell.convert(localPoint, to: host)
                    app.injectedEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(point, to: nil), modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                    HubLocalFilePressDispatch.begin(app.injectedEvent!)
                    precondition(host.hitTest(host.convert(point, to: host.superview)) === cell,
                        "The latest content remains clickable at its center and inner 2pt edges during its reveal")
                }
                app.injectedEvent = nil
                router.currentEventType = { .leftMouseDragged }; router.currentEventIsLocalPress = { false }; router.primaryMousePressed = { true }
                let point = CGPoint(x: host.bounds.midX, y: host.bounds.maxY - 80)
                precondition(host.hitTest(host.convert(point, to: host.superview)) === router,
                    "Decorative transition layers cannot cover the active native file destination")
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                precondition(board.writeObjects([external as NSURL]))
                let info = TransitionDragInfo(board: board, window: window)
                info.draggingLocation = host.convert(point, to: nil)
                precondition(router.draggingEntered(info) == .copy && router.draggingUpdated(info) == .copy)
                precondition(feedback?.action == .copy && feedback?.rect.isEmpty == false,
                    "A drop during the reveal retains visible destination guidance")
                precondition(router.prepareForDragOperation(info) && router.performDragOperation(info))
                for _ in 0..<1000 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(model.fileOperationsInProgress == 0 && model.errorMessage == nil)
                precondition(fm.fileExists(atPath: folders[2].appendingPathComponent(external.lastPathComponent).path))
                precondition(!fm.fileExists(atPath: folders[0].appendingPathComponent(external.lastPathComponent).path) &&
                    !fm.fileExists(atPath: folders[1].appendingPathComponent(external.lastPathComponent).path),
                    "A superseded transition cannot redirect files to an older tab")
                precondition(fm.fileExists(atPath: external.path), "The external copy keeps its source intact")
                router.concludeDragOperation(info)
                NotificationCenter.default.post(name: hubFileDragDidEnd, object: nil)
                try await Task.sleep(nanoseconds: 350_000_000)
                // New files legitimately change sorted cell positions. The
                // post-drop check still requires native/anchor agreement, but
                // no longer compares them with the pre-drop single-file grid.
                host.layoutSubtreeIfNeeded(); checkStableReceivers(expectInitialItems: false)
                precondition(model.selectedWorkspaceID == workspaces[2].id, "Late transition completions cannot restore an earlier workspace")
            }
        }
        print("PASS: real HubView rapid A/B/C retargeting preserves native header/file receiver identity, fixed hit geometry and immediate clicks, then copies external drops to the latest folder at 0/40ms in grid/list/columns")
        print("LIMIT: 0ms means the first reconciled UI turn; hidden callback tests do not measure rendered frame rate or subjective transition quality")
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func layoutTurn(_ view: NSView) async {
        view.layoutSubtreeIfNeeded(); await Task.yield(); view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    }
}

private struct TransitionRegionProbe: View {
    let regions: [HubFileDropRegion: CGRect]
    let receive: ([HubFileDropRegion: CGRect]) -> Void
    var body: some View {
        Color.clear.onAppear { receive(regions) }.onChange(of: regions) { receive($0) }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor private final class TransitionDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
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
