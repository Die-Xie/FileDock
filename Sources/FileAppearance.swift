import AppKit
import UniformTypeIdentifiers

/// Cache only the current icon revision for each path. Finder changes metadata
/// without necessarily changing the file's contents or modification date.
@MainActor
enum HubFileIconCache {
    static var prefersLightweight = false
    private static let genericCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    private struct Revision: Equatable {
        let attributesModified: Date?
        let modified: Date?
        let label: Int
        let tags: [String]
        let exists: Bool
    }
    private final class CachedIcon {
        let revision: Revision
        let image: NSImage
        init(revision: Revision, image: NSImage) { self.revision = revision; self.image = image }
    }
    private static let cache: NSCache<NSString, CachedIcon> = {
        let result = NSCache<NSString, CachedIcon>()
        result.countLimit = 256
        result.totalCostLimit = 32 * 1024 * 1024
        return result
    }()

    static func image(for entry: FileEntry) -> NSImage {
        let key = entry.url.path as NSString
        let revision = Revision(attributesModified: entry.attributesModified, modified: entry.modified,
                                label: entry.labelNumber, tags: entry.tagNames, exists: entry.exists)
        if let cached = cache.object(forKey: key), cached.revision == revision { return cached.image }
        // Drag tracking must not synchronously ask the file provider for every
        // newly revealed file's custom icon. Restore detailed icons on release.
        if prefersLightweight {
            let type: UTType = entry.isDirectory && !entry.isPackage ? .folder : UTType(filenameExtension: entry.url.pathExtension) ?? .data
            let genericKey = type.identifier as NSString
            if let image = genericCache.object(forKey: genericKey) { return image }
            let image = NSWorkspace.shared.icon(for: type)
            genericCache.setObject(image, forKey: genericKey)
            return image
        }
        // Ask for the effective icon, including Finder's folder customization.
        // A fresh URL must not reuse a cached resource value from an old scan.
        var url = URL(fileURLWithPath: entry.url.path)
        url.removeAllCachedResourceValues()
        let effective = (try? url.resourceValues(forKeys: [.effectiveIconKey]))?.effectiveIcon as? NSImage
        let original = effective ?? NSWorkspace.shared.icon(forFile: entry.url.path)
        // Icon-family reps may advertise every scale at once. Keep a bounded
        // bitmap sufficient for the largest 100pt file icon on a Retina screen.
        let image = rasterized(original) ?? ((original.copy() as? NSImage) ?? original)
        cache.setObject(CachedIcon(revision: revision, image: image), forKey: key, cost: 256 * 256 * 4)
        return image
    }

    private static func rasterized(_ image: NSImage) -> NSImage? {
        var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                      bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(256 / CGFloat(source.width), 256 / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (256 - size.width) / 2, y: (256 - size.height) / 2,
                                       width: size.width, height: size.height))
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: 128, height: 128))
    }
}
