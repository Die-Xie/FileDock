import AppKit

@main struct TrashDropTests {
    @MainActor private static func wait(_ model: HubModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.fileOperationsInProgress > 0 || model.stagingTransferInProgress), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0 && !model.stagingTransferInProgress)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let token = UUID().uuidString
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-Trash-\(token)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var restore: [(URL, Data)] = []
        defer {
            // Resolve only bookmarks created for these unique fixtures. Never
            // enumerate, empty or remove unrelated contents of the user's Trash.
            for (original, bookmark) in restore where !fm.fileExists(atPath: original.path) {
                var stale = false
                var moved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                // Bookmarks may resolve a symlink's target instead of the link.
                // Fall back only to the exact UUID fixture name, never a list
                // or guessed non-fixture item in the user's Trash.
                if moved == nil || moved!.path.hasPrefix(root.path + "/") {
                    if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: false) {
                        moved = trash.appendingPathComponent(original.lastPathComponent)
                    }
                }
                if let moved, original.lastPathComponent.hasPrefix(token), moved != original,
                   !moved.path.hasPrefix(root.path + "/") {
                    try? fm.moveItem(at: moved, to: original)
                }
            }
            try? fm.removeItem(at: root)
        }
        let folder = root.appendingPathComponent("\(token)-tree"), sibling = root.appendingPathComponent("\(token)-tree-sibling.txt")
        let child = folder.appendingPathComponent("child.txt"), file = root.appendingPathComponent("\(token)-image.svg")
        let missing = root.appendingPathComponent("missing.txt"), target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("\(token)-alias")
        let retained = target.appendingPathComponent("keep.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        for url in [file, child, sibling, retained] { try Data("fixture".utf8).write(to: url) }
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        for url in [file, folder, link] {
            restore.append((url, try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
        }
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let source = model.addWorkspace(name: "Source", mode: .folder, urls: [root])!
        let other = model.addWorkspace(name: "Other", mode: .folder, urls: [target])!
        model.setFavoriteShortcutVisible(true)
        model.selectWorkspace(model.favoriteWorkspace!.id)
        model.appendReferences([file, folder, child, sibling, missing, link, target])
        model.openStagingWorkspace()
        precondition(model.stageFiles([file, folder, child, sibling, missing, link, target]))
        model.trash([file])
        precondition(fm.fileExists(atPath: file.path) && model.fileOperationsInProgress == 0,
                     "The staging remove command must still remove only the reference")
        precondition(model.stageFiles([file]))
        model.trashDraggedFiles([file, file, folder, child, missing])
        precondition(model.fileOperationsInProgress == 1 && fm.fileExists(atPath: file.path), "Native completion must return before filesystem work")
        model.selectWorkspace(other.id)
        model.selectedIDs = [retained]
        try await wait(model)
        precondition(!fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: folder.path))
        precondition(fm.fileExists(atPath: sibling.path) && model.selectedWorkspaceID == other.id)
        precondition(model.selectedIDs == [retained], "Trash completion cannot replace the current selection in another tab")
        precondition(model.errorMessage != nil, "Partial failure must be reported without rolling back successful Trash operations")
        for workspace in [model.favoriteWorkspace!, model.stagingWorkspace!] {
            precondition(!workspace.referencePaths.contains(file.path) && !workspace.referencePaths.contains(folder.path) && !workspace.referencePaths.contains(child.path))
            precondition(workspace.referencePaths.contains(sibling.path) && workspace.referencePaths.contains(missing.path))
        }
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as! [String: Any]
        let bookmarks = state["bookmarks"] as! [String: Any]
        precondition(bookmarks[file.path] == nil && bookmarks[folder.path] == nil && bookmarks[child.path] == nil,
                     "Deleted references must not follow old bookmarks into Trash after restart")
        model.errorMessage = nil
        model.trashDraggedFiles([link])
        try await wait(model)
        precondition(model.errorMessage == nil && fm.fileExists(atPath: target.path), "Trashing a symlink cannot trash its target")
        precondition(model.favoriteWorkspace!.referencePaths.contains(target.path))
        model.selectWorkspace(source.id)
        precondition(!model.entries.contains { $0.url == file || $0.url == folder || $0.url == child })
        print("PASS: actual system Trash of isolated SVG/folder/symlink fixtures, top-level coalescing, staging removal distinction, partial failures, cross-workspace completion, reference/bookmark cleanup and sibling/target preservation")
    }
}
