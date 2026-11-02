import AppKit
import Combine
import Foundation

@MainActor private final class ContentDirectoryLoader: HubDirectoryLoading {
    struct Job {
        let request: HubDirectoryRequest
        let progress: (HubDirectorySnapshot) -> Void
        let completion: (Result<HubDirectorySnapshot, Error>) -> Void
    }
    private(set) var latest: UUID?
    private(set) var loadCount = 0
    private var jobs: [UUID: Job] = [:]
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        load(id: id, request: request, progress: { _ in }, completion: completion)
    }
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        loadCount += 1
        latest = id; jobs[id] = Job(request: request, progress: progress, completion: completion)
    }
    // Keep callbacks intentionally: tests deliver cancelled results to prove
    // neither content nor animation state can be changed by an obsolete read.
    func cancel(id: UUID) { }
    func emit(_ entries: [FileEntry], complete: Bool, id: UUID? = nil) throws {
        let job = jobs[id ?? latest!]!
        let order = try job.request.order?.sorted(entries, canonicalPath: job.request.directory?.path)
        let snapshot = HubDirectorySnapshot(entries: entries, canonicalDirectoryPath: job.request.directory?.path,
            order: job.request.order, orderedEntries: order)
        if complete { job.completion(.success(snapshot)) } else { job.progress(snapshot) }
    }
}

@MainActor private final class ContentRecentProvider: HubRecentFilesProviding {
    private var receive: ((HubRecentFilesSnapshot) -> Void)?
    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) { self.receive = receive }
    func refresh() { }
    func stop() { receive = nil }
    func emit(gathering: Bool) { receive?(.init(files: [], gathering: gathering, message: nil)) }
}

