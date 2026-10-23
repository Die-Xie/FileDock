import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct ImageImportTests {
    static func main() throws {
        let tiny = try tinyPNG()
        let output = try HubImageImport.pngData(from: tiny)
        guard let source = CGImageSourceCreateWithData(output as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            preconditionFailure("Imported PNG must be readable")
        }
        precondition((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2)
        precondition((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 3)
        precondition(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "Roundtrip must preserve a decodable image")

        // Six distinct pixels make rotation and mirroring observable, not just
        // the output dimensions. TIFF keeps these fixture colors lossless.
        let orientationPixels: [Int: [Int]] = [
            1: [0, 1, 2, 3, 4, 5],
            2: [2, 1, 0, 5, 4, 3],
            3: [5, 4, 3, 2, 1, 0],
            4: [3, 4, 5, 0, 1, 2],
            5: [0, 3, 1, 4, 2, 5],
            6: [3, 0, 4, 1, 5, 2],
            7: [5, 2, 4, 1, 3, 0],
            8: [2, 5, 1, 4, 0, 3]
        ]
        for orientation in 1...8 {
            let input = try orientedImage(orientation: orientation, type: .tiff)
            let normalized = try HubImageImport.pngData(from: input)
            let image = try decodedImage(normalized)
            let swapsAxes = orientation >= 5
            precondition(image.width == (swapsAxes ? 2 : 3) && image.height == (swapsAxes ? 3 : 2),
                         "Orientation normalization must preserve every original pixel")
            let actualPixels = try pixelIDs(image)
            precondition(actualPixels == orientationPixels[orientation],
                         "EXIF orientation \(orientation) must be baked into the PNG pixels")
            let normalizedOrientation = try sourceOrientation(normalized)
            precondition(normalizedOrientation == 1,
                         "The transformed PNG must not retain a second rotation or mirror instruction")
        }
        for orientation in [6, 8] {
            let normalized = try HubImageImport.pngData(from: orientedImage(orientation: orientation, type: .jpeg))
            let image = try decodedImage(normalized)
            let normalizedOrientation = try sourceOrientation(normalized)
            precondition(image.width == 2 && image.height == 3 && normalizedOrientation == 1,
                         "Rotated camera JPEGs must retain full resolution with a normalized orientation")
        }

        for invalid in [Data(), Data("not an image".utf8), Data([0x89, 0x50, 0x4E, 0x47])] {
            do {
                _ = try HubImageImport.pngData(from: invalid)
                preconditionFailure("Invalid image input must be rejected")
            } catch HubImageImportError.invalid { }
        }
        do {
            _ = try HubImageImport.pngData(from: Data(repeating: 0, count: 32 * 1024 * 1024 + 1))
            preconditionFailure("Encoded input cap must be enforced before parsing")
        } catch HubImageImportError.tooLarge { }

        // Alter metadata headers only: no large pixel buffer is allocated.
        // The PNG exercises the side cap; JPEG exercises the total-pixel cap
        // because ImageIO independently rejects huge PNGs with tiny IDAT data.
        let oversizedFixtures: [(Data, UInt32, UInt32)] = [
            (png(tiny, declaringWidth: 8193, height: 1), 8193, 1),
            (try jpeg(declaringWidth: 6000, height: 5000), 6000, 5000)
        ]
        for (oversized, width, height) in oversizedFixtures {
            guard let header = CGImageSourceCreateWithData(oversized as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(header, 0, nil) as? [CFString: Any] else {
                preconditionFailure("Oversized fixture must expose valid header metadata")
            }
            precondition((metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value == width)
            precondition((metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value == height)
            do {
                _ = try HubImageImport.pngData(from: oversized)
                preconditionFailure("Oversized dimensions must be rejected before decoding")
            } catch HubImageImportError.dimensions { }
        }
        print("PASS: PNG roundtrip, all EXIF rotations/mirrors without downsampling, rotated JPEGs, invalid images and header limits")
    }

    private static let colors: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
        [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255]
    ]

    private static func orientedImage(orientation: Int, type: UTType) throws -> Data {
        let bytes = Data(colors.flatMap { $0 })
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 12, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw HubImageImportError.invalid
        }
        let result = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else {
            throw HubImageImportError.invalid
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw HubImageImportError.invalid }
        let data = result as Data
        let storedOrientation = try sourceOrientation(data)
        precondition(storedOrientation == orientation, "The fixture must contain its EXIF orientation")
        return data
    }

    private static func sourceOrientation(_ data: Data) throws -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw HubImageImportError.invalid
        }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private static func decodedImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw HubImageImportError.invalid }
        return image
    }

    private static func pixelIDs(_ image: CGImage) throws -> [Int] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw HubImageImportError.invalid }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { pixel in
            guard let id = colors.firstIndex(where: { color in
                (0..<4).allSatisfy { abs(Int(color[$0]) - Int(bytes[pixel * 4 + $0])) <= 1 }
            }) else { preconditionFailure("Orientation conversion must preserve the fixture's pixel colors") }
            return id
        }
    }

    private static func tinyPNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw HubImageImportError.invalid }
        let result = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw HubImageImportError.invalid
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw HubImageImportError.invalid }
        return result as Data
    }

    private static func png(_ original: Data, declaringWidth width: UInt32, height: UInt32) -> Data {
        var result = original
        precondition(result.count > 33 && String(data: result[12..<16], encoding: .ascii) == "IHDR")
        writeBigEndian(width, into: &result, at: 16)
        writeBigEndian(height, into: &result, at: 20)
        writeBigEndian(crc32(result[12..<29]), into: &result, at: 29)
        return result
    }

    private static func jpeg(declaringWidth width: UInt16, height: UInt16) throws -> Data {
        let tiny = try tinyPNG()
        guard let source = CGImageSourceCreateWithData(tiny as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw HubImageImportError.invalid }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HubImageImportError.invalid
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw HubImageImportError.invalid }
        var result = output as Data
        for index in 0..<(result.count - 9) where result[index] == 0xFF && [0xC0, 0xC1, 0xC2].contains(result[index + 1]) {
            result[index + 5] = UInt8(height >> 8); result[index + 6] = UInt8(height & 0xFF)
            result[index + 7] = UInt8(width >> 8); result[index + 8] = UInt8(width & 0xFF)
            return result
        }
        throw HubImageImportError.invalid
    }

    private static func writeBigEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(24 - 8 * index)) & 0xFF) }
    }

    private static func crc32(_ bytes: Data.SubSequence) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return crc ^ UInt32.max
    }
}
