import Foundation

struct HubRecentFile: Equatable, Sendable {
    let url: URL
    let lastUsed: Date
    var metadataOnly = false
}

struct HubRecentFilesSnapshot: Sendable {
    let files: [HubRecentFile]
    let gathering: Bool
    let message: String?
}

@MainActor
protocol HubRecentFilesProviding: AnyObject {
    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void)
    func refresh()
    func refreshIfNeeded()
    func stop()
}

extension HubRecentFilesProviding {
    func refreshIfNeeded() { refresh() }
}

/// Only metadata is inspected here. In particular, a cloud-only document is not
/// opened, coordinated, or requested for download just to appear in Recents.
struct HubRecentFilesCandidate: Sendable {
    let url: URL
    let lastUsed: Date
    var invisible = false
    var contentTypeTree: [String] = []
    var ubiquitous = false
    var downloadingStatus: String?
}

enum HubRecentFilesPolicy {
    static let maximumResults = 500

    static func allowsPath(_ url: URL, homeURL: URL) -> Bool {
        guard url.isFileURL, homeURL.isFileURL else { return false }
        let components = url.standardizedFileURL.pathComponents
        let home = homeURL.standardizedFileURL.pathComponents
        guard components.count > home.count, components.starts(with: home) else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") || $0.lowercased().hasSuffix(".app") || $0.lowercased().hasSuffix(".appex") }) else {
            return false
        }
        let relative = Array(components.dropFirst(home.count))
        if relative.first == "Library" {
            guard relative.count > 2, ["Mobile Documents", "CloudStorage"].contains(relative[1]) else { return false }
        }
        return true
    }

    static func file(for candidate: HubRecentFilesCandidate, homeURL: URL,
                     fileManager: FileManager = .default) -> HubRecentFile? {
        let url = candidate.url.standardizedFileURL
        guard allowsPath(url, homeURL: homeURL), !candidate.invisible,
              !candidate.contentTypeTree.contains("com.apple.application-bundle"),
              candidate.lastUsed.timeIntervalSinceReferenceDate.isFinite else { return nil }

        // attributesOfItem performs a stat, without reading the document. Keep
        // indexed iCloud placeholders even when their logical URL has no local
        // data; do not turn an ordinary deleted file into a stale recent item.
        // An evicted iCloud document may still have a stat-able placeholder
        // inode. Its explicit download status takes precedence over that stat.
        var metadataOnly = candidate.ubiquitous &&
            candidate.downloadingStatus == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey, .isApplicationKey])
            guard values?.isHidden != true, values?.isApplication != true else { return nil }
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular:
                guard !candidate.contentTypeTree.contains("public.folder") else { return nil }
            case .typeDirectory:
                // Pages, Keynote and similar document packages are presented
                // as files by Finder even though stat reports a directory.
                guard values?.isPackage == true, values?.isApplication == false else { return nil }
            default:
                return nil
            }
        } else {
            guard !candidate.contentTypeTree.contains("public.folder"), candidate.ubiquitous,
                  candidate.downloadingStatus != NSMetadataUbiquitousItemDownloadingStatusCurrent else { return nil }
            metadataOnly = true
        }
        return HubRecentFile(url: url, lastUsed: candidate.lastUsed, metadataOnly: metadataOnly)
    }

    static func sorted(_ files: [HubRecentFile]) -> [HubRecentFile] {
        var newestByURL: [URL: HubRecentFile] = [:]
        for file in files {
            let normalized = HubRecentFile(url: file.url.standardizedFileURL, lastUsed: file.lastUsed,
                                           metadataOnly: file.metadataOnly)
            if let previous = newestByURL[normalized.url] {
                if previous.lastUsed > normalized.lastUsed { continue }
                if previous.lastUsed == normalized.lastUsed && (!previous.metadataOnly || normalized.metadataOnly) { continue }
            }
            newestByURL[normalized.url] = normalized
        }
        return newestByURL.values.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.url.path < $1.url.path
        }.prefix(maximumResults).map { $0 }
    }
}

