import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HubImageImportError: LocalizedError {
    case tooLarge, invalid, dimensions
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "图片文件超过 32 MB，未保存。"
        case .invalid: return "无法读取拖入的图片。"
        case .dimensions: return "图片尺寸超过 8192 像素或 2400 万像素，未保存。"
        }
    }
}

/// Reads image headers before decoding. Call on a worker queue, never the UI queue.
enum HubImageImport {
    static let workerQueue = DispatchQueue(label: "FolderHubReplica.ImageImport", qos: .userInitiated)
    static func pngData(from data: Data) throws -> Data {
        guard data.count <= 32 * 1024 * 1024 else { throw HubImageImportError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw HubImageImportError.invalid }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 24_000_000 else {
            throw HubImageImportError.dimensions
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if (2...8).contains(orientation) {
            // Decode the full source, never an embedded camera thumbnail, and
            // bake EXIF rotation/mirroring into the pixels before stripping
            // metadata. The original longest edge prevents downsampling.
            let transformedOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(w, h))
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, transformedOptions as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, options)
        }
        guard let image else { throw HubImageImportError.invalid }
        let swapsAxes = (5...8).contains(orientation)
        guard image.width == Int(swapsAxes ? h : w), image.height == Int(swapsAxes ? w : h) else {
            throw HubImageImportError.dimensions
        }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw HubImageImportError.invalid
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(writer), output.length <= 64 * 1024 * 1024 else { throw HubImageImportError.tooLarge }
        return output as Data
    }
}
