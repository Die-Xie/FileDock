import AppKit
import Foundation

@MainActor private final class EmptyFolderDropLoader: HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        completion(.success(.init(entries: [], canonicalDirectoryPath: request.directory?.path)))
    }
    func cancel(id: UUID) {}
}
@MainActor private final class DeferredFolderDrop: HubFolderWorkspacePreparing {
    var completion: ((Result<HubPreparedFolderWorkspaces, Error>) -> Void)?
    var calls = 0
    var admitted = true
    func prepare(_ urls: [URL], completion: @escaping (Result<HubPreparedFolderWorkspaces, Error>) -> Void) -> Bool {
        calls += 1
        if admitted { self.completion = completion }
        return admitted
    }
}
private final class FolderReadGate: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    func enter() -> Int { lock.lock(); defer { lock.unlock() }; starts += 1; return starts }
}

@main struct FolderWorkspaceDropTests {
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Folder drop did not finish")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FolderDrop-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("Source A", isDirectory: true)
        let b = root.appendingPathComponent("Source B", isDirectory: true)
        let c = root.appendingPathComponent("Source C", isDirectory: true)
        for folder in [a, b, c] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let child = a.appendingPathComponent("keep.svg")
        try Data("<svg></svg>".utf8).write(to: child)
        let storage = root.appendingPathComponent("config.json")
        let model = HubModel(storageURL: storage, directoryLoader: EmptyFolderDropLoader())
        let left = model.addWorkspace(name: "Left", mode: .folder, urls: [root])!
        let right = model.addWorkspace(name: "Right", mode: .folder, urls: [root])!
        let original = model.workspaces, settings = model.settings, writes = model.configurationWriteCount
        precondition(model.canOfferFolderWorkspaceDrop([a, b]))
        precondition(model.addFolderWorkspaces([a, b, a], before: right.id))
        precondition(!model.canOfferFolderWorkspaceDrop([c]), "Only one folder batch can be pending per model")
        try await wait { model.fileOperationsInProgress == 0 }
        let inserted = model.tabWorkspaces
        let rightIndex = inserted.firstIndex { $0.id == right.id }!
        precondition(Array(inserted[(rightIndex - 2)..<rightIndex]).map(\.rootPath) == [a.path, b.path])
        let created = inserted.filter { !original.map(\.id).contains($0.id) }
        precondition(created.count == 2 && model.selectedWorkspaceID == created.first?.id)
        precondition(created.allSatisfy { $0.mode == .folder && $0.symbol == "folder" })
        precondition(model.settings == settings && model.configurationWriteCount == writes + 1,
                     "A batch must persist once without modifying unrelated preferences")
        let restored = HubModel(storageURL: storage, directoryLoader: EmptyFolderDropLoader())
        precondition(restored.workspaces.count == model.workspaces.count && restored.selectedWorkspaceID == model.selectedWorkspaceID)
        for (expected, actual) in zip(model.workspaces, restored.workspaces) {
            var normalized = expected
            if let before = expected.rootPath, let after = actual.rootPath, before != after {
                // Bookmarks may canonicalize /var to /private/var on reload.
                let first = try fm.attributesOfItem(atPath: before), second = try fm.attributesOfItem(atPath: after)
                precondition(first[.systemNumber] as? NSNumber == second[.systemNumber] as? NSNumber)
                precondition(first[.systemFileNumber] as? NSNumber == second[.systemFileNumber] as? NSNumber)
                normalized.rootPath = actual.rootPath
            }
            precondition(normalized == actual, "Restart must preserve every tab property and the same filesystem directory")
        }
        let originalBytes = try Data(contentsOf: child)
        precondition(originalBytes == Data("<svg></svg>".utf8) && fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
        let beforeInvalid = model.workspaces, configBeforeInvalid = try Data(contentsOf: storage)
        precondition(model.addFolderWorkspaces([c, child], before: nil))
        try await wait { model.fileOperationsInProgress == 0 }
        let configAfterInvalid = try Data(contentsOf: storage)
        precondition(model.workspaces == beforeInvalid && configAfterInvalid == configBeforeInvalid,
                     "Mixed folders/files must reject the whole batch and keep configuration unchanged")
        precondition(model.errorMessage != nil && fm.fileExists(atPath: child.path))
        let package = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        for urls in [[package], [root.appendingPathComponent("missing-folder")]] {
            precondition(model.addFolderWorkspaces(urls, before: nil))
            try await wait { model.fileOperationsInProgress == 0 }
            let after = try Data(contentsOf: storage)
            precondition(model.workspaces == beforeInvalid && after == configBeforeInvalid)
        }
        precondition(!model.addFolderWorkspaces([URL(string: "file://remote-host/share")!], before: nil))
        precondition(!model.addFolderWorkspaces([URL(string: "https://example.invalid/")!], before: nil))
        precondition(!model.addFolderWorkspaces([c], before: UUID()))
        let childEntry = FileEntry(url: child)
        model.entries = [childEntry]
        precondition(model.isKnownNonFolderDrop([child]) && !model.canOfferFolderWorkspaceDrop([child]))
        let fileKinds = model.folderURLsForDrag([child], including: childEntry)
        precondition(fileKinds == [])
        let folderEntry = FileEntry(url: c)
        precondition(model.folderURLsForDrag([c, child], including: folderEntry) == [c])
        precondition(model.folderURLsForDrag([root.appendingPathComponent("unknown")], including: folderEntry) == nil)
        model.entries = []
        precondition(!model.canOfferFolderWorkspaceDrop([child], knownFolderURLs: fileKinds),
            "Source file hints remain valid after spring navigation replaces the directory snapshot")
        precondition(model.canOfferFolderWorkspaceDrop([root.appendingPathComponent("not-read-during-hover")]),
                     "Hover checks must not access metadata or reject unknown external URL kinds")
        try await delayedDrops(root: root, folder: c, left: left, right: right)
        try await stalledReads(folder: c)
        print("PASS: real folder-tab batches, exact insertion/order/selection, deduplication, one-write persistence/restart, original SVG/folders untouched, atomic mixed rejection, URL admission, cached hover hints, stale/duplicate callbacks and timeout worker bounds")
    }

