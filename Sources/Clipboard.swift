import AppKit
import Carbon
import UniformTypeIdentifiers

enum HubClipboardError: LocalizedError, Equatable {
    case empty, unsupported, invalidFile, changed, tooLarge, unavailable, timedOut
    var errorDescription: String? {
        switch self {
        case .empty: return L("剪贴板为空。")
        case .unsupported: return L("剪贴板中没有可粘贴的文件或图片。")
        case .invalidFile: return L("剪贴板中的文件地址无效，请重新复制文件。")
        case .changed: return L("剪贴板内容已改变，请重新粘贴。")
        case .tooLarge: return L("剪贴板内容过多或过大，请分批粘贴（最多 20000 项，单项数据 32 MB，总数据 64 MB）。")
        case .unavailable: return L("暂时无法读取剪贴板，请重新复制后再试。")
        case .timedOut: return L("读取剪贴板超时，请重新复制后再试。")
        }
    }
}

/// Immutable data only. AppKit's shared NSPasteboard/NSPasteboardItem instances
/// never cross queues: each read owns a fresh system Pasteboard reference.
struct HubClipboardContents: Sendable {
    enum Item: Sendable {
        case file(URL)
        case data(Data, type: String, name: String)
    }
    let items: [Item]
    var fileURLs: [URL]? {
        var urls: [URL] = []
        for item in items {
            guard case .file(let url) = item else { return nil }
            urls.append(url)
        }
        return urls
    }

    static func read(name: String, cancelled: @Sendable () -> Bool) throws -> Self {
        precondition(!Thread.isMainThread)
        guard !cancelled() else { throw HubClipboardError.timedOut }
        var reference: Pasteboard?
        let systemName = name == NSPasteboard.Name.general.rawValue ? kPasteboardClipboard : name
        guard PasteboardCreate(systemName as CFString, &reference) == noErr, let reference else { throw HubClipboardError.unavailable }
        _ = PasteboardSynchronize(reference)
        var count = 0
        guard PasteboardGetItemCount(reference, &count) == noErr else { throw HubClipboardError.unavailable }
        guard count > 0 else { throw HubClipboardError.empty }
        guard count <= 20_000 else { throw HubClipboardError.tooLarge }
        var result: [Item] = [], bytes = 0
        for position in 1...count {
            guard !cancelled() else { throw HubClipboardError.timedOut }
            var identifier: PasteboardItemID?, rawTypes: CFArray?
            guard PasteboardGetItemIdentifier(reference, position, &identifier) == noErr, let identifier,
                  PasteboardCopyItemFlavors(reference, identifier, &rawTypes) == noErr,
                  let types = rawTypes as? [String] else { throw HubClipboardError.unavailable }
            guard types.count <= 256, types.allSatisfy({ $0.utf8.count <= 512 }) else { throw HubClipboardError.tooLarge }
            // A real file address always wins over an image representation.
            // In particular, copying an SVG must not rasterize or decode it.
            let fileType = UTType.fileURL.identifier
            let type = types.contains(fileType) ? fileType
                : types.first { UTType($0)?.conforms(to: .svg) == true }
                ?? [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier].first { types.contains($0) }
                ?? types.first { UTType($0)?.conforms(to: .image) == true }
                ?? types.first { UTType($0)?.conforms(to: .pdf) == true }
            guard let type else { throw HubClipboardError.unsupported }
            guard !cancelled() else { throw HubClipboardError.timedOut }
            var rawData: CFData?
            guard PasteboardCopyItemFlavorData(reference, identifier, type as CFString, &rawData) == noErr,
                  let rawData else { throw HubClipboardError.unavailable }
            let data = rawData as Data
            guard data.count <= 32 * 1024 * 1024, bytes <= 64 * 1024 * 1024 - data.count else { throw HubClipboardError.tooLarge }
            bytes += data.count
            if type == fileType {
                guard data.count <= 32768, let text = String(data: data, encoding: .utf8),
                      !text.contains("\0"), let url = URL(string: text), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" else { throw HubClipboardError.invalidFile }
                result.append(.file(url.standardizedFileURL))
            } else {
                let name = UTType(type)?.conforms(to: .pdf) == true ? L("剪贴板文档.pdf")
                    : L("剪贴板图片.") + (UTType(type)?.preferredFilenameExtension ?? "png")
                result.append(.data(data, type: type, name: name))
            }
        }
        return Self(items: result)
    }
}

private final class HubClipboardReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

@MainActor enum HubClipboardReader {
    typealias Read = @Sendable (String, @Sendable () -> Bool) throws -> HubClipboardContents
    private static let queue = DispatchQueue(label: "FileDock.Clipboard", qos: .userInitiated, attributes: .concurrent)
    private(set) static var activeWorkers = 0

