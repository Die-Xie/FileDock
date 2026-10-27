import AppKit
import Combine

enum HubAirDropError: LocalizedError {
    case emptySelection, invalidURL, tooManyItems, busy, timedOut, unavailable
    case missing(String), unreadable(String), unsupported(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: return L("请先选择要通过 AirDrop 发送的文件或文件夹。")
        case .invalidURL: return L("AirDrop 仅支持本机文件和文件夹，请先将链接内容保存为文件。")
        case .tooManyItems: return L("一次最多发送 1000 个项目，请分批发送或先压缩为一个文件。")
        case .busy: return L("AirDrop 正在处理另一批文件，请稍后重试。")
        case .timedOut: return L("准备 AirDrop 文件超时，请检查文件所在磁盘或网络位置后重试。")
        case .unavailable: return L("当前无法使用 AirDrop。请确认 Mac 支持 AirDrop，并已开启 Wi-Fi 和蓝牙。")
        case .missing(let name): return L("“\(name)”已被移动或删除，请刷新后重新选择。")
        case .unreadable(let name): return L("无法读取“\(name)”，请检查文件权限或所在磁盘是否可用。")
        case .unsupported(let name): return L("“\(name)”不是可发送的普通文件或文件夹。")
        }
    }
}

enum HubAirDropPolicy {
    static func allowsService(title: String, airDropTitle: String?, allowsAirDrop: Bool) -> Bool {
        allowsAirDrop || airDropTitle == nil || title != airDropTitle
    }

    /// Preserve the actual scoped URL; normalization is for deduplication only.
    static func uniqueFiles(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { throw HubAirDropError.emptySelection }
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/") else { throw HubAirDropError.invalidURL }
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
            guard result.count <= 1000 else { throw HubAirDropError.tooManyItems }
        }
        return result
    }

    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
            || (error.domain == NSOSStatusErrorDomain && error.code == -128)
    }

    /// Performs no recursive enumeration and never launches an app or preview.
    static func validateFile(_ url: URL) throws {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        do {
            guard try url.checkResourceIsReachable() else { throw HubAirDropError.missing(name) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isDirectory == true || values.isSymbolicLink == true else {
                throw HubAirDropError.unsupported(name)
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw HubAirDropError.unreadable(name) }
        } catch let error as HubAirDropError {
            throw error
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == NSCocoaErrorDomain,
               code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError {
                throw HubAirDropError.missing(name)
            }
            throw HubAirDropError.unreadable(name)
        }
    }
}

/// Independent access counts survive workspace changes and release exactly
/// once after either validation or the system sharing service has finished.
final class HubAirDropScopeLease: @unchecked Sendable {
    private let scopes: [URL]
    private let stop: (URL) -> Void

    init(urls: [URL], start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.stop = stop
        var seen = Set<String>()
        scopes = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }.filter(start)
    }

    deinit { scopes.forEach(stop) }
}

struct HubAirDropPreparedItems: @unchecked Sendable {
    let urls: [URL]
    let scopes: HubAirDropScopeLease
}

final class HubAirDropPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// A stalled network filesystem may outlive its UI timeout. Bound those workers
/// too, and keep their scopes until the actual filesystem calls have returned.
final class HubAirDropPreparer: @unchecked Sendable {
    static let shared = HubAirDropPreparer()
    private let lock = NSLock()
    private var workers = 0
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FileDock.AirDropPreparation"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    @discardableResult
    func prepare(_ urls: [URL], scopeURLs: [URL], job: HubAirDropPreparation,
                 validate: @escaping (URL) throws -> Void = HubAirDropPolicy.validateFile,
                 makeLease: @escaping ([URL]) -> HubAirDropScopeLease = { HubAirDropScopeLease(urls: $0) },
                 completion: @escaping (Result<HubAirDropPreparedItems, Error>) -> Void) -> Bool {
        lock.lock()
        guard workers < 2 else { lock.unlock(); return false }
        workers += 1
        lock.unlock()
        queue.addOperation { [self] in
            let result: Result<HubAirDropPreparedItems, Error> = Result {
                if job.isCancelled { throw CancellationError() }
                let files = try HubAirDropPolicy.uniqueFiles(urls)
                let lease = makeLease(scopeURLs + files)
                for url in files {
                    if job.isCancelled { throw CancellationError() }
                    try validate(url)
                }
                if job.isCancelled { throw CancellationError() }
                return HubAirDropPreparedItems(urls: files, scopes: lease)
            }
            lock.lock(); workers -= 1; lock.unlock()
            completion(result)
        }
        return true
    }
}

