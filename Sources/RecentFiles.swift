import Foundation

struct HubRecentFile: Equatable, Sendable {
    let url: URL
    let lastUsed: Date
    var metadataOnly = false
}

struct HubRecentFilesSnapshot {
    let files: [HubRecentFile]
    let gathering: Bool
    let message: String?
}

@MainActor
protocol HubRecentFilesProviding: AnyObject {
    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void)
    func refresh()
    func stop()
}

/// Only metadata is inspected here. In particular, a cloud-only document is not
/// opened, coordinated, or requested for download just to appear in Recents.
struct HubRecentFilesCandidate {
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

@MainActor
final class HubRecentFilesSource: HubRecentFilesProviding {
    // The base expression comes from Finder's shipped Recents saved search.
    // Use a public, bounded home scope rather than Finder's private MyFiles scope.
    // FSInvisible is not reliably indexed: a negative clause for that attribute
    // can suppress every result. Hidden paths and flags are filtered after stat.
    static let rawQuery = #"(kMDItemLastUsedDate = "*") && ((kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive)) && !(kMDItemContentTypeTree = public.folder) && !(kMDItemContentTypeTree = com.apple.application-bundle)"#

    private let homeURL: URL
    private let notificationCenter: NotificationCenter
    private let makeQuery: () -> NSMetadataQuery
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var receive: ((HubRecentFilesSnapshot) -> Void)?
    private var generation: UInt64 = 0

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         notificationCenter: NotificationCenter = .default,
         makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() }) {
        self.homeURL = homeURL.standardizedFileURL
        self.notificationCenter = notificationCenter
        self.makeQuery = makeQuery
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
        query?.stop()
    }

    func start(_ receive: @escaping (HubRecentFilesSnapshot) -> Void) {
        self.receive = receive
        if query != nil {
            publishSnapshot()
            return
        }
        guard let predicate = NSPredicate(fromMetadataQueryString: Self.rawQuery) else {
            receive(HubRecentFilesSnapshot(files: [], gathering: false,
                                           message: "无法建立最近使用的文件查询。"))
            return
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
                    guard let self, self.generation == startedGeneration else { return }
                    self.publishSnapshot()
                }
            })
        }
        receive(HubRecentFilesSnapshot(files: [], gathering: true, message: "正在读取最近使用的文件…"))
        // A receiver may synchronously leave this workspace from its callback.
        guard self.query === query, generation == startedGeneration else { return }
        if !query.start() {
            stopQuery()
            self.receive?(HubRecentFilesSnapshot(files: [], gathering: false,
                                                message: "无法读取最近使用的文件，请检查 Spotlight 索引后重试。"))
        }
    }

    /// Republish the live query; repeatedly rebuilding Spotlight queries makes
    /// a timer-driven refresh look permanently empty on a large home directory.
    func refresh() {
        guard query != nil else {
            // A failed start keeps the receiver so an explicit refresh can
            // retry. stop() clears it, so inactive workspaces remain stopped.
            if let receive { start(receive) }
            return
        }
        publishSnapshot()
    }

    func stop() {
        stopQuery()
        receive = nil
    }

    private func stopQuery() {
        generation &+= 1
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        query?.stop()
        query = nil
    }

    private func snapshot(from query: NSMetadataQuery) -> HubRecentFilesSnapshot {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var files: [HubRecentFile] = []
        var seen: Set<URL> = []
        for index in 0..<query.resultCount {
            // Query-level attribute access is limited to sort/group/value-list fields.
            // Read each metadata item directly for its path and other fields;
            // query.results is intentionally avoided because it is for bindings.
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            let url: URL
            if let value = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                url = value
            } else if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                url = URL(fileURLWithPath: path)
            } else { continue }
            guard let lastUsed = item.value(forAttribute: "kMDItemLastUsedDate") as? Date else { continue }
            let candidate = HubRecentFilesCandidate(
                url: url, lastUsed: lastUsed,
                invisible: (item.value(forAttribute: "kMDItemFSInvisible") as? NSNumber)?.boolValue == true,
                contentTypeTree: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? [],
                ubiquitous: (item.value(forAttribute: NSMetadataItemIsUbiquitousKey) as? NSNumber)?.boolValue == true,
                downloadingStatus: item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String)
            guard let file = HubRecentFilesPolicy.file(for: candidate, homeURL: homeURL), seen.insert(file.url).inserted else { continue }
            files.append(file)
            // The query is sorted newest first, so no lower-ranked result can
            // displace these first 500 distinct eligible documents.
            if files.count == HubRecentFilesPolicy.maximumResults { break }
        }
        let gathering = query.isGathering
        let message = gathering ? "正在读取最近使用的文件…" : (files.isEmpty ? "暂无最近使用的文件。结果取决于 Spotlight 索引。" : nil)
        return HubRecentFilesSnapshot(files: HubRecentFilesPolicy.sorted(files), gathering: gathering, message: message)
    }

    private func publishSnapshot() {
        guard let query else { return }
        let value = snapshot(from: query)
        receive?(value)
    }
}
