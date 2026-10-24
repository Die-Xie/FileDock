import Foundation

private final class MetadataItem: NSMetadataItem {
    let file: URL
    init(_ url: URL) { file = url; super.init() }
    override func value(forAttribute key: String) -> Any? {
        switch key {
        case NSMetadataItemURLKey: return file
        case "kMDItemLastUsedDate": return Date(timeIntervalSince1970: 100)
        default: return nil
        }
    }
}
private final class Query: NSMetadataQuery {
    let rows: [URL]
    init(_ rows: [URL]) { self.rows = rows; super.init() }
    override func start() -> Bool { true }
    override func stop() {}
    override var isGathering: Bool { false }
    override var resultCount: Int { rows.count }
    override func disableUpdates() {}
    override func enableUpdates() {}
    override func result(at index: Int) -> Any {
        precondition(!Thread.isMainThread, "Even item extraction must not block the UI actor")
        return MetadataItem(rows[index])
    }
}
private final class Gates: @unchecked Sendable {
    let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
}
@main struct BackgroundRecentsTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition())
    }
    @MainActor static func main() async throws {
        let center = NotificationCenter(), home = URL(fileURLWithPath: "/tmp/recents-test", isDirectory: true)
        let slow = home.appendingPathComponent("blocked.txt"), healthy = home.appendingPathComponent("ready.txt")
        let gates = Gates()
        var made: [Query] = []
        let source = HubRecentFilesSource(homeURL: home, notificationCenter: center, makeQuery: {
            let query = Query([made.count < 2 ? slow : healthy]); made.append(query); return query
        }, timeout: 0.08, validate: { candidate, _ in
            precondition(!Thread.isMainThread)
            if candidate.url == slow {
                let gate = gates.next() == 1 ? gates.first : gates.second
                precondition(gate.wait(timeout: .now() + 10) == .success)
            }
            return .init(url: candidate.url, lastUsed: candidate.lastUsed)
        })
        var values: [HubRecentFilesSnapshot] = []
        source.start { values.append($0) }
        center.post(name: .NSMetadataQueryDidFinishGathering, object: made[0])
        try await wait { gates.count == 1 }
        try await wait { values.last?.gathering == false }
        precondition(source.activeReadCount == 1 && values.last?.message != nil)
        let timedOut = values.count
        for _ in 0..<30 { source.refreshIfNeeded() }
        precondition(values.count == timedOut && gates.count == 1, "Ticks cannot retry a timed-out syscall forever")
        source.refresh() // Explicit retry starts a distinct query/read.
        center.post(name: .NSMetadataQueryDidFinishGathering, object: made[1])
        try await wait { gates.count == 2 }
        try await wait { values.last?.gathering == false }
        precondition(source.activeReadCount == 2)
        source.stop()
        source.start { values.append($0) }
        center.post(name: .NSMetadataQueryDidFinishGathering, object: made[2])
        precondition(source.activeReadCount == 2, "Cancelled reads retain their actual worker slots")
        try await wait { values.last?.gathering == false }
        precondition(values.last?.files.isEmpty == true && values.last?.message != nil)
        gates.first.signal(); gates.second.signal()
        try await wait { source.activeReadCount == 0 }
        let afterOldResults = values.count
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(values.count == afterOldResults, "Old workers must never republish into the current query")
        source.refresh()
        center.post(name: .NSMetadataQueryDidFinishGathering, object: made.last!)
        try await wait { values.last?.files.map(\.url) == [healthy] }
        source.stop()
        print("PASS: Recents metadata/stat work off-main, idle timeout, no automatic retry flood, bounded real workers, explicit retry, cancellation and late-result isolation")
    }
}
