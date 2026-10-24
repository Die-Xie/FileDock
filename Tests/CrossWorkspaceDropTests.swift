import AppKit
import Foundation

@main struct CrossWorkspaceDropTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("FileDock-CrossDrop-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let svg = source.appendingPathComponent("Vector.svg"), folder = source.appendingPathComponent("Folder")
        try Data("<svg/>".utf8).write(to: svg)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("child.txt")
        try Data("original".utf8).write(to: child)
        let model = makeTestModel(storageURL: base.appendingPathComponent("settings.json"))
        model.addWorkspace(name: "Source", mode: .folder, urls: [source])
        let sourceID = model.selectedWorkspaceID!
        model.addWorkspace(name: "Target", mode: .folder, urls: [target])
        let targetID = model.selectedWorkspaceID!
        model.addWorkspace(name: "收藏", mode: .references, urls: [])
        let favoriteID = model.selectedWorkspaceID!
        model.selectWorkspace(sourceID)
        precondition(model.acceptFileDrop([svg, folder, child], workspaceID: favoriteID, directory: nil, copy: false))
        precondition(model.selectedWorkspaceID == sourceID, "Dropping on a shortcut does not need to change UI selection")
        precondition(Set(model.workspaces.first { $0.id == favoriteID }!.referencePaths) == Set([svg.path, folder.path, child.path]))
        precondition(fm.fileExists(atPath: svg.path) && fm.fileExists(atPath: child.path), "Favorites only store references")
        precondition(model.acceptFileDrop([svg], workspaceID: targetID, directory: target, copy: true))
        model.selectWorkspace(favoriteID)
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(fm.fileExists(atPath: svg.path) && fm.fileExists(atPath: target.appendingPathComponent(svg.lastPathComponent).path))
        precondition(model.acceptFileDrop([folder, child], workspaceID: targetID, directory: target, copy: false))
        model.selectWorkspace(sourceID)
        try await wait { model.fileOperationsInProgress == 0 }
        let moved = target.appendingPathComponent("Folder/child.txt")
        let movedBytes = try Data(contentsOf: moved)
        precondition(movedBytes == Data("original".utf8))
        precondition(!fm.fileExists(atPath: folder.path), "Cross-tab move transfers the actual files")
        precondition(model.workspaces.first { $0.id == favoriteID }!.referencePaths.contains(moved.path), "Moving a parent repairs descendant references")
        precondition(!fm.fileExists(atPath: target.appendingPathComponent("child.txt").path), "A selected child is not moved twice")
        model.selectWorkspace(targetID)
        model.rename(FileEntry(url: target.appendingPathComponent("Folder")), to: "Renamed")
        precondition(model.workspaces.first { $0.id == favoriteID }!.referencePaths.contains(target.appendingPathComponent("Renamed/child.txt").path))
        let alpha = source.appendingPathComponent("Alpha.txt"), beta = source.appendingPathComponent("Beta.txt")
        try Data("alpha".utf8).write(to: alpha); try Data("beta".utf8).write(to: beta)
        let marker = target.appendingPathComponent("Vector.svg")
        let priorOrder = model.fileOrderURLs
        precondition(model.acceptFileDrop([alpha, beta], workspaceID: targetID, directory: target, copy: true,
            insertionOrder: priorOrder, before: marker))
        model.selectWorkspace(sourceID)
        try await wait { model.fileOperationsInProgress == 0 }
        model.selectWorkspace(targetID)
        let inserted = model.visibleEntries.map(\.url.lastPathComponent)
        guard let markerIndex = inserted.firstIndex(of: marker.lastPathComponent) else { preconditionFailure() }
        precondition(Array(inserted[(markerIndex - 2)..<markerIndex]) == ["Alpha.txt", "Beta.txt"], "Cross-tab insertion must preserve the dragged group order at the indicated position after async transfer/UI changes")
        let previousNames = Set(model.visibleEntries.map(\.name))
        precondition(model.acceptFileDrop([alpha], workspaceID: targetID, directory: target, copy: true,
            insertionOrder: model.fileOrderURLs, before: marker))
        try await wait { model.fileOperationsInProgress == 0 }
        let renamed = Set(model.visibleEntries.map(\.name)).subtracting(previousNames)
        precondition(renamed.count == 1)
        let finalNames = model.visibleEntries.map(\.name)
        precondition(finalNames[finalNames.firstIndex(of: marker.lastPathComponent)! - 1] == renamed.first!, "Filename collisions must insert the actual renamed output, not the original source name")
        model.selectWorkspace(favoriteID)
        precondition(model.acceptFileDrop([alpha, beta], workspaceID: favoriteID, directory: nil, copy: false,
            insertionOrder: model.fileOrderURLs, before: svg))
        precondition(Array(model.selectedWorkspace!.referencePaths.prefix(2)) == [alpha.path, beta.path], "Favorite insertion only reorders references, preserving the indicated group order")
        let restored = makeTestModel(storageURL: base.appendingPathComponent("settings.json"))
        restored.selectWorkspace(targetID)
        precondition(restored.visibleEntries.map(\.name) == model.workspaces.first(where: { $0.id == targetID })!.directoryOrders![target.path]!, "File insertion order must survive relaunch")
        let asynchronous = HubModel(storageURL: base.appendingPathComponent("async-settings.json"), monitor: false)
        asynchronous.setStagingEnabled(true); asynchronous.openStagingWorkspace()
        precondition(asynchronous.stageFiles([svg]))
        try await wait { !asynchronous.directoryLoading && asynchronous.entries.count == 1 }
        precondition(asynchronous.acceptFileDrop([alpha, beta], workspaceID: asynchronous.selectedWorkspaceID, directory: nil, copy: false,
            insertionOrder: asynchronous.fileOrderURLs, before: svg))
        try await wait { !asynchronous.directoryLoading && asynchronous.entries.count == 3 }
        precondition(Array(asynchronous.visibleEntries.map(\.url).prefix(2)) == [alpha, beta], "Staging insertion must publish a fresh asynchronous snapshot after changing reference order")
        model.removeWorkspace(favoriteID)
        precondition(!model.acceptFileDrop([svg], workspaceID: favoriteID, directory: nil, copy: false))
        print("PASS: real cross-tab copy/move after UI changes, Finder-equivalent favorite references, SVG/directory/child preservation, moved/renamed descendant bookmarks and removed targets")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("File operation did not complete")
    }
}
