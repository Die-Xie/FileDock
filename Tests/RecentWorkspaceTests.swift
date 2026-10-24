import AppKit
import Foundation

@MainActor private final class RecentFilesFixtureProvider: HubRecentFilesProviding {
    private(set) var callbacks: [(HubRecentFilesSnapshot) -> Void] = []
    private(set) var refreshCount = 0
    private(set) var stopCount = 0

    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) { callbacks.append(receive) }
    func refresh() { refreshCount += 1 }
    func stop() { stopCount += 1 }

    var latestCallback: Int {
        precondition(!callbacks.isEmpty, "A selected recent workspace must start its provider")
        return callbacks.count - 1
    }

    func emit(_ files: [HubRecentFile], gathering: Bool = false, message: String? = nil, callback: Int? = nil) {
        callbacks[callback ?? latestCallback](HubRecentFilesSnapshot(files: files, gathering: gathering, message: message))
    }
}

@main struct RecentWorkspaceTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("FileDock-RecentTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let directory = base.appendingPathComponent("files", isDirectory: true)
        let child = directory.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let alpha = directory.appendingPathComponent("alpha.txt")
        let zulu = directory.appendingPathComponent("zulu.txt")
        let nested = child.appendingPathComponent("nested.txt")
        try Data("alpha contents".utf8).write(to: alpha)
        try Data("zulu contents, deliberately longer".utf8).write(to: zulu)
        try Data("nested contents".utf8).write(to: nested)

        try persistenceAndSanitization(in: base, directory: directory, alpha: alpha)
        try orderingAndProtection(in: base, directory: directory, child: child, alpha: alpha, zulu: zulu)
        try navigationAndStaleCallbacks(in: base, directory: directory, child: child, alpha: alpha, zulu: zulu)
        print("PASS: recent workspace persistence, ordering, navigation and write protection")
    }

    @MainActor private static func persistenceAndSanitization(in base: URL, directory: URL, alpha: URL) throws {
        let storage = base.appendingPathComponent("persistence/config.json")
        let provider = RecentFilesFixtureProvider()
        let model = makeTestModel(storageURL: storage, monitor: false, recentFiles: provider)
        let bookmarksBefore = try configuration(at: storage)["bookmarks"] as? [String: Any] ?? [:]
        let recent = model.addWorkspace(name: "Recents", symbol: "clock", mode: .recents, urls: [directory, alpha])
        precondition(model.isRecentsRoot && model.isVirtualWorkspace && model.currentURL == nil)
        precondition(recent.rootPath == nil && recent.referencePaths.isEmpty,
                     "A recent workspace must never turn supplied URLs into a real root or references")
        let bookmarksAfter = try configuration(at: storage)["bookmarks"] as? [String: Any] ?? [:]
        precondition(Set(bookmarksBefore.keys) == Set(bookmarksAfter.keys), "Adding Recents must not bookmark ignored input URLs")
        let count = model.workspaces.count
        let reused = model.addRecentWorkspace()
        precondition(reused.id == recent.id && model.workspaces.count == count,
                     "The add-recent command must select the existing workspace instead of creating duplicates")

        var dirty = recent
        dirty.rootPath = directory.path
        dirty.referencePaths = [alpha.path]
        dirty.directoryOrders = [directory.path: [alpha.lastPathComponent]]
        model.updateWorkspace(dirty)
        precondition(model.selectedWorkspace?.mode == .recents && model.selectedWorkspace?.rootPath == nil)
        precondition(model.selectedWorkspace?.referencePaths.isEmpty == true && (model.selectedWorkspace?.directoryOrders?.isEmpty ?? true),
                     "Editing a recent workspace must discard incompatible filesystem and curated-order metadata")
        model.chooseRoot()
        precondition(model.selectedWorkspace?.mode == .recents && model.currentURL == nil,
                     "Choosing a real root is unavailable for the system recent collection")
        model.save()

        var payload = try configuration(at: storage)
        var workspaces = payload["workspaces"] as! [[String: Any]]
        let index = workspaces.firstIndex { ($0["id"] as? String)?.lowercased() == recent.id.uuidString.lowercased() }!
        workspaces[index]["rootPath"] = directory.path
        workspaces[index]["referencePaths"] = [alpha.path]
        workspaces[index]["directoryOrders"] = [directory.path: [alpha.lastPathComponent]]
        payload["workspaces"] = workspaces
        try JSONSerialization.data(withJSONObject: payload).write(to: storage, options: .atomic)
        let restored = makeTestModel(storageURL: storage, monitor: false, recentFiles: RecentFilesFixtureProvider())
        precondition(restored.errorMessage == nil && restored.selectedWorkspaceID == recent.id && restored.isRecentsRoot,
                     "A saved recent workspace must survive restart without a fabricated filesystem root")
        precondition(restored.selectedWorkspace?.rootPath == nil && restored.selectedWorkspace?.referencePaths.isEmpty == true)
        precondition(restored.selectedWorkspace?.directoryOrders?.isEmpty ?? true,
                     "Configuration loading must normalize incompatible recent-workspace fields")
        let savedAgain = try configuration(at: storage)
        let restoredEntry = (savedAgain["workspaces"] as! [[String: Any]]).first { ($0["id"] as? String)?.lowercased() == recent.id.uuidString.lowercased() }!
        precondition(restoredEntry["mode"] as? String == "recents" && restoredEntry["rootPath"] == nil,
                     "The normalized recent mode must round-trip as a virtual workspace")
    }

    @MainActor private static func orderingAndProtection(in base: URL, directory: URL, child: URL, alpha: URL, zulu: URL) throws {
        let provider = RecentFilesFixtureProvider()
        let model = makeTestModel(storageURL: base.appendingPathComponent("ordering/config.json"), monitor: false, recentFiles: provider)
        let ordinary = model.addWorkspace(name: "Fixture folder", mode: .folder, urls: [directory])
        model.sortKey = .size
        model.ascending = false
        model.reorderEntries([zulu], before: child)
        let ordinaryOrder = model.visibleEntries.map(\.url)
        let ordinaryMetadata = model.selectedWorkspace?.directoryOrders
        let previousReferenceManualOrder = model.referenceManualOrder
        let recent = model.addRecentWorkspace()
        precondition(model.sortKey == .size && !model.ascending,
                     "Selecting Recents must not overwrite the global sorting preferences")
        let alphaRecord = HubRecentFile(url: alpha, lastUsed: Date(timeIntervalSince1970: 500))
        let zuluRecord = HubRecentFile(url: zulu, lastUsed: Date(timeIntervalSince1970: 400))
        provider.emit([zuluRecord, alphaRecord, HubRecentFile(url: alpha, lastUsed: Date(timeIntervalSince1970: 100)),
                       HubRecentFile(url: directory.appendingPathComponent("missing.txt"), lastUsed: Date(timeIntervalSince1970: 900)),
                       HubRecentFile(url: URL(string: "https://example.invalid/document.txt")!, lastUsed: Date(timeIntervalSince1970: 1000))])
        precondition(model.visibleEntries.map(\.url) == [alpha, zulu],
                     "Recent results must deduplicate local existing files and sort by latest use rather than name, size or modification time")
        precondition(!model.canReorderEntries && !model.isManualEntryOrder)
        let alphaBefore = try Data(contentsOf: alpha)
        let zuluBefore = try Data(contentsOf: zulu)
        let contentBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        model.reorderEntries([zulu], before: alpha)
        model.setManualEntryOrder(true)
        model.appendReferences([child])
        model.removeReferences([alpha])
        let accepted = try? model.handleDrop(urls: [child, alpha], copy: false)
        precondition(accepted != true, "A recent virtual root must not accept filesystem transfers")
        precondition(model.visibleEntries.map(\.url) == [alpha, zulu] && model.referenceManualOrder == previousReferenceManualOrder)
        precondition(model.selectedWorkspace?.id == recent.id && model.selectedWorkspace?.rootPath == nil && model.selectedWorkspace?.referencePaths.isEmpty == true)
        precondition(model.selectedWorkspace?.directoryOrders?.isEmpty ?? true,
                     "Dragging or toggling manual order must not create curated ordering at the recent root")
        let alphaAfter = try Data(contentsOf: alpha)
        let zuluAfter = try Data(contentsOf: zulu)
        let contentAfter = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        precondition(alphaAfter == alphaBefore && zuluAfter == zuluBefore)
        precondition(contentAfter == contentBefore,
                     "Rejected recent-root drops must leave the original files untouched")

        provider.emit([alphaRecord, HubRecentFile(url: zulu, lastUsed: Date(timeIntervalSince1970: 700))])
        precondition(model.visibleEntries.map(\.url) == [zulu, alpha],
                     "A new last-used date must reorder results even when path, size and modification time are unchanged")
        model.search = "alpha"
        precondition(model.visibleEntries.map(\.url) == [alpha], "The recent collection must support the existing name search")
        model.search = ""
        let cloudURL = directory.appendingPathComponent("cloud-only.txt")
        let missingURL = directory.appendingPathComponent("missing-ordinary.txt")
        provider.emit([HubRecentFile(url: alpha, lastUsed: Date(timeIntervalSince1970: 700), metadataOnly: true),
                       HubRecentFile(url: cloudURL, lastUsed: Date(timeIntervalSince1970: 800), metadataOnly: true),
                       HubRecentFile(url: missingURL, lastUsed: Date(timeIntervalSince1970: 900))])
        precondition(model.entries.count == 2 && !model.entries.contains { $0.url == missingURL },
                     "Only an explicit cloud metadata record may keep a missing file in Recents")
        let localPlaceholder = model.entries.first { $0.url == alpha }!
        let missingPlaceholder = model.entries.first { $0.url == cloudURL }!
        precondition(localPlaceholder.exists && model.isCloudPlaceholder(localPlaceholder) && model.canOpen(localPlaceholder),
                     "An evicted cloud document may still stat successfully; its metadata must control preview availability")
        precondition(!missingPlaceholder.exists && model.isCloudPlaceholder(missingPlaceholder) && model.canOpen(missingPlaceholder),
                     "An explicit cloud-only record remains available for a user-initiated system open")
        provider.emit([alphaRecord, HubRecentFile(url: alpha, lastUsed: alphaRecord.lastUsed, metadataOnly: true),
                       HubRecentFile(url: zulu, lastUsed: zuluRecord.lastUsed, metadataOnly: true), zuluRecord])
        precondition(model.entries.count == 2 && model.entries.allSatisfy { !model.isCloudPlaceholder($0) },
                     "Equal-date duplicate records must prefer locally available data regardless of arrival order")
        provider.emit([], gathering: true)
        precondition(model.recentFilesLoading, "A gathering provider must expose its loading state")
        provider.emit([], message: "Fixture indexing message")
        precondition(!model.recentFilesLoading && model.recentFilesMessage == "Fixture indexing message")
        model.selectWorkspace(ordinary.id)
        precondition(model.sortKey == .size && !model.ascending && model.isManualEntryOrder)
        precondition(model.visibleEntries.map(\.url) == ordinaryOrder && model.selectedWorkspace?.directoryOrders == ordinaryMetadata,
                     "Returning from Recents must preserve the ordinary directory's manual presentation order")
    }

    @MainActor private static func navigationAndStaleCallbacks(in base: URL, directory: URL, child: URL, alpha: URL, zulu: URL) throws {
        let provider = RecentFilesFixtureProvider()
        let model = makeTestModel(storageURL: base.appendingPathComponent("navigation/config.json"), monitor: false, recentFiles: provider)
        let ordinary = model.addWorkspace(name: "Fixture folder", mode: .folder, urls: [directory])
        let recent = model.addRecentWorkspace()
        let initialCallback = provider.latestCallback
        let initialRecords = [HubRecentFile(url: child, lastUsed: Date(timeIntervalSince1970: 400)),
                              HubRecentFile(url: alpha, lastUsed: Date(timeIntervalSince1970: 300))]
        provider.emit(initialRecords)
        precondition(model.isVirtualWorkspace && model.isRecentsRoot && !model.isReferenceRoot)
        precondition(model.pathComponents.count == 1 && model.pathComponents.first?.url == nil)
        let virtualRoot = model.pathComponents.first!
        model.navigate(to: child)
        precondition(model.currentURL == child && model.canGoBack && !model.isRecentsRoot && model.isVirtualWorkspace)
        let childEntries = model.entries.map(\.url)
        provider.emit([HubRecentFile(url: zulu, lastUsed: Date())], callback: initialCallback)
        precondition(model.currentURL == child && model.entries.map(\.url) == childEntries,
                     "A delayed recent query must not replace a real directory after navigation")
        model.goBack()
        precondition(model.isRecentsRoot && model.canGoForward)
        provider.emit(initialRecords)
        let rootEntries = model.entries.map(\.url)
        provider.emit([HubRecentFile(url: zulu, lastUsed: Date())], callback: initialCallback)
        precondition(model.entries.map(\.url) == rootEntries,
                     "A previous recent-query session must remain stale after returning to the same virtual workspace")
        model.goForward()
        precondition(model.currentURL == child)
        model.navigate(to: directory)
        model.goBack()
        precondition(model.currentURL == child)
        model.goBack()
        precondition(model.isRecentsRoot && model.canGoForward)
        provider.emit(initialRecords)
        model.goForward()
        let filesystemComponents = model.pathComponents
        precondition(filesystemComponents.first == virtualRoot && filesystemComponents.last?.url == child,
                     "The virtual recent root must remain visible before real filesystem breadcrumbs")
        model.search = "nested"
        model.selectedIDs = Set(model.entries.map(\.url))
        model.navigatePathComponent(virtualRoot)
        precondition(model.isRecentsRoot && model.search.isEmpty && model.selectedIDs.isEmpty && model.canGoForward)
        provider.emit(initialRecords)
        model.navigatePathComponent(filesystemComponents.last!)
        precondition(model.isRecentsRoot, "Filesystem breadcrumb actions from an earlier location must expire at the virtual root")

        let beforeSwitchCallback = provider.latestCallback
        model.selectWorkspace(ordinary.id)
        let ordinaryEntries = model.entries.map(\.url)
        provider.emit([HubRecentFile(url: zulu, lastUsed: Date())], callback: beforeSwitchCallback)
        precondition(model.selectedWorkspaceID == ordinary.id && model.currentURL == directory && model.entries.map(\.url) == ordinaryEntries,
                     "A delayed query must never overwrite another workspace")
        model.selectWorkspace(recent.id)
        provider.emit(initialRecords)
        let currentRootEntries = model.entries.map(\.url)
        provider.emit([HubRecentFile(url: zulu, lastUsed: Date())], callback: beforeSwitchCallback)
        precondition(model.isRecentsRoot && model.entries.map(\.url) == currentRootEntries,
                     "Switching away and back must not revive an old recent-query callback")
        precondition(provider.stopCount > 0, "Recent query sessions must stop when leaving their root")
    }

    private static func configuration(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
