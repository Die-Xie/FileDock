import AppKit
import Foundation

@main struct StagingWorkspaceTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FolderHub-StagingTests-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try migrationAndReferenceSafety(base)
        try importedSelectionAndBlacklistSettings(base)
        try explicitPathAliases(base)
        try await transferSafety(base)
        try await directoryTransfer(base)
        try await transferDestinationAliases(base)
        try persistenceTransactionsAndRetention(base)
        try freshAppearanceMetadata(base)
        try await backgroundRefreshSafety(base)
        print("PASS: staging persistence, scope retention, bounded writes, refresh concurrency, appearance metadata, path aliases, reference safety, partial transfers and blacklist settings")
    }

    @MainActor private static func importedSelectionAndBlacklistSettings(_ base: URL) throws {
        let storage = base.appendingPathComponent("import/config.json")
        let model = HubModel(storageURL: storage)
        let ordinaryID = model.selectedWorkspaceID!
        model.openStagingWorkspace()
        let shelfID = model.stagingWorkspace!.id
        var payload = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
        var settings = payload["settings"] as! [String: Any]
        settings["stagingEnabled"] = false
        settings.removeValue(forKey: "blockedApplicationBundleIDs")
        settings.removeValue(forKey: "suppressHoverInFullScreen")
        payload["settings"] = settings
        payload["selectedWorkspaceID"] = shelfID.uuidString
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        precondition(!model.isStagingWorkspace && model.selectedWorkspaceID == ordinaryID,
                     "Import must not leave a disabled shelf selected")
        precondition(model.settings.resolvedBlockedApplicationBundleIDs.isEmpty && model.settings.resolvedSuppressHoverInFullScreen,
                     "Legacy configurations have no blocked apps and default to pausing hover in full screen")

        settings["blockedApplicationBundleIDs"] = [" com.example.game ", "com.example.game", "", "  ",
            "com.example.video", "bad\u{0}identifier", String(repeating: "a", count: 256)]
        settings["suppressHoverInFullScreen"] = false
        payload["settings"] = settings
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        let expected = ["com.example.game", "com.example.video"]
        precondition(model.settings.blockedApplicationBundleIDs == expected && !model.settings.resolvedSuppressHoverInFullScreen)
        let reloaded = HubModel(storageURL: storage)
        precondition(reloaded.settings.blockedApplicationBundleIDs == expected && !reloaded.settings.resolvedSuppressHoverInFullScreen,
                     "Normalized blacklist IDs and an explicit disabled full-screen setting must persist")
        precondition(reloaded.selectedWorkspaceID == ordinaryID)

        // A crafted configuration containing only a hidden shelf must clear old folder/history state.
        payload["workspaces"] = (payload["workspaces"] as! [[String: Any]]).filter {
            ($0["id"] as? String)?.lowercased() == shelfID.uuidString.lowercased()
        }
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        precondition(model.selectedWorkspaceID == nil && model.currentURL == nil && model.entries.isEmpty && model.history.isEmpty)
        precondition(model.stagingWorkspace?.id == shelfID && !model.settings.resolvedStagingEnabled)
    }

    @MainActor private static func explicitPathAliases(_ base: URL) throws {
        let file = base.appendingPathComponent("alias-source.txt")
        let bytes = Data("alias references preserve file bytes".utf8)
        try bytes.write(to: file)
        // Foundation may itself shorten a resolved /private/var URL to /var;
        // construct both literal spellings so this test cannot normalize them away.
        let canonicalPath = file.path.hasPrefix("/var/") ? "/private" + file.path : file.path
        guard canonicalPath.hasPrefix("/private/var/") else {
            preconditionFailure("This macOS fixture must exercise the /private/var to /var alias")
        }
        let canonical = URL(fileURLWithPath: canonicalPath)
        let alias = URL(fileURLWithPath: String(canonicalPath.dropFirst("/private".count)))
        precondition(canonical.path != alias.path && HubFileOperations.canonical(canonical) == HubFileOperations.canonical(alias))
        let storage = base.appendingPathComponent("aliases/config.json")
        let model = HubModel(storageURL: storage)
        model.stageFiles([canonical, alias])
        precondition(model.stagedURLs.count == 1)
        let restored = HubModel(storageURL: storage)
        precondition(restored.stagedURLs.count == 1)
        restored.stageFiles([alias, canonical])
        precondition(restored.stagedURLs.count == 1, "Bookmark resolution must not make a second alias entry after restart")
        restored.removeStagedFiles([canonical])
        precondition(restored.stagedURLs.isEmpty)
        let after = try Data(contentsOf: alias)
        precondition(after == bytes)
    }

    @MainActor private static func migrationAndReferenceSafety(_ base: URL) throws {
        let storage = base.appendingPathComponent("migration/config.json")
        let file = base.appendingPathComponent("source.txt")
        try Data("original remains".utf8).write(to: file)
        let original = HubModel(storageURL: storage)
        let initialIDs = original.workspaces.map(\.id)
        let originalSelection = original.selectedWorkspaceID
        // Optional fields must not seed another workspace into a pre-feature config.
        var payload = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
        var settings = payload["settings"] as! [String: Any]
        settings.removeValue(forKey: "stagingWorkspaceID")
        settings.removeValue(forKey: "stagingEnabled")
        payload["settings"] = settings
        try JSONSerialization.data(withJSONObject: payload).write(to: storage)
        let model = HubModel(storageURL: storage)
        precondition(model.settings.resolvedStagingEnabled && model.stagingWorkspace == nil)
        precondition(model.workspaces.map(\.id) == initialIDs && model.selectedWorkspaceID == originalSelection)
        precondition(!model.stageFiles([URL(string: "https://example.invalid/document")!]))
        precondition(model.stagingWorkspace == nil, "An unsupported drop must not create an empty shelf")
        precondition(model.stageFiles([file, file, base.appendingPathComponent("child/../source.txt")]))
        let shelf = model.stagingWorkspace!
        precondition(shelf.mode == .references && shelf.rootPath == nil && shelf.referencePaths == [file.path])
        precondition(model.selectedWorkspaceID == originalSelection, "Dropping on the shelf must preserve the browsing location")
        precondition(!model.tabWorkspaces.contains { $0.id == shelf.id }, "The shelf only appears in the fixed toolbar")
        model.openStagingWorkspace()
        precondition(model.isStagingRoot && model.isReferenceRoot && model.entries.map(\.url) == [file])
        model.setStagingEnabled(false)
        precondition(!model.isStagingWorkspace && model.stagedURLs == [file])
        precondition(!model.stageFiles([base.appendingPathComponent("another.txt")]))
        model.selectWorkspace(shelf.id)
        precondition(!model.isStagingWorkspace, "Disabling the shelf also excludes workspace keyboard/navigation selection")
        let reloaded = HubModel(storageURL: storage)
        precondition(!reloaded.settings.resolvedStagingEnabled && reloaded.stagingWorkspace?.id == shelf.id)
        precondition(reloaded.stagedURLs == [file] && !reloaded.isStagingWorkspace)
        reloaded.setStagingEnabled(true)
        reloaded.openStagingWorkspace()
        precondition(reloaded.stagingWorkspace?.id == shelf.id && reloaded.isStagingRoot)
        let accepted = try reloaded.handleDrop(urls: [file])
        precondition(accepted && reloaded.stagedURLs == [file])
        reloaded.selectedIDs = [file]
        reloaded.trashSelected()
        precondition(reloaded.stagedURLs.isEmpty, "Delete from the shelf must only remove references")
        let text = try String(contentsOf: file, encoding: .utf8)
        precondition(text == "original remains")
        reloaded.stageFiles([file])
        reloaded.clearStagedFiles()
        precondition(reloaded.stagedURLs.isEmpty && FileManager.default.fileExists(atPath: file.path))
        reloaded.stageFiles([file])
        reloaded.removeReferences([file])
        precondition(reloaded.stagedURLs.isEmpty && FileManager.default.fileExists(atPath: file.path))
        // Hiding a shelf that is the only workspace must produce a valid empty selection.
        for id in reloaded.workspaces.map(\.id) where id != shelf.id { reloaded.removeWorkspace(id) }
        reloaded.setStagingEnabled(false)
        precondition(reloaded.selectedWorkspaceID == nil && reloaded.entries.isEmpty)
        let onlyShelf = HubModel(storageURL: storage)
        precondition(onlyShelf.selectedWorkspaceID == nil && onlyShelf.entries.isEmpty)
        onlyShelf.setStagingEnabled(true)
        onlyShelf.openStagingWorkspace()
        precondition(onlyShelf.isStagingRoot && onlyShelf.stagingWorkspace?.id == shelf.id)
    }

    @MainActor private static func transferSafety(_ base: URL) async throws {
        let fm = FileManager.default
        let source = base.appendingPathComponent("transfer-source")
        let destination = base.appendingPathComponent("transfer-destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("same.txt")
        let missing = source.appendingPathComponent("missing.txt")
        let untouched = source.appendingPathComponent("not-staged.txt")
        try Data("incoming".utf8).write(to: file)
        try Data("not staged".utf8).write(to: untouched)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("same.txt"))
        let model = HubModel(storageURL: base.appendingPathComponent("transfer/config.json"))
        model.stageFiles([file, missing])
        do {
            _ = try await model.transferStagedFiles([file, missing, untouched], to: destination, copy: true)
            preconditionFailure("A failed source must be reported even when another source succeeds")
        } catch HubFileError.partial(let errors) { precondition(errors.count == 1 && errors[0].contains("missing.txt")) }
        precondition(!model.stagingTransferInProgress && model.stagedURLs == [missing])
        precondition(fm.fileExists(atPath: file.path), "Copy must preserve the original")
        let preserved = try String(contentsOf: destination.appendingPathComponent("same.txt"), encoding: .utf8)
        let copied = try String(contentsOf: destination.appendingPathComponent("same copy.txt"), encoding: .utf8)
        precondition(preserved == "existing" && copied == "incoming", "Collisions must never overwrite destination data")
        precondition(!fm.fileExists(atPath: destination.appendingPathComponent("not-staged.txt").path))
        model.clearStagedFiles()
        model.stageFiles([untouched])
        let sameFolder = try await model.transferStagedFiles([untouched], to: source, copy: false)
        precondition(sameFolder == [untouched] && model.stagedURLs.isEmpty && fm.fileExists(atPath: untouched.path),
                     "A same-folder move drains the reference without moving or deleting the original")
        model.stageFiles([file])
        do {
            _ = try await model.transferStagedFiles([file], to: base.appendingPathComponent("missing-target"), copy: false)
            preconditionFailure("A missing destination must fail")
        } catch HubFileError.partial { }
        precondition(model.stagedURLs == [file] && fm.fileExists(atPath: file.path))
        // A successful move updates references in other collections, then drains only the shelf.
        let collection = model.addWorkspace(name: "Other references", mode: .references, urls: [file])
        let targets = try await model.transferStagedFiles([file], to: destination, copy: false)
        precondition(targets.count == 1 && targets[0].lastPathComponent == "same copy 2.txt")
        precondition(!fm.fileExists(atPath: file.path) && model.stagedURLs.isEmpty)
        precondition(model.workspaces.first { $0.id == collection.id }?.referencePaths == targets.map(\.path))
        let restarted = HubModel(storageURL: base.appendingPathComponent("transfer/config.json"))
        precondition(restarted.stagedURLs.isEmpty && restarted.workspaces.first { $0.id == collection.id }?.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == targets.map(\.path))
    }

    @MainActor private static func directoryTransfer(_ base: URL) async throws {
        let fm = FileManager.default
        let folder = base.appendingPathComponent("directory-parent")
        let child = folder.appendingPathComponent("child.txt")
        let destination = base.appendingPathComponent("directory-target")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: child)
        let model = HubModel(storageURL: base.appendingPathComponent("directory/config.json"))
        model.stageFiles([folder, child])
        do {
            _ = try await model.transferStagedFiles([folder], to: folder, copy: false)
            preconditionFailure("A folder must not be moved into itself")
        } catch HubFileError.partial { }
        precondition(model.stagedURLs.map(\.path) == [folder.path, child.path])
        let references = model.addWorkspace(name: "Nested references", mode: .references, urls: [child])
        let folderWorkspace = model.addWorkspace(name: "Folder", mode: .folder, urls: [folder])
        let targets = try await model.transferStagedFiles([folder, child], to: destination, copy: false)
        precondition(targets.count == 1, "Parent and child must transfer once as a single directory")
        let movedChild = targets[0].appendingPathComponent("child.txt")
        precondition(model.stagedURLs.isEmpty && !fm.fileExists(atPath: folder.path))
        precondition(fm.fileExists(atPath: movedChild.path))
        precondition(model.workspaces.first { $0.id == references.id }?.referencePaths == [movedChild.path])
        precondition(model.workspaces.first { $0.id == folderWorkspace.id }?.rootURL?.path == targets[0].path)
        precondition(model.currentURL?.path == targets[0].path && model.entries.map { $0.url.path } == [movedChild.path])
    }

    private static func expect(_ condition: Bool, _ message: String = "") { precondition(condition, message) }

    @MainActor private static func transferDestinationAliases(_ base: URL) async throws {
        let fm = FileManager.default
        let source = base.appendingPathComponent("alias-move-source")
        let destination = base.appendingPathComponent("alias-move-target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("reference.txt")
        try Data("aliased move".utf8).write(to: file)
        let literalPath = destination.path.hasPrefix("/var/") ? "/private" + destination.path : destination.path
        let aliasedDestination = URL(fileURLWithPath: literalPath)
        precondition(aliasedDestination.path.hasPrefix("/private/var/"))
        let storage = base.appendingPathComponent("alias-transfer/config.json")
        let model = HubModel(storageURL: storage)
        model.stageFiles([file])
        let collection = model.addWorkspace(name: "Keep moved reference", mode: .references, urls: [file])
        let targets = try await model.transferStagedFiles([file], to: aliasedDestination, copy: false)
        precondition(model.stagedURLs.isEmpty, "Successful moves must drain the shelf even when the destination uses /private/var")
        precondition(targets == [destination.appendingPathComponent(file.lastPathComponent).standardizedFileURL])
        precondition(model.workspaces.first { $0.id == collection.id }?.referencePaths == targets.map(\.path))
        let reloaded = HubModel(storageURL: storage)
        precondition(reloaded.stagedURLs.isEmpty && fm.fileExists(atPath: targets[0].path))
    }

    @MainActor private static func persistenceTransactionsAndRetention(_ base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("persistence-source")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try (0..<120).map { index -> URL in
            let url = root.appendingPathComponent("item-\(index).txt")
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let storage = base.appendingPathComponent("batch/config.json")
        let model = HubModel(storageURL: storage)
        var writes = model.configurationWriteCount
        precondition(model.stageFiles(files))
        precondition(model.configurationWriteCount == writes + 1, "A batch of bookmarks and a lazy shelf must persist once")
        func bookmarks() throws -> Set<String> {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
            return Set((json["bookmarks"] as! [String: String]).keys.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        }
        try expect(bookmarks().isSuperset(of: files.map(\.path)))
        let collection = model.addWorkspace(name: "Retained child", mode: .references, urls: [files[0]])
        model.clearStagedFiles()
        try expect(bookmarks() == [files[0].path], "Clearing the shelf removes unused bookmarks while retaining shared references")
        // A parent security scope is still useful when only a child remains referenced.
        let folder = model.addWorkspace(name: "Parent authorization", mode: .folder, urls: [root])
        model.selectWorkspace(collection.id)
        model.removeWorkspace(folder.id)
        try expect(bookmarks().contains(root.path), "A retained child must keep its authorized parent scope")
        // Current directory/history keep access even after the collection reference is removed.
        model.appendReferences([root])
        model.navigate(to: root)
        model.removeReferences([root, files[0]])
        try expect(bookmarks().contains(root.path), "Browsing/history must keep a folder scope alive")
        model.selectWorkspace(model.favoriteWorkspace!.id)
        try expect(bookmarks().isEmpty, "Changing workspace releases scopes no longer referenced by history")
        var workspace = model.workspaces.first { $0.id == collection.id }!
        workspace.customIconPath = files[1].path
        model.updateWorkspace(workspace)
        try expect(bookmarks() == [files[1].path], "Custom icon access must survive bookmark cleanup")
        workspace.customIconPath = nil
        model.updateWorkspace(workspace)
        try expect(bookmarks().isEmpty)

        writes = model.configurationWriteCount
        model.beginInteractiveResize(); model.beginInteractiveResize()
        for index in 0..<100 { model.settings.width = Double(700 + index); model.settings.height = Double(400 + index) }
        precondition(model.configurationWriteCount == writes)
        model.endInteractiveResize(); model.endInteractiveResize()
        precondition(model.configurationWriteCount == writes + 1, "A live resize must write once on release")
        model.beginInteractiveResize()
        model.settings.width = 901
        model.save()
        precondition(model.configurationWriteCount == writes + 2, "Termination-style save must flush a live resize")
        model.endInteractiveResize()
        precondition(model.configurationWriteCount == writes + 2)
        let validDisk = try Data(contentsOf: storage)
        let originalName = model.workspaces[0].name
        writes = model.configurationWriteCount
        model.workspaces[0].name = String(repeating: "x", count: 16 * 1024 * 1024)
        precondition(model.configurationWriteCount == writes && model.errorMessage?.contains("16 MiB") == true)
        try expect(Data(contentsOf: storage) == validDisk, "An oversized configuration must never replace the last valid disk state")
        let recovered = HubModel(storageURL: storage)
        precondition(recovered.workspaces[0].name == originalName)
        model.workspaces[0].name = originalName
        precondition(model.configurationWriteCount == writes + 1)
        precondition(files.allSatisfy { fm.fileExists(atPath: $0.path) }, "Scope garbage collection must not remove files")
    }

    @MainActor private static func freshAppearanceMetadata(_ base: URL) throws {
        let fm = FileManager.default
        let folder = base.appendingPathComponent("appearance-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Populate the caller URL's resource cache before changing Finder metadata.
        _ = try folder.resourceValues(forKeys: [.labelNumberKey, .tagNamesKey, .attributeModificationDateKey])
        let before = FileEntry(url: folder)
        var changes = URLResourceValues()
        changes.labelNumber = before.labelNumber == 6 ? 2 : 6
        changes.tagNames = ["FolderHub Test Tag"]
        var writable = folder
        try writable.setResourceValues(changes)
        var fresh = URL(fileURLWithPath: folder.path)
        fresh.removeAllCachedResourceValues()
        let actual = try fresh.resourceValues(forKeys: [.labelNumberKey, .tagNamesKey, .attributeModificationDateKey])
        let after = FileEntry(url: folder)
        precondition(after.labelNumber == (actual.labelNumber ?? 0))
        precondition(after.tagNames == (actual.tagNames ?? []).sorted())
        precondition(after.attributesModified == actual.attributeModificationDate)
        precondition(after.snapshotSignature != before.snapshotSignature, "Finder appearance changes must invalidate the display snapshot")
        let model = HubModel(storageURL: base.appendingPathComponent("appearance/config.json"))
        _ = model.addWorkspace(name: "Appearance", mode: .references, urls: [folder])
        precondition(model.entries.first?.snapshotSignature == after.snapshotSignature)
        let prior = model.entries[0].snapshotSignature
        changes.labelNumber = after.labelNumber == 2 ? 6 : 2
        changes.tagNames = ["Different Test Tag"]
        try writable.setResourceValues(changes)
        model.refresh()
        precondition(model.entries[0].snapshotSignature != prior)
        let subsecondFile = base.appendingPathComponent("subsecond-appearance.txt")
        try Data("unchanged size".utf8).write(to: subsecondFile)
        let second = floor(Date().timeIntervalSince1970) - 10
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.125)], ofItemAtPath: subsecondFile.path)
        let early = FileEntry(url: subsecondFile)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.875)], ofItemAtPath: subsecondFile.path)
        let late = FileEntry(url: subsecondFile)
        precondition(early.modified != late.modified && early.snapshotSignature != late.snapshotSignature,
                     "Subsecond content/attribute changes must survive snapshot comparison")
    }

    @MainActor private static func backgroundRefreshSafety(_ base: URL) async throws {
        let fm = FileManager.default
        let first = base.appendingPathComponent("background-first")
        let second = base.appendingPathComponent("background-second")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<240 { try Data("fixture".utf8).write(to: first.appendingPathComponent("item-\(index).txt")) }
        let secondFile = second.appendingPathComponent("second.txt")
        try Data("second folder".utf8).write(to: secondFile)
        let model = HubModel(storageURL: base.appendingPathComponent("background/config.json"))
        let workspace = model.addWorkspace(name: "Background", mode: .folder, urls: [first])
        let startCount = model.backgroundRefreshCount
        model.refreshInBackground()
        for _ in 0..<20 { model.refreshInBackground() }
        precondition(model.backgroundRefreshCount == startCount + 1, "Concurrent ticks must share a single metadata scan")
        model.navigate(to: second)
        precondition(model.entries.map(\.url) == [secondFile])
        try await waitForRefresh(model)
        precondition(model.entries.map(\.url) == [secondFile] && model.currentURL?.standardizedFileURL == second.standardizedFileURL,
                     "A late scan must not replace a synchronously navigated folder")
        precondition(model.backgroundRefreshCount == startCount + 1, "Navigation must cancel the obsolete coalesced scan")
        let newFile = second.appendingPathComponent("new.txt")
        try Data("new file".utf8).write(to: newFile)
        model.refreshInBackground()
        for _ in 0..<20 { model.refreshInBackground() }
        try await waitForRefresh(model)
        precondition(Set(model.entries.map(\.url)) == [secondFile, newFile])
        precondition(model.backgroundRefreshCount == startCount + 3, "Many ticks should schedule at most one follow-up scan")
        let hidden = second.appendingPathComponent(".hidden.txt")
        try Data("hidden fixture".utf8).write(to: hidden)
        model.refreshInBackground()
        model.showHiddenFiles = true
        try await waitForRefresh(model)
        precondition(model.entries.contains { $0.url == hidden }, "Old hidden-file settings must not overwrite a refreshed snapshot")
        model.selectWorkspace(workspace.id)
        let saved = try Data(contentsOf: base.appendingPathComponent("background/config.json"))
        model.navigate(to: second)
        model.refreshInBackground()
        try model.importConfiguration(data: saved)
        try await waitForRefresh(model)
        precondition(model.currentURL?.standardizedFileURL == first.standardizedFileURL && model.entries.count == 240, "Import must invalidate old background results")
    }

    @MainActor private static func waitForRefresh(_ model: HubModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isRefreshingInBackground && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(!model.isRefreshingInBackground, "Metadata refresh should finish within the fixture timeout")
    }

}
