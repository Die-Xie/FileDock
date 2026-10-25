import AppKit
import Combine
import ImageIO

private final class IconReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct WorkspaceCustomIconTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-WorkspaceIcon-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("icon.png")
        try png(width: 2048, height: 1024).write(to: file)
        let first = HubWorkspaceIconReader.read(path: file.path, previous: nil)
        guard case .replace(let pixels?, let revision?) = first else { preconditionFailure("PNG must decode") }
        expect(pixels.width <= 128 && pixels.height <= 128, "Large custom images decode to bounded pixels")
        guard case .unchanged = HubWorkspaceIconReader.read(path: file.path, previous: revision) else {
            preconditionFailure("Unchanged metadata avoids image decoding")
        }
        try png(width: 32, height: 32).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        guard case .replace(let changed?, let revised?) = HubWorkspaceIconReader.read(path: file.path, previous: revision) else {
            preconditionFailure("Replacing image at the same path invalidates metadata cache")
        }
        expect(revised != revision && changed.width <= 128, "Updated file is decoded without growing cache dimensions")
        let link = root.appendingPathComponent("icon-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        guard case .replace(.some, _) = HubWorkspaceIconReader.read(path: link.path, previous: nil) else {
            preconditionFailure("Symlink icons remain supported")
        }
        try FileManager.default.removeItem(at: file)
        expectEmpty(HubWorkspaceIconReader.read(path: file.path, previous: revised), "Deleted files use the fallback icon")
        expectEmpty(HubWorkspaceIconReader.read(path: "relative.png", previous: nil), "Relative paths are rejected")
        expectEmpty(HubWorkspaceIconReader.read(path: root.path, previous: nil), "Directories are not image files")
        try Data("not an image".utf8).write(to: file)
        expectEmpty(HubWorkspaceIconReader.read(path: file.path, previous: nil), "Corrupt images fail without crashing")
        let large = root.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(HubWorkspaceIconReader.maximumFileBytes + 1)); try handle.close()
        expectEmpty(HubWorkspaceIconReader.read(path: large.path, previous: nil), "Oversized files are rejected before decode")

        await testMemoryCacheAndInvalidation()
        await testStalledWorkerAndLateResult()
        await testBoundedQueue()
        print("Workspace icon bounded decoding, cache, invalidation and worker tests passed")
    }

    @MainActor private static func testMemoryCacheAndInvalidation() async {
        let counter = IconReadCounter(), pixels = image(width: 8, height: 8)
        let revision = HubWorkspaceIconRevision(size: 42, modified: nil, attributesModified: nil)
        let store = HubWorkspaceIconStore(cacheLimit: 3, refreshInterval: 3600, read: { _, previous in
            expect(!Thread.isMainThread, "Custom icon file reads must never occur on the main thread")
            _ = counter.increment()
            return previous == revision ? .unchanged : .replace(pixels, revision)
        })
        var notifications: [String] = []
        let observation = store.updates.sink { notifications.append($0) }
        defer { observation.cancel() }
        store.request("/icon/a")
        for _ in 0..<30 { store.request("/icon/a") }
        await wait { store.pendingCount == 0 }
        expect(counter.value == 1 && notifications == ["/icon/a"], "Concurrent views share one image read and one notification")
        for _ in 0..<100 { _ = store.image(for: "/icon/a"); store.request("/icon/a") }
        expect(counter.value == 1, "Cache lookups and repeated renders never stat or decode")
        store.request("/icon/a", force: true)
        await wait { store.pendingCount == 0 }
        expect(counter.value == 2 && notifications.count == 1, "Unchanged metadata refresh produces no visual invalidation")
        for path in ["/icon/b", "/icon/c", "/icon/d"] {
            store.request(path); await wait { store.pendingCount == 0 }
        }
        expect(store.cachedCount == 3 && store.image(for: "/icon/a") == nil, "Cache evicts the least recently used image at its strict limit")
        store.invalidate("/icon/d")
        expect(store.image(for: "/icon/d") == nil, "Explicit invalidation drops stale pixels")
        store.request("/icon/d"); await wait { store.pendingCount == 0 }
        expect(store.image(for: "/icon/d") != nil, "An invalidated path loads again")
    }

    @MainActor private static func testStalledWorkerAndLateResult() async {
        let counter = IconReadCounter(), gate = DispatchSemaphore(value: 0)
        let older = image(width: 7, height: 7), newer = image(width: 9, height: 9)
        let queue = HubThumbnailWorkQueue(limit: 2, queueLimit: 2)
        let store = HubWorkspaceIconStore(queue: queue, read: { _, _ in
            expect(!Thread.isMainThread, "Slow file providers cannot block the main actor")
            let call = counter.increment()
            if call == 1 { gate.wait() }
            return .replace(call == 1 ? older : newer, nil)
        })
        store.request("/slow/icon")
        await wait { counter.value == 1 }
        expect(store.image(for: "/slow/icon") == nil, "A slow disk leaves a usable fallback while loading")
        store.invalidate("/slow/icon"); store.request("/slow/icon")
        await wait { store.image(for: "/slow/icon")?.size.width == 9 }
        expect(queue.activeCount == 1, "Invalidating a blocked read retains its real worker slot")
        gate.signal()
        await wait { queue.activeCount == 0 }
        expect(store.image(for: "/slow/icon")?.size.width == 9, "A late prior-generation read cannot overwrite the current image")
    }

    @MainActor private static func testBoundedQueue() async {
        let counter = IconReadCounter(), gate = DispatchSemaphore(value: 0)
        let queue = HubThumbnailWorkQueue(limit: 2, queueLimit: 2)
        let store = HubWorkspaceIconStore(cacheLimit: 3, queue: queue, read: { _, _ in
            expect(!Thread.isMainThread, "Every queued image read runs on a worker")
            _ = counter.increment(); gate.wait(); return .replace(nil, nil)
        })
        store.request("/stalled/0"); store.request("/stalled/1")
        await wait { counter.value == 2 }
        for index in 2..<100 { store.request("/stalled/\(index)") }
        expect(queue.activeCount == 2 && queue.pendingCount == 2 && store.pendingCount == 4,
               "Disconnected file providers cannot spawn extra workers or an unbounded queue")
        for _ in 0..<4 { gate.signal() }
        await wait { store.pendingCount == 0 }
        expect(counter.value == 4 && store.cachedCount == 3, "Only admitted work executes and failed lookups remain bounded")
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func png(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(width: width, height: height), nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for asynchronous icon test state")
    }

    private static func expectEmpty(_ result: HubWorkspaceIconRead, _ message: String) {
        guard case .replace(nil, _) = result else { preconditionFailure(message) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
}