@MainActor protocol HubAirDropSharing: AnyObject {
    var completion: ((Result<Void, Error>) -> Void)? { get set }
    var willPresentTransfer: (() -> Void)? { get set }
    func canShare(_ urls: [URL]) -> Bool
    func perform(_ urls: [URL], from window: NSWindow?)
}

/// The system owns recipient selection and transmission. FileDock never picks
/// a recipient, starts a transfer in the background, or changes radio settings.
@MainActor final class HubNativeAirDropService: NSObject, HubAirDropSharing, NSSharingServiceDelegate {
    var completion: ((Result<Void, Error>) -> Void)?
    var willPresentTransfer: (() -> Void)?
    private let service: NSSharingService
    private weak var sourceWindow: NSWindow?

    private init(service: NSSharingService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    static func make() -> HubNativeAirDropService? {
        NSSharingService(named: .sendViaAirDrop).map { HubNativeAirDropService(service: $0) }
    }

    func canShare(_ urls: [URL]) -> Bool { service.canPerform(withItems: urls) }

    func perform(_ urls: [URL], from window: NSWindow?) {
        sourceWindow = window
        willPresentTransfer?()
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.success(()))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(.failure(error))
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sharingContentScope.pointee = .item
        // An embedded status-bar-level browser is hidden while the system UI
        // runs. Attaching a sheet to that hidden source would hide it as well.
        return sourceWindow?.isVisible == true ? sourceWindow : nil
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        completion = nil
        willPresentTransfer = nil
        service.delegate = nil
        callback?(result)
    }
}

/// The existing general Share action uses the same lease as direct AirDrop.
/// Keep the picker and its chosen service alive through their full callbacks.
@MainActor final class HubNativeSharingPicker: NSObject, HubAirDropSharing,
                                               NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    var completion: ((Result<Void, Error>) -> Void)?
    var willPresentTransfer: (() -> Void)?
    private weak var anchorView: NSView?
    private weak var sourceWindow: NSWindow?
    private let anchorRect: NSRect
    private let preferredEdge: NSRectEdge
    private let allowsAirDrop: Bool
    private let airDropTitle: String?
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?

    init(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge, allowsAirDrop: Bool = true) {
        anchorRect = rect; anchorView = view; self.preferredEdge = preferredEdge
        self.allowsAirDrop = allowsAirDrop
        // NSSharingService exposes a localized title, but no public name.
        // Compare the actual system service's title without KVC/private IDs.
        airDropTitle = allowsAirDrop ? nil : NSSharingService(named: .sendViaAirDrop)?.title
        super.init()
    }

    func canShare(_ urls: [URL]) -> Bool { anchorView?.window?.isVisible == true }

    func perform(_ urls: [URL], from window: NSWindow?) {
        guard let anchorView, anchorView.window?.isVisible == true else {
            finish(.failure(CancellationError())); return
        }
        sourceWindow = window
        let picker = NSSharingServicePicker(items: urls)
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: preferredEdge)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        let policy = MainActor.assumeIsolated { (allowsAirDrop, airDropTitle) }
        return proposedServices.filter {
            HubAirDropPolicy.allowsService(title: $0.title, airDropTitle: policy.1, allowsAirDrop: policy.0)
        }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        MainActor.assumeIsolated { service = sharingService; return self }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            guard let service else { finish(.failure(CancellationError())); return }
            self.service = service
            willPresentTransfer?()
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(.success(())) }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(.failure(error))
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sharingContentScope.pointee = .item
        return sourceWindow?.isVisible == true ? sourceWindow : nil
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        completion = nil; willPresentTransfer = nil
        picker?.delegate = nil; picker = nil
        service?.delegate = nil; service = nil
        callback?(result)
    }
}

@MainActor final class HubAirDropController: ObservableObject {
    enum State: Equatable { case idle, preparing, sharing }
    @Published private(set) var state: State = .idle
    var isBusy: Bool { state != .idle }
    var onError: ((String) -> Void)?
    /// Hide/suspend the browser before system UI; restore its exact previous
    /// presentation only after completion, cancellation, or failure.
    var presentationStateDidChange: ((Bool) -> Void)?

