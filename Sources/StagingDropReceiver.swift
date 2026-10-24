import Foundation
import UniformTypeIdentifiers

/// Materializes only provider-owned data. Ordinary local files remain references
/// to their original locations, regardless of extension, package or directory type.
@MainActor
enum HubStagingDropReceiver {
    typealias WebFetch = (URL, @escaping (Result<Data, Error>) -> Void) -> Void

    @discardableResult
    static func receive(_ providers: [NSItemProvider], store: HubStagingImportStore = .init(),
                        completion: @escaping ([URL], [String]) -> Void) -> Bool {
        receive(providers, store: store, fetch: { url, completion in
            HubWebImageLoader.fetch(url: url, completion: completion)
        }, completion: completion)
    }

    /// The fetch seam keeps provider/lifetime tests entirely offline.
    @discardableResult
    static func receive(_ providers: [NSItemProvider], store: HubStagingImportStore,
                        fetch: @escaping WebFetch, timeout: TimeInterval = 30,
                        completion: @escaping ([URL], [String]) -> Void) -> Bool {
        guard !providers.isEmpty, providers.count <= 128,
              providers.contains(where: { route(for: $0) != nil }),
              let ticket = HubImportActivity.begin() else { return false }
        let lease = HubImportLease(id: ticket)
        let batch = Batch(providers: providers, store: store, fetch: fetch, lease: lease, completion: completion)
        batch.start(timeout: timeout)
        return true
    }

    private enum Route {
        case fileURL, image(String), webURL, file(String)
    }

