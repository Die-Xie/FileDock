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
                        fetch: @escaping WebFetch,
                        completion: @escaping ([URL], [String]) -> Void) -> Bool {
        guard providers.contains(where: { route(for: $0) != nil }) else { return false }
        let batch = Batch(providers: providers, store: store, fetch: fetch, completion: completion)
        batch.advance()
        return true
    }

    private enum Route {
        case fileURL, image(String), webURL, file(String)
    }

    private static func route(for provider: NSItemProvider) -> Route? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return .fileURL }
        let types = provider.registeredTypeIdentifiers
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

        @discardableResult
        func loadFileRepresentation(completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
            provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: completionHandler)
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

        init(providers: [NSItemProvider], store: HubStagingImportStore, fetch: @escaping WebFetch,
             completion: @escaping ([URL], [String]) -> Void) {
            self.providers = providers
            self.store = store
            self.fetch = fetch
            self.completion = completion
        }

        func advance() {
            guard index < providers.count else {
                let finish = completion
                completion = nil
                finish?(urls, failures)
                return
            }
            let provider = providers[index]
            let position = index
            let name = provider.suggestedName
            switch HubStagingDropReceiver.route(for: provider) {
            case .fileURL, .webURL:
                let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                provider.loadItem(forTypeIdentifier: isFile ? UTType.fileURL.identifier : UTType.url.identifier, options: nil) { item, error in
                    let url = HubStagingDropReceiver.url(from: item)
                    DispatchQueue.main.async {
                        guard let url else {
                            self.finish(.failure(error ?? DropError.invalidFileURL), at: position)
                            return
                        }
                        if url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" {
                            self.finish(.success(url.standardizedFileURL), at: position)
                        }
                        else if isFile { self.finish(.failure(DropError.invalidFileURL), at: position) }
                        else {
                            self.fetch(url) { result in
                                // Fetch implementations may invoke completion on a worker queue.
                                DispatchQueue.main.async { self.saveImage(result, name: name ?? url.lastPathComponent, at: position) }
                            }
                        }
                    }
                }
            case .image(let type):
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    let result: Result<Data, Error> = data.map { .success($0) } ?? .failure(error ?? DropError.unavailable)
                    DispatchQueue.main.async { self.saveImage(result, name: name, at: position) }
                }
            case .file(let type):
                let store = store
                let load = FileRepresentationLoad(provider: provider, type: type)
                // Start on a worker, including providers that complete synchronously.
                HubImageImport.workerQueue.async {
                    load.loadFileRepresentation { temporaryURL, error in
                        // NSItemProvider deletes its temporary representation after
                        // this callback returns. Copy here, never in a later task.
                        let result: Result<URL, Error> = Result {
                            guard let temporaryURL else { throw error ?? DropError.unavailable }
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
            let store = store
            HubImageImport.workerQueue.async {
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
