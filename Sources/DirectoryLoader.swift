import Foundation
import Combine

private final class DirectoryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
struct HubDirectoryRequest: Sendable {
    var directory: URL?
    var references: [String] = []
    var showHiddenFiles = false
    var metadataOnlyPaths: Set<String>? = nil
    fileprivate var cancellation: DirectoryReadCancellation? = nil
    init(directory: URL?, references: [String] = [], showHiddenFiles: Bool = false,
         metadataOnlyPaths: Set<String>? = nil) {
        self.directory = directory
        self.references = references
        self.showHiddenFiles = showHiddenFiles
        self.metadataOnlyPaths = metadataOnlyPaths
    }
}
struct HubDirectorySnapshot: Sendable {
    var entries: [FileEntry]
    var canonicalDirectoryPath: String?
}
enum HubDirectoryLoadError: LocalizedError {
    case timeout, busy
    var errorDescription: String? {
        switch self {
        case .timeout: return "目录读取超时。可以切换工作区，或稍后重试。"
        case .busy: return "仍有目录等待系统响应。请稍后重试；界面仍可正常操作。"
        }
    }
}
@MainActor protocol HubDirectoryLoading: AnyObject {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void)
    func cancel(id: UUID)
}

/// Cancellation cannot interrupt a filesystem syscall. Timed-out/cancelled reads
/// therefore keep their slot until they really return, preventing retry floods.
@MainActor final class HubDirectoryLoader: HubDirectoryLoading {
    private struct Job {
        var completion: ((Result<HubDirectorySnapshot, Error>) -> Void)?
        var deadline: Task<Void, Never>?
        let cancellation: DirectoryReadCancellation
    }
    private var jobs: [UUID: Job] = [:]
    private let timeout: TimeInterval
    private let maximumReads: Int
    private let read: @Sendable (HubDirectoryRequest) throws -> HubDirectorySnapshot
    var activeReadCount: Int { jobs.count }

    init(timeout: TimeInterval = 5, maximumReads: Int = 3,
         read: @escaping @Sendable (HubDirectoryRequest) throws -> HubDirectorySnapshot = { try HubDirectoryLoader.readSnapshot($0) }) {
        self.timeout = timeout.isFinite ? min(60, max(0.01, timeout)) : 5
        self.maximumReads = max(1, maximumReads)
        self.read = read
    }
    deinit { for job in jobs.values { job.deadline?.cancel() } }

    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        if request.directory == nil && request.references.isEmpty {
            completion(.success(HubDirectorySnapshot(entries: [], canonicalDirectoryPath: nil))); return
        }
        guard jobs.count < maximumReads else { completion(.failure(HubDirectoryLoadError.busy)); return }
        let delay = UInt64(timeout * 1_000_000_000)
        let cancellation = DirectoryReadCancellation()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, var job = self.jobs[id], let complete = job.completion else { return }
            job.cancellation.cancel()
            job.completion = nil; job.deadline = nil
            self.jobs[id] = job
            complete(.failure(HubDirectoryLoadError.timeout))
        }
        jobs[id] = Job(completion: completion, deadline: deadline, cancellation: cancellation)
        let read = read
        var cancellableRequest = request
        cancellableRequest.cancellation = cancellation
        let input = cancellableRequest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try read(input) }
            Task { @MainActor [weak self] in
                guard let job = self?.jobs.removeValue(forKey: id) else { return }
                job.deadline?.cancel()
                job.completion?(result)
            }
        }
    }
    func cancel(id: UUID) {
        guard var job = jobs[id] else { return }
        job.cancellation.cancel()
        job.deadline?.cancel(); job.deadline = nil; job.completion = nil
        jobs[id] = job
    }
    nonisolated static func readSnapshot(_ request: HubDirectoryRequest) throws -> HubDirectorySnapshot {
        try request.cancellation?.check()
        let urls: [URL]
        if let directory = request.directory {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                         options: request.showHiddenFiles ? [] : [.skipsHiddenFiles])
        } else { urls = request.references.map { URL(fileURLWithPath: $0, isDirectory: false) } }
        let entries = try urls.map { url in
            try request.cancellation?.check()
            return FileEntry(url: url)
        }.filter { entry in
            guard let placeholders = request.metadataOnlyPaths else { return true }
            return entry.exists || placeholders.contains(entry.url.path)
        }
        try request.cancellation?.check()
        return HubDirectorySnapshot(entries: entries,
            canonicalDirectoryPath: request.directory.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
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