    /// Timed-out IPC keeps its real worker slot until it returns. Reading cannot
    /// write files, and late results never start materialization or a transfer.
    @discardableResult static func receive(from pasteboard: NSPasteboard, timeout: TimeInterval = 15,
                                          read: @escaping Read = { try HubClipboardContents.read(name: $0, cancelled: $1) },
                                          completion: @escaping (Result<HubClipboardContents, Error>) -> Void) -> Bool {
        guard activeWorkers < 2, let ticket = HubImportActivity.begin() else { return false }
        let session = ReadSession(pasteboard: pasteboard, ticket: ticket, timeout: timeout, completion: completion)
        let name = pasteboard.name.rawValue, cancellation = session.cancellation
        activeWorkers += 1
        queue.async {
            let result = autoreleasepool { Result { try read(name, { cancellation.isCancelled }) } }
            DispatchQueue.main.async {
                activeWorkers -= 1
                session.finish(result)
            }
        }
        return true
    }

    @MainActor private final class ReadSession {
        let pasteboard: NSPasteboard
        let changeCount: Int
        let ticket: UUID
        let cancellation = HubClipboardReadCancellation()
        var completion: ((Result<HubClipboardContents, Error>) -> Void)?
        var deadline: Task<Void, Never>?
        init(pasteboard: NSPasteboard, ticket: UUID, timeout: TimeInterval,
             completion: @escaping (Result<HubClipboardContents, Error>) -> Void) {
            self.pasteboard = pasteboard; changeCount = pasteboard.changeCount
            self.ticket = ticket; self.completion = completion
            let delay = timeout.isFinite ? min(60, max(0.05, timeout)) : 15
            deadline = Task { [self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                finish(.failure(HubClipboardError.timedOut))
            }
        }
        func finish(_ result: Result<HubClipboardContents, Error>) {
            guard let completion else { return }
            self.completion = nil
            cancellation.cancel()
            deadline?.cancel(); deadline = nil
            // The read has no filesystem side effects. Hand its ticket to a
            // materializer/transfer in this same main-actor turn.
            HubImportActivity.end(ticket)
            completion(pasteboard.changeCount == changeCount ? result : .failure(HubClipboardError.changed))
        }
    }
}

@MainActor extension HubModel {
    var canPasteFiles: Bool {
        guard let workspace = selectedWorkspace, workspace.mode != .recents,
              currentURL != nil || workspace.mode == .references else { return false }
        return !isStagingRoot || (settings.resolvedStagingEnabled && !stagingTransferInProgress)
    }

    func pasteFiles(copy: Bool = true, from pasteboard: NSPasteboard = .general,
                    store: HubStagingImportStore = .init()) {
        guard canPasteFiles else { errorMessage = L("请在文件夹、收藏或暂存区中粘贴。"); return }
        guard fileOperationsInProgress < 3 else { errorMessage = L("已有文件操作正在进行，请稍后重试。"); return }
        let workspaceID = selectedWorkspaceID, directory = currentURL
        let accepted = HubClipboardReader.receive(from: pasteboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.errorMessage = error.localizedDescription
            case .success(let contents):
                if let urls = contents.fileURLs {
                    if !self.acceptFileDrop(urls, workspaceID: workspaceID, directory: directory, copy: copy) {
                        self.errorMessage = L("粘贴目标已不可用，或正在进行其他文件操作。")
                    }
                    return
                }
                guard contents.items.count <= 128 else { self.errorMessage = L("剪贴板图片项目过多，请分批粘贴（每批最多 128 项）。"); return }
                // Materialization shares the drop importer's validation, limits,
                // private storage, write leases and shutdown/update accounting.
                let providers = contents.items.map { item -> NSItemProvider in
                    switch item {
                    case .file(let url): return NSItemProvider(object: url as NSURL)
                    case .data(let data, let type, let name):
                        let provider = NSItemProvider(); provider.suggestedName = name
                        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { finish in finish(data, nil); return nil }
                        return provider
                    }
                }
                let accepted = HubStagingDropReceiver.receive(providers, store: store) { [weak self] urls, failures in
                    guard let self else { return }
                    if !urls.isEmpty, !self.acceptFileDrop(urls, workspaceID: workspaceID, directory: directory, copy: true) {
                        self.errorMessage = L("粘贴目标已不可用。剪贴板图片已保留在本机暂存目录。")
                    } else if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n") }
                }
                if !accepted { self.errorMessage = L("已有导入任务正在进行，或剪贴板项目过多，请稍后分批粘贴。") }
            }
        }
        if !accepted { errorMessage = L("已有剪贴板或导入任务正在进行，请稍后重试。") }
    }
}
