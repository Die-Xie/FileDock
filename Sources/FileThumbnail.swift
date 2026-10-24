import AppKit
import SwiftUI
import QuickLookThumbnailing

/// A system file icon that upgrades to an actual thumbnail when Quick Look can provide one.
/// Quick Look renders outside this view; the app never reads or decodes arbitrary file contents.
@MainActor struct HubFileIcon: View {
    let entry: FileEntry
    let size: Double
    var allowsThumbnail = true
    var lightweight = false
    @StateObject private var loader = HubThumbnailLoader()

    var body: some View {
        Image(nsImage: loader.image ?? entry.icon)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .opacity(entry.exists ? 1 : 0.4)
            .task(id: requestKey) {
                if lightweight { loader.cancel() }
                else if allowsThumbnail { loader.load(entry: entry, size: size, key: requestKey) }
                else { loader.clear() }
            }
            .onDisappear { loader.cancel() }
    }

    private var requestKey: String {
        HubThumbnailLoader.key(for: entry, size: size) + "|thumbnail:\(allowsThumbnail)|drag:\(lightweight)"
    }
}

@MainActor private final class HubThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private var currentRequest: QLThumbnailGenerator.Request?
    private var generation = UUID()

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 40 * 1024 * 1024
        cache.name = "FileDock.QuickLookThumbnails"
        return cache
    }()

    private static func requestSide(_ size: Double) -> CGFloat {
        CGFloat(min(180, max(24, size.isFinite ? size : 46)))
    }

    static func key(for entry: FileEntry, size: Double) -> String {
        let scale = min(2, NSScreen.main?.backingScaleFactor ?? 2)
        return "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(entry.size)|\(Int(requestSide(size) * scale))"
    }

    func load(entry: FileEntry, size: Double, key: String) {
        cancel()
        image = nil
        // Native folder/package icons are already appropriate. Missing references stay visible.
        guard entry.exists, !entry.isDirectory, entry.url.isFileURL else { return }
        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            return
        }
        let token = generation
        let side = Self.requestSide(size)
        let scale = min(2, NSScreen.main?.backingScaleFactor ?? 2)
        let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                                                    size: NSSize(width: side, height: side),
                                                    scale: scale,
                                                    representationTypes: .thumbnail)
        currentRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            // The provider callback can arrive after a view was reused or disappeared.
            // Check the generation on the main actor before publishing or populating the cache.
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.currentRequest = nil
                guard let representation else { return }
                let cgImage = representation.cgImage
                guard cgImage.width <= 1024, cgImage.height <= 1024 else { return }
                let thumbnail = representation.nsImage
                let cost = cgImage.bytesPerRow * cgImage.height
                Self.cache.setObject(thumbnail, forKey: key as NSString, cost: cost)
                self.image = thumbnail
            }
        }
    }

    func cancel() {
        generation = UUID()
        if let currentRequest {
            QLThumbnailGenerator.shared.cancel(currentRequest)
            self.currentRequest = nil
        }
    }

    func clear() {
        cancel()
        image = nil
    }
}
