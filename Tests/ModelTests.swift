import AppKit
import Foundation

@main struct ModelTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        var wakeSettings = HubSettings()
        precondition(wakeSettings.appearance == "system" && wakeSettings.resolvedBackgroundTheme == "liquidGlass")
        precondition(wakeSettings.hoverDelay == 0 && wakeSettings.resolvedAutoHideDelay == 0 && wakeSettings.switchDelay == 0.1)
        precondition(wakeSettings.resolvedAnimationSpeed == 1.3 && wakeSettings.resolvedNotchIntegrationStyle == "embedded")
        precondition(wakeSettings.width == 683 && wakeSettings.height == 400 && wakeSettings.launchAtLogin)
        precondition(wakeSettings.resolvedQQMusicEnabled && wakeSettings.resolvedFavoriteShortcutEnabled && wakeSettings.resolvedStagingEnabled)
        precondition(!wakeSettings.resolvedFoldersFirst && wakeSettings.favoriteWorkspaceID == nil && wakeSettings.stagingWorkspaceID == nil,
                     "Factory preferences must not contain a user's workspace identity")
        precondition(!wakeSettings.usesNotchClickToWake)
        wakeSettings.notchClickToWake = true
        precondition(wakeSettings.usesNotchClickToWake)
        for corner in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
            wakeSettings.hotCorner = corner
            precondition(!wakeSettings.usesNotchClickToWake)
        }
        let encodedWake = try JSONEncoder().encode(wakeSettings)
        let decodedWake = try JSONDecoder().decode(HubSettings.self, from: encodedWake)
        precondition(decodedWake.notchClickToWake == true)
        let base = fm.temporaryDirectory.appendingPathComponent("FileDock-Tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: file)
        try Data("existing".utf8).write(to: target.appendingPathComponent("notes.txt"))
        let copied = try HubFileOperations.transfer(file, to: target, copy: true)
        precondition(copied.lastPathComponent == "notes copy.txt", "Collision must get a new filename")
        let existingText = try String(contentsOf: target.appendingPathComponent("notes.txt"), encoding: .utf8)
        let copiedText = try String(contentsOf: copied, encoding: .utf8)
        precondition(existingText == "existing", "Existing destination was overwritten")
        precondition(copiedText == "original")
        let copiedAgain = try HubFileOperations.transfer(file, to: target, copy: true)
        precondition(copiedAgain.lastPathComponent == "notes copy 2.txt")
        let unchanged = try HubFileOperations.transfer(file, to: source, copy: false)
        precondition(unchanged == file && fm.fileExists(atPath: file.path), "Moving into same parent should be a no-op")
        let child = source.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        do {
            try HubFileOperations.transfer(source, to: child, copy: false)
            preconditionFailure("Descendant move must fail")
        } catch HubFileError.descendant {}
        do {
            try HubFileOperations.transfer(URL(fileURLWithPath: "/", isDirectory: true), to: target, copy: true)
            preconditionFailure("Filesystem root cannot be copied into its descendants")
        } catch HubFileError.descendant {}
        let link = base.appendingPathComponent("link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: child)
        do {
            try HubFileOperations.transfer(source, to: link, copy: true)
            preconditionFailure("Symlink descendant copy must fail")
        } catch HubFileError.descendant {}
        do {
            try HubFileOperations.validateName("../escape")
            preconditionFailure("Path traversal must not be accepted as a name")
        } catch HubFileError.invalidName {}

        let storage = base.appendingPathComponent("settings/config.json")
        let model = makeTestModel(storageURL: storage, monitor: false)
        precondition(model.isInitialConfiguration && model.sortKey == .modified && !model.ascending)
        // These navigation/reordering fixtures use a deterministic named baseline.
        model.sortKey = .name
        model.ascending = true
        model.settings.foldersFirst = true
        let workspace = model.addWorkspace(name: "Fixtures", symbol: "folder", mode: .folder, urls: [source])
        precondition(model.currentURL == source && model.entries.count == 2)
        model.settings.fontSize = 17
        model.settings.animationSpeed = 1.5
        model.settings.notchIntegrationStyle = "embedded"
        model.settings.qqMusicEnabled = false
        model.settings.autoHideDelay = 1.25
        precondition(model.settings.resolvedBackgroundTheme == "liquidGlass")
        model.settings.backgroundTheme = "liquidGlass"
        model.settings.appearance = "system"
        for savedAppearance in ["system", "light", "dark"] {
            var settings = model.settings
            settings.appearance = savedAppearance
            precondition(settings.resolvedAppearance == "dark", "Glass keeps a fixed dark appearance")
            settings.backgroundTheme = "solid"
            precondition(settings.resolvedAppearance == savedAppearance, "Solid appearance preference must be retained")
        }
        model.navigate(to: child)
        precondition(model.canGoBack)
        model.goBack()
        precondition(model.currentURL == source)
        model.createFolder(named: "New Folder")
        precondition(fm.fileExists(atPath: source.appendingPathComponent("New Folder").path))
        let newDirectory = source.appendingPathComponent("New Folder", isDirectory: true).standardizedFileURL
        model.selectedIDs = [file]
        model.reorderEntries([file], before: child)
        precondition(model.isManualEntryOrder && model.visibleEntries.first?.url == file, "Files may be manually placed before folders")
        precondition(model.selectedIDs == [file], "Reordering must preserve selection")
        model.search = "notes"
        model.reorderEntries([file], before: nil)
        model.search = ""
        precondition(model.visibleEntries.map(\.url) == [child, newDirectory, file], "Filtered drags must retain hidden-by-search entries")
        let previousOrder = model.visibleEntries.map(\.url)
        model.reorderEntries([child, file], before: file)
        model.reorderEntries([target], before: child)
        model.reorderEntries([file], before: target)
        precondition(model.visibleEntries.map(\.url) == previousOrder, "Self, missing-source and stale-target drops must do nothing")
        model.navigate(to: child)
        precondition(!model.isManualEntryOrder, "Directory order must be scoped to each directory")
        model.goBack()
        precondition(model.visibleEntries.map(\.url) == previousOrder)
        model.sortByColumn(.name)
        precondition(!model.isManualEntryOrder && model.visibleEntries.first?.url == child, "Choosing a sort mode must leave manual order")
        precondition(model.ascending, "The first header click exits manual order in ascending direction")
        model.sortByColumn(.name)
        precondition(!model.ascending, "A repeated header click reverses the active direction")
        model.sortByColumn(.size)
        precondition(model.sortKey == .size && model.ascending, "A different header starts its own ascending sort")
        model.sortByColumn(.size)
        precondition(!model.ascending)
        model.sortKey = .name
        model.ascending = true
        model.reorderEntries([file], before: child)
        let contentAfterReorder = try String(contentsOf: file, encoding: .utf8)
        precondition(contentAfterReorder == "original", "Reordering must never change file data")
        model.rename(FileEntry(url: file), to: "renamed.txt")
        precondition(model.visibleEntries.first?.name == "renamed.txt", "Renaming must preserve a manually ordered file's position")
        model.rename(FileEntry(url: source.appendingPathComponent("renamed.txt")), to: "notes.txt")
        model.navigate(to: child)
        model.setManualEntryOrder(true)
        model.goBack()
        let sourceWorkspaceIndex = model.workspaces.firstIndex { $0.id == workspace.id }!
        let staleDirectoryKey = HubFileOperations.canonical(source).appendingPathComponent("renamed-child").path
        model.workspaces[sourceWorkspaceIndex].directoryOrders?[staleDirectoryKey] = ["stale-entry"]
        model.rename(FileEntry(url: child), to: "renamed-child")
        let renamedChild = source.appendingPathComponent("renamed-child", isDirectory: true)
        model.navigate(to: renamedChild)
        precondition(model.isManualEntryOrder, "Renaming a directory must migrate its stored order key")
        precondition(model.selectedWorkspace?.directoryOrders?[staleDirectoryKey] == [], "Renamed source order must replace stale target metadata")
        model.goBack()
        model.rename(FileEntry(url: renamedChild), to: "child")
        let favorites = model.addWorkspace(name: "Favorites", symbol: "star", mode: .references, urls: [file])
        let countBeforeDrop = try fm.contentsOfDirectory(atPath: source.path).count
        try model.handleDrop(urls: [child, file], copy: false)
        precondition(model.selectedWorkspace?.referencePaths.count == 2, "References must deduplicate without moving files")
        let countAfterDrop = try fm.contentsOfDirectory(atPath: source.path).count
        precondition(countAfterDrop == countBeforeDrop)
        model.navigate(to: child)
        precondition(model.canGoBack)
        model.goBack()
        precondition(model.currentURL == nil && model.isReferenceRoot, "Back should return to curated root")
        precondition(model.canGoForward)
        model.goForward()
        precondition(model.currentURL == child, "Forward should reenter the reference folder")
        model.goBack()
        model.reorderReference(child, before: file)
        precondition(model.visibleEntries.first?.url == child)
        model.appendReferences([copied])
        model.reorderEntries([copied, file], before: child)
        precondition(model.visibleEntries.map(\.url) == [file, copied, child], "Multi-item reordering must retain the displayed relative order")
        model.reorderEntries([file], before: nil)
        precondition(model.visibleEntries.map(\.url) == [copied, child, file], "Dropping on empty space must append")
        model.removeReferences([file, copied])
        precondition(fm.fileExists(atPath: file.path), "Removing a reference must preserve the original")
        model.selectWorkspace(workspace.id)
        model.search = "notes"
        precondition(model.visibleEntries.count == 1)
        model.save()
        let reloaded = makeTestModel(storageURL: storage, monitor: false)
        precondition(!reloaded.isInitialConfiguration)
        precondition(reloaded.settings.fontSize == 17, "Nested settings change must persist")
        precondition(reloaded.settings.resolvedBackgroundTheme == "liquidGlass" && reloaded.settings.appearance == "system",
                     "Glass theme and the saved solid-theme appearance must survive relaunch")
        precondition(reloaded.settings.resolvedAppearance == "dark")
        precondition(reloaded.settings.resolvedAnimationSpeed == 1.5 && !reloaded.settings.resolvedQQMusicEnabled,
                     "Animation speed and music visibility must survive a restart")
        precondition(reloaded.settings.resolvedAutoHideDelay == 1.25, "Mouse-exit delay must survive a restart")
        precondition(reloaded.settings.resolvedNotchIntegrationStyle == "embedded", "Embedded notch integration must survive a restart")
        precondition(reloaded.workspaces.contains { $0.id == favorites.id && $0.referencePaths.map { HubFileOperations.canonical(URL(fileURLWithPath: $0)) } == [HubFileOperations.canonical(child)] })
        precondition(reloaded.selectedWorkspaceID == workspace.id)
        precondition(reloaded.isManualEntryOrder && reloaded.visibleEntries.first.map { HubFileOperations.canonical($0.url) } == HubFileOperations.canonical(file), "Directory manual order must survive a restart")
        reloaded.setManualEntryOrder(false)
        precondition(!reloaded.isManualEntryOrder)
        reloaded.setManualEntryOrder(true)
        precondition(reloaded.isManualEntryOrder)
        let permissions = try fm.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600, "Bookmarks/config should be private")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HubSettings())) as! [String: Any]
        legacy.removeValue(forKey: "animationSpeed")
        legacy.removeValue(forKey: "qqMusicEnabled")
        legacy.removeValue(forKey: "autoHideDelay")
        legacy.removeValue(forKey: "notchIntegrationStyle")
        legacy.removeValue(forKey: "backgroundTheme")
        legacy.removeValue(forKey: "foldersFirst")
        let oldSettings = try JSONDecoder().decode(HubSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(oldSettings.resolvedAnimationSpeed == 1 && oldSettings.resolvedQQMusicEnabled,
                     "Configs saved before music/speed settings must continue to load")
        precondition(oldSettings.resolvedAutoHideDelay == 0.55, "Older configs must retain the previous 550ms exit delay")
        precondition(oldSettings.notchIntegrationStyle == nil && oldSettings.resolvedNotchIntegrationStyle == "connected", "Older configs must retain the existing connected notch style")
        precondition(oldSettings.resolvedBackgroundTheme == "solid" && oldSettings.resolvedFoldersFirst,
                     "New factory defaults must not change missing legacy settings")
        var malformed = HubSettings()
        for (value, expected) in [("embedded", "embedded"), ("connected", "connected"), ("unknown", "connected"), ("", "connected")] {
            malformed.notchIntegrationStyle = value
            precondition(malformed.resolvedNotchIntegrationStyle == expected)
            malformed.normalize()
            precondition(malformed.notchIntegrationStyle == expected)
        }
        malformed.notchIntegrationStyle = nil
        malformed.normalize()
        precondition(malformed.notchIntegrationStyle == nil, "Normalization must preserve an absent legacy notch setting")
        for (value, expected) in [(Double.nan, 1.0), (.infinity, 1), (-3, 0.5), (8, 2)] {
            malformed.animationSpeed = value
            malformed.normalize()
            precondition(malformed.resolvedAnimationSpeed == expected)
        }
        for (value, expected) in [(Double.nan, 0.55), (.infinity, 0.55), (-1, 0), (8, 3), (0, 0), (1.25, 1.25)] {
            malformed.autoHideDelay = value
            precondition(malformed.resolvedAutoHideDelay == expected)
            malformed.normalize()
            precondition(malformed.autoHideDelay == expected)
        }
        try testWorkspaceReorder(in: base)
        try testPathNavigation(in: base)
        try testParentChildNavigation(in: base)
        try testFavoriteShortcutAndIconOnly(in: base)
        try testFolderGrouping(in: base)
        print("PASS: collisions, no overwrite, same-parent move, descendant and symlink validation, names, navigation, reference semantics/order, filtering, persistence, private config, workspace reorder, breadcrumb navigation, parent-child keyboard navigation, favorite shortcut migration and icon-only labels")
    }

    @MainActor private static func testFolderGrouping(in base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("grouping", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("z-folder", isDirectory: true)
        let file = root.appendingPathComponent("a-file.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: file)
        let storage = base.appendingPathComponent("grouping-config.json")
        let model = makeTestModel(storageURL: storage, monitor: false)
        let workspace = model.addWorkspace(name: "Sort", mode: .folder, urls: [root])
        model.sortKey = .name; model.ascending = true
        precondition(!model.settings.resolvedFoldersFirst, "New installs start with mixed folder/file sorting")
        model.settings.foldersFirst = true
        precondition(model.settings.resolvedFoldersFirst && model.visibleEntries.map(\.name) == ["z-folder", "a-file.txt"],
                     "Enabling folders-first groups directories before the selected sort column")
        model.settings.foldersFirst = false
        precondition(model.visibleEntries.map(\.name) == ["a-file.txt", "z-folder"], "Disabling grouping interleaves folders and files by the selected column")
        model.sortByColumn(.name)
        precondition(model.visibleEntries.map(\.name) == ["z-folder", "a-file.txt"], "Mixed descending order must also respect the column")
        model.reorderEntries([file], before: folder)
        let manual = model.visibleEntries.map(\.name)
        model.settings.foldersFirst = true
        precondition(model.visibleEntries.map(\.name) == manual && model.isManualEntryOrder,
                     "The grouping preference cannot rewrite a manually arranged sequence")
        model.settings.foldersFirst = false
        model.save()
        let restored = makeTestModel(storageURL: storage, monitor: false)
        precondition(!restored.settings.resolvedFoldersFirst && restored.selectedWorkspaceID == workspace.id,
                     "The grouping toggle survives restart without changing workspace identity")
    }

    @MainActor private static func testFavoriteShortcutAndIconOnly(in base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("favorite-shortcut", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("keep.md")
        let originalData = Data("Favorite visibility and labels must preserve this file".utf8)
        try originalData.write(to: file)
        let storage = base.appendingPathComponent("favorite-shortcut-config.json")
        let initial = makeTestModel(storageURL: storage, monitor: false)
        let favoriteID = initial.favoriteWorkspace!.id
        initial.selectWorkspace(favoriteID)
        initial.appendReferences([file])
        let folder = initial.addWorkspace(name: "Research files", symbol: "books.vertical", mode: .folder, urls: [root])
        initial.save()

        // Remove every new field to reproduce a configuration from before this feature.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
        var legacySettings = legacy["settings"] as! [String: Any]
        legacySettings.removeValue(forKey: "favoriteWorkspaceID")
        legacySettings.removeValue(forKey: "favoriteShortcutEnabled")
        legacy["settings"] = legacySettings
        var legacyWorkspaces = legacy["workspaces"] as! [[String: Any]]
        for index in legacyWorkspaces.indices { legacyWorkspaces[index].removeValue(forKey: "iconOnly") }
        legacy["workspaces"] = legacyWorkspaces
        try JSONSerialization.data(withJSONObject: legacy).write(to: storage, options: .atomic)
        let model = makeTestModel(storageURL: storage, monitor: false)
        precondition(model.errorMessage == nil && model.settings.favoriteWorkspaceID == favoriteID && model.settings.resolvedFavoriteShortcutEnabled)
        precondition(model.favoriteWorkspace?.id == favoriteID && model.fixedFavoriteWorkspace?.id == favoriteID,
                     "Legacy reference workspaces named 收藏 must migrate to the fixed shortcut without duplication")
        let expectedReference = HubFileOperations.canonical(file)
        precondition(model.favoriteWorkspace?.referencePaths.map { HubFileOperations.canonical(URL(fileURLWithPath: $0)) } == [expectedReference] &&
                     !model.tabWorkspaces.contains { $0.id == favoriteID })
        precondition(model.workspaces.count == initial.workspaces.count && model.workspaces.allSatisfy { $0.iconOnly == nil })
        model.navigate(to: child)
        model.search = "keep"
        model.selectedIDs = [file]
        let location = model.currentURL, history = model.history, selection = model.selectedIDs
        let allWorkspaces = model.workspaces
        model.setFavoriteShortcutVisible(false)
        precondition(model.fixedFavoriteWorkspace == nil && model.favoriteWorkspace?.id == favoriteID && model.workspaces == allWorkspaces)
        precondition(model.tabWorkspaces.map(\.id) == allWorkspaces.map(\.id),
                     "Hiding the fixed shortcut returns the existing favorite to its original tab position")
        model.setFavoriteShortcutVisible(true)
        precondition(model.fixedFavoriteWorkspace?.id == favoriteID && model.workspaces == allWorkspaces,
                     "Restoring an existing shortcut must preserve its references and must not add a workspace")
        model.setWorkspaceIconOnly(id: folder.id, enabled: true)
        let iconWorkspace = model.workspaces.first { $0.id == folder.id }!
        precondition(iconWorkspace.iconOnly == true && iconWorkspace.name == folder.name && iconWorkspace.symbol == folder.symbol,
                     "Icon-only presentation must preserve the full label and existing icon")
        precondition(model.currentURL == location && model.history == history && model.selectedIDs == selection && model.search == "keep",
                     "Changing shortcut visibility or a tab label must not reset the active folder's navigation")
        var renamed = model.favoriteWorkspace!
        renamed.name = "Saved research"
        model.updateWorkspace(renamed)
        precondition(model.favoriteWorkspace?.id == favoriteID && model.favoriteWorkspace?.name == "Saved research" && model.fixedFavoriteWorkspace?.id == favoriteID,
                     "The migrated favorite is identified by ID after its user-visible name changes")
        model.save()
        let restored = makeTestModel(storageURL: storage, monitor: false)
        precondition(restored.fixedFavoriteWorkspace?.id == favoriteID &&
                     restored.favoriteWorkspace?.referencePaths.map { HubFileOperations.canonical(URL(fileURLWithPath: $0)) } == [expectedReference])
        precondition(restored.workspaces.first { $0.id == folder.id }?.iconOnly == true && restored.workspaces.first { $0.id == folder.id }?.name == folder.name,
                     "Fixed-favorite binding and icon-only presentation must survive a restart")
        restored.setWorkspaceIconOnly(id: folder.id, enabled: false)
        precondition(restored.workspaces.first { $0.id == folder.id }?.iconOnly == false && restored.workspaces.first { $0.id == folder.id }?.name == folder.name)
        restored.setFavoriteShortcutVisible(false)
        let hiddenReload = makeTestModel(storageURL: storage, monitor: false)
        precondition(hiddenReload.fixedFavoriteWorkspace == nil && hiddenReload.favoriteWorkspace?.id == favoriteID && hiddenReload.tabWorkspaces.contains { $0.id == favoriteID },
                     "The hidden shortcut preference must persist while its collection remains an ordinary tab")
        hiddenReload.setFavoriteShortcutVisible(true)
        hiddenReload.removeWorkspace(favoriteID)
        let afterRemovalCount = hiddenReload.workspaces.count
        precondition(hiddenReload.favoriteWorkspace == nil && hiddenReload.fixedFavoriteWorkspace == nil)
        let removedReload = makeTestModel(storageURL: storage, monitor: false)
        precondition(removedReload.favoriteWorkspace == nil && removedReload.fixedFavoriteWorkspace == nil && removedReload.workspaces.count == afterRemovalCount,
                     "Removing the favorite must not silently recreate it on refresh or restart")
        removedReload.setFavoriteShortcutVisible(true)
        let recreated = removedReload.favoriteWorkspace!
        precondition(recreated.id != favoriteID && recreated.mode == .references && recreated.name == "收藏" && recreated.referencePaths.isEmpty)
        precondition(removedReload.settings.favoriteWorkspaceID == recreated.id && removedReload.workspaces.count == afterRemovalCount + 1,
                     "Only an explicit restore command creates and binds a missing favorite")
        removedReload.setFavoriteShortcutVisible(true)
        precondition(removedReload.favoriteWorkspace?.id == recreated.id && removedReload.workspaces.count == afterRemovalCount + 1)

        let absentStorage = base.appendingPathComponent("favorite-absent-legacy-config.json")
        let favoriteIndex = legacyWorkspaces.firstIndex { ($0["id"] as? String)?.lowercased() == favoriteID.uuidString.lowercased() }!
        legacyWorkspaces[favoriteIndex]["name"] = "Other references"
        legacy["workspaces"] = legacyWorkspaces
        try JSONSerialization.data(withJSONObject: legacy).write(to: absentStorage, options: .atomic)
        let absent = makeTestModel(storageURL: absentStorage, monitor: false)
        precondition(absent.favoriteWorkspace == nil && absent.fixedFavoriteWorkspace == nil && absent.workspaces.count == legacyWorkspaces.count,
                     "A legacy configuration without a reference collection named 收藏 must not acquire one automatically")

        let emptyStorage = base.appendingPathComponent("favorite-deleted-last-config.json")
        let empty = makeTestModel(storageURL: emptyStorage, monitor: false)
        let soleFavoriteID = empty.favoriteWorkspace!.id
        for id in empty.workspaces.map(\.id) where id != soleFavoriteID { empty.removeWorkspace(id) }
        empty.removeWorkspace(soleFavoriteID)
        let emptyReload = makeTestModel(storageURL: emptyStorage, monitor: false)
        precondition(emptyReload.workspaces.isEmpty && emptyReload.favoriteWorkspace == nil && emptyReload.fixedFavoriteWorkspace == nil,
                     "Deleting the last workspace is an intentional empty configuration, not a request to seed new defaults")
        emptyReload.setFavoriteShortcutVisible(true)
        precondition(emptyReload.workspaces.count == 1 && emptyReload.fixedFavoriteWorkspace?.mode == .references)
        let finalData = try Data(contentsOf: file)
        precondition(finalData == originalData && fm.fileExists(atPath: child.path),
                     "Hiding, renaming, removing and restoring a shortcut must not modify or delete referenced files")
    }

    @MainActor private static func testParentChildNavigation(in base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("keyboard-navigation", isDirectory: true)
        let middle = root.appendingPathComponent("middle", isDirectory: true)
        let leaf = middle.appendingPathComponent("leaf", isDirectory: true)
        try fm.createDirectory(at: leaf, withIntermediateDirectories: true)
        let document = leaf.appendingPathComponent("keep.txt")
        let originalData = Data("Keyboard navigation must leave this document untouched".utf8)
        try originalData.write(to: document)
        let model = makeTestModel(storageURL: base.appendingPathComponent("keyboard-navigation-config.json"), monitor: false)
        model.addWorkspace(name: "Keyboard navigation", mode: .folder, urls: [root])
        model.navigate(to: leaf)

        for (child, parent) in [(leaf, middle), (middle, root)] {
            model.search = "a filter that hides the parent entry"
            model.selectedIDs = [document]
            model.goUp()
            precondition(model.currentURL == parent && model.search.isEmpty,
                         "Command-Up must navigate to the parent and clear the previous directory's filter")
            precondition(model.selectedIDs == [child] && model.selectedEntries.first?.canNavigate == true,
                         "The parent must select the actual folder just left, ready for Command-Down")
            model.openSelected()
            precondition(model.currentURL == child,
                         "Command-Down's existing open-selected action must return to the child selected by Command-Up")
            model.goUp()
            precondition(model.currentURL == parent && model.selectedIDs == [child],
                         "Repeated parent-child keyboard round trips must continue to select the correct folder")
        }
        let contentAfterNavigation = try Data(contentsOf: document)
        precondition(contentAfterNavigation == originalData && fm.fileExists(atPath: leaf.path) && fm.fileExists(atPath: middle.path),
                     "Parent-child keyboard navigation must never move, rename or change the underlying files")

        model.addWorkspace(name: "Filesystem root", mode: .folder, urls: [URL(fileURLWithPath: "/", isDirectory: true)])
        model.search = "preserved at root"
        model.selectedIDs = Set(model.entries.prefix(1).map(\.url))
        let rootHistory = model.history
        let rootHistoryIndex = model.historyIndex
        let rootSelection = model.selectedIDs
        let rootEntries = model.entries.map(\.url)
        model.goUp()
        model.goUp()
        precondition(model.currentURL?.path == "/" && !model.canGoUp && model.history == rootHistory && model.historyIndex == rootHistoryIndex)
        precondition(model.search == "preserved at root" && model.selectedIDs == rootSelection && model.entries.map(\.url) == rootEntries,
                     "Command-Up at the filesystem root must preserve navigation, selection and filtering without side effects")

        model.addWorkspace(name: "Virtual root", mode: .references, urls: [leaf])
        model.search = "preserved at virtual root"
        model.selectedIDs = [leaf]
        let virtualHistory = model.history
        model.goUp()
        precondition(model.isReferenceRoot && model.history == virtualHistory && model.historyIndex == -1 && model.selectedIDs == [leaf])
        precondition(model.search == "preserved at virtual root",
                     "Command-Up at a virtual root must not leave the workspace or clear its selection")
    }

    @MainActor private static func testWorkspaceReorder(in base: URL) throws {
        let folder = base.appendingPathComponent("workspace-reorder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = folder.appendingPathComponent("config.json")
        let model = makeTestModel(storageURL: storage, monitor: false)
        let fixtures = (0..<4).map { index in
            model.addWorkspace(name: "Workspace \(index)", mode: .folder, urls: [folder])
        }
        let a = fixtures[0].id, b = fixtures[1].id, c = fixtures[2].id, d = fixtures[3].id
        model.workspaces = fixtures
        model.selectWorkspace(b)
        model.search = "keep search"
        let current = model.currentURL, history = model.history
        func expect(_ expected: [UUID]) {
            precondition(model.workspaces.map(\.id) == expected)
            precondition(model.selectedWorkspaceID == b && model.currentURL == current && model.history == history,
                         "Reordering tabs must preserve selection and browsing state")
            precondition(model.search == "keep search")
        }
        model.reorderWorkspace(a, relativeTo: c, after: true)
        expect([b, c, a, d])
        model.reorderWorkspace(d, relativeTo: b, after: false)
        expect([d, b, c, a])
        model.reorderWorkspace(d, relativeTo: c, after: false)
        expect([b, d, c, a])
        model.reorderWorkspace(a, relativeTo: b, after: true)
        expect([b, a, d, c])
        let saved = try Data(contentsOf: storage)
        model.reorderWorkspace(a, relativeTo: a, after: false)
        model.reorderWorkspace(a, relativeTo: a, after: true)
        model.reorderWorkspace(UUID(), relativeTo: a, after: false)
        model.reorderWorkspace(a, relativeTo: UUID(), after: true)
        model.reorderWorkspace(a, relativeTo: b, after: true)
        model.reorderWorkspace(d, relativeTo: c, after: false)
        expect([b, a, d, c])
        let savedAfterNoOps = try Data(contentsOf: storage)
        precondition(savedAfterNoOps == saved, "Invalid and unchanged drops must not rewrite configuration")
        let reloaded = makeTestModel(storageURL: storage, monitor: false)
        precondition(reloaded.workspaces.map(\.id) == [b, a, d, c] && reloaded.selectedWorkspaceID == b,
                     "Tab order and selected tab must survive a restart")
        model.removeWorkspace(c)
        model.reorderWorkspace(a, relativeTo: c, after: true)
        model.reorderWorkspace(c, relativeTo: b, after: false)
        expect([b, a, d])
        model.reorderWorkspace(d, before: b)
        expect([d, b, a])
    }

    @MainActor private static func testPathNavigation(in base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("path-navigation", isDirectory: true)
        let parent = root.appendingPathComponent("Home Fixture", isDirectory: true)
        let child = parent.appendingPathComponent("文件夹", isDirectory: true)
        let nested = child.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"), monitor: false)
        let folder = model.addWorkspace(name: "Folder", mode: .folder, urls: [nested])
        let components = model.pathComponents
        precondition(components.first?.url?.path == "/" && components.first?.title == "/")
        precondition(components.last?.url == nested)
        precondition(components.map(\.id).count == Set(components.map(\.id)).count, "Path IDs must be unique")
        precondition(components.compactMap(\.url) == model.breadcrumbs, "The entire filesystem ancestry must be available")
        precondition(components.contains { $0.url == parent && $0.title == fm.displayName(atPath: parent.path) },
                     "Home and other ancestors must retain their display names and real destinations")
        for pair in zip(components, components.dropFirst()) {
            precondition(pair.1.url?.deletingLastPathComponent() == pair.0.url)
        }
        let nestedComponent = components.last!
        let childComponent = components.first { $0.url == child }!
        let parentComponent = components.first { $0.url == parent }!
        model.search = "clear me"
        model.selectedIDs = [nested]
        model.navigatePathComponent(parentComponent)
        precondition(model.currentURL == parent && model.search.isEmpty && model.selectedIDs.isEmpty)
        precondition(model.canGoBack)
        model.goBack()
        precondition(model.currentURL == nested)
        model.goForward()
        precondition(model.currentURL == parent)
        model.navigatePathComponent(nestedComponent)
        precondition(model.currentURL == parent, "A stale descendant breadcrumb must not navigate")
        model.navigatePathComponent(HubPathComponent(id: parentComponent.id, title: "Forged", url: child))
        precondition(model.currentURL == parent, "Matching IDs alone must not authorize a stale or changed destination")
        let other = model.addWorkspace(name: "Same location", mode: .folder, urls: [nested])
        model.navigatePathComponent(parentComponent)
        precondition(model.selectedWorkspaceID == other.id && model.currentURL == nested,
                     "A breadcrumb from a different workspace must be rejected")
        model.selectWorkspace(folder.id)
        model.navigatePathComponent(childComponent)
        precondition(model.currentURL == child)
        let currentComponent = model.pathComponents.last!
        let historyBeforeCurrent = model.history
        model.navigatePathComponent(currentComponent)
        precondition(model.history == historyBeforeCurrent, "Clicking the current directory must not duplicate history")

        let collection = model.addWorkspace(name: "My collection", symbol: "star", mode: .references, urls: [child])
        let collectionComponent = model.pathComponents.first!
        precondition(model.pathComponents == [collectionComponent] && collectionComponent.url == nil && collectionComponent.title == "My collection",
                     "A collection root must display its own name without a fictitious filesystem path")
        model.navigate(to: child)
        model.navigate(to: nested)
        precondition(model.pathComponents.first == collectionComponent && model.pathComponents.last?.url == nested,
                     "A browsed reference folder must retain a way back to its collection")
        let referencedAncestor = model.pathComponents.first { $0.url == parent }!
        model.search = "clear reference search"
        model.selectedIDs = [nested]
        model.navigatePathComponent(collectionComponent)
        precondition(model.currentURL == nil && model.isReferenceRoot && model.search.isEmpty && model.selectedIDs.isEmpty)
        precondition(model.canGoForward && !model.canGoBack)
        model.goForward()
        precondition(model.currentURL == child)
        model.goForward()
        precondition(model.currentURL == nested)
        model.goBack()
        precondition(model.currentURL == child)
        model.navigatePathComponent(referencedAncestor)
        precondition(model.currentURL == parent && model.selectedWorkspaceID == collection.id,
                     "A reference breadcrumb can navigate filesystem ancestors within its workspace")
        model.goBack()
        precondition(model.currentURL == child)
        model.goBack()
        precondition(model.isReferenceRoot)
        model.navigatePathComponent(referencedAncestor)
        precondition(model.isReferenceRoot, "Filesystem breadcrumbs must expire at the virtual collection root")

        let removed = root.appendingPathComponent("removed", isDirectory: true)
        try fm.createDirectory(at: removed, withIntermediateDirectories: true)
        model.navigate(to: removed)
        let removedComponent = model.pathComponents.last!
        try fm.removeItem(at: removed)
        let historyBeforeRemoved = model.history
        model.navigatePathComponent(removedComponent)
        precondition(model.history == historyBeforeRemoved, "A removed breadcrumb destination must never open as a file")

        var iconOnlyCollection = collection
        iconOnlyCollection.name = ""
        model.updateWorkspace(iconOnlyCollection)
        model.selectWorkspace(collection.id)
        precondition(model.pathComponents.count == 1 && model.pathComponents.first?.title == "文件合集" && model.pathComponents.first?.url == nil,
                     "An icon-only collection still needs a visible, navigable virtual-root label")
        model.navigate(to: child)
        model.navigatePathComponent(model.pathComponents.first!)
        precondition(model.isReferenceRoot, "An icon-only collection breadcrumb must return to its virtual root")
    }
}
