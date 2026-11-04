import AppKit
import Foundation

/// Model history is driven only against temporary fixture files and configs.
/// Core undo tests cover filesystem identity and collision validation separately.
@main struct FileOperationHistoryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FileHistory-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try await references(base.appendingPathComponent("references"))
        try await shelfHistory(base.appendingPathComponent("shelf"))
        try await directoryOrder(base.appendingPathComponent("order"))
        try await stagedTransfer(base.appendingPathComponent("move"), copy: false)
        try await stagedTransfer(base.appendingPathComponent("copy"), copy: true)
        try await partialTransfer(base.appendingPathComponent("partial"))
        try await inPlaceShelfTransfer(base.appendingPathComponent("in-place"))
        try await concurrentReferenceEdit(base.appendingPathComponent("concurrent"))
        print("PASS: reference/shelf add-remove and file/reference manual ordering support bounded multi-step undo/redo; no-ops do not add history")
        print("PASS: staged move/copy restores files plus shelf references as one group; partial successes remain undoable and in-place shelf removal is metadata-only")
        print("PASS: a reference edit made while a staged copy runs remains an independent undo step")
    }

    @MainActor private static func references(_ base: URL) async throws {
        let files = try fixtures(base, count: 3)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        let workspace = Workspace(name: "Reference history", mode: .references, rootPath: nil, referencePaths: [files[0].path])
        model.workspaces = [workspace]; model.selectWorkspace(workspace.id)
        precondition(!model.canUndoFileDrop)
        model.appendReferences([files[0]])
        model.removeReferences([base.appendingPathComponent("not-a-reference")])
        model.reorderEntries([files[0]], before: files[0])
        model.setManualEntryOrder(true)
        precondition(!model.canUndoFileDrop, "Duplicate appends, missing removals and unchanged ordering cannot create undo steps")

        model.appendReferences([files[1]])
        model.appendReferences([files[1]])
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths == [files[0].path], "One undo skips the duplicate append and removes only the added reference")
        try await redo(model)
        precondition(model.selectedWorkspace!.referencePaths == files.prefix(2).map(\.path))
        model.appendReferences([files[2]])
        model.removeReferences([files[0]])
        model.reorderEntries([files[2]], before: files[1])
        model.setManualEntryOrder(false)
        precondition(!model.referenceManualOrder && model.selectedWorkspace!.referencePaths == [files[2].path, files[1].path])
        try await undo(model)
        precondition(model.referenceManualOrder && model.selectedWorkspace!.referencePaths == [files[2].path, files[1].path])
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths == [files[1].path, files[2].path])
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths == files.map(\.path))
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths == files.prefix(2).map(\.path))
        for _ in 0..<4 { try await redo(model) }
        precondition(!model.referenceManualOrder && model.selectedWorkspace!.referencePaths == [files[2].path, files[1].path])
        for (index, file) in files.enumerated() {
            let bytes = try Data(contentsOf: file)
            precondition(bytes == Data("fixture \(index)".utf8), "Reference history cannot change source bytes")
        }
    }

    @MainActor private static func shelfHistory(_ base: URL) async throws {
        let files = try fixtures(base, count: 2)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        model.setStagingEnabled(true); model.openStagingWorkspace()
        precondition(!model.canUndoFileDrop)
        precondition(model.stageFiles(files))
        precondition(model.stageFiles(files))
        model.clearStagedFiles()
        precondition(model.stagedURLs.isEmpty)
        try await undo(model)
        precondition(Set(model.stagedURLs) == Set(files))
        try await undo(model)
        precondition(model.stagedURLs.isEmpty && !model.canUndoFileDrop, "Adding a shelf batch is one group; duplicate batches add no step")
        try await redo(model)
        precondition(Set(model.stagedURLs) == Set(files))
        try await redo(model)
        precondition(model.stagedURLs.isEmpty)
        precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let fresh = makeTestModel(storageURL: base.appendingPathComponent("fresh-config.json"))
        fresh.setStagingEnabled(true)
        precondition(fresh.stageFiles(files), "The first shelf addition must create the shelf lazily")
        try await undo(fresh)
        precondition(fresh.stagedURLs.isEmpty, "The first addition is undoable before the shelf has ever been opened")
        try await redo(fresh)
        precondition(Set(fresh.stagedURLs) == Set(files))
    }

    @MainActor private static func directoryOrder(_ base: URL) async throws {
        let files = try fixtures(base, count: 3)
        let storage = base.deletingLastPathComponent().appendingPathComponent("order-config.json")
        let model = makeTestModel(storageURL: storage)
        let workspace = Workspace(name: "Order history", rootPath: base.path)
        model.workspaces = [workspace]; model.selectWorkspace(workspace.id)
        let original = model.fileOrderURLs
        precondition(Set(original) == Set(files))
        precondition(!model.isManualEntryOrder && !model.canUndoFileDrop)
        model.reorderEntries([original[0]], before: original[1])
        precondition(!model.isManualEntryOrder && !model.canUndoFileDrop,
            "Dropping an item in its existing slot cannot silently enable manual ordering or add history")
        model.setManualEntryOrder(true)
        precondition(model.isManualEntryOrder)
        model.reorderEntries([original.last!], before: original.first!)
        let reordered = model.fileOrderURLs
        precondition(reordered.first == original.last!)
        model.reorderEntries([reordered.first!], before: reordered.first!)
        try await undo(model)
        precondition(model.fileOrderURLs == original && model.isManualEntryOrder, "An invalid self target cannot hide the last real reorder")
        try await undo(model)
        precondition(!model.isManualEntryOrder && !model.canUndoFileDrop)
        try await redo(model); try await redo(model)
        precondition(model.fileOrderURLs == reordered && model.isManualEntryOrder)
        model.setManualEntryOrder(false)
        precondition(!model.isManualEntryOrder)
        try await undo(model)
        precondition(model.fileOrderURLs == reordered && model.isManualEntryOrder, "Turning manual ordering off is reversible")
    }

    @MainActor private static func stagedTransfer(_ base: URL, copy: Bool) async throws {
        let files = try fixtures(base.appendingPathComponent("source"), count: 2)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        model.setStagingEnabled(true); model.openStagingWorkspace()
        precondition(model.stageFiles(files))
        let destinations = try await model.transferStagedFiles(files, to: target, copy: copy)
        precondition(destinations.count == files.count && model.stagedURLs.isEmpty)
        precondition(destinations.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == copy })
        try await undo(model)
        precondition(Set(model.stagedURLs) == Set(files), "One transfer undo restores the shelf references too")
        precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        precondition(destinations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try await redo(model)
        precondition(model.stagedURLs.isEmpty && destinations.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == copy })
    }

    @MainActor private static func partialTransfer(_ base: URL) async throws {
        let files = try fixtures(base.appendingPathComponent("source"), count: 1)
        let missing = base.appendingPathComponent("source/missing.txt")
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        model.setStagingEnabled(true); model.openStagingWorkspace()
        precondition(model.stageFiles(files + [missing]))
        do {
            _ = try await model.transferStagedFiles(files + [missing], to: target, copy: false)
            preconditionFailure("Missing batch member must report a partial transfer")
        } catch { }
        precondition(model.stagedURLs == [missing])
        let destination = target.appendingPathComponent(files[0].lastPathComponent)
        precondition(FileManager.default.fileExists(atPath: destination.path))
        try await undo(model)
        precondition(Set(model.stagedURLs) == Set(files + [missing]) && FileManager.default.fileExists(atPath: files[0].path))
        precondition(!FileManager.default.fileExists(atPath: destination.path), "A failed member cannot discard the successful member's undo")
        try await redo(model)
        precondition(model.stagedURLs == [missing] && FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor private static func inPlaceShelfTransfer(_ base: URL) async throws {
        let files = try fixtures(base, count: 1)
        let model = makeTestModel(storageURL: base.deletingLastPathComponent().appendingPathComponent("in-place-config.json"))
        model.setStagingEnabled(true); model.openStagingWorkspace()
        precondition(model.stageFiles(files))
        let result = try await model.transferStagedFiles(files, to: base, copy: false)
        precondition(result == files && model.stagedURLs.isEmpty)
        try await undo(model)
        precondition(model.stagedURLs == files && FileManager.default.fileExists(atPath: files[0].path),
            "An in-place transfer records only shelf removal, never a bogus filesystem move")
        try await redo(model)
        precondition(model.stagedURLs.isEmpty && FileManager.default.fileExists(atPath: files[0].path))
    }

    @MainActor private static func concurrentReferenceEdit(_ base: URL) async throws {
        let tree = base.appendingPathComponent("source/Tree", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        for folder in [tree, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let data = Data(repeating: 42, count: 64 * 1024)
        for index in 0..<128 { try data.write(to: tree.appendingPathComponent("\(index).bin")) }
        let unrelated = base.appendingPathComponent("unrelated.txt")
        try Data("independent reference".utf8).write(to: unrelated)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        let reference = Workspace(name: "Concurrent references", mode: .references, rootPath: nil)
        model.workspaces = [reference]
        model.setStagingEnabled(true); model.openStagingWorkspace()
        precondition(model.stageFiles([tree]))
        let transfer = Task { @MainActor in try await model.transferStagedFiles([tree], to: target, copy: true) }
        for _ in 0..<100 where !model.stagingTransferInProgress { await Task.yield() }
        precondition(model.stagingTransferInProgress, "Observe the worker boundary before making the independent reference edit")
        model.selectWorkspace(reference.id); model.appendReferences([unrelated])
        _ = try await transfer.value
        precondition(model.selectedWorkspace!.referencePaths == [unrelated.path] && model.stagedURLs.isEmpty)
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths == [unrelated.path] && model.stagedURLs == [tree],
            "Undoing the transfer must not rewind an earlier edit made during its worker await")
        try await undo(model)
        precondition(model.selectedWorkspace!.referencePaths.isEmpty && model.stagedURLs == [tree])
        try await redo(model); try await redo(model)
        precondition(model.selectedWorkspace!.referencePaths == [unrelated.path] && model.stagedURLs.isEmpty)
    }

    @MainActor private static func undo(_ model: HubModel) async throws {
        precondition(model.undoLastFileDrop(), "Expected an available undo step")
        try await idle(model)
    }
    @MainActor private static func redo(_ model: HubModel) async throws {
        precondition(model.redoLastFileOperation(), "Expected an available redo step")
        try await idle(model)
    }
    @MainActor private static func idle(_ model: HubModel) async throws {
        for _ in 0..<1000 where model.fileOperationsInProgress > 0 || model.stagingTransferInProgress || model.directoryLoading {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(model.fileOperationsInProgress == 0 && !model.stagingTransferInProgress && !model.directoryLoading)
        precondition(model.errorMessage == nil, "Undo/redo failed: \(String(describing: model.errorMessage))")
    }
    private static func fixtures(_ base: URL, count: Int) throws -> [URL] {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = base.appendingPathComponent("\(index).txt")
            try Data("fixture \(index)".utf8).write(to: url)
            return url
        }
    }
}
