import Foundation

enum HubFolderWorkspaceDropError: LocalizedError {
    case invalidFiles, notFolder(String), busy, timedOut, targetChanged
    var errorDescription: String? {
        switch self {
        case .invalidFiles: return L("请拖入本机文件夹以创建标签，原文件不会移动。")
        case .notFolder(let name): return L("“\(name)”不是可浏览的文件夹，未创建任何标签。")
        case .busy: return L("正在添加其他文件夹，请稍后再拖入。")
        case .timedOut: return L("检查文件夹超时，未创建标签。请检查磁盘或网络位置后重试。")
        case .targetChanged: return L("标签插入位置已失效，请重新拖入文件夹。")
        }
    }
}

enum HubFolderWorkspaceDropPolicy {
    /// URL-only admission is safe on drag updates. No metadata, bookmarks or
    /// recursive directory reads happen until the user releases the folder.
    static func urls(_ urls: [URL], maximum: Int) throws -> [URL] {
        guard !urls.isEmpty, urls.count <= 20000, maximum > 0 else { throw HubFolderWorkspaceDropError.invalidFiles }
        var seen = Set<String>(), unique: [URL] = []
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
                  !url.path.contains("\0"), url.path.utf8.count <= 65536 else { throw HubFolderWorkspaceDropError.invalidFiles }
            if seen.insert(url.standardizedFileURL.path).inserted { unique.append(url) }
            guard unique.count <= maximum else { throw HubFolderWorkspaceDropError.invalidFiles }
        }
        return unique
    }
}

final class HubFolderWorkspaceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Scopes survive a UI timeout until the real filesystem worker returns. On
/// success the model adopts them; rejected/stale results balance them on release.
final class HubFolderWorkspaceScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    init(_ urls: [URL]) { self.urls = urls.filter { $0.startAccessingSecurityScopedResource() } }
    func take() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let result = urls; urls = []; return result
    }
    deinit { for url in urls { url.stopAccessingSecurityScopedResource() } }
}
struct HubPreparedFolderWorkspace: Sendable {
    let url: URL
    let name: String
    let bookmark: Data?
}
struct HubPreparedFolderWorkspaces: Sendable {
    let folders: [HubPreparedFolderWorkspace]
    let scopes: HubFolderWorkspaceScopes
}

@MainActor protocol HubFolderWorkspacePreparing: AnyObject {
    @discardableResult
    func prepare(_ urls: [URL], completion: @escaping (Result<HubPreparedFolderWorkspaces, Error>) -> Void) -> Bool
}

/// Keep real worker slots after timeout: an uninterruptible disk provider must
/// not permit unlimited replacement requests. Only two preparations can exist.
@MainActor final class HubFolderWorkspacePreparer: HubFolderWorkspacePreparing {
    static let shared = HubFolderWorkspacePreparer()
    private struct Job {
        var completion: ((Result<HubPreparedFolderWorkspaces, Error>) -> Void)?
        var deadline: Task<Void, Never>?
        let cancellation: HubFolderWorkspaceCancellation
    }
    private var jobs: [UUID: Job] = [:]
    private let timeout: TimeInterval
    private let read: @Sendable ([URL], HubFolderWorkspaceCancellation) throws -> HubPreparedFolderWorkspaces
    var activeCount: Int { jobs.count }
    init(timeout: TimeInterval = 5,
         read: @escaping @Sendable ([URL], HubFolderWorkspaceCancellation) throws -> HubPreparedFolderWorkspaces = { try HubFolderWorkspacePreparer.readFolders($0, cancellation: $1) }) {
        self.timeout = timeout.isFinite ? min(30, max(0.01, timeout)) : 5
        self.read = read
    }
    deinit { for job in jobs.values { job.cancellation.cancel(); job.deadline?.cancel() } }

    func prepare(_ urls: [URL], completion: @escaping (Result<HubPreparedFolderWorkspaces, Error>) -> Void) -> Bool {
        guard jobs.count < 2 else { return false }
        let id = UUID(), cancellation = HubFolderWorkspaceCancellation()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 5) * 1_000_000_000)) }
            catch { return }
            guard let self, var job = self.jobs[id], let complete = job.completion else { return }
            job.cancellation.cancel(); job.completion = nil; job.deadline = nil
            self.jobs[id] = job
            complete(.failure(HubFolderWorkspaceDropError.timedOut))
        }
        jobs[id] = Job(completion: completion, deadline: deadline, cancellation: cancellation)
        let read = read
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try read(urls, cancellation) }
            Task { @MainActor [weak self] in
                guard let job = self?.jobs.removeValue(forKey: id) else { return }
                job.deadline?.cancel()
                job.completion?(result)
            }
        }
        return true
    }

    nonisolated static func readFolders(_ urls: [URL], cancellation: HubFolderWorkspaceCancellation) throws -> HubPreparedFolderWorkspaces {
        try cancellation.check()
        let scopes = HubFolderWorkspaceScopes(urls)
        var folders: [HubPreparedFolderWorkspace] = []
        for url in urls {
            try cancellation.check()
            try autoreleasepool {
                var fresh = url.standardizedFileURL
                fresh.removeAllCachedResourceValues()
                let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard values.isDirectory == true, values.isPackage != true else {
                    throw HubFolderWorkspaceDropError.notFolder(url.lastPathComponent)
                }
                try cancellation.check()
                let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                    ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                folders.append(HubPreparedFolderWorkspace(url: fresh,
                    name: fresh.lastPathComponent.isEmpty ? "/" : fresh.lastPathComponent, bookmark: bookmark))
            }
        }
        try cancellation.check()
        return HubPreparedFolderWorkspaces(folders: folders, scopes: scopes)
    }
}
