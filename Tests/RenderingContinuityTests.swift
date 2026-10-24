import AppKit
import SwiftUI
import Combine
import QuickLookThumbnailing

@main struct RenderingContinuityTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("FileDock-Rendering-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("A.txt"), b = root.appendingPathComponent("B.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let first = FileEntry(url: a), second = FileEntry(url: b)
        try await thumbnails(first, second)
        try await queueBoundaries()
        try await presentationAndIconUpdates(a.path, b.path)
        let cache = HubDirectorySnapshotCache<String>(capacity: 2, maximumEntries: 1, lifetime: 5)
        let snapshot = HubDirectorySnapshot(entries: [first], canonicalDirectoryPath: root.path)
        cache.insert(snapshot, for: "a", now: 1); cache.insert(snapshot, for: "b", now: 1)
        precondition(cache.snapshot(for: "a", now: 2) != nil)
        cache.insert(snapshot, for: "c", now: 2)
        precondition(cache.snapshot(for: "b", now: 2) == nil && cache.snapshot(for: "a", now: 7) == nil)
        cache.insert(.init(entries: [first, second], canonicalDirectoryPath: nil), for: "large", now: 3)
        precondition(cache.snapshot(for: "large", now: 3) == nil)
        let icon = FileDockMenuBarIcon.make()
        precondition(icon.isTemplate && icon.size == CGSize(width: 18, height: 18))
        let bitmap = NSBitmapImageRep(data: icon.tiffRepresentation!)!
        var opaque = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.1 {
                opaque += 1
                precondition(x > 0 && y > 0 && x < bitmap.pixelsWide - 1 && y < bitmap.pixelsHigh - 1, "Menu mark must remain inside its template bounds")
            }
        }
        precondition(opaque > 20)
        print("PASS: stable/cached/deferred thumbnails, exact late callback isolation, bounded actual Quick Look work, path-scoped/coalesced icon updates, deferred music-layout changes, bounded expiring workspace snapshots and unclipped menu template")
    }
    @MainActor static func thumbnails(_ a: FileEntry, _ b: FileEntry) async throws {
        let queue = HubThumbnailWorkQueue(limit: 1)
        var callbacks: [@MainActor (NSImage?, Int) -> Void] = []
        let generate: HubThumbnailLoader.Generate = { _, complete in callbacks.append(complete) }
        let loader = HubThumbnailLoader(queue: queue, generate: generate, cancel: { _ in })
        let key = HubThumbnailLoader.key(for: a, size: 46)
        loader.load(entry: a, size: 46, key: key)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(callbacks.count == 1 && queue.activeCount == 1)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        callbacks[0](image, 1024)
        precondition(loader.image === image)
        loader.load(entry: a, size: 46, key: key, suspended: true)
        precondition(loader.image === image && callbacks.count == 1)
        let restored = HubThumbnailLoader(queue: queue, generate: generate, cancel: { _ in })
        restored.load(entry: a, size: 46, key: key, suspended: true)
        precondition(restored.image === image, "A newly revealed cached file must not flash a generic icon during tracking")
        let nextKey = HubThumbnailLoader.key(for: b, size: 46)
        loader.load(entry: b, size: 46, key: nextKey, suspended: true)
        precondition(loader.image == nil, "A reused cell must never display another file's cached image")
        loader.load(entry: b, size: 46, key: nextKey)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(callbacks.count == 2)
        loader.cancel()
        precondition(queue.activeCount == 1, "A cancelled request retains its actual system slot")
        callbacks[1](image, 1024)
        precondition(loader.image == nil && HubThumbnailLoader.cached(for: nextKey, eligible: true) == nil)
        precondition(queue.activeCount == 0)
    }
    @MainActor static func queueBoundaries() async throws {
        let queue = HubThumbnailWorkQueue(limit: 1, queueLimit: 2)
        var completions: [@MainActor () -> Void] = [], cancels = 0
        let first = queue.submit(start: { completions.append($0) }, cancel: { cancels += 1 })!
        let second = queue.submit(start: { completions.append($0) }, cancel: {})!
        precondition(queue.submit(start: { _ in }, cancel: {}) == nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(completions.count == 1 && queue.activeCount == 1 && queue.pendingCount == 1)
        queue.cancel(first); queue.cancel(second)
        precondition(cancels == 1 && queue.activeCount == 1 && queue.pendingCount == 0)
        _ = queue.submit(start: { completions.append($0) }, cancel: {})
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(completions.count == 1)
        completions[0](); completions[0]()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(completions.count == 2 && queue.activeCount == 1)
        completions[1]()
    }
    @MainActor static func presentationAndIconUpdates(_ a: String, _ b: String) async throws {
        let state = HubPresentationState()
        precondition(state.defersFileRendering, "Hidden panels must not generate thumbnails")
        state.previewVisible = true
        state.header = .init(embedded: true, exclusionWidth: 240, topInset: 32, split: true)
        let header = state.header
        state.beginWindowMove(pinned: false)
        precondition(state.header == header && !state.movingPinned && state.defersFileRendering)
        state.setFileDragActive(true); state.setSurfaceAnimating(true); state.setSurfaceAnimating(false)
        state.endWindowMove(reduceMotion: false)
        precondition(!state.header.embedded && state.layoutChanging && state.defersFileRendering)
        state.setFileDragActive(false)
        try await Task.sleep(nanoseconds: 260_000_000)
        precondition(!state.defersFileRendering)
        state.beginWindowMove(pinned: true); state.endWindowMove(reduceMotion: true)
        precondition(!state.layoutChanging && !state.defersFileRendering)
        var batches: [Set<String>] = []
        let observer = HubFileIconUpdates.changes.sink { batches.append($0) }
        HubFileIconUpdates.setPaused(true); HubFileIconUpdates.mark(a); HubFileIconUpdates.mark(b)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(batches.isEmpty)
        HubFileIconUpdates.setPaused(false)
        try await Task.sleep(nanoseconds: 35_000_000)
        precondition(batches == [[a, b]])
        observer.cancel()
    }
}
