import AppKit
import Foundation

private final class BlockedRead: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func started() { lock.lock(); count += 1; lock.unlock() }
}
@main struct DirectoryLoadingTests {
    @MainActor static func wait(_ condition: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Directory load fixture did not finish", file: file, line: line)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("FileDock-BlockedRead-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let slow = root.appendingPathComponent("slow", isDirectory: true)
        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        try fm.createDirectory(at: slow, withIntermediateDirectories: true)
        try fm.createDirectory(at: healthy, withIntermediateDirectories: true)
        let file = healthy.appendingPathComponent("ready.txt")
        try Data("safe".utf8).write(to: file)
        let fixture = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let slowWorkspace = fixture.addWorkspace(name: "Slow", mode: .folder, urls: [slow])
        let healthyWorkspace = fixture.addWorkspace(name: "Healthy", mode: .folder, urls: [healthy])
        fixture.selectWorkspace(slowWorkspace.id)
        let blocked = BlockedRead()
        let loader = HubDirectoryLoader(timeout: 0.12, maximumReads: 2) { request in
            precondition(!Thread.isMainThread, "Filesystem work must never run on the UI thread")
            if request.directory.map(HubFileOperations.canonical) == HubFileOperations.canonical(slow) {
                blocked.started()
                precondition(blocked.gate.wait(timeout: .now() + 10) == .success)
            }
            return try HubDirectoryLoader.readSnapshot(request)
        }
        let model = HubModel(storageURL: root.appendingPathComponent("config.json"), directoryLoader: loader)
        precondition(model.directoryLoading, "Startup must return before reading its initial workspace")
        try await wait { blocked.starts == 1 }
        // This main-actor continuation is the heartbeat: the simulated kernel
        // read remains blocked while navigation and the timeout still execute.
        try await Task.sleep(nanoseconds: 20_000_000)
        model.selectWorkspace(healthyWorkspace.id)
        try await wait { !model.directoryLoading }
        precondition(model.entries.map(\.url) == [file] && model.directoryLoadMessage == nil)
        blocked.gate.signal()
        try await wait { loader.activeReadCount == 0 }
        precondition(model.selectedWorkspaceID == healthyWorkspace.id && model.entries.map(\.url) == [file], "A late cancelled result must not replace the new workspace")

        model.selectWorkspace(slowWorkspace.id)
        try await wait { blocked.starts == 2 }
        try await wait { model.directoryLoadMessage != nil }
        precondition(!model.directoryLoading && loader.activeReadCount == 1, "A timeout releases the UI, never the still-blocked worker slot")
        let starts = blocked.starts
        for _ in 0..<30 { model.refreshInBackground() }
        precondition(blocked.starts == starts, "Periodic refresh must not retry a timed-out directory forever")
        model.selectWorkspace(healthyWorkspace.id)
        try await wait { !model.directoryLoading }
        precondition(model.entries.map(\.url) == [file])
        blocked.gate.signal()
        try await wait { loader.activeReadCount == 0 }

        // Fill both slots with genuinely unfinished reads; rejected retries must
        // finish immediately without adding more threads, including after cancel.
        let first = UUID(), second = UUID(), rejected = UUID()
        var completions = 0
        loader.load(id: first, request: .init(directory: slow)) { _ in completions += 1 }
        loader.load(id: second, request: .init(directory: slow)) { _ in completions += 1 }
        try await wait { blocked.starts == 4 }
        loader.cancel(id: first)
        var wasBusy = false
        loader.load(id: rejected, request: .init(directory: healthy)) { result in
            if case .failure(let error) = result, case HubDirectoryLoadError.busy = error { wasBusy = true }
        }
        precondition(wasBusy && loader.activeReadCount == 2)
        try await wait { completions == 1 }
        blocked.gate.signal(); blocked.gate.signal()
        try await wait { loader.activeReadCount == 0 }
        precondition(completions == 1, "Cancellation and timeout must not publish a second completion after the syscall returns")

        let previousLocation = model.currentURL, previousHistory = model.history
        model.navigate(to: slow)
        try await wait { blocked.starts == 5 }
        try await wait { model.directoryLoadMessage != nil }
        precondition(model.currentURL == previousLocation && model.history == previousHistory,
                     "A failed path jump must retain its previous directory/history")
        model.retryDirectoryLoad()
        try await wait { blocked.starts == 6 }
        blocked.gate.signal(); blocked.gate.signal()
        try await wait { loader.activeReadCount == 0 && !model.directoryLoading }
        precondition(model.currentURL.map(HubFileOperations.canonical)?.path == HubFileOperations.canonical(slow).path,
                     "Retry must reopen the failed target, not refresh the previous directory")
        model.goBack()
        try await wait { !model.directoryLoading }
        precondition(model.currentURL == previousLocation && model.entries.map(\.url) == [file])
        print("PASS: startup and navigation stay responsive during blocked reads, timeout recovery, stale result rejection, bounded real workers, cancelled-slot retention and no periodic retry flood")
    }
}