    private static func route(for provider: NSItemProvider) -> Route? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return .fileURL }
        let types = provider.registeredTypeIdentifiers
        if let type = types.first(where: { UTType($0)?.conforms(to: .svg) == true }) { return .file(type) }
        if let type = types.first(where: { UTType($0)?.conforms(to: .image) == true }) { return .image(type) }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return .webURL }
        if let type = types.first(where: { UTType($0)?.conforms(to: .item) == true }) ?? types.first {
            return .file(type)
        }
        return nil
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private enum DropError: LocalizedError {
        case unsupported, invalidFileURL, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "此项目没有可读取的文件表示。"
            case .invalidFileURL: return "无法读取拖入的本地文件地址。"
            case .unavailable: return "拖入的项目未返回可读取的内容。"
            }
        }
    }

    /// Only the asynchronous loading API crosses queues. Provider registration
    /// is complete before this handle is made and remains unchanged for this
    /// load's lifetime; routing and suggested-name metadata were read on main.
    /// NSItemProvider delivers representations asynchronously across queues, but
    /// its general mutable API does not declare Sendable. Keep this exception
    /// confined to an immutable handle with no registration/metadata access.
    private struct FileRepresentationLoad: @unchecked Sendable {
        private let provider: NSItemProvider
        private let type: String

        init(provider: NSItemProvider, type: String) {
            self.provider = provider
            self.type = type
        }

        func loadItem(completionHandler: @escaping @Sendable (NSSecureCoding?, Error?) -> Void) {
            provider.loadItem(forTypeIdentifier: type, options: nil, completionHandler: completionHandler)
        }

        @discardableResult
        func loadFileRepresentation(completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
            provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: completionHandler)
        }

        @discardableResult
        func loadDataRepresentation(completionHandler: @escaping @Sendable (Data?, Error?) -> Void) -> Progress {
            provider.loadDataRepresentation(forTypeIdentifier: type, completionHandler: completionHandler)
        }
    }

    /// Each provider finishes loading, downloading and materializing before the
    /// next starts. Closures retain this batch until its one final completion.
    @MainActor
    private final class Batch {
        let providers: [NSItemProvider]
        let store: HubStagingImportStore
        let fetch: WebFetch
        var completion: (([URL], [String]) -> Void)?
        var index = 0
        var urls: [URL] = []
        var failures: [String] = []
        let lease: HubImportLease
        var deadline: Task<Void, Never>?
        var providerProgress: Progress?

        init(providers: [NSItemProvider], store: HubStagingImportStore, fetch: @escaping WebFetch, lease: HubImportLease,
             completion: @escaping ([URL], [String]) -> Void) {
            self.providers = providers
            self.store = store
            self.fetch = fetch
            self.lease = lease
            self.completion = completion
        }

        func start(timeout: TimeInterval) {
            let seconds = timeout.isFinite ? min(300, max(0.05, timeout)) : 30
            deadline = Task { [self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                guard completion != nil else { return }
                providerProgress?.cancel()
                failures.append("导入等待超时，未完成的项目可重新拖入。")
                complete()
            }
            advance()
        }

        private func complete() {
            let finish = completion
            completion = nil
            deadline?.cancel(); deadline = nil
            providerProgress = nil
            lease.close()
            finish?(urls, failures)
        }

        func advance() {
            guard completion != nil else { return }
            guard index < providers.count else { complete(); return }
            let provider = providers[index]
            let position = index
            let name = provider.suggestedName
            switch HubStagingDropReceiver.route(for: provider) {
            case .fileURL, .webURL:
                let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                let load = FileRepresentationLoad(provider: provider, type: isFile ? UTType.fileURL.identifier : UTType.url.identifier)
                HubImageImport.workerQueue.async {
                    load.loadItem { [weak self] item, error in
                        guard let self else { return }
                        let url = HubStagingDropReceiver.url(from: item)
                        DispatchQueue.main.async {
                            guard self.completion != nil, self.index == position else { return }
                            guard let url else {
                                self.finish(.failure(error ?? DropError.invalidFileURL), at: position)
                                return
                            }
                            if url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" {
                                self.finish(.success(url.standardizedFileURL), at: position)
                            } else if isFile { self.finish(.failure(DropError.invalidFileURL), at: position) }
                            else {
                                self.fetch(url) { result in
                                    DispatchQueue.main.async { self.saveImage(result, name: name ?? url.lastPathComponent, at: position) }
                                }
                            }
                        }
                    }
                }
            case .image(let type):
                let load = FileRepresentationLoad(provider: provider, type: type)
                HubImageImport.workerQueue.async {
                    let progress = load.loadDataRepresentation { [weak self] data, error in
                        guard let self else { return }
                        let result: Result<Data, Error> = data.map { .success($0) } ?? .failure(error ?? DropError.unavailable)
                        DispatchQueue.main.async { self.saveImage(result, name: name, at: position) }
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.completion != nil, self.index == position else { progress.cancel(); return }
                        self.providerProgress = progress
                    }
                }
            case .file(let type):
                let store = store, lease = lease
                let load = FileRepresentationLoad(provider: provider, type: type)
                // Start on a worker, including providers that complete synchronously.
                HubImageImport.workerQueue.async {
                    load.loadFileRepresentation { [weak self] temporaryURL, error in
                        guard let self else { return }
                        guard let temporaryURL else {
                            // Some Finder/SwiftUI bridges expose only an SVG's
                            // bytes, or a document data representation. Try it
                            // before declaring an otherwise valid file unreadable.
                            load.loadDataRepresentation { data, dataError in
                                HubImageImport.workerQueue.async {
                                    guard lease.beginWrite() else { return }
                                    defer { lease.endWrite() }
                                    let result: Result<URL, Error> = Result {
                                        guard let data else { throw dataError ?? error ?? DropError.unavailable }
                                        return try store.saveFileData(data, typeIdentifier: type, suggestedName: name)
                                    }
                                    DispatchQueue.main.async { self.finish(result, at: position) }
                                }
                            }
                            return
                        }
                        // NSItemProvider deletes its temporary representation after
                        // this callback returns. Copy here, never in a later task.
                        guard lease.beginWrite() else { return }
                        defer { lease.endWrite() }
                        let result: Result<URL, Error> = Result {
                            return try store.copyFile(at: temporaryURL, suggestedName: name)
                        }
                        DispatchQueue.main.async { self.finish(result, at: position) }
                    }
                }
            case nil:
                finish(.failure(DropError.unsupported), at: position)
            }
        }

        func saveImage(_ input: Result<Data, Error>, name: String?, at position: Int) {
            guard position == index, completion != nil else { return }
            let store = store, lease = lease
            HubImageImport.workerQueue.async {
                guard lease.beginWrite() else { return }
                defer { lease.endWrite() }
                let result = input.flatMap { data in Result { try store.saveImage(data: data, suggestedName: name) } }
                DispatchQueue.main.async { self.finish(result, at: position) }
            }
        }

        func finish(_ result: Result<URL, Error>, at position: Int) {
            guard position == index, completion != nil else { return }
            switch result {
            case .success(let url): urls.append(url)
            case .failure(let error):
                let name = providers[index].suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? "第 \(index + 1) 项"
                failures.append("\(name)：\(error.localizedDescription)")
            }
            index += 1
            // An immediate provider callback must not recurse through a huge drop.
            DispatchQueue.main.async { self.advance() }
        }
    }
}