/// Immutable query identity plus a lock-protected cancellation/idle clock.
/// Query result reads run off-main, while start/stop and notifications stay on
/// their owner. Cancelled reads retain a real worker slot until they return.
private final class HubRecentQueryRead: @unchecked Sendable {
    let query: NSMetadataQuery
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var activity = ProcessInfo.processInfo.systemUptime
    init(_ query: NSMetadataQuery) { self.query = query }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
    func checkpoint() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        activity = ProcessInfo.processInfo.systemUptime
    }
    func isIdle(for timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && !cancelled && ProcessInfo.processInfo.systemUptime - activity >= timeout
    }
}

@MainActor
final class HubRecentFilesSource: HubRecentFilesProviding {
    // Finder's public expression, scoped to the home directory. FSInvisible may
    // be missing from the index, so filter hidden metadata after querying.
    static let rawQuery = #"(kMDItemLastUsedDate = "*") && ((kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive)) && !(kMDItemContentTypeTree = public.folder) && !(kMDItemContentTypeTree = com.apple.application-bundle)"#

    private let homeURL: URL
    private let notificationCenter: NotificationCenter
    private let makeQuery: () -> NSMetadataQuery
    private let validate: @Sendable (HubRecentFilesCandidate, URL) -> HubRecentFile?
    private let timeout: TimeInterval
    private let workers: OperationQueue = {
        let queue = OperationQueue(); queue.name = "FileDock.RecentsValidation"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        return queue
    }()
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var receive: ((HubRecentFilesSnapshot) -> Void)?
    private var generation: UInt64 = 0
    private struct Job {
        let read: HubRecentQueryRead
        var deadline: Task<Void, Never>?
        var timedOut = false
    }
    private var jobs: [UUID: Job] = [:]
    private var current: UUID?
    private var refreshPending = false
    private var needsRetry = false
    private var lastFiles: [HubRecentFile] = []
    var activeReadCount: Int { jobs.count }

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         notificationCenter: NotificationCenter = .default,
         makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
         timeout: TimeInterval = 5,
         validate: @escaping @Sendable (HubRecentFilesCandidate, URL) -> HubRecentFile? = { HubRecentFilesPolicy.file(for: $0, homeURL: $1) }) {
        self.homeURL = homeURL.standardizedFileURL
        self.notificationCenter = notificationCenter
        self.makeQuery = makeQuery
        self.validate = validate
        self.timeout = timeout.isFinite ? min(60, max(0.01, timeout)) : 5
    }

    deinit {
        for job in jobs.values { job.read.cancel(); job.deadline?.cancel() }
        for observer in observers { notificationCenter.removeObserver(observer) }
        query?.stop()
    }

    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) {
        self.receive = receive
        if query != nil { refresh(); return }
        guard let predicate = NSPredicate(fromMetadataQueryString: Self.rawQuery) else {
            receive(.init(files: [], gathering: false, message: "无法建立最近使用的文件查询。")); return
        }
        let query = makeQuery()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        query.notificationBatchingInterval = 0.5
        query.operationQueue = .main
        self.query = query
        generation &+= 1
        let startedGeneration = generation
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate,
                     NSNotification.Name.NSMetadataQueryGatheringProgress] {
            observers.append(notificationCenter.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == startedGeneration, !self.needsRetry else { return }
                    self.publishSnapshot()
                }
            })
        }
        receive(.init(files: lastFiles, gathering: true, message: "正在读取最近使用的文件…"))
        guard self.query === query, generation == startedGeneration else { return }
        if !query.start() {
            stopQuery()
            self.receive?(.init(files: lastFiles, gathering: false, message: "无法读取最近使用的文件，请检查 Spotlight 索引后重试。"))
        }
    }

    /// Explicit refresh may retry a failed provider with a new query identity.
    /// Never read concurrently from the old paused query after its timeout.
    func refresh() {
        if needsRetry, let receive {
            stopQuery(); start(receive); return
        }
        guard query != nil else {
            if let receive { start(receive) }
            return
        }
        publishSnapshot()
    }
    func refreshIfNeeded() {
        guard !needsRetry else { return }
        refresh()
    }
    func stop() { stopQuery(); receive = nil; lastFiles = [] }

    private func stopQuery() {
        generation &+= 1
        for job in jobs.values { job.read.cancel(); job.deadline?.cancel() }
        current = nil; refreshPending = false; needsRetry = false
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        query?.stop(); query = nil
    }

    nonisolated private static func snapshot(read: HubRecentQueryRead, homeURL: URL,
        validate: @Sendable (HubRecentFilesCandidate, URL) -> HubRecentFile?) throws -> HubRecentFilesSnapshot {
        try read.checkpoint()
        let query = read.query
        query.disableUpdates()
        defer { query.enableUpdates() }
        var files: [HubRecentFile] = [], seen = Set<URL>()
        for index in 0..<query.resultCount {
            try read.checkpoint()
            // Item attributes, not the binding-oriented query.results proxy.
            let candidate: HubRecentFilesCandidate? = autoreleasepool {
                guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
                let url: URL
                if let value = item.value(forAttribute: NSMetadataItemURLKey) as? URL { url = value }
                else if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { url = URL(fileURLWithPath: path) }
                else { return nil }
                guard let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date else { return nil }
                return HubRecentFilesCandidate(url: url, lastUsed: date,
                    invisible: (item.value(forAttribute: "kMDItemFSInvisible") as? NSNumber)?.boolValue == true,
                    contentTypeTree: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? [],
                    ubiquitous: (item.value(forAttribute: NSMetadataItemIsUbiquitousKey) as? NSNumber)?.boolValue == true,
                    downloadingStatus: item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String)
            }
            guard let candidate else { continue }
            guard let file = autoreleasepool(invoking: { validate(candidate, homeURL) }), seen.insert(file.url).inserted else { continue }
            files.append(file)
            if files.count == HubRecentFilesPolicy.maximumResults { break }
        }
        try read.checkpoint()
        let gathering = query.isGathering
        let message = gathering ? "正在读取最近使用的文件…" : files.isEmpty ? "暂无最近使用的文件。结果取决于 Spotlight 索引。" : nil
        return .init(files: HubRecentFilesPolicy.sorted(files), gathering: gathering, message: message)
    }

    private func publishSnapshot() {
        guard let query, !needsRetry else { return }
        if current != nil { refreshPending = true; return }
        guard jobs.count < 2 else {
            needsRetry = true
            receive?(.init(files: lastFiles, gathering: false, message: "仍有最近使用查询等待系统响应。请稍后重试。")); return
        }
        let id = UUID(), epoch = generation
        let read = HubRecentQueryRead(query), timeout = timeout
        current = id
        let deadline = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(min(0.25, timeout / 4) * 1_000_000_000)) } catch { return }
                guard let self, self.current == id, var job = self.jobs[id] else { return }
                guard job.read.isIdle(for: timeout) else { continue }
                job.read.cancel(); job.timedOut = true; job.deadline = nil
                self.jobs[id] = job; self.needsRetry = true; self.refreshPending = false
                self.receive?(.init(files: self.lastFiles, gathering: false,
                                   message: "最近使用读取暂时无响应。可以切换工作区，或点击刷新重试。"))
                return
            }
        }
        jobs[id] = Job(read: read, deadline: deadline)
        let home = homeURL, validate = validate
        workers.addOperation { [weak self] in
            let result = Result { try Self.snapshot(read: read, homeURL: home, validate: validate) }
            read.finish()
            Task { @MainActor [weak self] in
                guard let self, let job = self.jobs.removeValue(forKey: id) else { return }
                job.deadline?.cancel()
                guard self.current == id, self.generation == epoch else { return }
                self.current = nil
                guard !job.timedOut else { return }
                let again = self.refreshPending; self.refreshPending = false
                if case .success(let snapshot) = result {
                    self.lastFiles = snapshot.files
                    self.receive?(snapshot)
                }
                // Receiver callbacks can synchronously leave or restart Recents.
                if again && self.generation == epoch && self.query === read.query && !self.needsRetry { self.publishSnapshot() }
            }
        }
    }
}
