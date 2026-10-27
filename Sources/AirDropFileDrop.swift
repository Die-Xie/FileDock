import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sharing is a copy operation regardless of the source drag's default move
/// semantics. Merely hovering never reads providers or opens a recipient UI.
@MainActor struct HubAirDropFileDropDelegate: DropDelegate {
    static let contentTypes: [UTType] = [.fileURL]
    let canReceive: () -> Bool
    var targeted: (Bool) -> Void = { _ in }
    let receive: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        canReceive() && info.hasItemsConforming(to: Self.contentTypes)
    }
    func dropEntered(info: DropInfo) { targeted(validateDrop(info: info)) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = validateDrop(info: info)
        targeted(allowed)
        return Self.proposal(allowed: allowed)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        guard validateDrop(info: info) else { return false }
        // Include the other offered items so the receiver can reject a mixed
        // selection atomically instead of silently sending only its URL subset.
        return receive(info.itemProviders(for: [.fileURL, .item]))
    }
    static func proposal(allowed: Bool) -> DropProposal {
        DropProposal(operation: allowed ? .copy : .cancel)
    }
}

/// This bridge only reads existing file URLs. Raw images, promises and web URLs
/// cannot silently become temporary files, partial selections, or chooser UI.
@MainActor enum HubAirDropFileDropReceiver {
    @discardableResult
    static func receive(providers: [NSItemProvider], timeout: TimeInterval = 30,
                        canReceive: @escaping @MainActor () -> Bool,
                        beginActivity: @MainActor () -> UUID? = { HubImportActivity.begin() },
                        endActivity: @escaping @MainActor (UUID) -> Void = { HubImportActivity.end($0) },
                        completion: @escaping @MainActor ([URL]) -> Void,
                        onError: @escaping @MainActor (String) -> Void) -> Bool {
        guard canReceive(), !providers.isEmpty, providers.count <= 1000,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
              let ticket = beginActivity() else { return false }
        Batch(providers: providers, ticket: ticket, canReceive: canReceive, endActivity: endActivity,
              completion: completion, onError: onError).start(timeout: timeout)
        return true
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let text = item as? String { return URL(string: text) }
        return nil
    }

    @MainActor private final class Batch {
        private var providers: [NSItemProvider]
        private let ticket: UUID
        private let canReceive: @MainActor () -> Bool
        private let endActivity: @MainActor (UUID) -> Void
        private let completion: @MainActor ([URL]) -> Void
        private let onError: @MainActor (String) -> Void
        private var collector: HubDropBatch?
        private var providerLoad: HubAirDropURLProviderWorker.Invocation?
        private var index = 0
        private var finished = false

        init(providers: [NSItemProvider], ticket: UUID, canReceive: @escaping @MainActor () -> Bool,
             endActivity: @escaping @MainActor (UUID) -> Void,
             completion: @escaping @MainActor ([URL]) -> Void, onError: @escaping @MainActor (String) -> Void) {
            self.providers = providers; self.ticket = ticket; self.canReceive = canReceive
            self.endActivity = endActivity; self.completion = completion; self.onError = onError
        }

        func start(timeout: TimeInterval) {
            // The collector retains this batch only until completion/deadline.
            // Provider callbacks are weak, so a stalled provider cannot retain
            // the UI or the entire selection after the timeout has fired.
            collector = HubDropBatch(count: providers.count, timeout: timeout) { [self] in finish($0) }
            advance()
        }

        private func advance() {
            guard !finished, index < providers.count else { return }
            let position = index
            guard let load = HubAirDropURLProviderWorker.load(providers[position], completion: { [weak self] item, error in
                let url = error == nil ? HubAirDropFileDropReceiver.fileURL(from: item) : nil
                Task { @MainActor in self?.loaded(url, at: position) }
            }) else { rejectRemaining(); return }
            providerLoad = load
        }

        private func loaded(_ url: URL?, at position: Int) {
            guard !finished, position == index else { return }
            providerLoad = nil
            guard let url else { rejectRemaining(); return }
            collector?.finish(index: index, url: url)
            index += 1
            if index < providers.count { advance() }
        }

        private func rejectRemaining() {
            while index < providers.count {
                collector?.finish(index: index, url: nil)
                index += 1
            }
        }

        private func finish(_ urls: [URL]) {
            guard !finished else { return }
            finished = true
            collector = nil
            providerLoad = nil
            providers.removeAll()
            // Release our own ticket before the final busy check. Other file
            // work still blocks delivery, while this batch cannot block itself.
            endActivity(ticket)
            guard canReceive() else { onError(L("AirDrop 已关闭或正忙，本次拖入未发送。")); return }
            guard !urls.isEmpty else {
                onError(L("无法读取全部拖入的文件地址，或等待已超时。未发送任何项目。")); return
            }
            do { completion(try HubAirDropPolicy.uniqueFiles(urls)) }
            catch { onError(error.localizedDescription) }
        }
    }
}

/// Even a provider that blocks synchronously inside loadItem cannot block UI or
/// accumulate an unbounded worker queue across repeated timed-out drops.
private enum HubAirDropURLProviderWorker {
    private static let lock = NSLock()
    private static var workers = 0

    @discardableResult
    static func load(_ provider: NSItemProvider,
                     completion: @escaping @Sendable (NSSecureCoding?, Error?) -> Void) -> Invocation? {
        lock.lock()
        guard workers < 2 else { lock.unlock(); return nil }
        workers += 1
        lock.unlock()
        let invocation = Invocation(provider: provider, completion: completion)
        DispatchQueue.global(qos: .userInitiated).async {
            invocation.start()
            lock.lock(); workers -= 1; lock.unlock()
            invocation.didReturn()
        }
        return invocation
    }

    /// Only immutable registration/loading crosses queues. Buffer a synchronous
    /// callback until loadItem returns and the real invocation slot is free.
    final class Invocation: @unchecked Sendable {
        let provider: NSItemProvider
        let completion: @Sendable (NSSecureCoding?, Error?) -> Void
        let lock = NSLock()
        var returned = false
        var delivered = false
        var pending: (NSSecureCoding?, Error?)?

        init(provider: NSItemProvider, completion: @escaping @Sendable (NSSecureCoding?, Error?) -> Void) {
            self.provider = provider; self.completion = completion
        }

        func start() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                guard let self else { return }
                lock.lock()
                guard !delivered, pending == nil else { lock.unlock(); return }
                if returned {
                    delivered = true; lock.unlock(); completion(item, error)
                } else {
                    pending = (item, error); lock.unlock()
                }
            }
        }

        func didReturn() {
            lock.lock()
            returned = true
            let result = pending
            pending = nil
            if result != nil { delivered = true }
            lock.unlock()
            if let result { completion(result.0, result.1) }
        }
    }
}