@main struct WorkspaceContentTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-WorkspaceContent-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a", isDirectory: true), b = root.appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let firstURL = a.appendingPathComponent("z.md"), secondURL = a.appendingPathComponent("a.pdf")
        try Data("first".utf8).write(to: firstURL); try Data("second".utf8).write(to: secondURL)
        for (original, label) in [(firstURL, HubFinderLabel.red), (secondURL, .blue)] {
            var url = original, values = URLResourceValues(); values.labelNumber = label.rawValue
            try url.setResourceValues(values)
        }
        let first = FileEntry(url: firstURL), second = FileEntry(url: secondURL)
        try cacheBudgets(first, second)
        try contentVisits(root: root, a: a, b: b, first: first, second: second)
        try filterPresentation(root: root, a: a, b: b, first: first, second: second)
        try await persistence(root: root, a: a, b: b)
        print("PASS: bounded large workspace snapshots, prepared-order reuse, first-content visit revisions, stale/partial/background isolation and debounced selection persistence/flush/lifetime")
    }

    @MainActor static func filterPresentation(root: URL, a: URL, b: URL, first: FileEntry, second: FileEntry) throws {
        let loader = ContentDirectoryLoader()
        let model = HubModel(storageURL: root.appendingPathComponent("filters.json"), monitor: false, directoryLoader: loader)
        let wa = Workspace(name: "A", rootPath: a.path), wb = Workspace(name: "B", rootPath: b.path)
        model.workspaces = [wa, wb]
        model.selectWorkspace(wa.id)
        model.setFileTypeFilter("pdf"); model.setColorLabelFilter(.red)
        model.setFileTypeFilter(nil); model.setColorLabelFilter(nil)
        precondition(model.filterRevision == 0, "A new, still-empty browse cannot animate filter resets against old content")
        try loader.emit([first, second], complete: true)
        let content = model.contentRevision, loads = loader.loadCount, calculations = model.entryOrderCalculationCount
        var visible: [[URL]] = [], clearedSelection: [Bool] = []
        let observer = model.$filterRevision.dropFirst().sink { _ in
            visible.append(model.visibleEntries.map(\.url))
            clearedSelection.append(model.selectedIDs.isEmpty)
        }
        defer { observer.cancel() }
        model.selectedIDs = [first.url, second.url]
        model.setFileTypeFilter("md")
        precondition(model.filterRevision == 1 && visible.last == [first.url])
        model.setFileTypeFilter("MD")
        precondition(model.filterRevision == 1, "An equivalent normalized type cannot replay the animation")
        model.setColorLabelFilter(.red)
        model.setColorLabelFilter(.red)
        precondition(model.filterRevision == 2 && visible.last == [first.url])
        model.setFileTypeFilter("pdf")
        precondition(model.filterRevision == 3 && visible.last?.isEmpty == true, "Empty filtered results also commit their presentation change")
        model.setColorLabelFilter(.blue)
        precondition(model.filterRevision == 4 && visible.last == [second.url])
        model.setFileTypeFilter(nil); model.setColorLabelFilter(nil)
        precondition(model.filterRevision == 6 && Set(visible.last!) == Set([first.url, second.url]))
        precondition(clearedSelection.allSatisfy { $0 }, "Filter subscribers observe the new visible set after selection has been cleared")
        precondition(model.contentRevision == content && loader.loadCount == loads && model.entryOrderCalculationCount == calculations,
                     "Filter feedback preserves first-content revision semantics and performs no directory IO or re-sorting")
        model.search = "a"; model.search = ""; model.sortKey = .size
        precondition(model.filterRevision == 6, "Search keystrokes and sorting do not replay filter feedback")
        model.setColorLabelFilter(.red)
        let beforeNavigation = model.filterRevision
        model.selectWorkspace(wb.id)
        precondition(model.filterRevision == beforeNavigation && model.colorLabelFilter == nil,
                     "Switching tabs resets filters without revealing stale content")
        try loader.emit([first], complete: true)
        model.setFileTypeFilter("md")
        let beforeDirectory = model.filterRevision
        model.navigate(to: a)
        try loader.emit([first, second], complete: true)
        precondition(model.filterRevision == beforeDirectory && model.fileTypeFilter == nil,
                     "Directory navigation must arm first-content before its filter resets")
        precondition(model.contentRevision == content + 2, "Filter animation cannot consume the next tab/directory's first-content commit")
    }

    @MainActor static func cacheBudgets(_ first: FileEntry, _ second: FileEntry) throws {
        let single = HubDirectorySnapshot(entries: [first], canonicalDirectoryPath: nil, orderedEntries: [first])
        let pair = HubDirectorySnapshot(entries: [first, second], canonicalDirectoryPath: nil, orderedEntries: [second, first])
        let normal = HubDirectorySnapshotCache<String>()
        normal.insert(.init(entries: Array(repeating: first, count: 1200), canonicalDirectoryPath: nil), for: "large", now: 1)
        precondition(normal.snapshot(for: "large", now: 2)?.entries.count == 1200, "Ordinary large folders must have a warm snapshot")
        let entries = HubDirectorySnapshotCache<String>(capacity: 4, maximumEntries: 3, maximumTotalEntries: 3)
        entries.insert(pair, for: "a", now: 1); entries.insert(pair, for: "b", now: 1)
        precondition(entries.snapshot(for: "a", now: 2) == nil && entries.retainedEntryCount == 2)
        entries.insert(single, for: "c", now: 2)
        precondition(entries.retainedEntryCount == 3 && entries.snapshotCount == 2)
        _ = entries.snapshot(for: "b", now: 2)
        entries.insert(single, for: "d", now: 2)
        precondition(entries.snapshot(for: "c", now: 2) == nil && entries.snapshot(for: "b", now: 2) != nil,
                     "Budget eviction follows actual recent use, not insertion order")
        precondition(entries.retainedEntryCount == 3)
        entries.insert(single, for: "b", now: 3)
        precondition(entries.retainedEntryCount == 2 && entries.snapshotCount == 2, "Replacing a cache entry releases its prior cost")
        precondition(entries.snapshot(for: "b", now: 20) == nil)
        entries.removeAll()
        precondition(entries.retainedEntryCount == 0 && entries.estimatedByteCount == 0 && entries.snapshotCount == 0)

        let measured = HubDirectorySnapshotCache<String>()
        measured.insert(single, for: "a", now: 1)
        let bytes = measured.estimatedByteCount
        precondition(bytes > 0)
        let byteBound = HubDirectorySnapshotCache<String>(maximumEstimatedBytes: bytes * 2 - 1)
        byteBound.insert(single, for: "a", now: 1); byteBound.insert(single, for: "b", now: 1)
        precondition(byteBound.snapshotCount == 1 && byteBound.snapshot(for: "a", now: 2) == nil)
        precondition(byteBound.estimatedByteCount == bytes, "Byte-budget eviction releases all previous accounting")
        let oversized = HubDirectorySnapshotCache<String>(maximumEstimatedBytes: bytes)
        oversized.insert(single, for: "a", now: 1); oversized.insert(pair, for: "a", now: 2)
        precondition(oversized.snapshotCount == 0 && oversized.retainedEntryCount == 0 && oversized.estimatedByteCount == 0,
                     "An oversized replacement cannot leave the older version or stale accounting behind")
        let keyBound = HubDirectorySnapshotCache<String>(maximumEstimatedBytes: bytes, keyByteCost: { _ in bytes })
        keyBound.insert(single, for: "key", now: 1)
        precondition(keyBound.snapshotCount == 0, "Reference membership retained by a key consumes the same byte budget")
        let zero = HubDirectorySnapshotCache<String>(maximumTotalEntries: 0, maximumEstimatedBytes: 0)
        zero.insert(single, for: "a", now: 1)
        precondition(zero.snapshotCount == 0)
        measured.insert(single, for: "a", now: 3)
        precondition(measured.snapshot(for: "a", now: 2) == nil && measured.estimatedByteCount == 0, "A backwards clock cannot retain an indefinitely stale snapshot")
        measured.insert(single, for: "a", now: .infinity)
        precondition(measured.snapshotCount == 0)
    }

    @MainActor static func contentVisits(root: URL, a: URL, b: URL, first: FileEntry, second: FileEntry) throws {
        let loader = ContentDirectoryLoader(), recent = ContentRecentProvider()
        let model = HubModel(storageURL: root.appendingPathComponent("content.json"), monitor: false,
            recentFiles: recent, directoryLoader: loader)
        let wa = Workspace(name: "A", rootPath: a.path), wb = Workspace(name: "B", rootPath: b.path)
        let refs = Workspace(name: "References", mode: .references)
        let recents = Workspace(name: "Recent", mode: .recents)
        model.workspaces = [wa, wb, refs, recents]
        model.settings.recentShortcutEnabled = true
        var committedEntryCounts: [Int] = []
        var observerSorts = 0
        let observer = model.$contentRevision.dropFirst().sink { _ in
            committedEntryCounts.append(model.entries.count)
            let calculations = model.entryOrderCalculationCount
            _ = model.visibleEntries
            observerSorts += model.entryOrderCalculationCount - calculations
        }
        defer { observer.cancel() }
        model.selectWorkspace(wa.id)
        let firstRead = loader.latest!
        try loader.emit([], complete: false)
        precondition(model.contentRevision == 0)
        try loader.emit([first], complete: false)
        precondition(model.contentRevision == 1 && committedEntryCounts == [1], "First content announces after the new snapshot is fully installed")
        precondition(observerSorts == 0, "Synchronous reveal observers must see the worker-prepared order rather than sort stale entries on the UI thread")
        try loader.emit([first, second], complete: false)
        try loader.emit([first, second], complete: true)
        precondition(model.contentRevision == 1, "Later progressive batches do not restart the transition")
        model.refreshInBackground(); try loader.emit([first, second], complete: true)
        model.setFileTypeFilter("md"); model.setColorLabelFilter(.red); model.search = "z"
        model.setFileTypeFilter(nil); model.setColorLabelFilter(nil); model.search = ""
        precondition(model.contentRevision == 1)
        model.showHiddenFiles = true; try loader.emit([first, second], complete: true)
        precondition(model.contentRevision == 1, "Hidden-file refresh is the same visit")

        model.selectWorkspace(wb.id)
        let beforeStale = model.contentRevision
        try loader.emit([first], complete: true, id: firstRead)
        precondition(model.contentRevision == beforeStale && model.entries.isEmpty, "An obsolete snapshot cannot trigger a content transition")
        try loader.emit([second], complete: true)
        precondition(model.contentRevision == 2)
        model.selectWorkspace(wa.id)
        precondition(model.contentRevision == 3 && model.entries.count == 2, "A warm revisit announces a new visit immediately")
        precondition(committedEntryCounts.last == 2 && observerSorts == 0, "Warm announcements also expose complete, prepared new contents")
        let calculations = model.entryOrderCalculationCount
        _ = model.visibleEntries
        precondition(model.entryOrderCalculationCount == calculations, "A matching warm snapshot reuses its worker-prepared ordering")

        model.selectWorkspace(wb.id)
        model.sortKey = .name
        let mismatch = model.entryOrderCalculationCount
        model.selectWorkspace(wa.id)
        _ = model.visibleEntries
        precondition(model.entryOrderCalculationCount == mismatch + 1, "A different sort must not reuse stale cached ordering")
        try loader.emit([first, second], complete: true)
        let afterSort = model.contentRevision
        model.refresh(); try loader.emit([first, second], complete: true)
        precondition(model.contentRevision == afterSort)

        model.selectWorkspace(refs.id)
        try loader.emit([], complete: true)
        let empty = model.contentRevision
        precondition(empty == afterSort + 1, "An actually empty completed location also commits once")
        model.appendReferences([first.url]); try loader.emit([first], complete: true)
        precondition(model.contentRevision == empty, "Reference membership updates do not create a new visit")

        model.selectWorkspace(wb.id) // Warm B visit, then leave before A publishes.
        let warmB = model.contentRevision
        model.selectWorkspace(refs.id)
        precondition(model.contentRevision == warmB + 1)
        model.selectWorkspace(recents.id)
        recent.emit(gathering: true); try loader.emit([], complete: true)
        let gathering = model.contentRevision
        recent.emit(gathering: false); try loader.emit([], complete: true)
        precondition(model.contentRevision == gathering + 1, "A gathering empty Recents result waits for its query to complete")
    }

    @MainActor static func persistence(root: URL, a: URL, b: URL) async throws {
        let loader = ContentDirectoryLoader(), config = root.appendingPathComponent("persistence.json")
        var model: HubModel? = HubModel(storageURL: config, monitor: false, directoryLoader: loader)
        let wa = Workspace(name: "A", rootPath: a.path), wb = Workspace(name: "B", rootPath: b.path)
        model!.workspaces = [wa, wb]
        let writes = model!.configurationWriteCount
        for index in 0..<10 { model!.selectWorkspace(index % 2 == 0 ? wa.id : wb.id) }
        precondition(model!.selectedWorkspaceID == wb.id && model!.configurationWriteCount == writes,
                     "Selection is immediate and rapid tab switches perform no synchronous writes")
        try await Task.sleep(nanoseconds: 380_000_000)
        precondition(model!.configurationWriteCount == writes + 1, "Rapid switches coalesce into one saved selection")
        func savedSelection() throws -> String? {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            return object["selectedWorkspaceID"] as? String
        }
        let savedAfterDebounce = try savedSelection()
        precondition(savedAfterDebounce == wb.id.uuidString)
        model!.selectWorkspace(wa.id)
        model!.settings.iconSize += 1
        let immediate = model!.configurationWriteCount
        let savedAfterPreference = try savedSelection()
        precondition(immediate == writes + 2 && savedAfterPreference == wa.id.uuidString,
                     "Other preference saves immediately include the newest selection")
        try await Task.sleep(nanoseconds: 380_000_000)
        precondition(model!.configurationWriteCount == immediate, "An ordinary save cancels the pending redundant selection save")
        model!.selectWorkspace(wb.id); model!.save()
        let flushed = model!.configurationWriteCount
        let savedAfterFlush = try savedSelection()
        precondition(savedAfterFlush == wb.id.uuidString)
        try await Task.sleep(nanoseconds: 380_000_000)
        precondition(model!.configurationWriteCount == flushed, "Explicit save/termination flushes and cancels the pending work")
        model!.selectWorkspace(wa.id)
        weak var released = model
        model = nil
        precondition(released == nil, "Queued selection saves must not retain a closed model")
        released = nil
        try await Task.sleep(nanoseconds: 380_000_000)
        let savedAfterRelease = try savedSelection()
        precondition(savedAfterRelease == wb.id.uuidString, "A released model's cancelled callback cannot write again")
    }
}
