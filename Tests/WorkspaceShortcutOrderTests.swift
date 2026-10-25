import Foundation

@MainActor private final class ShortcutRecentFixture: HubRecentFilesProviding {
    var starts = 0
    var stops = 0
    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) { starts += 1 }
    func refresh() {}
    func stop() { stops += 1 }
}

@MainActor private final class ShortcutDirectoryFixture: HubDirectoryLoading {
    struct Pending {
        var id: UUID
        var completion: (Result<HubDirectorySnapshot, Error>) -> Void
    }
    var pending: [Pending] = []
    var cancelled: [UUID] = []
    var hold = false
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        if hold { pending.append(.init(id: id, completion: completion)) }
        else { completion(.success(.init(entries: [], canonicalDirectoryPath: request.directory?.path))) }
    }
    func cancel(id: UUID) { cancelled.append(id) }
}

@main struct WorkspaceShortcutOrderTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-ShortcutTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try normalizationAndMigration(root)
        try orderAndNavigation(root)
        try favoriteVisibility(root)
        try favoriteOnlyAndAdmission(root)
        print("PASS: shortcut order normalization/migration/stable identities, visible-only reorder and hidden slots, favorite hiding/cancellation/reuse/capacity")
    }

    @MainActor private static func makeModel(_ storage: URL, recent: ShortcutRecentFixture? = nil,
                                           loader: ShortcutDirectoryFixture? = nil) -> HubModel {
        HubModel(storageURL: storage, recentFiles: recent ?? ShortcutRecentFixture(), directoryLoader: loader ?? ShortcutDirectoryFixture())
    }

    @MainActor private static func normalizationAndMigration(_ root: URL) throws {
        let defaults: [HubShortcutItem] = [.favorite, .airDrop, .recents, .staging]
        precondition(HubSettings().resolvedShortcutOrder == defaults)
        precondition(HubShortcutItem.normalized([]) == defaults && HubShortcutItem.normalized(["unknown"]) == defaults)
        precondition(HubShortcutItem.normalized(["staging", "staging", "unknown", "favorite"]) == [.staging, .favorite, .airDrop, .recents])
        let ids = HubShortcutItem.allCases.map(\.dragID)
        precondition(Set(ids).count == 4 && HubShortcutItem.allCases.allSatisfy { HubShortcutItem(rawValue: $0.rawValue)?.dragID == $0.dragID })
        precondition(HubShortcutItem.favorite.dragID.uuidString == "3E8D642C-BD2F-4D73-813E-000000000001")
        let storage = root.appendingPathComponent("migration.json"), model = makeModel(root.appendingPathComponent("migration.json"))
        var payload = try configuration(storage), settings = payload["settings"] as! [String: Any]
        settings.removeValue(forKey: "shortcutOrder"); payload["settings"] = settings
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        precondition(model.settings.shortcutOrder == nil && model.settings.resolvedShortcutOrder == defaults)
        settings["shortcutOrder"] = ["recents", "invalid", "recents", "airDrop"]
        payload["settings"] = settings
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        precondition(model.settings.shortcutOrder == ["recents", "airDrop", "favorite", "staging"])
        let restored = makeModel(storage)
        precondition(restored.settings.resolvedShortcutOrder == [.recents, .airDrop, .favorite, .staging])
    }

    @MainActor private static func orderAndNavigation(_ root: URL) throws {
        let storage = root.appendingPathComponent("order.json"), recent = ShortcutRecentFixture()
        let model = makeModel(storage, recent: recent)
        let initialCount = model.workspaces.count
        precondition(model.visibleShortcutItems == [.favorite, .airDrop, .staging] && model.stagingWorkspace == nil)
        model.setRecentShortcutVisible(true)
        precondition(model.workspaces.count == initialCount + 1 && model.visibleShortcutItems == HubShortcutItem.defaultOrder)
        model.search = "unchanged"
        let selection = model.selectedWorkspaceID, workspaces = model.workspaces, starts = recent.starts, stops = recent.stops
        let writes = model.configurationWriteCount
        model.reorderShortcut(sourceID: HubShortcutItem.staging.dragID, targetID: HubShortcutItem.favorite.dragID, after: false)
        precondition(model.visibleShortcutItems == [.staging, .favorite, .airDrop, .recents] && model.configurationWriteCount == writes + 1)
        let reorderedWrites = model.configurationWriteCount
        model.reorderShortcut(sourceID: HubShortcutItem.staging.dragID, targetID: HubShortcutItem.favorite.dragID, after: false)
        model.reorderShortcut(sourceID: HubShortcutItem.staging.dragID, targetID: HubShortcutItem.staging.dragID, after: true)
        model.reorderShortcut(sourceID: model.workspaces[0].id, targetID: HubShortcutItem.favorite.dragID, after: false)
        precondition(model.configurationWriteCount == reorderedWrites, "No-op and foreign workspace identities cannot persist shortcut reorders")
        model.settings.airDropEnabled = false
        model.reorderShortcut(sourceID: HubShortcutItem.recents.dragID, targetID: HubShortcutItem.staging.dragID, after: false)
        precondition(model.settings.resolvedShortcutOrder == [.recents, .staging, .airDrop, .favorite],
                     "Reorder only the visible slots; hidden AirDrop keeps its position")
        let hiddenWrites = model.configurationWriteCount
        model.reorderShortcut(sourceID: HubShortcutItem.airDrop.dragID, targetID: HubShortcutItem.favorite.dragID, after: true)
        model.reorderShortcut(sourceID: HubShortcutItem.favorite.dragID, targetID: HubShortcutItem.airDrop.dragID, after: true)
        precondition(model.configurationWriteCount == hiddenWrites, "Neither hidden sources nor hidden destinations can reorder")
        model.reorderShortcut(sourceID: HubShortcutItem.recents.dragID, targetID: HubShortcutItem.favorite.dragID, after: true)
        precondition(model.settings.resolvedShortcutOrder == [.staging, .favorite, .airDrop, .recents])
        precondition(model.selectedWorkspaceID == selection && model.workspaces == workspaces && model.search == "unchanged"
                     && recent.starts == starts && recent.stops == stops,
                     "Toolbar reordering cannot navigate, restart queries, or mutate workspace data")
        model.settings.airDropEnabled = true
        let restored = makeModel(storage)
        precondition(restored.visibleShortcutItems == [.staging, .favorite, .airDrop, .recents])
        model.setFavoriteShortcutVisible(false); model.settings.airDropEnabled = false
        model.setStagingEnabled(false); model.setRecentShortcutVisible(false)
        precondition(model.visibleShortcutItems.isEmpty && model.stagingWorkspace == nil,
                     "Visibility filtering cannot create lazy workspaces")
        model.setRecentShortcutVisible(true); model.setFavoriteShortcutVisible(true)
        precondition(model.visibleShortcutItems == [.favorite, .recents], "Re-enabling features restores their stored relative order")
    }

    @MainActor private static func favoriteVisibility(_ root: URL) throws {
        let storage = root.appendingPathComponent("favorite.json"), loader = ShortcutDirectoryFixture()
        let model = makeModel(storage, loader: loader)
        let favorite = model.favoriteWorkspace!
        let other = model.addWorkspace(name: "Ordinary collection", mode: .references, urls: [root])!
        let sameName = model.addWorkspace(name: "收藏", mode: .references, urls: [])!
        model.selectWorkspace(favorite.id)
        model.appendReferences([root])
        loader.hold = true
        model.navigate(to: root)
        let pending = loader.pending.last!, saved = model.workspaces
        model.search = "clear me"; model.selectedIDs = [root]
        model.setFavoriteShortcutVisible(false)
        precondition(model.workspaces == saved && model.favoriteWorkspace?.id == favorite.id && model.fixedFavoriteWorkspace == nil
                     && !model.tabWorkspaces.contains(where: { $0.id == favorite.id })
                     && model.tabWorkspaces.contains(where: { $0.id == other.id }) && model.tabWorkspaces.contains(where: { $0.id == sameName.id }),
                     "Only the canonical favorite is hidden; ordinary reference collections remain available")
        precondition(model.selectedWorkspaceID != favorite.id && model.selectedIDs.isEmpty && model.search.isEmpty
                     && !model.canGoBack && loader.cancelled.contains(pending.id))
        let fallback = model.selectedWorkspaceID
        pending.completion(.success(.init(entries: [FileEntry(url: root)], canonicalDirectoryPath: root.path)))
        model.selectWorkspace(favorite.id)
        precondition(model.selectedWorkspaceID == fallback && model.currentURL?.path != root.path,
                     "A late directory result or stale icon action cannot restore the hidden favorite")
        for _ in 0..<(model.workspaces.count * 2) {
            model.nextWorkspace()
            precondition(model.selectedWorkspaceID != favorite.id)
        }
        let restored = makeModel(storage)
        precondition(restored.favoriteWorkspace?.id == favorite.id && restored.fixedFavoriteWorkspace == nil
                     && restored.selectedWorkspaceID != favorite.id && !restored.tabWorkspaces.contains(where: { $0.id == favorite.id }))
        let before = model.configurationWriteCount, current = model.selectedWorkspaceID
        model.setFavoriteShortcutVisible(false)
        precondition(model.configurationWriteCount == before)
        model.setFavoriteShortcutVisible(true)
        precondition(model.favoriteWorkspace?.id == favorite.id && model.workspaces == saved && model.selectedWorkspaceID == current,
                     "Re-enabling an existing favorite preserves its references and the current ordinary workspace")
    }

    @MainActor private static func favoriteOnlyAndAdmission(_ root: URL) throws {
        let storage = root.appendingPathComponent("only-favorite.json"), loader = ShortcutDirectoryFixture()
        let model = makeModel(storage, loader: loader)
        // Keep this test independent of default seed workspace names.
        let id = model.favoriteWorkspace!.id
        for workspace in model.workspaces where workspace.id != id { model.removeWorkspace(workspace.id) }
        model.selectWorkspace(id); model.appendReferences([root])
        loader.hold = true; model.refresh()
        let pending = loader.pending.last!
        model.setFavoriteShortcutVisible(false)
        precondition(model.selectedWorkspaceID == nil && model.entries.isEmpty && !model.directoryLoading
                     && model.tabWorkspaces.isEmpty && model.favoriteWorkspace?.referencePaths == [root.path]
                     && loader.cancelled.contains(pending.id))
        pending.completion(.success(.init(entries: [FileEntry(url: root)], canonicalDirectoryPath: nil)))
        precondition(model.entries.isEmpty && model.selectedWorkspaceID == nil)
        var payload = try configuration(storage)
        payload["selectedWorkspaceID"] = id.uuidString
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: payload))
        precondition(model.selectedWorkspaceID == nil && model.favoriteWorkspace?.id == id)
        let restored = makeModel(storage)
        precondition(restored.selectedWorkspaceID == nil && restored.favoriteWorkspace?.id == id && restored.tabWorkspaces.isEmpty)
        restored.setFavoriteShortcutVisible(true)
        precondition(restored.selectedWorkspaceID == id && restored.workspaces.count == 1)
        restored.setFavoriteShortcutVisible(false)
        restored.removeWorkspace(id)
        restored.setFavoriteShortcutVisible(true)
        precondition(restored.favoriteWorkspace != nil && restored.selectedWorkspaceID == restored.favoriteWorkspace?.id,
                     "First creation while disabled must enable the feature before selecting it")

        let cappedStorage = root.appendingPathComponent("favorite-capacity.json"), capped = makeModel(root.appendingPathComponent("favorite-capacity.json"))
        capped.workspaces = (0..<HubModel.maximumWorkspaces).map { Workspace(name: "Folder \($0)") }
        capped.settings.favoriteShortcutEnabled = false
        capped.selectWorkspace(capped.workspaces[0].id)
        let workspaces = capped.workspaces, settings = capped.settings, selected = capped.selectedWorkspaceID
        let bytes = try Data(contentsOf: cappedStorage), writes = capped.configurationWriteCount
        capped.setFavoriteShortcutVisible(true)
        let after = try Data(contentsOf: cappedStorage)
        precondition(capped.workspaces == workspaces && capped.settings == settings && capped.selectedWorkspaceID == selected
                     && bytes == after && capped.configurationWriteCount == writes,
                     "Failed lazy creation must not partially enable or write favorite settings")
        capped.workspaces[0].mode = .references
        capped.settings.favoriteWorkspaceID = capped.workspaces[0].id
        capped.setFavoriteShortcutVisible(true)
        precondition(capped.fixedFavoriteWorkspace?.id == workspaces[0].id && capped.workspaces.count == HubModel.maximumWorkspaces)
    }

    private static func configuration(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
