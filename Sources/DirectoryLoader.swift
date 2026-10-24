import Foundation
import Combine

/// A filesystem syscall cannot be interrupted. Keep its real worker slot until
/// it returns; only one pending partial snapshot is retained for the UI.
private final class DirectoryReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var pending: HubDirectorySnapshot?
    func cancel() { lock.lock(); cancelled = true; pending = nil; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func advance(_ snapshot: HubDirectorySnapshot? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if let snapshot { pending = snapshot }
    }
    func finish() { lock.lock(); finished = true; lock.unlock() }
    func poll() -> (activity: TimeInterval, snapshot: HubDirectorySnapshot?, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        let value = (lastActivity, pending, finished); pending = nil
        return value
    }
}
struct HubDirectoryRequest: Sendable {
    var directory: URL?
    var references: [String] = []
    var showHiddenFiles = false
    var metadataOnlyPaths: Set<String>? = nil
    var order: HubDirectoryOrder?
    fileprivate var state: DirectoryReadState? = nil
    init(directory: URL?, references: [String] = [], showHiddenFiles: Bool = false,
         metadataOnlyPaths: Set<String>? = nil) {
        self.directory = directory
        self.references = references
        self.showHiddenFiles = showHiddenFiles
        self.metadataOnlyPaths = metadataOnlyPaths
    }
    func checkCancellation() throws { try state?.check() }
    func recordProgress(_ snapshot: HubDirectorySnapshot? = nil) throws { try state?.advance(snapshot) }
}
/// Value-only ordering input can be captured with a read and applied off-main.
struct HubDirectoryOrder: Equatable, Sendable {
    var key: SortKey
    var ascending: Bool
    var foldersFirst: Bool
    var preservesInputOrder: Bool
    var directoryOrders: [String: [String]]

    func sorted(_ entries: [FileEntry], canonicalPath: String?, checkpoint: () throws -> Void = {}) throws -> [FileEntry] {
        if preservesInputOrder { return entries }
        let names = canonicalPath.flatMap { directoryOrders[$0] }
        let positions = names.map { Dictionary($0.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min) }
        var comparisons = 0
        func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
            let left = lhs ?? .distantPast, right = rhs ?? .distantPast
            return left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        }
        return try entries.sorted { left, right in
            comparisons += 1
            if comparisons % 512 == 0 { try checkpoint() }
            if let positions {
                let a = positions[left.url.lastPathComponent] ?? Int.max, b = positions[right.url.lastPathComponent] ?? Int.max
                return a == b ? left.name.localizedStandardCompare(right.name) == .orderedAscending : a < b
            }
            if foldersFirst && left.canNavigate != right.canNavigate { return left.canNavigate }
            let result: ComparisonResult
            switch key {
            case .name: result = left.name.localizedStandardCompare(right.name)
            case .kind: result = left.kind.localizedStandardCompare(right.kind)
            case .size: result = left.size == right.size ? .orderedSame : left.size < right.size ? .orderedAscending : .orderedDescending
            case .created: result = compareDates(left.created, right.created)
            case .modified: result = compareDates(left.modified, right.modified)
            case .added: result = compareDates(left.added, right.added)
            }
            if result == .orderedSame { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
struct HubDirectorySnapshot: Sendable {
    var entries: [FileEntry]
    var canonicalDirectoryPath: String?
    var order: HubDirectoryOrder? = nil
    var orderedEntries: [FileEntry]? = nil
}
enum HubDirectoryLoadError: LocalizedError {
    case timeout, busy
    var errorDescription: String? {
        switch self {
        case .timeout: return "目录读取暂时无响应。已读内容仍可使用，可以切换工作区或稍后重试。"
        case .busy: return "仍有目录等待系统响应。请稍后重试；界面仍可正常操作。"
        }
    }
}
@MainActor protocol HubDirectoryLoading: AnyObject {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void)
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void)
    func cancel(id: UUID)
}
extension HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        load(id: id, request: request, completion: completion)
    }
}

