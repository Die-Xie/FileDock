import AppKit
import SwiftUI

@MainActor private final class FolderTabLoader: HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        completion(.success(.init(entries: [], canonicalDirectoryPath: request.directory?.path)))
    }
    func cancel(id: UUID) {}
}
@MainActor private final class FolderTabInfo: NSObject, NSDraggingInfo {
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
    init(board: NSPasteboard, source: Any?) { draggingPasteboard = board; draggingSource = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main struct FolderTabNativeTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FolderTab-Native-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let incoming = root.appendingPathComponent("New Folder", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let child = incoming.appendingPathComponent("unchanged.svg")
        try Data("<svg/>".utf8).write(to: child)
        for split in [false, true] {
            for local in [false, true] {
                let model = HubModel(storageURL: root.appendingPathComponent("config-\(split)-\(local).json"), directoryLoader: FolderTabLoader())
                let a = Workspace(name: "Left", mode: .folder, rootPath: root.path)
                let b = Workspace(name: "Right", mode: .folder, rootPath: root.path)
                model.workspaces = [a, b]
                model.settings.language = local ? "zh-Hans" : "en"
                model.settings.backgroundTheme = "solid"
                model.settings.appearance = "dark"
                model.settings.qqMusicEnabled = true
                model.selectWorkspace(a.id)
                let presentation = HubPresentationState()
                presentation.previewVisible = true
                presentation.header = .init(embedded: split, exclusionWidth: split ? 200 : 0, topInset: split ? 32 : 0, split: split)
                let music = HubQQMusicController() // Disabled: no real player reads or permissions.
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: music, onSettings: {}, onClose: {}))
                window.contentView = host
                settle(host)
                let native = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first!
                let views = descendants(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
                let left = views.first { $0.workspaceID == a.id }!
                let right = views.first { $0.workspaceID == b.id }!
                let leftFrame = native.convert(left.bounds, from: left)
                let rightFrame = native.convert(right.bounds, from: right)
                let gap = CGPoint(x: (leftFrame.maxX + rightFrame.minX) / 2, y: leftFrame.midY)
                let center = CGPoint(x: rightFrame.midX, y: rightFrame.midY)
                let board = NSPasteboard.withUniqueName(), source = NSObject(), session = UUID()
                let payload = HubFileDragPayload(id: session, context: .init(workspaceID: a.id, directory: root), urls: [incoming], folderURLs: [incoming])
                // The local marker stands in for a held mouse for native hit
                // testing. Finder-style inputs below have no private URL token.
                HubFileDragState.begin(payload, source: source)
                if local {
                    board.writeObjects([HubFileDragData.pasteboardItem(for: incoming, sessionID: session)])
                    HubFileDragState.bind(pasteboard: board, for: session)
                } else { board.writeObjects([incoming as NSURL]) }
                let info = FolderTabInfo(board: board, source: local ? source : nil)
                info.draggingDestinationWindow = window
                info.draggingLocation = native.convert(center, to: nil)
                precondition(!native.draggingEntered(info).isEmpty, "Existing tab centers must still accept ordinary file drops")
                info.draggingLocation = native.convert(gap, to: nil)
                precondition(native.draggingUpdated(info) == .copy, "Creating a folder tab must not advertise a source move")
                settle(host)
                let hitPoint = host.superview?.convert(gap, from: native) ?? host.convert(gap, from: native)
                precondition(host.hitTest(hitPoint) === native,
                             "The unified native receiver must own gap drops over actual SwiftUI tabs")
                precondition(model.workspaces.count == 2 && model.fileOperationsInProgress == 0,
                             "Hover only displays guidance; no metadata preparation or tab creation starts")
                try await Task.sleep(nanoseconds: 200_000_000)
                precondition(model.selectedWorkspaceID == a.id, "Entering an insertion gap cancels the old spring-loading timer")
                if split {
                    precondition(!native.contains(CGPoint(x: native.bounds.midX, y: leftFrame.midY)),
                                 "The physical notch and music exclusion cannot create tabs")
                }
                if let folder = ProcessInfo.processInfo.environment["FILEDOCK_FOLDER_TAB_CAPTURE_DIR"] {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder)
                        .appendingPathComponent("new-tab-\(split)-\(local).png"))
                }
                precondition(native.prepareForDragOperation(info) && native.performDragOperation(info))
                for _ in 0..<400 {
                    if model.fileOperationsInProgress == 0 { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                precondition(model.fileOperationsInProgress == 0 && model.errorMessage == nil)
                precondition(model.tabWorkspaces.count == 3 && model.tabWorkspaces[1].rootPath == incoming.path)
                precondition(model.selectedWorkspaceID == model.tabWorkspaces[1].id)
                precondition(descendants(host).contains { $0 === native }, "The native destination survives tab insertion and selection")
                precondition(fm.fileExists(atPath: child.path))
                HubFileDragState.end(session); board.releaseGlobally()
                // The current directory is now the created tab and its loader
                // has no source entry. Preserve captured file kind nonetheless.
                let fileBoard = NSPasteboard.withUniqueName(), fileSession = UUID()
                let filePayload = HubFileDragPayload(id: fileSession, context: .init(workspaceID: a.id, directory: root),
                    urls: [child], folderURLs: [])
                HubFileDragState.begin(filePayload, source: source)
                fileBoard.writeObjects([HubFileDragData.pasteboardItem(for: child, sessionID: fileSession)])
                HubFileDragState.bind(pasteboard: fileBoard, for: fileSession)
                settle(host)
                let currentRight = descendants(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }.first { $0.workspaceID == b.id }!
                let edge = native.convert(currentRight.bounds, from: currentRight)
                let fileInfo = FolderTabInfo(board: fileBoard, source: source)
                fileInfo.draggingDestinationWindow = window
                fileInfo.draggingLocation = native.convert(CGPoint(x: edge.minX + 2, y: edge.midY), to: nil)
                precondition(native.draggingEntered(fileInfo) == .move,
                    "A local file at a tab edge after navigation remains a file transfer, never a create-tab operation")
                precondition(model.fileOperationsInProgress == 0 && model.tabWorkspaces.count == 3)
                native.draggingExited(fileInfo)
                HubFileDragState.end(fileSession); fileBoard.releaseGlobally()
                window.contentView = nil; window.close()
            }
        }
        print("PASS: actual HubView tab-gap native routing/guidance, Finder/local URL inputs, center spring cancellation, notch exclusion, copy-only proposals, exact inserted position, unchanged source and stable receiver in floating/embedded layouts")
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
}
