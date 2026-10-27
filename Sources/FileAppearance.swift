import AppKit
import UniformTypeIdentifiers
import CoreImage
import Combine
import Darwin

/// Finder customization is metadata, not file contents. Snapshot it on the
/// directory worker so render/cache lookup never reads xattrs on the main actor.
struct HubFolderAppearance: Hashable, Sendable {
    var customIcon = false
    var customization = Data()
    var symbol: String? {
        guard let object = try? JSONSerialization.jsonObject(with: customization) as? [String: Any],
              let value = object["sym"] as? String, value.utf8.count <= 128 else { return nil }
        return value
    }
    static func read(_ url: URL) -> Self {
        func attribute(_ name: String, limit: Int) -> Data {
            var data = Data(count: limit)
            let count = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, limit, 0, XATTR_NOFOLLOW) }
            guard count > 0, count <= limit else { return Data() }
            data.count = count; return data
        }
        let finder = attribute("com.apple.FinderInfo", limit: 32)
        let custom = finder.count >= 10 && finder[8] & 0x04 != 0
        return Self(customIcon: custom, customization: attribute("com.apple.icon.folder#S", limit: 4096))
    }
}

/// Cache only the current icon revision for each path. Finder changes metadata
/// without necessarily changing the file's contents or modification date.
@MainActor enum HubFileIconUpdates {
    static let changes = PassthroughSubject<Set<String>, Never>()
    private static var changed = Set<String>()
    private static var scheduled = false
    private static var paused = false
    static func setPaused(_ value: Bool) {
        paused = value
        if !value { schedule() }
    }
    static func mark(_ path: String) {
        changed.insert(path)
        schedule()
    }
    private static func schedule() {
        guard !paused, !changed.isEmpty, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            scheduled = false
            guard !paused else { return }
            let paths = changed; changed = []
            changes.send(paths)
        }
    }
}

@MainActor
enum HubFileIconCache {
    static var prefersLightweight = false
    private static let workers: OperationQueue = {
        let queue = OperationQueue(); queue.name = "FileDock.FileIcons"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
        return queue
    }()
    private static var pending: [String: UUID] = [:]
    private static var outstanding = 0
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
        let folder: HubFolderAppearance
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
                                label: entry.labelNumber, tags: entry.tagNames, exists: entry.exists, folder: entry.folderAppearance)
        if let cached = cache.object(forKey: key), cached.revision == revision { return cached.image }
        // Drag tracking must not synchronously ask the file provider for every
        // newly revealed file's custom icon. Restore detailed icons on release.
        if prefersLightweight {
            if let old = cache.object(forKey: key) { return old.image }
            let type: UTType = entry.isDirectory && !entry.isPackage ? .folder : UTType(filenameExtension: entry.url.pathExtension) ?? .data
            let genericKey = type.identifier as NSString
            if let image = genericCache.object(forKey: genericKey) { return image }
            let image = NSWorkspace.shared.icon(for: type)
            genericCache.setObject(image, forKey: genericKey)
            return image
        }
        // Slow file-provider icon lookups are bounded independently of view
        // lifetime. Keep old pixels while refreshing; never block a drag/preview.
        if pending[entry.url.path] == nil, outstanding < 64 {
            let token = UUID(), path = entry.url.path
            pending[path] = token; outstanding += 1
            workers.addOperation {
                var url = URL(fileURLWithPath: path)
                url.removeAllCachedResourceValues()
                let effective = (try? url.resourceValues(forKeys: [.effectiveIconKey]))?.effectiveIcon as? NSImage
                let original = effective ?? NSWorkspace.shared.icon(forFile: path)
                let bitmap = rasterized(original) ?? original
                Task { @MainActor in
                    outstanding -= 1
                    guard pending[path] == token else { return }
                    pending.removeValue(forKey: path)
                    let image = customizedFolder(bitmap, entry: entry)
                    cache.setObject(CachedIcon(revision: revision, image: image), forKey: path as NSString, cost: 256 * 256 * 4)
                    HubFileIconUpdates.mark(path)
                }
            }
        }
        if let old = cache.object(forKey: key) { return old.image }
        let type: UTType = entry.canNavigate ? .folder : UTType(filenameExtension: entry.url.pathExtension) ?? .data
        let genericKey = type.identifier as NSString
        if let image = genericCache.object(forKey: genericKey) { return image }
        let image = NSWorkspace.shared.icon(for: type)
        genericCache.setObject(image, forKey: genericKey)
        return image
    }

    static func isCurrent(_ entry: FileEntry) -> Bool {
        cache.object(forKey: entry.url.path as NSString)?.revision == Revision(
            attributesModified: entry.attributesModified, modified: entry.modified, label: entry.labelNumber,
            tags: entry.tagNames, exists: entry.exists, folder: entry.folderAppearance)
    }

    static func invalidate(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            cache.removeObject(forKey: path as NSString)
            // Existing real workers keep their accounting; obsolete callbacks
            // cannot publish an icon captured before the explicit edit.
            pending.removeValue(forKey: path)
            HubFileIconUpdates.mark(path)
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static func customizedFolder(_ image: NSImage, entry: FileEntry) -> NSImage {
        // Tahoe uses Finder labels as folder colors. Older systems retain their
        // native tag dots; an explicit custom bitmap always takes precedence.
        guard #available(macOS 26, *), entry.canNavigate, !entry.folderAppearance.customIcon else { return image }
        let colors: [Int: NSColor] = [1: .systemGray, 2: .systemGreen, 3: .systemPurple,
                                     4: .systemBlue, 5: .systemYellow, 6: .systemRed, 7: .systemOrange]
        var base = image
        if let color = colors[entry.labelNumber], let data = image.tiffRepresentation,
           let source = CIImage(data: data), let filter = CIFilter(name: "CIColorMonochrome") {
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(CIColor(color: color), forKey: kCIInputColorKey)
            filter.setValue(1, forKey: kCIInputIntensityKey)
            if let output = filter.outputImage, let bitmap = context.createCGImage(output, from: source.extent) {
                base = NSImage(cgImage: bitmap, size: image.size)
            }
        }
        guard let name = entry.folderAppearance.symbol,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return base }
        let configured = symbol.withSymbolConfiguration(.init(paletteColors: [.white.withAlphaComponent(0.85)])) ?? symbol
        let result = NSImage(size: base.size)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        configured.draw(in: NSRect(x: base.size.width * 0.31, y: base.size.height * 0.22,
                                  width: base.size.width * 0.38, height: base.size.height * 0.38))
        result.unlockFocus()
        return result
    }

    nonisolated private static func rasterized(_ image: NSImage) -> NSImage? {
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
