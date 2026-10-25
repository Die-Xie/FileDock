import AppKit
import Foundation

@MainActor private final class RecentSource: HubRecentFilesProviding {
    var receive: ((HubRecentFilesSnapshot) -> Void)?
    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) { self.receive = receive }
    func refresh() {}
    func stop() { receive = nil }
}
private final class Gate: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    func start() { lock.lock(); starts += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return starts }
}
@main struct BackgroundFileWorkTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition())
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-Worker-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let files = try (0..<40).map { index -> URL in
            let url = source.appendingPathComponent("item-\(index).txt")
            try Data("data".utf8).write(to: url); return url
        }
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let sourceTab = model.addWorkspace(name: "Source", mode: .folder, urls: [source])!
        let targetTab = model.addWorkspace(name: "Target", mode: .folder, urls: [target])!
        let before = model.configurationWriteCount
        precondition(model.acceptFileDrop(files, workspaceID: targetTab.id, directory: target, copy: true))
        precondition(model.configurationWriteCount <= before + 1, "Batch bookmark admission must save once rather than once per file")
        model.selectWorkspace(sourceTab.id)
        try await wait { model.fileOperationsInProgress == 0 }
        let transferred = try fm.contentsOfDirectory(atPath: target.path)
        precondition(transferred.count == 40)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        precondition(clipboard.writeObjects([files[0] as NSURL]))
        model.selectWorkspace(targetTab.id)
        model.pasteFiles(from: clipboard)
        precondition(model.fileOperationsInProgress == 1, "Paste must admit background work and return before copying")
        model.selectWorkspace(sourceTab.id)
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(fm.fileExists(atPath: target.appendingPathComponent("item-0 copy.txt").path))
        precondition(!fm.fileExists(atPath: source.appendingPathComponent("item-0 copy.txt").path), "Navigation cannot redirect a pending paste")
        model.createFolder(named: "new")
        precondition(model.fileOperationsInProgress == 1 && !fm.fileExists(atPath: source.appendingPathComponent("new").path))
        model.selectWorkspace(targetTab.id)
        let selection = Set([target.appendingPathComponent("item-1.txt")]); model.selectedIDs = selection
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(fm.fileExists(atPath: source.appendingPathComponent("new").path) && model.selectedIDs == selection,
                     "A completed command must not select its result in a different workspace")
        model.rename(FileEntry(url: files[0]), to: "renamed.txt")
        precondition(model.fileOperationsInProgress == 1 && fm.fileExists(atPath: files[0].path))
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(fm.fileExists(atPath: source.appendingPathComponent("renamed.txt").path) && model.selectedIDs == selection)
        let displayed = target.appendingPathComponent("item-2.txt")
        model.selectedIDs = [displayed]
        model.rename(FileEntry(url: displayed), to: "renamed-target.txt")
        model.selectedIDs = selection
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(model.selectedIDs == selection, "Changing selection during a rename must not be undone by its completion")
        model.trash([root.appendingPathComponent("does-not-exist")])
        precondition(model.fileOperationsInProgress == 1)
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(model.errorMessage != nil, "Failed trash work must release its busy ticket and report an error")
        model.errorMessage = nil
        model.openStagingWorkspace()
        precondition(model.stageFiles([files[1], files[2]]))
        let staged = model.stagedURLs
        for _ in 0..<1000 { precondition(model.stagedURLs == staged) }
        model.removeStagedFiles([files[1]])
        precondition(model.stagedURLs == [files[2]], "Removing references invalidates the derived shelf cache")
        model.clearStagedFiles()
        precondition(model.stagedURLs.isEmpty)

        let storage = root.appendingPathComponent("recents/config.json")
        let fixture = makeTestModel(storageURL: storage); _ = fixture.addRecentWorkspace()!
        let recent = RecentSource(), gate = Gate()
        let loader = HubDirectoryLoader(timeout: 2) { request in
            if !request.references.isEmpty {
                gate.start(); precondition(gate.gate.wait(timeout: .now() + 5) == .success)
            }
            return try HubDirectoryLoader.readSnapshot(request)
        }
        let recents = HubModel(storageURL: storage, recentFiles: recent, directoryLoader: loader)
        let snapshot = HubRecentFilesSnapshot(files: [.init(url: files[1], lastUsed: Date())], gathering: false, message: nil)
        recent.receive?(snapshot)
        try await wait { gate.count == 1 }
        for _ in 0..<30 { recent.receive?(snapshot) }
        precondition(loader.activeReadCount == 1 && gate.count == 1, "Unchanged Spotlight updates must not cancel and flood the metadata loader")
        gate.gate.signal()
        try await wait { !recents.directoryLoading }
        precondition(recents.entries.map(\.url) == [files[1]])
        print("PASS: bounded batch persistence, asynchronous paste/create/rename with captured destinations and selection, staging cache invalidation and unchanged Recents scan coalescing")
    }
}
