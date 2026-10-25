import AppKit
import Combine
import ImageIO
import SwiftUI

struct HubWorkspaceIconRevision: Equatable, Sendable {
    let size: Int
    let modified: Date?
    let attributesModified: Date?
}

enum HubWorkspaceIconRead: @unchecked Sendable {
    case unchanged
    case replace(CGImage?, HubWorkspaceIconRevision?)
}

enum HubWorkspaceIconReader {
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumPixelSize = 128

    /// Runs on the bounded worker queue. No metadata reads or lazy image
    /// decoding escape into a SwiftUI body or onto the main actor.
    static func read(path: String, previous: HubWorkspaceIconRevision?) -> HubWorkspaceIconRead {
        guard path.hasPrefix("/") else { return .replace(nil, nil) }
        let original = URL(fileURLWithPath: path)
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        let url = original.resolvingSymlinksInPath()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                          .contentModificationDateKey, .attributeModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= maximumFileBytes else { return .replace(nil, nil) }
            let revision = HubWorkspaceIconRevision(size: size, modified: values.contentModificationDate,
                                                    attributesModified: values.attributeModificationDate)
            if revision == previous { return .unchanged }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Cap the read as well as checking metadata: a file can grow after
            // the stat, and a mapped file can still force an unbounded decode.
            guard let data = try handle.read(upToCount: maximumFileBytes + 1),
                  !data.isEmpty, data.count <= maximumFileBytes else { return .replace(nil, revision) }
            return .replace(decode(data), revision)
        } catch { return .replace(nil, nil) }
    }

    static func decode(_ data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary)
        }
        // Preserve AppKit-only custom formats (e.g. vector image reps), but
        // rasterize them on this worker into a small immutable bitmap.
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: maximumPixelSize,
                  pixelsHigh: maximumPixelSize, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let factor = CGFloat(maximumPixelSize) / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let rect = NSRect(x: (CGFloat(maximumPixelSize) - size.width) / 2,
                          y: (CGFloat(maximumPixelSize) - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        return bitmap.cgImage
    }
}

private final class HubWorkspaceIconCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor final class HubWorkspaceIconStore {
    static let shared = HubWorkspaceIconStore()
    let updates = PassthroughSubject<String, Never>()
    private struct Entry {
        var image: NSImage?
        var revision: HubWorkspaceIconRevision?
        var checkedAt: TimeInterval
        var lastUse: UInt64
    }
    private struct Request { let id: UUID; let queueID: UUID; let cancellation: HubWorkspaceIconCancellation }
    private var entries: [String: Entry] = [:]
    private var requests: [String: Request] = [:]
    private var sequence: UInt64 = 0
    private let cacheLimit: Int
    private let refreshInterval: TimeInterval
    private let queue: HubThumbnailWorkQueue
    private let read: (String, HubWorkspaceIconRevision?) -> HubWorkspaceIconRead
    var cachedCount: Int { entries.count }
    var pendingCount: Int { requests.count }

    init(cacheLimit: Int = 64, refreshInterval: TimeInterval = 10,
         queue: HubThumbnailWorkQueue? = nil,
         read: @escaping (String, HubWorkspaceIconRevision?) -> HubWorkspaceIconRead = HubWorkspaceIconReader.read) {
        self.cacheLimit = max(1, cacheLimit); self.refreshInterval = refreshInterval
        self.queue = queue ?? HubThumbnailWorkQueue(limit: 2, queueLimit: 32); self.read = read
    }

    /// Memory-only lookup, safe during rendering and pointer tracking.
    func image(for path: String) -> NSImage? {
        guard var entry = entries[path] else { return nil }
        sequence &+= 1; entry.lastUse = sequence; entries[path] = entry
        return entry.image
    }

    func request(_ path: String, force: Bool = false) {
        guard path.hasPrefix("/"), requests[path] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let entry = entries[path], now - entry.checkedAt < refreshInterval { return }
        let id = UUID(), previous = entries[path]?.revision
        let cancellation = HubWorkspaceIconCancellation(), reader = read
        guard let queueID = queue.submit(start: { [weak self] finish in
            DispatchQueue.global(qos: .utility).async {
                let result = cancellation.isCancelled ? HubWorkspaceIconRead.replace(nil, nil) : reader(path, previous)
                Task { @MainActor in
                    defer { finish() }
                    guard let self, self.requests[path]?.id == id, !cancellation.isCancelled else { return }
                    self.requests.removeValue(forKey: path)
                    self.receive(result, path: path)
                }
            }
        }, cancel: { cancellation.cancel() }) else { return }
        requests[path] = Request(id: id, queueID: queueID, cancellation: cancellation)
    }

    func invalidate(_ path: String) {
        entries.removeValue(forKey: path)
        if let request = requests.removeValue(forKey: path) {
            request.cancellation.cancel(); queue.cancel(request.queueID)
        }
        updates.send(path)
    }

    private func receive(_ result: HubWorkspaceIconRead, path: String) {
        sequence &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        switch result {
        case .unchanged:
            guard var entry = entries[path] else { request(path, force: true); return }
            entry.checkedAt = now; entry.lastUse = sequence; entries[path] = entry
        case .replace(let pixels, let revision):
            let shouldNotify = pixels != nil || entries[path]?.image != nil
            entries[path] = Entry(image: pixels.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) },
                                  revision: revision, checkedAt: now, lastUse: sequence)
            while entries.count > cacheLimit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                entries.removeValue(forKey: oldest)
            }
            if shouldNotify { updates.send(path) }
        }
    }
}

struct HubWorkspaceCustomIcon: View {
    let path: String
    let fallbackSymbol: String
    let tint: Color
    var isVisible = true
    @State private var image: NSImage?
    @State private var displayedPath: String?
    private struct RequestKey: Hashable { let path: String; let visible: Bool }

    var body: some View {
        Group {
            if displayedPath == path, let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: fallbackSymbol.isEmpty ? "folder" : fallbackSymbol).foregroundStyle(tint) }
        }
        .task(id: RequestKey(path: path, visible: isVisible)) {
            guard isVisible else { return }
            displayedPath = path; image = HubWorkspaceIconStore.shared.image(for: path)
            while !Task.isCancelled {
                HubWorkspaceIconStore.shared.request(path)
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
        .onReceive(HubWorkspaceIconStore.shared.updates) { changed in
            guard isVisible, changed == path else { return }
            displayedPath = path; image = HubWorkspaceIconStore.shared.image(for: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isVisible { HubWorkspaceIconStore.shared.request(path, force: true) }
        }
    }
}