    @MainActor private static func delayedDrops(root: URL, folder: URL, left: Workspace, right: Workspace) async throws {
        let deferred = DeferredFolderDrop()
        let model = HubModel(storageURL: root.appendingPathComponent("deferred.json"), directoryLoader: EmptyFolderDropLoader(), folderWorkspacePreparer: deferred)
        model.workspaces = [left, right]
        model.selectWorkspace(left.id)
        let prepared = try await Task.detached { try HubFolderWorkspacePreparer.readFolders([folder], cancellation: HubFolderWorkspaceCancellation()) }.value
        precondition(model.addFolderWorkspaces([folder], before: right.id))
        model.removeWorkspace(right.id)
        let retained = model.workspaces, writes = model.configurationWriteCount
        deferred.completion?(.success(prepared))
        precondition(model.workspaces == retained && model.fileOperationsInProgress == 0 && model.configurationWriteCount == writes)
        deferred.completion?(.success(prepared))
        precondition(model.workspaces == retained && model.fileOperationsInProgress == 0, "Late duplicate preparation cannot create another tab")
        model.workspaces = [left, right]
        model.selectWorkspace(left.id)
        precondition(model.addFolderWorkspaces([folder], before: right.id))
        model.selectWorkspace(right.id); model.search = "keep current navigation"
        let second = try await Task.detached { try HubFolderWorkspacePreparer.readFolders([folder], cancellation: HubFolderWorkspaceCancellation()) }.value
        deferred.completion?(.success(second))
        precondition(model.selectedWorkspaceID == right.id && model.search == "keep current navigation")
        precondition(model.workspaces.map(\.rootPath).contains(folder.path))
        deferred.admitted = false
        precondition(!model.addFolderWorkspaces([folder], before: nil) && model.fileOperationsInProgress == 0)
        deferred.admitted = true
        precondition(model.addFolderWorkspaces([folder], before: right.id))
        let beforeOversize = model.workspaces, writesBeforeOversize = model.configurationWriteCount
        let oversized = HubPreparedFolderWorkspaces(folders: [HubPreparedFolderWorkspace(url: folder,
            name: "Oversize", bookmark: Data(repeating: 0, count: 16 * 1024 * 1024))], scopes: HubFolderWorkspaceScopes([]))
        deferred.completion?(.success(oversized))
        precondition(model.workspaces == beforeOversize && model.configurationWriteCount == writesBeforeOversize && model.fileOperationsInProgress == 0)
        precondition(model.errorMessage == HubFileError.configurationTooLarge.localizedDescription,
                     "Oversize bookmark/configuration data must not create an unpersistable tab")
        precondition(model.addFolderWorkspaces([folder], before: nil))
        model.workspaces = (0..<HubModel.maximumWorkspaces).map { Workspace(name: "Tab \($0)", mode: .folder, rootPath: root.path) }
        let filled = model.workspaces
        let third = try await Task.detached { try HubFolderWorkspacePreparer.readFolders([folder], cancellation: HubFolderWorkspaceCancellation()) }.value
        deferred.completion?(.success(third))
        precondition(model.workspaces == filled && model.fileOperationsInProgress == 0)
    }

    @MainActor private static func stalledReads(folder: URL) async throws {
        let gate = FolderReadGate()
        let worker = HubFolderWorkspacePreparer(timeout: 0.15, read: { urls, cancellation in
            precondition(!Thread.isMainThread)
            let count = gate.enter()
            if count <= 2 { precondition(gate.gate.wait(timeout: .now() + 5) == .success) }
            try cancellation.check()
            return try HubFolderWorkspacePreparer.readFolders(urls, cancellation: cancellation)
        })
        var outcomes = 0
        for _ in 0..<2 {
            precondition(worker.prepare([folder]) { result in
                outcomes += 1
                if case .success = result { preconditionFailure("Blocked reads must timeout") }
            })
        }
        try await wait { outcomes == 2 }
        precondition(worker.activeCount == 2, "Timed-out real workers keep their slots")
        precondition(!worker.prepare([folder]) { _ in preconditionFailure("A busy worker must not start another task") })
        gate.gate.signal(); gate.gate.signal()
        try await wait { worker.activeCount == 0 }
        precondition(outcomes == 2)
        var success = false
        precondition(worker.prepare([folder]) { result in if case .success = result { success = true } })
        try await wait { success && worker.activeCount == 0 }
    }
}