    private let serviceFactory: @MainActor () -> HubAirDropSharing?
    private let preparer: HubAirDropPreparer
    private let timeoutNanoseconds: UInt64
    private let validate: (URL) throws -> Void
    private let makeLease: ([URL]) -> HubAirDropScopeLease
    private var generation = UUID()
    private var preparation: HubAirDropPreparation?
    private var timeout: Task<Void, Never>?
    private var service: HubAirDropSharing?
    private var preparedItems: HubAirDropPreparedItems?
    private var presentationActive = false
    private var requestFactory: (@MainActor () -> HubAirDropSharing?)?

    init(preparer: HubAirDropPreparer = .shared, timeoutNanoseconds: UInt64 = 30_000_000_000,
         serviceFactory: @escaping @MainActor () -> HubAirDropSharing? = { HubNativeAirDropService.make() },
         validate: @escaping (URL) throws -> Void = HubAirDropPolicy.validateFile,
         makeLease: @escaping ([URL]) -> HubAirDropScopeLease = { HubAirDropScopeLease(urls: $0) }) {
        self.preparer = preparer
        self.timeoutNanoseconds = timeoutNanoseconds
        self.serviceFactory = serviceFactory
        self.validate = validate; self.makeLease = makeLease
    }

    deinit { timeout?.cancel(); preparation?.cancel() }

    /// Call only in response to the explicit AirDrop action. Selection is
    /// captured here; later tab changes cannot change what will be shared.
    func send(_ urls: [URL], securityScopedURLs: [URL] = [], from window: NSWindow? = nil) {
        begin(urls, securityScopedURLs: securityScopedURLs, window: window, factory: serviceFactory)
    }

    func showPicker(_ urls: [URL], securityScopedURLs: [URL] = [], relativeTo rect: NSRect,
                    of view: NSView, preferredEdge: NSRectEdge = .minY, allowsAirDrop: Bool = true) {
        begin(urls, securityScopedURLs: securityScopedURLs, window: view.window, factory: { [weak view] in
            guard let view else { return nil }
            return HubNativeSharingPicker(relativeTo: rect, of: view, preferredEdge: preferredEdge, allowsAirDrop: allowsAirDrop)
        })
    }

    private func begin(_ urls: [URL], securityScopedURLs: [URL], window: NSWindow?,
                       factory: @escaping @MainActor () -> HubAirDropSharing?) {
        guard !isBusy else { onError?(HubAirDropError.busy.localizedDescription); return }
        do { _ = try HubAirDropPolicy.uniqueFiles(urls) }
        catch { onError?(error.localizedDescription); return }
        let id = UUID(), job = HubAirDropPreparation()
        generation = id; preparation = job; requestFactory = factory; state = .preparing
        guard preparer.prepare(urls, scopeURLs: securityScopedURLs, job: job, validate: validate, makeLease: makeLease,
                               completion: { [weak self, weak window] result in
            Task { @MainActor in self?.didPrepare(result, id: id, window: window) }
        }) else {
            finish(error: HubAirDropError.busy)
            return
        }
        timeout = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            guard let self, self.generation == id, self.state == .preparing else { return }
            self.finish(error: HubAirDropError.timedOut)
        }
    }

    func cancelPreparation() {
        guard state == .preparing else { return }
        finish(error: nil)
    }

    private func didPrepare(_ result: Result<HubAirDropPreparedItems, Error>, id: UUID, window: NSWindow?) {
        guard generation == id, state == .preparing else { return }
        timeout?.cancel(); timeout = nil; preparation = nil
        switch result {
        case .failure(let error): finish(error: error)
        case .success(let items):
            guard let service = requestFactory?(), service.canShare(items.urls) else {
                finish(error: HubAirDropError.unavailable)
                return
            }
            self.service = service; preparedItems = items
            requestFactory = nil
            service.completion = { [weak self] result in
                guard let self, self.generation == id, self.state == .sharing else { return }
                if case .failure(let error) = result { self.finish(error: error) }
                else { self.finish(error: nil) }
            }
            service.willPresentTransfer = { [weak self] in
                guard let self, self.generation == id, self.state == .sharing, !self.presentationActive else { return }
                self.presentationActive = true
                self.presentationStateDidChange?(true)
            }
            state = .sharing
            service.perform(items.urls, from: window)
        }
    }

    private func finish(error: Error?) {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        preparation?.cancel(); preparation = nil
        service?.completion = nil; service?.willPresentTransfer = nil; service = nil
        requestFactory = nil
        preparedItems = nil
        state = .idle
        if presentationActive { presentationActive = false; presentationStateDidChange?(false) }
        if let error, !(error is CancellationError), !HubAirDropPolicy.isCancellation(error) {
            onError?(error.localizedDescription)
        }
    }
}