@MainActor final class HubDirectoryLoader: HubDirectoryLoading {
    private struct Job {
        var completion: ((Result<HubDirectorySnapshot, Error>) -> Void)?
        var progress: ((HubDirectorySnapshot) -> Void)?
        var deadline: Task<Void, Never>?
        let state: DirectoryReadState
    }
    private var jobs: [UUID: Job] = [:]
    private let timeout: TimeInterval
    private let maximumReads: Int
    private let read: @Sendable (HubDirectoryRequest) throws -> HubDirectorySnapshot
    var activeReadCount: Int { jobs.count }

    /// Timeout measures inactivity, not total elapsed time in a large directory.
    init(timeout: TimeInterval = 5, maximumReads: Int = 3,
         read: @escaping @Sendable (HubDirectoryRequest) throws -> HubDirectorySnapshot = { try HubDirectoryLoader.readSnapshot($0) }) {
        self.timeout = timeout.isFinite ? min(60, max(0.01, timeout)) : 5
        self.maximumReads = max(1, maximumReads)
        self.read = read
    }
    deinit { for job in jobs.values { job.state.cancel(); job.deadline?.cancel() } }

    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        load(id: id, request: request, progress: { _ in }, completion: completion)
    }
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        if request.directory == nil && request.references.isEmpty {
            completion(.success(HubDirectorySnapshot(entries: [], canonicalDirectoryPath: nil))); return
        }
        guard jobs[id] == nil, jobs.count < maximumReads else { completion(.failure(HubDirectoryLoadError.busy)); return }
        let interval = UInt64(min(0.1, timeout / 4) * 1_000_000_000)
        let state = DirectoryReadState()
        let deadline = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self, var job = self.jobs[id], job.completion != nil else { return }
                let update = job.state.poll()
                if let snapshot = update.snapshot { job.progress?(snapshot) }
                if update.finished { return }
                // Progress callbacks can synchronously navigate or cancel.
                guard let current = self.jobs[id], let complete = current.completion else { return }
                guard ProcessInfo.processInfo.systemUptime - update.activity >= self.timeout else { continue }
                current.state.cancel()
                job.completion = nil; job.progress = nil; job.deadline = nil
                self.jobs[id] = job
                complete(.failure(HubDirectoryLoadError.timeout))
                return
            }
        }
        jobs[id] = Job(completion: completion, progress: progress, deadline: deadline, state: state)
        let read = read
        var input = request
        input.state = state
        let cancellableRequest = input
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try read(cancellableRequest) }
            state.finish()
            Task { @MainActor [weak self] in
                guard let job = self?.jobs.removeValue(forKey: id) else { return }
                job.deadline?.cancel()
                // Preserve the final partial batch if a provider failed mid-read.
                if case .failure = result, let snapshot = job.state.poll().snapshot { job.progress?(snapshot) }
                job.completion?(result)
            }
        }
    }
    func cancel(id: UUID) {
        guard var job = jobs[id] else { return }
        job.state.cancel()
        job.deadline?.cancel(); job.deadline = nil; job.completion = nil; job.progress = nil
        jobs[id] = job
    }
    nonisolated static func readSnapshot(_ request: HubDirectoryRequest) throws -> HubDirectorySnapshot {
        try request.checkCancellation()
        let canonical = request.directory.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        var entries: [FileEntry] = []
        var lastPublish = ProcessInfo.processInfo.systemUptime
        var published = false
        func snapshot() throws -> HubDirectorySnapshot {
            let ordered = try request.order?.sorted(entries, canonicalPath: canonical) { try request.recordProgress() }
            return HubDirectorySnapshot(entries: entries, canonicalDirectoryPath: canonical, order: request.order, orderedEntries: ordered)
        }
        func append(_ url: URL, prefetched: Bool) throws {
            try request.checkCancellation()
            let entry = FileEntry(url: url, preservingResourceCache: prefetched)
            if request.metadataOnlyPaths.map({ entry.exists || $0.contains(entry.url.path) }) ?? true { entries.append(entry) }
            try request.recordProgress()
            let now = ProcessInfo.processInfo.systemUptime
            // Small first batch; adaptive cadence bounds copying, sorting and
            // SwiftUI updates as a directory grows. No task per file/batch.
            let cadence: TimeInterval = entries.count > 10000 ? 1 : entries.count > 1000 ? 0.4 : 0.15
            if (!published && entries.count >= 64) || (now - lastPublish >= cadence && !entries.isEmpty) {
                try request.recordProgress(snapshot())
                published = true; lastPublish = now
            }
        }
        if let directory = request.directory {
            // A new enumerator per refresh avoids stale resource caches while
            // preserving the metadata prefetched by the filesystem in this scan.
            let root = URL(fileURLWithPath: directory.path, isDirectory: true)
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "目标不是文件夹。"])
            }
            var enumerationError: Error?
            var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
            if !request.showHiddenFiles { options.insert(.skipsHiddenFiles) }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(FileEntry.resourceKeys),
                options: options, errorHandler: { _, error in enumerationError = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            while true {
                try request.checkCancellation()
                let advanced: Bool = try autoreleasepool {
                    guard let url = enumerator.nextObject() as? URL else { return false }
                    try append(url, prefetched: true)
                    return true
                }
                if !advanced { break }
            }
            if let enumerationError { throw enumerationError }
        } else {
            for path in request.references {
                try autoreleasepool { try append(URL(fileURLWithPath: path, isDirectory: false), prefetched: false) }
            }
        }
        try request.checkCancellation()
        return try snapshot()
    }
}

