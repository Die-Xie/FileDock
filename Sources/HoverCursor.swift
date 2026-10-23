import AppKit

/// Stable for the app's lifetime: an I-beam, resize cursor, drag cursor or
/// another app changing NSCursor.currentSystem cannot alter notch eligibility.
@MainActor
enum HubHoverCursor {
    static let footprint = makeFootprint(image: NSCursor.arrow.image, hotSpot: NSCursor.arrow.hotSpot)

    static func makeFootprint(image: NSImage, hotSpot: NSPoint) -> HubCursorFootprint? {
        // NSImage may choose the 10x representation of the system cursor.
        // A fixed 2x raster is subpoint-accurate without keeping its huge mask.
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 256, image.size.height <= 256 else { return nil }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else { return nil }
        let width = Int(ceil(image.size.width * 2)), height = Int(ceil(image.size.height * 2))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // CGImage data and this unflipped bitmap context preserve row order:
            // row zero is the top of the source image, including its padding.
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        return HubCursorFootprint(alpha: alpha, pixelsWide: width, pixelsHigh: height,
                                  imageSize: image.size, hotSpot: hotSpot)
    }
}
