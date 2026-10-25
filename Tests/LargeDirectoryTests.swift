import AppKit
import Foundation
import Combine

private final class ScanMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var background = false
    func mark() { lock.lock(); background = !Thread.isMainThread; lock.unlock() }
    var usedBackground: Bool { lock.lock(); defer { lock.unlock() }; return background }
}

@main struct LargeDirectoryTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("LargeDirectoryTests line \(line): \(message)\n".utf8))
            exit(1)
        }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 15
        while !condition() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 5_000_000) }
        require(condition(), "Large-directory fixture did not complete")
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("FileDock-Large-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("large", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<12000 { fm.createFile(atPath: directory.appendingPathComponent("item-\(i).txt").path, contents: Data()) }
        let subdirectory = directory.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Data().write(to: subdirectory.appendingPathComponent("must-not-enumerate.txt"))
        try Data().write(to: directory.appendingPathComponent(".hidden"))
        let package = directory.appendingPathComponent("Example.app", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("must-not-read.txt"))
        let fixture = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let workspace = fixture.addWorkspace(name: "Large", mode: .folder, urls: [directory])!
        let metrics = ScanMetrics()
        let loader = HubDirectoryLoader { request in
            metrics.mark()
            return try HubDirectoryLoader.readSnapshot(request)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let model = HubModel(storageURL: root.appendingPathComponent("config.json"), directoryLoader: loader)
        var heartbeats = 0, firstBatch: TimeInterval?
        while model.directoryLoading {
            heartbeats += 1
            if !model.entries.isEmpty && firstBatch == nil { firstBatch = ProcessInfo.processInfo.systemUptime - start }
            try await Task.sleep(nanoseconds: 5_000_000)
            require(ProcessInfo.processInfo.systemUptime - start < 15)
        }
        let total = ProcessInfo.processInfo.systemUptime - start
        require(metrics.usedBackground && heartbeats > 0 && model.directoryLoadMessage == nil)
        require(model.entries.count == 12002, "Shallow enumeration must include packages but never their contents or hidden files")
        require(model.entries.allSatisfy { $0.url.deletingLastPathComponent() == directory })
        let calculations = model.entryOrderCalculationCount
        let order = model.visibleEntries.map(\.url)
        for _ in 0..<100 { require(model.visibleEntries.count == 12002) }
        require(model.entryOrderCalculationCount == calculations, "Worker-prepared order must be reused by rendering and footer/drag lookups")
        model.search = "item-42"
        require(model.visibleEntries.allSatisfy { $0.name.contains("item-42") })
        require(model.entryOrderCalculationCount == calculations, "Searching must not re-sort the entire directory")
        model.search = ""
        require(model.visibleEntries.map(\.url) == order)
        model.sortByColumn(.size)
        _ = model.visibleEntries
        require(model.entryOrderCalculationCount == calculations + 1)
        model.settings.foldersFirst = true
        require(model.visibleEntries.first!.canNavigate)
        model.settings.foldersFirst = false
        model.showHiddenFiles = true
        try await wait { !model.directoryLoading }
        require(model.entries.count == 12003)
        require(model.selectedWorkspaceID == workspace.id)
        var invalidations = 0
        let observer = model.objectWillChange.sink { invalidations += 1 }
        model.refreshInBackground()
        try await wait { !model.isRefreshingInBackground }
        require(invalidations == 0, "An unchanged metadata refresh must not invalidate the entire browser")
        observer.cancel()
        print(String(format: "12,002 entries: first batch %@, complete %.3fs, UI heartbeats %d", firstBatch.map { String(format: "%.3fs", $0) } ?? "completed before first progress tick", total, heartbeats))
        fflush(stdout)

        // A healthy scan may exceed the inactivity budget many times over.
        let all = Array(model.entries.prefix(20))
        let progressing = HubDirectoryLoader(timeout: 0.08) { request in
            var entries: [FileEntry] = []
            for entry in all {
                Thread.sleep(forTimeInterval: 0.02)
                entries.append(entry)
                try request.recordProgress(.init(entries: entries, canonicalDirectoryPath: directory.path))
            }
            return .init(entries: entries, canonicalDirectoryPath: directory.path)
        }
        var done = false, batches = 0, failure: Error?
        progressing.load(id: UUID(), request: .init(directory: directory), progress: { snapshot in
            batches += 1
            require(!done && !snapshot.entries.isEmpty && snapshot.entries.count <= all.count)
        }) { result in
            done = true
            if case .failure(let error) = result { failure = error }
        }
        try await wait { done }
        require(failure == nil && batches > 1, "Ongoing progress must prevent a false total-duration timeout")

        // Even a worker which fails before the first timer tick must publish
        // its last valid partial snapshot once, before reporting the error.
        let failedRead = HubDirectoryLoader { request in
            try request.recordProgress(.init(entries: Array(all.prefix(2)), canonicalDirectoryPath: directory.path))
            throw CocoaError(.fileReadUnknown)
        }
        var failedDone = false, partialBatches = 0
        failedRead.load(id: UUID(), request: .init(directory: directory), progress: { snapshot in
            require(!failedDone && snapshot.entries.count == 2)
            partialBatches += 1
        }) { result in
            if case .success = result { require(false, "Expected an interrupted provider") }
            failedDone = true
        }
        try await wait { failedDone }
        require(partialBatches == 1)

        // UI publication may take longer than a tiny timeout budget while the
        // worker continues advancing. Recheck its current clock after callbacks.
        let publishing = HubDirectoryLoader(timeout: 0.06) { request in
            for index in 0..<60 {
                Thread.sleep(forTimeInterval: 0.01)
                try request.recordProgress(.init(entries: Array(all.prefix(index % 10 + 1)), canonicalDirectoryPath: directory.path))
            }
            return .init(entries: all, canonicalDirectoryPath: directory.path)
        }
        var publishingDone = false, publicationFailure = false, delayed = false
        publishing.load(id: UUID(), request: .init(directory: directory), progress: { _ in
            if !delayed { delayed = true; Thread.sleep(forTimeInterval: 0.12) }
        }) { result in
            publishingDone = true
            if case .failure = result { publicationFailure = true }
        }
        try await wait { publishingDone }
        require(delayed && !publicationFailure, "A stale pre-publication clock must not time out a progressing worker")

        // Publish partial navigation, retain selection during later batches,
        // retain partial contents on a genuine stalled provider, and retry.
        let stalled = root.appendingPathComponent("stalled", isDirectory: true)
        try fm.createDirectory(at: stalled, withIntermediateDirectories: true)
        let partialLoader = HubDirectoryLoader(timeout: 0.1) { request in
            if request.directory == stalled {
                try request.recordProgress(.init(entries: Array(all.prefix(2)), canonicalDirectoryPath: stalled.path))
                Thread.sleep(forTimeInterval: 0.05)
                try request.recordProgress(.init(entries: Array(all.prefix(3)), canonicalDirectoryPath: stalled.path))
                Thread.sleep(forTimeInterval: 0.25)
                try request.checkCancellation()
            }
            return try HubDirectoryLoader.readSnapshot(request)
        }
        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        try fm.createDirectory(at: healthy, withIntermediateDirectories: true)
        let ready = healthy.appendingPathComponent("ready.txt")
        try Data().write(to: ready)
        let partialStorage = root.appendingPathComponent("partial/config.json")
        let partialFixture = makeTestModel(storageURL: partialStorage)
        _ = partialFixture.addWorkspace(name: "Healthy", mode: .folder, urls: [healthy])
        let partial = HubModel(storageURL: partialStorage, directoryLoader: partialLoader)
        try await wait { !partial.directoryLoading }
        partial.navigate(to: stalled)
        try await wait { partial.currentURL == stalled && partial.entries.count == 2 }
        partial.selectedIDs = [all.last!.url]
        try await wait { partial.entries.count == 3 }
        require(partial.selectedIDs == [all.last!.url], "An early batch cannot prune a selected file that may arrive later")
        try await wait { !partial.directoryLoading }
        require(partial.entries.count == 3 && partial.directoryLoadMessage != nil)
        partial.goBack()
        try await wait { !partial.directoryLoading }
        require(partial.currentURL.map(HubFileOperations.canonical) == HubFileOperations.canonical(healthy) && partial.entries.map { HubFileOperations.canonical($0.url) } == [HubFileOperations.canonical(ready)])
        try await wait { partialLoader.activeReadCount == 0 }
        require(partial.directoryLoadMessage == nil && partial.currentURL.map(HubFileOperations.canonical) == HubFileOperations.canonical(healthy), "Late partial results cannot replace the current path")

        var failed = false
        let missing = root.appendingPathComponent("absent")
        loader.load(id: UUID(), request: .init(directory: missing)) { result in
            if case .failure = result { failed = true }
        }
        try await wait { failed }
        print("PASS: large shallow batched scans, worker sorting and render/search cache, progress-based deadlines, partial navigation/selection retention, stalled-read recovery, late-result isolation and missing-directory errors")
    }
}
