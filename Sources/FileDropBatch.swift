import Foundation

/// Single delivery for SwiftUI file providers; malformed/unfinished batches do
/// not transfer a subset of a selection. Native file drops bypass this bridge.
final class HubDropBatch: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var remaining: Int
    private var urls: [Int: URL] = [:]
    private var finished = Set<Int>()
    private var completion: (@MainActor ([URL]) -> Void)?
    private var deadline: DispatchWorkItem?
    init(count: Int, timeout: TimeInterval = 30, completion: @escaping @MainActor ([URL]) -> Void) {
        self.count = count; remaining = count; self.completion = completion
        let timer = DispatchWorkItem { [self] in complete(timedOut: true) }
        deadline = timer
        let delay = timeout.isFinite ? min(60, max(0.01, timeout)) : 30
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }
    func finish(index: Int, url: URL?) {
        lock.lock()
        guard completion != nil, remaining > 0, (0..<count).contains(index), finished.insert(index).inserted else { lock.unlock(); return }
        if let url, url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { urls[index] = url }
        remaining -= 1
        let ready = remaining == 0
        lock.unlock()
        if ready { complete(timedOut: false) }
    }
    private func complete(timedOut: Bool) {
        lock.lock()
        let finish = completion
        completion = nil
        let result = timedOut || urls.count != count ? [] : urls.sorted { $0.key < $1.key }.map(\.value)
        let timer = deadline; deadline = nil
        lock.unlock()
        timer?.cancel()
        if let finish { DispatchQueue.main.async { finish(result) } }
    }
}
