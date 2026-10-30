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
        try await wait { model.fileOperationsInProgress == 0 }
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
        // Real filesystem fixtures exercise label-on-drop and undo without
        // sending any test items to the user's Trash.
        let labelsSource = base.appendingPathComponent("label-source"), labelsTarget = base.appendingPathComponent("label-target")
        try fm.createDirectory(at: labelsSource, withIntermediateDirectories: true)
        try fm.createDirectory(at: labelsTarget, withIntermediateDirectories: true)
        let labelModel = makeTestModel(storageURL: base.appendingPathComponent("label-settings.json"))
        labelModel.addWorkspace(name: "Labels", mode: .folder, urls: [labelsTarget])
        let labelID = labelModel.selectedWorkspaceID!
        let labelSource = labelsSource.appendingPathComponent("color.txt")
        try Data("source".utf8).write(to: labelSource)
        var sourceEditable = labelSource, tagValues = URLResourceValues()
        try setFixtureTags(["keep custom tag"], on: labelSource)
        tagValues.labelNumber = 6
        try sourceEditable.setResourceValues(tagValues)
        let expectedSourceLabel = FileEntry(url: labelSource).labelNumber
        precondition(labelModel.acceptFileDrop([labelSource], workspaceID: labelID, directory: labelsTarget,
                                                copy: true, labelOnDrop: .orange))
        labelModel.setColorLabelFilter(.blue) // Must not retarget the in-flight operation.
        try await wait { labelModel.fileOperationsInProgress == 0 }
        let firstCopy = labelsTarget.appendingPathComponent("color.txt")
        precondition(FileEntry(url: firstCopy).labelNumber == 7 && FileEntry(url: labelSource).labelNumber == expectedSourceLabel)
        precondition(labelModel.dropUndoNotice == nil, "An unchanged copied source is safely journaled after color assignment")
        precondition(FileEntry(url: firstCopy).tagNames.contains("keep custom tag"))
        precondition(labelModel.acceptFileDrop([labelSource], workspaceID: labelID, directory: labelsTarget,
                                                copy: true, labelOnDrop: .orange))
        try await wait { labelModel.fileOperationsInProgress == 0 }
        let namedCopy = labelsTarget.appendingPathComponent("color copy.txt")
        precondition(fm.fileExists(atPath: namedCopy.path) && FileEntry(url: namedCopy).labelNumber == 7,
                     "The actual collision-renamed destination receives the label")
        precondition(labelModel.dropUndoNotice == nil, "Collision-renamed copies are compared against the original source")

        let moveSource = labelsSource.appendingPathComponent("move.txt")
        try Data("move".utf8).write(to: moveSource)
        var moveEditable = moveSource, moveValues = URLResourceValues(); moveValues.labelNumber = 2
        try moveEditable.setResourceValues(moveValues)
        precondition(labelModel.acceptFileDrop([moveSource], workspaceID: labelID, directory: labelsTarget,
                                                copy: false, labelOnDrop: .yellow))
        try await wait { labelModel.fileOperationsInProgress == 0 }
        let movedLabel = labelsTarget.appendingPathComponent("move.txt")
        precondition(FileEntry(url: movedLabel).labelNumber == 5 && !fm.fileExists(atPath: moveSource.path))
        precondition(labelModel.undoLastFileDrop())
        try await wait { labelModel.fileOperationsInProgress == 0 }
        precondition(fm.fileExists(atPath: moveSource.path) && !fm.fileExists(atPath: movedLabel.path))
        precondition(FileEntry(url: moveSource).labelNumber == 2, "Undo restores the moved file's original color")

        var local = firstCopy, localValues = URLResourceValues(); localValues.labelNumber = 4
        try local.setResourceValues(localValues)
        precondition(labelModel.acceptFileDrop([firstCopy], workspaceID: labelID, directory: labelsTarget,
                                                copy: true, labelOnDrop: HubFinderLabel.none, preserveLocalInPlace: true))
        try await wait { labelModel.fileOperationsInProgress == 0 }
        precondition(FileEntry(url: firstCopy).labelNumber == 0, "No Color clears the existing Finder color in place")
        precondition(labelModel.undoLastFileDrop())
        try await wait { labelModel.fileOperationsInProgress == 0 }
        precondition(FileEntry(url: firstCopy).labelNumber == 4, "Undo restores an in-place label without moving the file")

        let refModel = makeTestModel(storageURL: base.appendingPathComponent("label-references-settings.json"))
        refModel.addWorkspace(name: "References", mode: .references, urls: [])
        let referenceID = refModel.selectedWorkspaceID!
        precondition(refModel.acceptFileDrop([labelSource], workspaceID: referenceID, directory: nil, copy: false))
        let priorReferenceOrder = refModel.workspaces.first { $0.id == referenceID }!.referencePaths
        precondition(refModel.acceptFileDrop([labelSource, moveSource], workspaceID: referenceID, directory: nil,
                                             copy: false, labelOnDrop: .red))
        try await wait { refModel.fileOperationsInProgress == 0 }
        precondition(refModel.undoLastFileDrop())
        try await wait { refModel.fileOperationsInProgress == 0 }
        precondition(refModel.workspaces.first { $0.id == referenceID }!.referencePaths == priorReferenceOrder,
                     "Undo removes only newly added references and preserves the original order")
        precondition(fm.fileExists(atPath: labelSource.path) && fm.fileExists(atPath: moveSource.path),
                     "Reference undo must never move or delete source files")

        let stageModel = makeTestModel(storageURL: base.appendingPathComponent("label-stage-settings.json"))
        stageModel.setStagingEnabled(true); stageModel.openStagingWorkspace()
        let stagingID = stageModel.selectedWorkspaceID!
        precondition(stageModel.stageFiles([labelSource]))
        let stagePriorOrder = stageModel.workspaces.first { $0.id == stagingID }!.referencePaths
        precondition(stageModel.acceptFileDrop([labelSource, moveSource], workspaceID: stagingID, directory: nil,
                                               copy: false, labelOnDrop: .purple))
        try await wait { stageModel.fileOperationsInProgress == 0 }
        precondition(stageModel.undoLastFileDrop())
        try await wait { stageModel.fileOperationsInProgress == 0 }
        precondition(stageModel.workspaces.first { $0.id == stagingID }!.referencePaths == stagePriorOrder)
        precondition(fm.fileExists(atPath: labelSource.path) && fm.fileExists(atPath: moveSource.path))

        precondition(labelModel.acceptFileDrop([firstCopy], workspaceID: labelID, directory: labelsTarget,
                                                copy: false, labelOnDrop: .green, preserveLocalInPlace: true))
        try await wait { labelModel.fileOperationsInProgress == 0 }
        labelModel.performFinderAction(.label(6), urls: [firstCopy])
        try await wait { labelModel.fileOperationsInProgress == 0 }
        precondition(!labelModel.undoLastFileDrop(), "A later ordinary file action invalidates the stale drop journal")
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
