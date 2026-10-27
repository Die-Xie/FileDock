import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum HubFolderArtwork {
    private static let readLock = NSLock()
    private static var readers = 0
    @MainActor private static let colorContext = CIContext(options: [.cacheIntermediates: false])

    static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 32000, height.doubleValue <= 32000,
              width.doubleValue * height.doubleValue <= 100_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ] as CFDictionary)
    }

    /// Bounded actual readers, including file providers still blocked after the
    /// editor's UI deadline. No mapped reads or full-resolution image decoding.
    static func readImage(_ url: URL) throws -> Data {
        _ = try HubFinderFileActions.files([url])
        readLock.lock()
        guard readers < 2 else { readLock.unlock(); throw HubFinderActionError.invalidImage }
        readers += 1; readLock.unlock()
        defer { readLock.lock(); readers -= 1; readLock.unlock() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= 16 * 1024 * 1024 else { throw HubFinderActionError.invalidImage }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        guard let data = try file.read(upToCount: 16 * 1024 * 1024 + 1), let pixels = decode(data),
              let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { throw HubFinderActionError.invalidImage }
        return png
    }

    @MainActor static func render(label: HubFinderLabel, symbol: String? = nil, emoji: String? = nil, picture: Data? = nil) -> Data? {
        let size = NSSize(width: 512, height: 512)
        let base: NSImage
        if let picture, let pixels = decode(picture) { base = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height)) }
        else { base = NSWorkspace.shared.icon(for: .folder) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let factor = min(size.width / max(1, base.size.width), size.height / max(1, base.size.height))
        let fitted = NSSize(width: base.size.width * factor, height: base.size.height * factor)
        base.draw(in: NSRect(x: (512 - fitted.width) / 2, y: (512 - fitted.height) / 2, width: fitted.width, height: fitted.height))
        if picture == nil, label != .none, let pixels = bitmap.cgImage,
           let filter = CIFilter(name: "CIColorMonochrome") {
            let source = CIImage(cgImage: pixels)
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(CIColor(color: label.color), forKey: kCIInputColorKey)
            filter.setValue(1, forKey: kCIInputIntensityKey)
            if let output = filter.outputImage, let colored = colorContext.createCGImage(output, from: source.extent) {
                NSImage(cgImage: colored, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            }
        }
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let glyph = image.withSymbolConfiguration(.init(paletteColors: [.white.withAlphaComponent(0.92)])) ?? image
            glyph.draw(in: NSRect(x: 170, y: 115, width: 172, height: 172))
        } else if let emoji, !emoji.isEmpty, emoji.count == 1, emoji.utf8.count <= 64 {
            let text = NSAttributedString(string: emoji, attributes: [.font: NSFont(name: "Apple Color Emoji", size: 172) ?? NSFont.systemFont(ofSize: 172)])
            let measured = text.size()
            text.draw(at: NSPoint(x: (512 - measured.width) / 2, y: 200 - measured.height / 2))
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
