import AppKit
import Foundation

@MainActor private final class AdmissionDirectoryLoader: HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        completion(.success(.init(entries: [], canonicalDirectoryPath: request.directory?.path)))
    }
    func cancel(id: UUID) {}
}

@main struct ConfigurationAdmissionTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("FileDock-Admission-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try referenceLimits(root)
        try workspaceLimits(root)
        try optionalMetadataFailure(root)
        try serializedConfigurationLimit(root)
        try musicPlayerMigration(root)
        sharingScopeAncestry(root)
        try await configurationImportDuringFileWork(root)
        print("PASS: workspace/reference admission bounds, serialized size protection and recovery, player migrations, metadata fallbacks and configuration import guards during writes/sharing/providers")
    }

    @MainActor private static func unchanged(_ model: HubModel, storage: URL, _ action: () -> Void) throws {
        let workspaces = model.workspaces, settings = model.settings, selection = model.selectedWorkspaceID
        let writes = model.configurationWriteCount, bytes = try Data(contentsOf: storage)
        action()
        precondition(model.workspaces == workspaces && model.settings == settings && model.selectedWorkspaceID == selection,
                     "Rejected admission must not partially modify workspace settings")
        let after = try Data(contentsOf: storage)
        precondition(model.configurationWriteCount == writes && after == bytes,
                     "Rejected admission must not write configuration or bookmarks")
    }

    @MainActor private static func referenceLimits(_ root: URL) throws {
        let storage = root.appendingPathComponent("references.json")
        let model = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        let paths = (0..<HubModel.maximumReferences).map { root.appendingPathComponent("unread-\($0)").path }
        let extra = root.appendingPathComponent("excess.txt")
        try Data("safe".utf8).write(to: extra)
        let oversized = (paths + [extra.path]).map { URL(fileURLWithPath: $0) }
        try unchanged(model, storage: storage) {
            precondition(model.addWorkspace(name: "Too many", mode: .references, urls: oversized) == nil)
        }
        try unchanged(model, storage: storage) {
            precondition(!model.stageFiles(oversized))
            precondition(model.stagingWorkspace == nil, "Oversized first drop cannot create a partial shelf")
        }
        var collection = Workspace(name: "Full collection", symbol: "star", mode: .references)
        collection.referencePaths = paths
        model.workspaces = [collection]
        model.selectWorkspace(collection.id)
        try unchanged(model, storage: storage) { model.appendReferences([extra]) }
        try unchanged(model, storage: storage) {
            precondition(!model.acceptFileDrop([extra], workspaceID: collection.id, directory: nil, copy: true))
        }
        var edited = collection
        edited.name = "Must not apply"
        edited.customIconPath = extra.path
        edited.referencePaths.append(extra.path)
        try unchanged(model, storage: storage) { model.updateWorkspace(edited) }
        // Existing duplicate references consume no additional capacity.
        model.appendReferences([URL(fileURLWithPath: paths[0])])
        precondition(model.selectedWorkspace!.referencePaths.count == HubModel.maximumReferences)
        model.settings.stagingWorkspaceID = collection.id
        try unchanged(model, storage: storage) { precondition(!model.stageFiles([extra])) }
        let restored = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        precondition(restored.workspaces.first?.referencePaths == paths && !restored.isInitialConfiguration,
                     "A maximum-sized admitted configuration must remain loadable")
    }

    @MainActor private static func workspaceLimits(_ root: URL) throws {
        let storage = root.appendingPathComponent("workspaces.json")
        let model = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        model.settings.favoriteShortcutEnabled = false
        model.workspaces = (0..<HubModel.maximumWorkspaces).map { Workspace(name: "Folder \($0)", mode: .folder) }
        model.selectWorkspace(model.workspaces[0].id)
        try unchanged(model, storage: storage) { precondition(model.addWorkspace(name: "Extra", mode: .folder, urls: [root]) == nil) }
        try unchanged(model, storage: storage) { precondition(model.addRecentWorkspace() == nil) }
        try unchanged(model, storage: storage) { model.setFavoriteShortcutVisible(true) }
        try unchanged(model, storage: storage) { model.openStagingWorkspace() }
        try unchanged(model, storage: storage) { precondition(!model.stageFiles([root])) }
        precondition(model.favoriteWorkspace == nil && model.stagingWorkspace == nil)
        let restored = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        precondition(restored.workspaces.count == HubModel.maximumWorkspaces && !restored.isInitialConfiguration)
    }

    @MainActor private static func configurationImportDuringFileWork(_ root: URL) async throws {
        let storage = root.appendingPathComponent("import.json")
        let model = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        precondition(model.addWorkspace(name: "Working", mode: .folder, urls: [root]) != nil)
        let saved = try Data(contentsOf: storage)
        func reject() {
            do { try model.importConfiguration(data: saved); preconditionFailure("Import must wait for active file work") }
            catch HubFileError.partial { }
            catch { preconditionFailure("Unexpected import error: \(error)") }
        }
        model.createFolder(named: "Created while import blocked")
        precondition(model.fileOperationsInProgress == 1)
        try unchanged(model, storage: storage, reject)
        let deadline = Date().addingTimeInterval(5)
        while model.fileOperationsInProgress > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0)
        precondition(managerExists(root.appendingPathComponent("Created while import blocked")))
        model.sharingInProgress = true
        try unchanged(model, storage: storage, reject)
        model.sharingInProgress = false
        model.externalFileWorkInProgress = { true }
        try unchanged(model, storage: storage, reject)
        model.externalFileWorkInProgress = { false }
        try model.importConfiguration(data: saved)
        precondition(model.selectedWorkspace?.name == "Working")
    }

    private static func managerExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor private static func sharingScopeAncestry(_ root: URL) {
        // Ordinary test processes may receive no scoped grant from macOS. Test
        // membership independently of that OS decision using the original URL
        // values the model would retain after successful scope activation.
        let directory = root.appendingPathComponent("shared", isDirectory: true)
        let sibling = root.appendingPathComponent("shared-other", isDirectory: true)
        let child = directory.appendingPathComponent("nested/file.txt")
        let scoped = URL(fileURLWithPath: root.path + "/shared/nested/..", isDirectory: true)
        let matches = HubModel.matchingSecurityScopes([scoped, sibling], for: [child, child, directory.appendingPathComponent("second.txt")])
        precondition(matches == [scoped] && matches[0].absoluteString == scoped.absoluteString,
                     "Descendants retain the original scope URL once; matching must not use raw path prefixes")
        precondition(HubModel.matchingSecurityScopes([directory], for: [sibling.appendingPathComponent("file.txt")]).isEmpty)
        precondition(HubModel.matchingSecurityScopes([directory], for: [URL(string: "https://example.invalid/file")!]).isEmpty)
        precondition(HubModel.matchingSecurityScopes([directory], for: [directory]) == [directory])
    }

    @MainActor private static func serializedConfigurationLimit(_ root: URL) throws {
        let storage = root.appendingPathComponent("serialized-limit.json")
        let model = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        let previous = try Data(contentsOf: storage), writes = model.configurationWriteCount
        let longComponent = String(repeating: "a", count: 220)
        let prefix = root.path + "/" + Array(repeating: longComponent, count: 4).joined(separator: "/")
        let paths = (0..<HubModel.maximumReferences).map { prefix + "/item-\($0).txt" }
        let collection = Workspace(name: "Large serialized collection", mode: .references, referencePaths: paths)
        model.workspaces = [collection]
        let after = try Data(contentsOf: storage)
        precondition(model.errorMessage?.contains("16 MiB") == true,
                     "An oversized serialized configuration must explain why it was not saved")
        precondition(model.configurationWriteCount == writes && after == previous,
                     "Size rejection must happen before replacing the last readable configuration")
        precondition(model.workspaces[0].referencePaths == paths,
                     "Size protection must not silently truncate user references")
        let restored = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        precondition(restored.errorMessage == nil && !restored.workspaces.contains(where: { $0.id == collection.id }),
                     "The preserved configuration must remain readable after rejected writes")
        model.errorMessage = nil
        model.workspaces[0].referencePaths = [paths[0], paths[paths.count - 1]]
        precondition(model.errorMessage == nil && model.configurationWriteCount == writes + 1)
        let recovered = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        precondition(recovered.workspaces.first?.referencePaths == [paths[0], paths[paths.count - 1]],
                     "Reducing an oversized in-memory collection must restore normal saving without lost references")
    }

    @MainActor private static func musicPlayerMigration(_ root: URL) throws {
        precondition(HubSettings().resolvedMusicPlayer == "automatic")
        precondition(HubSettings().resolvedAirDropEnabled)
        let storage = root.appendingPathComponent("player-migration.json")
        let model = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
        var oldSettings = legacy["settings"] as! [String: Any]
        oldSettings.removeValue(forKey: "musicPlayer")
        oldSettings.removeValue(forKey: "airDropEnabled")
        oldSettings["qqMusicEnabled"] = false
        legacy["settings"] = oldSettings
        try model.importConfiguration(data: JSONSerialization.data(withJSONObject: legacy))
        precondition(model.settings.musicPlayer == nil && model.settings.resolvedMusicPlayer == "qqMusic"
                     && !model.settings.resolvedQQMusicEnabled,
                     "Legacy preferences retain QQ Music and the user's disabled state")
        precondition(model.settings.airDropEnabled == nil && model.settings.resolvedAirDropEnabled,
                     "Existing configurations enable AirDrop unless explicitly disabled")
        for player in ["automatic", "qqMusic", "appleMusic", "neteaseMusic", "unknownPlayer"] {
            var configuration = legacy, settings = oldSettings
            settings["musicPlayer"] = player
            settings["airDropEnabled"] = false
            configuration["settings"] = settings
            try model.importConfiguration(data: JSONSerialization.data(withJSONObject: configuration))
            let restored = HubModel(storageURL: storage, directoryLoader: AdmissionDirectoryLoader())
            let expected = player == "unknownPlayer" ? "automatic" : player
            precondition(restored.settings.musicPlayer == expected && restored.settings.resolvedMusicPlayer == expected
                         && restored.settings.qqMusicEnabled == false && restored.settings.airDropEnabled == false
                         && !restored.settings.resolvedAirDropEnabled,
                         "Player imports normalize and persist without changing music or AirDrop enablement")
        }
    }

    private static func optionalMetadataFailure(_ root: URL) throws {
        var attempts = 0
        let values = FileEntry.resourceValues(for: root) { url, keys in
            attempts += 1
            if keys.contains(.localizedTypeDescriptionKey) {
                throw NSError(domain: NSOSStatusErrorDomain, code: -10813)
            }
            return try url.resourceValues(forKeys: keys)
        }
        precondition(attempts == 2 && values?.isDirectory == true && values?.isPackage == false,
                     "Missing optional kind descriptions must preserve directory navigation metadata")
        attempts = 0
        let fallback = FileEntry.resourceValues(for: root) { url, keys in
            attempts += 1
            if keys.contains(.tagNamesKey) { throw CocoaError(.fileReadUnknown) }
            return try url.resourceValues(forKeys: keys)
        }
        precondition(attempts == 3 && fallback?.isDirectory == true,
                     "Unsupported extended metadata must still allow basic file browsing")
        attempts = 0
        let critical = FileEntry.resourceValues(for: root) { url, keys in
            attempts += 1
            guard keys == [.isDirectoryKey] else { throw CocoaError(.fileReadUnknown) }
            return try url.resourceValues(forKeys: keys)
        }
        precondition(attempts == 5 && critical?.isDirectory == true,
                     "An unsupported minimal attribute must not discard a readable directory bit")
    }
}
