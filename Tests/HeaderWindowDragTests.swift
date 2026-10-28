import AppKit
import SwiftUI

@MainActor private final class HeaderProbeApplication: NSApplication {
    var injectedEvent: NSEvent?
    override var currentEvent: NSEvent? { injectedEvent ?? super.currentEvent }
}
@MainActor private final class HeaderProbePanel: NSPanel {
    var dragCalls = 0
    override func performDrag(with event: NSEvent) { dragCalls += 1 }
}

@main struct HeaderWindowDragTests {
    @MainActor static func main() throws {
        let app = HeaderProbeApplication.shared as! HeaderProbeApplication
        geometry()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-HeaderDrag-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("config.json")
        let model = HubModel(storageURL: storage)
        model.workspaces = [Workspace(name: "Apps", symbol: "app.dashed", rootPath: folder.path),
                            Workspace(name: "Desktop", symbol: "desktopcomputer", rootPath: folder.path),
                            Workspace(name: "Downloads", symbol: "tray", rootPath: folder.path)]
        for index in model.workspaces.indices { model.workspaces[index].iconOnly = true }
        model.settings.favoriteShortcutEnabled = false
        model.settings.recentShortcutEnabled = false
        model.settings.switchDelay = 0.15736
        model.selectWorkspace(model.workspaces[1].id)
        let reloaded = HubModel(storageURL: storage)
        precondition(reloaded.settings.switchDelay == 0.15736, "A continuous setting must survive saving, normalization and restart without rounding")
        let music = HubQQMusicController() // Never made visible; no player polling or authorization.
        for split in [false, true] {
            let state = HubPresentationState(); state.previewVisible = true
            state.header = .init(embedded: split, exclusionWidth: split ? 200 : 0, topInset: split ? 32 : 0, split: split)
            let panel = HeaderProbePanel(contentRect: CGRect(x: 0, y: 0, width: 683, height: 400), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: music, onSettings: {}, onClose: {}))
            let surface = HubNotchSurface(contentView: host)
            panel.contentView = surface
            surface.configure(attached: split, sourceWidth: 200, bodyColor: .black, reduceMotion: true, embedded: split)
            surface.setPresented(true, animated: false) {}
            settle(surface)
            let root = flatten(host).compactMap { $0 as? HubWindowDragHandle.DragHandleView }.first { $0.dragRects != nil }!
            let files = flatten(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
            precondition(files.count == 1 && root.frame.size == host.bounds.size)
            precondition(panel.isMovable && !panel.isVisible)
            let tabIDs = Set(model.tabWorkspaces.map(\.id))
            let tabFrames = flatten(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
                .filter { tabIDs.contains($0.workspaceID) }.map { host.convert($0.bounds, from: $0) }.sorted { $0.minX < $1.minX }
            precondition(tabFrames.count == 3 && tabFrames.allSatisfy { abs($0.width - HubWorkspaceShortcutLabel.width) < 0.5 },
                         "Icon-only tabs must use the same 30-point bounds as fixed shortcuts")
            for pair in zip(tabFrames, tabFrames.dropFirst()) {
                precondition(abs(pair.1.minX - pair.0.maxX - HubWorkspaceHeaderLayout.tabSpacing) < 0.5,
                             "Actual native tab gaps must match the fixed shortcut strip")
            }
            var notifications = 0
            let observer = NotificationCenter.default.addObserver(forName: hubWindowDragWillBegin, object: panel, queue: nil) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            func event(_ type: NSEvent.EventType = .leftMouseDown, point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            func hit(_ point: CGPoint, type: NSEvent.EventType = .leftMouseDown, flags: NSEvent.ModifierFlags = []) -> NSView? {
                app.injectedEvent = event(type, point: point, flags: flags)
                return host.hitTest(host.convert(point, to: host.superview))
            }
            for point in [CGPoint(x: 180, y: 6), CGPoint(x: 500, y: 6)] {
                precondition(hit(point) === root, "Top header blank space must reach the persistent drag receiver in both layouts")
                root.mouseDown(with: app.injectedEvent!)
            }
            precondition(panel.dragCalls == 2 && notifications == 2, "Each header press must start exactly one native window move")
            precondition(hit(CGPoint(x: 330, y: 150)) !== root, "File content can never initiate window movement")
            for source in flatten(host).compactMap({ $0 as? HubWorkspaceDragBridge.WorkspaceDragView }) {
                let point = host.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), from: source)
                precondition(hit(point) === source, "Tab and fixed-icon sources retain their exact mouse-down target")
                root.mouseDown(with: event(point: point))
            }
            if split { precondition(hit(CGPoint(x: 341.5, y: 44)) !== root, "Embedded music controls are not window-drag space") }
            for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp, .rightMouseDown] {
                precondition(hit(CGPoint(x: 180, y: 6), type: type) !== root)
            }
            precondition(hit(CGPoint(x: 180, y: 6), flags: .control) !== root)
            app.injectedEvent = nil
            precondition(host.hitTest(host.convert(CGPoint(x: 180, y: 6), to: host.superview)) !== root, "Eventless file-destination lookup must pass through")
            let payload = HubFileDragPayload(id: UUID(), context: .init(workspaceID: model.selectedWorkspaceID, directory: folder), urls: [folder.appendingPathComponent("unused.txt")])
            HubFileDragState.begin(payload)
            precondition(hit(CGPoint(x: 330, y: 150), type: .leftMouseDragged) === files[0])
            root.mouseDown(with: event(point: CGPoint(x: 180, y: 6)))
            precondition(panel.dragCalls == 2)
            HubFileDragState.end(payload.id)
            let source = flatten(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }.first!
            let reorder = HubWorkspaceDragPayload(id: UUID(), workspaceID: source.workspaceID, domain: source.domain)
            HubWorkspaceDragState.begin(reorder, source: source)
            precondition(hit(CGPoint(x: 180, y: 6)) !== root)
            root.mouseDown(with: event(point: CGPoint(x: 180, y: 6)))
            precondition(panel.dragCalls == 2)
            HubWorkspaceDragState.end(reorder.id, source: source)
            state.beginWindowMove(pinned: false)
            state.endWindowMove(reduceMotion: true)
            settle(surface)
            precondition(flatten(host).contains { $0 === root }, "Detaching/rebuilding the header must preserve the active root receiver")
            precondition(hit(CGPoint(x: 180, y: 6)) === root)
            root.mouseDown(with: app.injectedEvent!)
            precondition(panel.dragCalls == 3 && notifications == 3)
            state.previewVisible = false
            app.injectedEvent = nil
            panel.contentView = nil; panel.close()
        }
        print("PASS: continuous delay persistence, whole-header blank hit routing in real HubView/NSPanel/surface, one native move per press, control/music/content exclusions, file/reorder/eventless pass-through and receiver survival across detach")
        print("LIMIT: Hidden panel overrides performDrag; actual WindowServer movement and detachment require installed UI verification")
    }

    private static func geometry() {
        let a = UUID(), b = UUID(), bounds = CGRect(x: 0, y: 0, width: 680, height: 400)
        let header = CGRect(x: 0, y: 0, width: 680, height: 58)
        let regions: [HubHeaderDragRegion: CGRect] = [.header: header,
            .tab(a): CGRect(x: -20, y: 12, width: 100, height: 32), .viewport(a): CGRect(x: 12, y: 0, width: 200, height: 58),
            .tab(b): CGRect(x: 160, y: 12, width: 100, height: 32), .viewport(b): CGRect(x: 12, y: 0, width: 200, height: 58),
            .controls: CGRect(x: 520, y: 8, width: 140, height: 38), .music: CGRect(x: 244, y: 34, width: 192, height: 20)]
        let result = HubHeaderDragGeometry.rectangles(in: bounds, regions: regions)
        precondition(!result.isEmpty && result.allSatisfy { header.contains($0) })
        for y in stride(from: CGFloat(0.5), to: 70, by: 1) {
            for x in stride(from: CGFloat(0.5), to: 680, by: 1) {
                let point = CGPoint(x: x, y: y)
                let excluded = [regions[.tab(a)]!.intersection(regions[.viewport(a)]!), regions[.tab(b)]!.intersection(regions[.viewport(b)]!), regions[.controls]!, regions[.music]!].contains { $0.contains(point) }
                precondition(result.contains { $0.contains(point) } == (header.contains(point) && !excluded))
            }
        }
        let reversed = Dictionary(regions.reversed(), uniquingKeysWith: { $1 })
        precondition(HubHeaderDragGeometry.rectangles(in: bounds, regions: reversed) == result, "Equivalent anchors must not churn cursor rectangles because of dictionary iteration order")
        precondition(HubHeaderDragGeometry.rectangles(in: bounds, regions: [:]).isEmpty)
        precondition(HubHeaderDragGeometry.rectangles(in: .zero, regions: regions).isEmpty)
        precondition(HubHeaderDragGeometry.rectangles(in: bounds, regions: [.header: .infinite]).isEmpty)
    }
    @MainActor private static func flatten(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(flatten) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
}
