import AppKit
import SwiftUI

/// Real HubView / NSDraggingInfo callbacks, with disposable filesystem fixtures.
/// No mouse events are posted, and no application or user configuration is used.
@main struct NativeFolderDropRoutingTests {
    private enum Scenario: String, CaseIterable {
        case localSingle, localBatch, localCopy, finderMove, finderCopy, crossTab, references, staging, grouped
        var external: Bool { self == .finderMove || self == .finderCopy }
        var copy: Bool { self == .localCopy || self == .finderCopy }
        var batch: Bool { self != .localSingle && self != .finderCopy }
        var referenceRoot: Bool { self == .references || self == .staging }
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FolderDrop-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var count = 0
        for mode in [HubViewMode.grid, .list, .columns] {
            for scenario in Scenario.allCases {
                try await exercise(mode: mode, scenario: scenario, fixture: base.appendingPathComponent("\(mode)-\(scenario.rawValue)"))
                count += 1
            }
        }
        print("PASS: \(count) real HubView native folder drops across grid/list/columns: local single/batch, copy-only sources, Finder, cross-tab, reference/staging folders and grouping; folder guidance, real transfer and result highlight verified")
        print("PASS: folder edges retain insertion guidance; packages, self-containing batches and ancestor-to-child drops cannot become folder transfers; one native file URL receiver remains")
        print("LIMIT: native callback tests do not post WindowServer drag events or measure rendered animation frame rate")
    }

