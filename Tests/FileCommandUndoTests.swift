import AppKit
import Foundation

/// Exercises completed commands through HubModel, not just inverse primitives.
/// Every file/config is disposable; undone creations are redone before cleanup
/// so these tests do not leave test files in the user's Trash.
@main struct FileCommandUndoTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FileDock-CommandUndo-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await transfers(root.appendingPathComponent("transfers"))
        try await largeMoves(root.appendingPathComponent("large"))
        try await largeLabeledTransfers(root.appendingPathComponent("large-labeled"))
        try await commands(root.appendingPathComponent("commands"))
        try await metadataAndCreatedActions(root.appendingPathComponent("finder"))
        try await safetyAndHistory(root.appendingPathComponent("safety"))
        try await partialUndoRetry(root.appendingPathComponent("partial"))
        print("PASS: ordinary batch move/copy undo and redo, collision naming, nested destinations, large file/directory moves, create/rename/Trash, reference repair, Finder metadata/archive/alias commands, multi-step history, navigation and failed/no-op commands")
        print("LIMIT: no NSWorkspace duplicate integration is invoked here; it depends on a live Finder service and is covered by the shared completed-created-item journal")
    }

    private static let fm = FileManager.default
    private static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    private static func file(_ parent: URL, _ name: String, _ text: String = "fixture") throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    @MainActor private static func fixture(_ base: URL) throws -> (HubModel, URL, URL, UUID, UUID) {
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let target = base.appendingPathComponent("Target", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        let sourceID = model.addWorkspace(name: "Source", mode: .folder, urls: [source])!.id
        let targetID = model.addWorkspace(name: "Target", mode: .folder, urls: [target])!.id
        model.settings.groupsEnabled = false
        return (model, source, target, sourceID, targetID)
    }
    @MainActor private static func wait(_ model: HubModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while (model.fileOperationsInProgress > 0 || model.directoryLoading || model.stagingTransferInProgress) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(model.fileOperationsInProgress == 0 && !model.directoryLoading && !model.stagingTransferInProgress,
                     "Command/undo must finish within the fixture deadline")
        if !allowError { precondition(model.errorMessage == nil, "Unexpected command error: \(model.errorMessage ?? "")") }
    }
    @MainActor private static func undo(_ model: HubModel) async throws {
        precondition(model.canUndoFileDrop && model.undoLastFileDrop(), "A completed mutation must expose Cmd-Z")
        try await wait(model)
    }
    @MainActor private static func redo(_ model: HubModel) async throws {
        precondition(model.canRedoFileOperation && model.redoLastFileOperation(), "A completed undo must expose redo")
        try await wait(model)
    }

    @MainActor private static func transfers(_ base: URL) async throws {
        let (model, source, target, sourceID, targetID) = try fixture(base)
        let alpha = try file(source, "alpha.txt", "alpha contents")
        let beta = try file(source, "beta.md", "beta contents")
        let branch = source.appendingPathComponent("branch", isDirectory: true)
        try fm.createDirectory(at: branch, withIntermediateDirectories: false)
        _ = try file(branch, "child.txt", "nested contents")
        let occupied = try file(target, "alpha.txt", "existing original")
        model.selectWorkspace(targetID)
        precondition(model.acceptFileDrop([alpha, beta, branch], workspaceID: targetID, directory: target, copy: false))
        try await wait(model)
        let renamed = target.appendingPathComponent("alpha copy.txt")
        try require(exists(renamed) && !exists(alpha) && !exists(beta) && !exists(branch), "Every move result must be real")
        let edit = try FileHandle(forWritingTo: renamed)
        try edit.seekToEnd(); try edit.write(contentsOf: Data(" plus later edit".utf8)); try edit.close()
        model.selectWorkspace(sourceID)
        try await undo(model)
        try require(exists(alpha) && exists(beta) && exists(branch) && !exists(renamed), "Batch move undo restores every original path")
        try require(try String(contentsOf: alpha, encoding: .utf8) == "alpha contents plus later edit", "Undo moving the same object must preserve later content edits")
        try require(try String(contentsOf: occupied, encoding: .utf8) == "existing original", "Undo may not change a colliding preexisting destination")
        precondition(model.selectedWorkspaceID == sourceID, "Undo must not switch tabs")
        try await redo(model)
        try require(exists(renamed) && !exists(alpha), "Redo reuses the actual collision-resolved result name")
        try await undo(model)
        try require(try String(contentsOf: branch.appendingPathComponent("child.txt"), encoding: .utf8) == "nested contents", "Directory contents survive round-trip")

        model.selectWorkspace(targetID)
        precondition(model.acceptFileDrop([alpha, beta], workspaceID: targetID, directory: target, copy: true))
        try await wait(model)
        let betaCopy = target.appendingPathComponent("beta.md")
        try require(exists(alpha) && exists(beta) && exists(renamed) && exists(betaCopy), "Copy retains originals")
        try await undo(model)
        try require(exists(alpha) && exists(beta) && !exists(renamed) && !exists(betaCopy), "Copy undo removes only created results to Trash")
        try await redo(model)
        try require(exists(renamed) && exists(betaCopy), "Redo restores copied results from their recoverable location")

        let nested = target.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        precondition(model.acceptFileDrop([alpha, beta], workspaceID: targetID, directory: nested, copy: false))
        try await wait(model)
        try await undo(model)
        try require(exists(alpha) && exists(beta) && !exists(nested.appendingPathComponent("alpha.txt")), "Nested folder move must also be undoable")
    }

    @MainActor private static func largeMoves(_ base: URL) async throws {
        let (model, source, target, _, targetID) = try fixture(base)
        let large = try file(source, "large.bin")
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 65 * 1024 * 1024)
        try handle.close()
        let many = source.appendingPathComponent("many", isDirectory: true)
        try fm.createDirectory(at: many, withIntermediateDirectories: false)
        for index in 0..<1030 { _ = try file(many, "item-\(index)", "") }
        precondition(model.acceptFileDrop([large, many], workspaceID: targetID, directory: target, copy: false))
        try await wait(model)
        try require(exists(target.appendingPathComponent("large.bin")) && !exists(large), "Large ordinary move must complete")
        precondition(model.dropUndoNotice == nil, "Ordinary undo cannot inherit strict color-drop content digest limits")
        try await undo(model)
        try require(exists(large) && exists(many), "Large file and >1024-child directory moves remain undoable")
        try require(try fm.contentsOfDirectory(atPath: many.path).count == 1030, "Undo must retain all directory children")
    }

    @MainActor private static func largeLabeledTransfers(_ base: URL) async throws {
        for copy in [false, true] {
            let (model, source, target, _, targetID) = try fixture(base.appendingPathComponent(copy ? "copy" : "move"))
            let large = try file(source, "large.bin")
            let handle = try FileHandle(forWritingTo: large)
            try handle.truncate(atOffset: 65 * 1024 * 1024); try handle.close()
            try setFixtureTags(["keep custom tag"], on: large)
            _ = try HubFinderFileActions.setLabel(HubFinderLabel.blue.rawValue, urls: [large])
            let priorTags = try HubDropUndo.captureTags(large)
            precondition(model.acceptFileDrop([large], workspaceID: targetID, directory: target, copy: copy, labelOnDrop: .orange))
            try await wait(model)
            let result = target.appendingPathComponent("large.bin")
            try require(exists(result) && exists(large) == copy, "Large labeled transfer must complete with correct source state")
            try require(FileEntry(url: result).labelNumber == HubFinderLabel.orange.rawValue, "Large labeled transfer applies its destination color")
            precondition(model.dropUndoNotice == nil, "Large labeled transfers must retain a safe non-digest undo fallback")
            try await undo(model)
            try require(exists(large) && !exists(result), "Large labeled undo restores a moved original or trashes only its copy")
            try require(FileEntry(url: large).labelNumber == HubFinderLabel.blue.rawValue, "Large labeled undo preserves the original color")
            try require(try HubDropUndo.captureTags(large) == priorTags, "Large labeled undo restores exact original user-tag bytes")
            try await redo(model)
            try require(exists(result) && exists(large) == copy, "Large labeled redo restores the transfer")
            try require(FileEntry(url: result).labelNumber == HubFinderLabel.orange.rawValue, "Large labeled redo restores the applied destination color")
            try require((try result.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).contains("keep custom tag"),
                        "Labeled redo retains custom tags")
            if copy {
                try require(FileEntry(url: large).labelNumber == HubFinderLabel.blue.rawValue, "Copy redo cannot recolor the source")
                try require(try HubDropUndo.captureTags(large) == priorTags, "Copy redo cannot change source tags")
            } else { try await undo(model) }
        }
    }

    @MainActor private static func commands(_ base: URL) async throws {
        let (model, source, _, sourceID, _) = try fixture(base)
        model.selectWorkspace(sourceID)
        model.createFolder(named: "New Folder")
        try await wait(model)
        let created = source.appendingPathComponent("New Folder", isDirectory: true)
        try require(exists(created), "Create folder must complete")
        try await undo(model)
        try require(!exists(created), "New-folder undo sends only that folder to Trash")
        try await redo(model)
        try require(exists(created), "New-folder redo restores its original object")

        let original = try file(source, "name.txt", "preserve me")
        let reference = model.addWorkspace(name: "References", mode: .references, urls: [original])!.id
        model.selectWorkspace(sourceID)
        model.setManualEntryOrder(true)
        let orderBefore = model.selectedWorkspace!.directoryOrders
        model.rename(FileEntry(url: original), to: "renamed.txt")
        try await wait(model)
        let renamed = source.appendingPathComponent("renamed.txt")
        try require(exists(renamed) && !exists(original), "Rename must complete")
        precondition(model.workspaces.first { $0.id == reference }!.referencePaths == [renamed.path], "Rename repairs references")
        try await undo(model)
        try require(exists(original) && !exists(renamed), "Rename undo restores the original path")
        precondition(model.workspaces.first { $0.id == reference }!.referencePaths == [original.path], "Rename undo repairs references back")
        precondition(model.selectedWorkspace!.directoryOrders == orderBefore, "Rename undo restores saved ordering metadata")
        try await redo(model)
        try require(exists(renamed), "Rename redo restores its later name")
        try await undo(model)

        model.trashDraggedFiles([original])
        try await wait(model)
        try require(!exists(original), "Trash command removes the original path")
        precondition(model.workspaces.first { $0.id == reference }!.referencePaths.isEmpty)
        try await undo(model)
        try require(exists(original), "Trash undo restores from the actual returned Trash URL")
        precondition(model.workspaces.first { $0.id == reference }!.referencePaths == [original.path], "Trash undo restores removed references")
        try await redo(model)
        try require(!exists(original), "Trash redo reuses the captured object")
        try await undo(model)
        try require(try String(contentsOf: original, encoding: .utf8) == "preserve me", "No command round-trip loses file contents")
    }

    @MainActor private static func metadataAndCreatedActions(_ base: URL) async throws {
        let (model, source, _, sourceID, _) = try fixture(base)
        model.selectWorkspace(sourceID)
        let document = try file(source, "document.md", "archive and alias source")
        model.performFinderAction(.label(HubFinderLabel.orange.rawValue), urls: [document])
        try await wait(model)
        try require(FileEntry(url: document).labelNumber == HubFinderLabel.orange.rawValue, "Menu label command must apply")
        try await undo(model)
        try require(FileEntry(url: document).labelNumber == 0, "Menu label command must be undoable")
        try await redo(model)
        try require(FileEntry(url: document).labelNumber == HubFinderLabel.orange.rawValue, "Menu label redo restores applied label")

        let folder = source.appendingPathComponent("Styled", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        model.performFinderAction(.folderStyle(HubFinderLabel.blue.rawValue, .unchanged), urls: [folder])
        try await wait(model)
        try await undo(model)
        try require(FileEntry(url: folder).labelNumber == 0, "Folder style label undo restores prior style")
        try await redo(model)
        try require(FileEntry(url: folder).labelNumber == HubFinderLabel.blue.rawValue, "Folder style redo works")

        for action in [HubFinderAction.compress, .alias] {
            let old = Set(try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).map(\.path))
            model.performFinderAction(action, urls: [document])
            try await wait(model)
            let created = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter { !old.contains($0.path) }
            precondition(created.count == 1, "Archive/alias command creates exactly one journaled result")
            try await undo(model)
            try require(!exists(created[0]), "Archive/alias undo only trashes its created result")
            try await redo(model)
            try require(exists(created[0]) && exists(document), "Archive/alias redo restores result while preserving source")
        }
    }

    @MainActor private static func safetyAndHistory(_ base: URL) async throws {
        let (model, source, target, sourceID, targetID) = try fixture(base)
        model.selectWorkspace(sourceID)
        let one = try file(source, "one.txt"), two = try file(source, "two.txt")
        precondition(model.acceptFileDrop([one], workspaceID: targetID, directory: target, copy: false))
        try await wait(model)
        precondition(model.acceptFileDrop([two], workspaceID: targetID, directory: target, copy: false))
        try await wait(model)
        try await undo(model)
        try require(exists(two) && !exists(one), "First undo reverses only the last command")
        try await undo(model)
        try require(exists(one) && exists(two), "A later operation cannot erase earlier history")
        try await redo(model)
        try require(!exists(one) && exists(two), "Redo applies in original forward order")
        try await redo(model)
        try require(!exists(one) && !exists(two), "Second redo restores the second operation")
        try await undo(model)
        try await undo(model)

        model.createFolder(named: "History Marker")
        try await wait(model)
        precondition(!model.canRedoFileOperation, "A completed new mutation invalidates only the redo branch")
        let marker = source.appendingPathComponent("History Marker")
        precondition(model.acceptFileDrop([one], workspaceID: sourceID, directory: source, copy: false))
        try await wait(model)
        precondition(model.acceptFileDrop([source.appendingPathComponent("missing.txt")], workspaceID: targetID, directory: target, copy: false))
        try await wait(model, allowError: true)
        precondition(model.errorMessage != nil)
        model.errorMessage = nil
        model.rename(FileEntry(url: one), to: one.lastPathComponent)
        try await wait(model)
        try await undo(model)
        try require(!exists(marker) && exists(one), "Failed moves and no-op move/rename may not consume or erase history")
        model.rename(FileEntry(url: one), to: one.lastPathComponent)
        try await wait(model)
        precondition(model.canRedoFileOperation, "A no-op command must not erase redo either")
        try await redo(model)

        precondition(model.acceptFileDrop([one], workspaceID: targetID, directory: target, copy: false))
        try await wait(model)
        let moved = target.appendingPathComponent("one.txt")
        _ = try file(source, "one.txt", "new independent occupant")
        precondition(model.undoLastFileDrop())
        try await wait(model, allowError: true)
        precondition(model.errorMessage != nil, "Undo must refuse to overwrite an occupied original path")
        try require(try String(contentsOf: one, encoding: .utf8) == "new independent occupant", "Unsafe undo cannot overwrite new user content")
        try require(exists(moved), "Rejected undo must preserve the moved object")
        try fm.removeItem(at: one)
        model.errorMessage = nil
        try await undo(model)
        try require(exists(one) && !exists(moved), "Untouched failed undo can be retried after resolving the collision")
    }

    @MainActor private static func partialUndoRetry(_ base: URL) async throws {
        let (model, source, target, _, targetID) = try fixture(base)
        let one = try file(source, "one.txt"), two = try file(source, "two.txt")
        let marker = try file(target, "marker.txt")
        let referenceID = model.addWorkspace(name: "References", mode: .references, urls: [one, two])!.id
        model.selectWorkspace(targetID)
        let orderBefore = model.selectedWorkspace!.directoryOrders
        precondition(model.acceptFileDrop([one, two], workspaceID: targetID, directory: target, copy: false,
            insertionOrder: [marker], before: marker))
        try await wait(model)
        let movedOne = target.appendingPathComponent("one.txt"), movedTwo = target.appendingPathComponent("two.txt")
        let orderAfter = model.selectedWorkspace!.directoryOrders
        let referenceAfter = model.workspaces.first { $0.id == referenceID }!.referencePaths
        _ = try file(source, "one.txt", "occupied during undo")
        precondition(model.undoLastFileDrop())
        try await wait(model, allowError: true)
        precondition(model.errorMessage != nil)
        try require(exists(movedOne) && !exists(movedTwo) && exists(two), "A batch undo may restore safe items while retaining the conflicted one")
        try fm.removeItem(at: one)
        model.errorMessage = nil
        try await undo(model)
        try require(exists(one) && exists(two) && !exists(movedOne) && !exists(movedTwo), "Retry reverses only the remaining failed item")
        precondition(model.workspaces.first { $0.id == referenceID }!.referencePaths == [one.path, two.path],
                     "Completed retry restores the complete original reference state")
        precondition((model.selectedWorkspace!.directoryOrders ?? [:]) == (orderBefore ?? [:]),
                     "Completed retry restores presentation metadata retained across partial failure")
        try await redo(model)
        try require(!exists(one) && !exists(two) && exists(movedOne) && exists(movedTwo),
                    "Redo after a partial/retried undo replays all successful inverse records, not only the final retry")
        precondition(model.workspaces.first { $0.id == referenceID }!.referencePaths == referenceAfter,
                     "Redo restores the full original post-operation reference state, not the partially undone snapshot")
        precondition(model.selectedWorkspace!.directoryOrders == orderAfter)
        try await undo(model)
    }
}
