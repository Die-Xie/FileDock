import AppKit
import SwiftUI

@main struct ColorLabelDropTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-ColorDrop-\(UUID())")
        let folder = root.appendingPathComponent("files", isDirectory: true)
        let child = folder.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = folder.appendingPathComponent("sample.svg")
        let bytes = Data("<svg><title>keep source</title></svg>".utf8)
        try bytes.write(to: file)
        try setFixtureTags(["keep custom tag"], on: file)
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        model.settings.switchDelay = 0
        model.settings.hoverSwitchingEnabled = false // Ordinary hover cannot disable label drops.
        let workspace = model.addWorkspace(name: "Drop fixture", mode: .folder, urls: [folder])!
        let state = HubPresentationState(); state.previewVisible = true
        let music = HubQQMusicController() // Never visible; no polling or authorization.
        let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: music,
            onSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let receivers = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
        precondition(receivers.count == 1, "All file URL targets must share one native destination")
        let destination = receivers[0]
        let y = destination.bounds.height - 21
        let row = stride(from: CGFloat(0), to: destination.bounds.width, by: 1).filter {
            destination.contains(CGPoint(x: $0, y: y))
        }
        precondition(row.count == 8 * 28, "Each color's full padded bounds must route through the unified destination")
        let start = row.min()!
        func point(_ index: Int) -> CGPoint { CGPoint(x: start + CGFloat(index * 28) + 14, y: y) }
        precondition(destination.contains(CGPoint(x: start + 2, y: y + 11)), "Color padding must accept a file drag")
        let order = model.fileOrderURLs
        precondition(destination.operation?(point(1), [file, child], nil, false) == .copy,
                     "Finder drops onto a label must never advertise a destructive move")
        precondition(destination.receive?([file, child], nil, point(1), false) == true)
        precondition(!model.applyDroppedColorLabel(6, urls: [file]), "Overlapping metadata operations must not race on the same files")
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 7 && FileEntry(url: child).labelNumber == 7)
        precondition(FileEntry(url: file).tagNames.contains("keep custom tag"))
        let afterFinderDrop = try Data(contentsOf: file)
        precondition(afterFinderDrop == bytes)
        precondition(model.fileOrderURLs == order && fm.fileExists(atPath: child.path))

        let payload = HubFileDragPayload(id: UUID(), context: .init(workspaceID: workspace.id, directory: folder), urls: [file])
        HubFileDragState.begin(payload)
        precondition(destination.operation?(point(4), [file], payload, false) == .copy)
        precondition(destination.receive?([file], payload, point(4), false) == true)
        HubFileDragState.end(payload.id)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 4 && model.fileOrderURLs == order,
                     "A local same-folder drag must assign color rather than reorder or move the file")
        precondition(destination.receive?([file], nil, point(7), true) == true)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 0 && FileEntry(url: file).tagNames.contains("keep custom tag"))
        let afterRemoval = try Data(contentsOf: file)
        precondition(afterRemoval == bytes)

        // Native color-circle drops must transfer external files into the
        // captured physical directory, then label the actual destination.
        let external = root.appendingPathComponent("external", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: false)
        var externalMove = external.appendingPathComponent("external-move.txt")
        try Data("move".utf8).write(to: externalMove)
        var oldLabel = URLResourceValues(); oldLabel.labelNumber = 6
        try externalMove.setResourceValues(oldLabel)
        precondition(destination.operation?(point(1), [externalMove], nil, false) == .move)
        precondition(destination.receive?([externalMove], nil, point(1), false) == true)
        try await wait(model)
        let moved = folder.appendingPathComponent(externalMove.lastPathComponent)
        precondition(!fm.fileExists(atPath: externalMove.path) && FileEntry(url: moved).labelNumber == 7)
        precondition(model.undoLastFileDrop())
        try await wait(model)
        precondition(fm.fileExists(atPath: externalMove.path) && !fm.fileExists(atPath: moved.path))
        precondition(FileEntry(url: externalMove).labelNumber == 6)

        var externalCopy = external.appendingPathComponent("external-copy.txt")
        try Data("copy".utf8).write(to: externalCopy)
        try externalCopy.setResourceValues(oldLabel)
        precondition(destination.operation?(point(4), [externalCopy], nil, true) == .copy)
        precondition(destination.receive?([externalCopy], nil, point(4), true) == true)
        try await wait(model)
        let copied = folder.appendingPathComponent(externalCopy.lastPathComponent)
        precondition(FileEntry(url: externalCopy).labelNumber == 6 && FileEntry(url: copied).labelNumber == 4)
        precondition(model.dropUndoNotice == nil, "A verified ordinary copy should be undoable")

        // Even Option on a circle does not duplicate an item already there.
        precondition(destination.receive?([file], nil, point(1), true) == true)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 7 && !fm.fileExists(atPath: folder.appendingPathComponent("sample copy.svg").path))

        // Dropping into the filtered content uses the color at release even
        // if selection changes before the worker finishes.
        model.setColorLabelFilter(.orange)
        settle(host)
        let contentPoint = CGPoint(x: host.bounds.width - 25, y: host.bounds.height / 2)
        precondition(destination.contains(contentPoint))
        let contentSource = external.appendingPathComponent("content.txt")
        try Data("content".utf8).write(to: contentSource)
        precondition(destination.receive?([contentSource], nil, contentPoint, false) == true)
        model.setColorLabelFilter(.blue)
        try await wait(model)
        let contentTarget = folder.appendingPathComponent(contentSource.lastPathComponent)
        precondition(FileEntry(url: contentTarget).labelNumber == 7)

        // Real hosted item frame: drop into the center of the visible folder,
        // not the parent filtered content; preserve the source color.
        model.setColorLabelFilter(.orange)
        settle(host)
        let selectionView = descendants(host).compactMap { $0 as? HubMarqueeSelectionBridge.SelectionView }
            .first { $0.frames[child] != nil }!
        let childFrame = selectionView.frames[child]!
        let childPoint = destination.convert(CGPoint(x: childFrame.midX, y: childFrame.midY), from: selectionView)
        let childSource = external.appendingPathComponent("child-drop.txt")
        try Data("nested drop".utf8).write(to: childSource)
        var childEditable = childSource
        try childEditable.setResourceValues(oldLabel)
        precondition(destination.operation?(childPoint, [childSource], nil, false) == .move)
        precondition(destination.receive?([childSource], nil, childPoint, false) == true)
        try await wait(model)
        let nestedTarget = child.appendingPathComponent(childSource.lastPathComponent)
        precondition(fm.fileExists(atPath: nestedTarget.path) && !fm.fileExists(atPath: childSource.path), "Drop should go into child folder")
        precondition(FileEntry(url: nestedTarget).labelNumber == 6, "Parent filter must not label a file dropped into a child folder")
        print("PASS: physical child item frame routes into child, retaining source label")

        // Probe the actual SwiftUI/AppKit anchor geometry of the header while
        // only a folder workspace and staging shortcut are eligible targets.
        model.setFavoriteShortcutVisible(false)
        model.setRecentShortcutVisible(false)
        model.settings.airDropEnabled = false
        model.setStagingEnabled(true)
        model.setColorLabelFilter(.orange)
        settle(host)
        let stageSource = external.appendingPathComponent("stage-direct.txt")
        try Data("staging".utf8).write(to: stageSource)
        var stageEditable = stageSource
        try stageEditable.setResourceValues(oldLabel)
        let originalWorkspace = model.selectedWorkspaceID
        let stageProbe = HubFileDragPayload(id: UUID(), context: .init(workspaceID: UUID(), directory: external), urls: [stageSource], folderURLs: [])
        let stageCandidates = stride(from: CGFloat(0), to: host.bounds.width, by: 1).map { CGPoint(x: $0, y: 30) }.filter {
            destination.contains($0) && destination.operation?($0, [stageSource], stageProbe, false) == .copy
        }
        precondition(!stageCandidates.isEmpty, "Staging shortcut must expose an eligible native target")
        let stagePoint = stageCandidates[stageCandidates.count / 2]
        precondition(destination.receive?([stageSource], nil, stagePoint, false) == true)
        try await wait(model)
        precondition(model.selectedWorkspaceID == originalWorkspace, "Direct drop must not switch workspace")
        precondition(model.stagedURLs.contains(stageSource.standardizedFileURL), "Direct header drop must add a staging reference")
        precondition(fm.fileExists(atPath: stageSource.path) && FileEntry(url: stageSource).labelNumber == 6,
                     "Direct staging header drop must not inherit the folder filter or move source")
        print("PASS: direct staging header drop uses staging without changing selection or source label")

        model.setColorLabelFilter(.orange)
        settle(host)
        let directoryKey = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let beforeOrder = model.selectedWorkspace?.directoryOrders?[directoryKey]
        let filteredDrag = HubFileDragPayload(id: UUID(), context: .init(workspaceID: workspace.id, directory: folder), urls: [file])
        HubFileDragState.begin(filteredDrag)
        precondition(destination.operation?(contentPoint, [file], filteredDrag, false) == .move)
        precondition(destination.receive?([file], filteredDrag, contentPoint, false) == true)
        HubFileDragState.end(filteredDrag.id)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 7)
        precondition(model.selectedWorkspace?.directoryOrders?[directoryKey] != beforeOrder, "Filtered reorder should save its insertion position")
        precondition(model.undoLastFileDrop())
        try await wait(model)
        precondition(model.selectedWorkspace?.directoryOrders?[directoryKey] == beforeOrder, "Undo restores the prior order as well as the label")

        precondition(!model.applyDroppedColorLabel(99, urls: [file]))
        precondition(!model.applyDroppedColorLabel(6, urls: [URL(string: "https://example.com/file")!]))
        model.settings.colorLabelFilterEnabled = false
        precondition(!model.applyDroppedColorLabel(6, urls: [file]), "Disabled settings reject a stale drop callback")
        settle(host)
        precondition(destination.receive?([file], nil, point(0), false) != true)
        precondition(FileEntry(url: file).labelNumber == 7)
        print("PASS: real HubView native footer geometry, padded targets, Finder/local drop routing, metadata-only color/removal, preserved contents/location/order/custom tags, disabled/stale/invalid rejection")
        print("LIMIT: Hidden native callbacks do not reproduce a physical WindowServer drag session")
    }
    @MainActor private static func wait(_ model: HubModel) async throws {
        for _ in 0..<1000 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0)
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
}