    @MainActor private static func exercise(mode: HubViewMode, scenario: Scenario, fixture: URL) async throws {
        let fm = FileManager.default
        let panel = fixture.appendingPathComponent("panel", isDirectory: true)
        let incoming = fixture.appendingPathComponent("incoming", isDirectory: true)
        let target = panel.appendingPathComponent("Target", isDirectory: true)
        let package = panel.appendingPathComponent("Utility.app", isDirectory: true)
        for folder in [target, package, incoming] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sourceDirectory = scenario.external || scenario == .crossTab ? incoming : panel
        let files = ["Alpha.txt", "Beta.pdf"].map { sourceDirectory.appendingPathComponent($0) }
        for file in files { try Data("fixture \(file.lastPathComponent)".utf8).write(to: file) }
        let branch = sourceDirectory.appendingPathComponent("Branch", isDirectory: true)
        try fm.createDirectory(at: branch, withIntermediateDirectories: true)
        try Data("nested fixture".utf8).write(to: branch.appendingPathComponent("child.txt"))
        let moving = scenario.batch ? files + [branch] : [files[0]]
        let model = makeTestModel(storageURL: fixture.appendingPathComponent("settings.json"))
        let sourceWorkspace = Workspace(name: "Source", rootPath: incoming.path)
        let workspace = Workspace(name: "Panel", mode: scenario.referenceRoot ? .references : .folder,
            rootPath: scenario.referenceRoot ? nil : panel.path,
            referencePaths: scenario.referenceRoot ? (files + [branch, target, package]).map(\.path) : [])
        model.workspaces = [sourceWorkspace, workspace]
        model.settings.qqMusicEnabled = false
        model.settings.favoriteShortcutEnabled = false; model.settings.recentShortcutEnabled = false
        model.settings.airDropEnabled = false
        model.settings.stagingEnabled = scenario == .staging
        if scenario == .staging { model.settings.stagingWorkspaceID = workspace.id }
        model.settings.groupsEnabled = scenario == .grouped
        model.viewMode = mode
        model.selectWorkspace(scenario == .crossTab ? sourceWorkspace.id : workspace.id)
        model.setManualEntryOrder(true)
        let presentation = HubPresentationState(); presentation.previewVisible = true
        var feedback: HubFileDropFeedback?
        let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: HubQQMusicController(), onSettings: {}, onClose: {},
            onFileDropFeedbackChanged: { feedback = $0 }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            presentation.previewVisible = false
            window.contentView = nil; window.close()
        }
        settle(host)
        let source = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }.first { $0.entryURL == files[0] }
        precondition(scenario.external || source != nil, "Local native source must exist: \(mode), \(scenario)")
        let sourceContext = HubFileDragContext(workspaceID: model.selectedWorkspaceID, directory: model.currentURL)
        if scenario == .crossTab {
            model.selectWorkspace(workspace.id)
            settle(host)
        }
        let routers = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
        precondition(routers.count == 1 && descendants(host).filter { $0.registeredDraggedTypes.contains(.fileURL) }.count == 1,
            "Folder support must not add another native file URL receiver")
        let router = routers[0]
        router.currentEventType = { .leftMouseDragged }; router.currentEventIsLocalPress = { false }; router.primaryMousePressed = { true }
        let cells = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }
        guard let targetCell = cells.first(where: { $0.entryURL == target }), let packageCell = cells.first(where: { $0.entryURL == package }) else {
            preconditionFailure("Target folder and package must be visible: \(mode), \(scenario)")
        }
        let targetRect = targetCell.convert(targetCell.bounds, to: router)
        // In rows the actual folder icon is near the leading edge, not at the
        // middle of the whole metadata row. It must accept a center-height drop.
        let center = CGPoint(x: mode == .grid ? targetRect.midX : targetRect.minX + 16, y: targetRect.midY)
        precondition(router.contains(center))
        precondition(host.hitTest(targetCell.convert(CGPoint(x: center.x - targetRect.minX, y: center.y - targetRect.minY), to: host.superview)) === router,
            "The actual folder cell must hit the unified native router")
        let board = NSPasteboard.withUniqueName(), sessionID = UUID()
        defer { HubFileDragState.end(sessionID); board.releaseGlobally() }
        let payload = HubFileDragPayload(id: sessionID, context: sourceContext, urls: moving, folderURLs: Set(moving.filter { $0 == branch }))
        if scenario.external { precondition(board.writeObjects(moving.map { $0 as NSURL })) }
        else {
            HubFileDragState.begin(payload, source: source!)
            precondition(board.writeObjects(moving.map { HubFileDragData.pasteboardItem(for: $0, sessionID: sessionID) }))
            HubFileDragState.bind(pasteboard: board, for: sessionID)
        }
        let info = FolderProbeDragInfo(board: board, source: scenario.external ? nil : source, window: window)
        info.draggingSourceOperationMask = scenario.copy ? [.copy] : [.move, .copy]
        info.numberOfValidItemsForDrop = moving.count
        info.draggingLocation = router.convert(center, to: nil)
        let expected: NSDragOperation = scenario.copy ? .copy : .move
        precondition(router.draggingEntered(info) == expected, "A folder center must offer a filesystem transfer: \(mode), \(scenario)")
        precondition(feedback?.action == (scenario.copy ? .copy : .move) && feedback?.insertion == false,
            "A folder center must highlight the folder instead of showing a reorder line: \(mode), \(scenario)")
        guard let rect = feedback?.rect else { preconditionFailure("Missing folder feedback") }
        precondition(abs(rect.minX - targetRect.minX) < 0.51 && abs(rect.minY - targetRect.minY) < 0.51 &&
            abs(rect.width - targetRect.width) < 0.51 && abs(rect.height - targetRect.height) < 0.51,
            "Folder guidance must use the visible native cell bounds")
        if scenario == .localSingle {
            // Edges keep the established reorder affordance, even for folders.
            let edge = mode == .grid ? CGPoint(x: targetRect.minX + 2, y: targetRect.midY) : CGPoint(x: targetRect.midX, y: targetRect.minY + 1)
            info.draggingLocation = router.convert(edge, to: nil)
            precondition(router.draggingUpdated(info) == .move && feedback?.action == .reorder && feedback?.insertion == true,
                "Folder edge must still expose a manual insertion line in \(mode)")
            let packageRect = packageCell.convert(packageCell.bounds, to: router)
            info.draggingLocation = router.convert(CGPoint(x: packageRect.midX, y: packageRect.midY), to: nil)
            precondition(router.draggingUpdated(info) == .move && feedback?.action == .reorder && feedback?.insertion == true,
                "An application package must never be a folder transfer target")
            info.draggingLocation = router.convert(center, to: nil)
            precondition(router.draggingUpdated(info) == .move && feedback?.insertion == false,
                "Moving from folder edge/package back to center must replace insertion guidance")
        }
        precondition(router.prepareForDragOperation(info) && router.performDragOperation(info), "Native folder drop must accept release: \(mode), \(scenario)")
        for _ in 0..<1000 where model.fileOperationsInProgress > 0 || model.directoryLoading { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0 && model.errorMessage == nil, "Folder transfer must complete without error: \(String(describing: model.errorMessage))")
        for file in moving {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            precondition(fm.fileExists(atPath: destination.path), "Every member must reach the folder: \(mode), \(scenario)")
            precondition(fm.fileExists(atPath: file.path) == scenario.copy, "Move/copy must preserve the correct original state")
            if file == branch {
                let contents = try Data(contentsOf: destination.appendingPathComponent("child.txt"))
                precondition(contents == Data("nested fixture".utf8))
            } else {
                let contents = try Data(contentsOf: destination)
                precondition(contents == Data("fixture \(file.lastPathComponent)".utf8))
            }
            precondition(!fm.fileExists(atPath: package.appendingPathComponent(file.lastPathComponent).path), "No file may be transferred inside an application package")
        }
        precondition(model.selectedIDs == [target], "Completed nested transfer highlights its visible destination folder: \(mode), \(scenario)")
        router.concludeDragOperation(info); HubFileDragState.end(sessionID)
        if scenario == .localSingle {
            settle(host)
            try rejectUnsafeDrops(model: model, host: host, router: router, window: window, folder: target, panel: panel, mode: mode)
        }
    }

    @MainActor private static func rejectUnsafeDrops(model: HubModel, host: NSView, router: HubNativeFileDropBridge.DestinationView,
                                                     window: NSWindow, folder: URL, panel: URL, mode: HubViewMode) throws {
        guard let cell = descendants(host).compactMap({ $0 as? HubFileDragBridge.FileDragView }).first(where: { $0.entryURL == folder }) else { preconditionFailure("Missing target after transfer") }
        let rect = cell.convert(cell.bounds, to: router), point = CGPoint(x: rect.midX, y: rect.midY)
        for urls in [[folder], [folder, folder.appendingPathComponent("Alpha.txt")], [panel]] {
            let board = NSPasteboard.withUniqueName(), id = UUID()
            defer { HubFileDragState.end(id); board.releaseGlobally() }
            let internalSource = urls[0] == folder
            if internalSource {
                let payload = HubFileDragPayload(id: id, context: .init(workspaceID: model.selectedWorkspaceID, directory: model.currentURL), urls: urls, folderURLs: [folder])
                HubFileDragState.begin(payload, source: cell)
                precondition(board.writeObjects(urls.map { HubFileDragData.pasteboardItem(for: $0, sessionID: id) }))
                HubFileDragState.bind(pasteboard: board, for: id)
            } else { precondition(board.writeObjects(urls.map { $0 as NSURL })) }
            let info = FolderProbeDragInfo(board: board, source: internalSource ? cell : nil, window: window)
            info.draggingLocation = router.convert(point, to: nil)
            precondition(router.draggingEntered(info).isEmpty && !router.prepareForDragOperation(info) && !router.performDragOperation(info),
                "A self-containing batch or ancestor-to-child drop must be rejected before transfer, mode=\(mode)")
            precondition(model.fileOperationsInProgress == 0 && model.errorMessage == nil)
            router.concludeDragOperation(info); HubFileDragState.end(id)
        }
        precondition(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Alpha.txt").path))
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    }
}

@MainActor private final class FolderProbeDragInfo: NSObject, NSDraggingInfo {
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
