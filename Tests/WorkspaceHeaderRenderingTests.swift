import AppKit
import SwiftUI

@main struct WorkspaceHeaderRenderingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-NarrowHeader-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        if let output { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
        let model = makeTestModel(storageURL: root.appendingPathComponent("settings.json"))
        let folders = (0..<18).map { root.appendingPathComponent("Project \($0)", isDirectory: true) }
        for folder in folders { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        model.workspaces = folders.enumerated().map { Workspace(name: "Research Project \($0.offset)", symbol: "folder", rootPath: $0.element.path) }
        let firstID = model.workspaces[0].id
        model.setFavoriteShortcutVisible(true); model.setRecentShortcutVisible(true)
        model.settings.stagingEnabled = true; model.settings.airDropEnabled = true
        model.settings.shortcutOrder = ["airDrop", "favorite", "recents", "staging"]
        model.settings.qqMusicEnabled = false; model.settings.animationSpeed = 1
        model.settings.appearance = "dark"; model.settings.backgroundTheme = "solid"
        model.pinned = true; model.selectWorkspace(firstID)
        let music = HubQQMusicController()
        for width in [CGFloat(600), 683, 900, 1600] {
            let placement = HubEmbeddedPlacement.make(screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1100),
                visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1068), safeTop: 32,
                leftAuxiliary: CGRect(x: 0, y: 1068, width: 790, height: 32),
                rightAuxiliary: CGRect(x: 1010, y: 1068, width: 790, height: 32),
                requestedSize: CGSize(width: width, height: 440))
            precondition(placement.usesSplitHeader, "All supported panel widths use the same one-row notch layout")
            let state = HubPresentationState(); state.previewVisible = true
            state.header = .init(embedded: true, exclusionWidth: placement.headerExclusionWidth,
                                 topInset: placement.topInset, split: placement.usesSplitHeader)
            var feedback: HubFileDropFeedback?
            let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: music, onSettings: {}, onClose: {},
                onFileDropFeedbackChanged: { feedback = $0 }))
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 440), styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua)
            let surface = HubNotchSurface(contentView: host); panel.contentView = surface
            surface.configure(attached: true, sourceWidth: placement.sourceWidth, bodyColor: .black,
                              reduceMotion: true, embedded: true, notchExtension: true)
            surface.setPresented(true, animated: false) {}
            settle(surface)
            precondition(!panel.isVisible && abs(host.bounds.width - (width - 32)) < 0.5)
            let sources = descendants(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
            let tabIDs = Set(model.tabWorkspaces.map(\.id))
            let visibleTabs = sources.filter { tabIDs.contains($0.workspaceID) }.compactMap { visibleFrame($0, in: host) }
            let physicalCutout = CGRect(x: (host.bounds.width - placement.headerExclusionWidth) / 2,
                                       y: 0, width: placement.headerExclusionWidth, height: placement.topInset)
            precondition(!visibleTabs.isEmpty && visibleTabs.allSatisfy { $0.minY < placement.topInset && !$0.intersects(physicalCutout) },
                         "Tabs stay in the first header row, inside the hardware's safe shoulders")
            let routers = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
            let registeredFiles = descendants(host).filter { $0.registeredDraggedTypes.contains(.fileURL) }
            precondition(routers.count == 1 && registeredFiles.count == 1, "Horizontal scrolling cannot add another file URL receiver")
            if let output {
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("header-\(Int(width)).png"))
            }
            if width == 600 {
                let shortcuts = sources.filter { $0.domain == .shortcut }
                precondition(shortcuts.count == 4)
                let air = shortcuts.first { $0.workspaceID == HubShortcutItem.airDrop.dragID }!
                let staging = shortcuts.first { $0.workspaceID == HubShortcutItem.staging.dragID }!
                guard let scroll = air.enclosingScrollView, let document = scroll.documentView else { preconditionFailure("Fixed shortcuts need a native horizontal scroll viewport") }
                let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
                let addPoint = CGPoint(x: host.bounds.maxX - 12 - 30 - 4 - 15, y: viewport.midY)
                let external = root.appendingPathComponent("external.txt")
                try Data("safe fixture".utf8).write(to: external)
                let router = routers[0]
                precondition(router.operation?(addPoint, [external], nil, true).isEmpty == true,
                             "The pinned add action cannot become an offscreen shortcut's file destination")
                precondition(visibleFrame(air, in: host) != nil)
                let maxX = max(0, document.bounds.width - scroll.contentView.bounds.width)
                precondition(maxX > 0, "All six controls must overflow at the minimum extended-panel width")
                scroll.contentView.scroll(to: CGPoint(x: maxX, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
                settle(surface)
                let hiddenAirPoint = host.convert(CGPoint(x: air.bounds.midX, y: air.bounds.midY), from: air)
                let hiddenAirOperation = router.operation?(hiddenAirPoint, [external], nil, true)
                precondition(visibleFrame(air, in: host) == nil && hiddenAirOperation?.isEmpty == true,
                             "An offscreen AirDrop icon cannot accept a file through the hardware cutout")
                guard let stagingFrame = visibleFrame(staging, in: host) else { preconditionFailure("Scrolling must reveal staging without moving the add action") }
                let stagingPoint = CGPoint(x: stagingFrame.midX, y: stagingFrame.midY)
                precondition(router.operation?(stagingPoint, [external], nil, true) == .copy && feedback?.action == .reference,
                             "The newly revealed staging icon keeps its file destination")
                let shortcutRouter = descendants(host).compactMap { $0 as? HubShortcutReorderDropBridge.DestinationView }.first { $0.domain == .shortcut }!
                precondition(shortcutRouter.frames[HubShortcutItem.airDrop.dragID] == nil && shortcutRouter.frames[HubShortcutItem.staging.dragID] != nil,
                             "Private shortcut reorder frames must use the same visible clip as file drops")
                guard let tab = sources.first(where: { tabIDs.contains($0.workspaceID) && visibleFrame($0, in: host) != nil }),
                      let tabFrame = visibleFrame(tab, in: host) else { preconditionFailure("A normal tab remains reachable while shortcuts scroll") }
                let tabPoint = CGPoint(x: tabFrame.midX, y: tabFrame.midY)
                precondition(router.operation?(tabPoint, [external], nil, true) == .copy && feedback?.action == .copy)
                precondition(router.receive?([external], nil, tabPoint, true) == true, "An ordinary tab still accepts a copied file")
                for _ in 0..<1000 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(fm.fileExists(atPath: folders[0].appendingPathComponent(external.lastPathComponent).path))
                let newFolder = root.appendingPathComponent("Create New Tab", isDirectory: true)
                try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
                let slotPoint = CGPoint(x: tabFrame.minX + 2, y: tabFrame.midY)
                precondition(router.operation?(slotPoint, [newFolder], nil, false) == .copy && feedback?.action == .createWorkspace,
                             "The first tab edge still offers folder-to-tab creation beside the fixed controls")
                router.exited?()
                NotificationCenter.default.post(name: hubFileDragDidEnd, object: nil)
            }
            panel.contentView = nil; panel.close()
        }
        print("PASS: real extended HubView stays single-row at 600/683/900/1600, hardware exclusion and tab scrolling, pinned add/close, clipped shortcut file/reorder destinations and ordinary-tab copy/folder-creation guidance")
        print("LIMIT: Hidden NSHostingView routes do not reproduce physical trackpad scrolling or WindowServer drag selection")
    }

    @MainActor private static func visibleFrame(_ view: NSView, in host: NSView) -> CGRect? {
        let rect = host.convert(view.visibleRect.intersection(view.bounds), from: view).intersection(host.bounds)
        return rect.isNull || rect.width < 0.5 || rect.height < 0.5 ? nil : rect
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    }
}