/// The parent column is independent of the current-directory read. A timed-out
/// provider cannot block SwiftUI body evaluation or publish into a later path.
@MainActor final class HubParentDirectory: ObservableObject {
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var message: String?
    private let loader: HubDirectoryLoading
    private var current: UUID?
    init(loader: HubDirectoryLoading? = nil) { self.loader = loader ?? HubDirectoryLoader() }
    func load(_ directory: URL) {
        clear()
        let id = UUID(); current = id
        loader.load(id: id, request: HubDirectoryRequest(directory: directory)) { [weak self] result in
            guard let self, self.current == id else { return }
            self.current = nil
            switch result {
            case .success(let snapshot):
                self.entries = snapshot.entries.filter(\.canNavigate).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .failure(let error): self.message = error.localizedDescription
            }
        }
    }
    func clear() {
        if let current { loader.cancel(id: current) }
        current = nil; entries = []; message = nil
    }
}

/// Small, short-lived workspace cache for immediate tab revisits. Fresh reads
/// still run in the background; recent-file queries are never cached here.
@MainActor final class HubDirectorySnapshotCache<Key: Hashable> {
    private struct Value { var snapshot: HubDirectorySnapshot; var date: TimeInterval }
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int
    private let maximumEntries: Int
    private let lifetime: TimeInterval
    init(capacity: Int = 4, maximumEntries: Int = 1000, lifetime: TimeInterval = 15) {
        self.capacity = max(1, capacity); self.maximumEntries = max(1, maximumEntries)
        self.lifetime = max(0, lifetime)
    }
    func insert(_ snapshot: HubDirectorySnapshot, for key: Key, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard snapshot.entries.count <= maximumEntries else { values.removeValue(forKey: key); order.removeAll { $0 == key }; return }
        values[key] = Value(snapshot: snapshot, date: now)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    func snapshot(for key: Key, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> HubDirectorySnapshot? {
        guard let value = values[key] else { return nil }
        guard now - value.date <= lifetime else { values.removeValue(forKey: key); order.removeAll { $0 == key }; return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value.snapshot
    }
}
