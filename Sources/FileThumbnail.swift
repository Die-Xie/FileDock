import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Existing pixels remain stable during tracking and animation. Cached thumbnails
/// are available immediately even while new Quick Look work is suspended.
@MainActor struct HubFileIcon: View {
    let entry: FileEntry
    let size: Double
    var allowsThumbnail = true
    var lightweight = false
    @State private var iconRevision: UInt64 = 0
    @StateObject private var loader = HubThumbnailLoader()

    var body: some View {
        let _ = iconRevision
        Image(nsImage: loader.image ?? HubThumbnailLoader.cached(for: assetKey, eligible: allowsThumbnail) ?? entry.icon)
            .resizable().scaledToFit().frame(width: size, height: size)
            .opacity(entry.exists ? 1 : 0.4)
            .task(id: requestKey) {
                loader.load(entry: entry, size: size, key: assetKey, enabled: allowsThumbnail, suspended: lightweight)
            }
            .onReceive(HubFileIconUpdates.changes) { paths in
                if paths.contains(entry.url.path) { iconRevision &+= 1 }
            }
            .onDisappear { loader.cancel() }
    }
    private var assetKey: String { HubThumbnailLoader.key(for: entry, size: size) }
    private var requestKey: String { assetKey + "|thumbnail:\(allowsThumbnail)|deferred:\(lightweight)" }
}

@MainActor final class HubThumbnailLoader: ObservableObject {
    typealias Generate = (QLThumbnailGenerator.Request, @escaping @MainActor (NSImage?, Int) -> Void) -> Void
    @Published private(set) var image: NSImage?
    private var job: UUID?
    private var generation = UUID()
    private var loadedKey: String?
    private var path: String?
    private let queue: HubThumbnailWorkQueue
    private let generate: Generate
    private let cancelRequest: (QLThumbnailGenerator.Request) -> Void

    init(queue: HubThumbnailWorkQueue? = nil, generate: Generate? = nil,
         cancel: @escaping (QLThumbnailGenerator.Request) -> Void = { QLThumbnailGenerator.shared.cancel($0) }) {
        self.queue = queue ?? .shared; self.cancelRequest = cancel
        self.generate = generate ?? { request, complete in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                Task { @MainActor in
                    guard let representation else { complete(nil, 0); return }
                    let cg = representation.cgImage
                    guard cg.width <= 1024, cg.height <= 1024 else { complete(nil, 0); return }
                    complete(representation.nsImage, cg.bytesPerRow * cg.height)
                }
            }
        }
    }
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 240
        cache.totalCostLimit = 40 * 1024 * 1024; cache.name = "FileDock.QuickLookThumbnails"; return cache
    }()
    private static func requestSide(_ size: Double) -> CGFloat { CGFloat(min(180, max(24, size.isFinite ? size : 46))) }
    static func key(for entry: FileEntry, size: Double) -> String {
        let scale = min(2, NSScreen.main?.backingScaleFactor ?? 2)
        return "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(entry.size)|\(entry.attributesModified?.timeIntervalSince1970 ?? 0)|\(Int(requestSide(size) * scale))"
    }
    static func cached(for key: String, eligible: Bool) -> NSImage? { eligible ? cache.object(forKey: key as NSString) : nil }

    func load(entry: FileEntry, size: Double, key: String, enabled: Bool = true, suspended: Bool = false) {
        guard enabled, entry.exists, !entry.isDirectory, entry.url.isFileURL else { clear(); return }
        if loadedKey != key {
            cancel()
            if path != entry.url.path { image = nil }
            path = entry.url.path; loadedKey = key
        }
        if let cached = Self.cache.object(forKey: key as NSString) {
            if image !== cached { image = cached }
            return
        }
        if suspended { cancel(); return }
        guard job == nil else { return }
        let token = generation, side = Self.requestSide(size)
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: NSSize(width: side, height: side),
            scale: min(2, NSScreen.main?.backingScaleFactor ?? 2), representationTypes: .thumbnail)
        let generate = generate, cancelRequest = cancelRequest
        job = queue.submit(start: { [weak self] finished in
            guard let self, self.generation == token else { finished(); return }
            generate(request) { [weak self] thumbnail, cost in
                finished()
                guard let self, self.generation == token else { return }
                self.job = nil
                guard let thumbnail else { self.image = nil; return }
                Self.cache.setObject(thumbnail, forKey: key as NSString, cost: max(0, cost))
                self.image = thumbnail
            }
        }, cancel: { cancelRequest(request) })
    }
    func cancel() {
        generation = UUID()
        if let job { queue.cancel(job); self.job = nil }
    }
    func clear() {
        cancel(); loadedKey = nil; path = nil
        if image != nil { image = nil }
    }
}
