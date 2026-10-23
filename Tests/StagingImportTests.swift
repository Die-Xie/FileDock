import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct StagingImportTests {
    static func main() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("FileDockStagingImportTests-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let root = base.appendingPathComponent("stored", isDirectory: true)
        let store = HubStagingImportStore(rootURL: root)
        let source = base.appendingPathComponent("source.unregisteredformat")
        let bytes = Data((0...255).map(UInt8.init))
        try bytes.write(to: source)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)

        let first = try store.copyFile(at: source)
        let second = try store.copyFile(at: source)
        precondition(first != second && first.deletingLastPathComponent() != second.deletingLastPathComponent(),
                     "Identical names must receive independent import containers")
        precondition(first.lastPathComponent == source.lastPathComponent)
        try equalContents(first, bytes)
        try equalContents(second, bytes)
        try equalContents(source, bytes)
        precondition(tryMode(root) == 0o700 && tryMode(first.deletingLastPathComponent()) == 0o700)
        precondition(tryMode(first) == 0o600 && tryMode(source) == 0o644,
                     "Private destination permissions must not change the provider's source")

        for name in ["../../escape.bin", "/tmp/escape", "..\\outside", "bad\0name:line\n.bin", ".", "..", "", String(repeating: "文件", count: 200) + ".data"] {
            let saved = try store.copyFile(at: source, suggestedName: name)
            precondition(saved.deletingLastPathComponent().deletingLastPathComponent() == root)
            precondition(UUID(uuidString: saved.deletingLastPathComponent().lastPathComponent) != nil)
            precondition(!saved.lastPathComponent.contains("/") && !saved.lastPathComponent.contains("\\") &&
                         !saved.lastPathComponent.contains(":"), "Suggested names must remain a single safe component")
            precondition(saved.lastPathComponent.utf8.count <= 220)
            try equalContents(saved, bytes)
        }
        precondition(!manager.fileExists(atPath: base.appendingPathComponent("escape.bin").path))
        let named = try store.copyFile(at: source, suggestedName: "Renamed")
        precondition(named.lastPathComponent == "Renamed.unregisteredformat", "A display name without an extension preserves the file type")

        let folder = base.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try bytes.write(to: nested.appendingPathComponent("child.weird"))
        let copiedFolder = try store.copyFile(at: folder)
        try equalContents(copiedFolder.appendingPathComponent("nested/child.weird"), bytes)
        try equalContents(nested.appendingPathComponent("child.weird"), bytes)

        let package = base.appendingPathComponent("Example.app", isDirectory: true)
        let executable = package.appendingPathComponent("Contents/MacOS/tool")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let copiedPackage = try store.copyFile(at: package)
        try equalContents(copiedPackage.appendingPathComponent("Contents/MacOS/tool"), bytes)
        precondition(tryMode(copiedPackage.appendingPathComponent("Contents/MacOS/tool")) == 0o755)
        precondition(tryMode(copiedPackage) == 0o700 && tryMode(executable) == 0o755)
        let copiedExecutable = try store.copyFile(at: executable)
        precondition(tryMode(copiedExecutable) == 0o700, "Standalone executable imports retain owner execute")

        // Provider callback lifetime: saved content remains after its original
        // temporary URL and an intermediate top-level symlink disappear.
        let ephemeral = base.appendingPathComponent("provider.tmp")
        try bytes.write(to: ephemeral)
        let link = base.appendingPathComponent("provider-link.tmp")
        try manager.createSymbolicLink(at: link, withDestinationURL: ephemeral)
        let durable = try store.copyFile(at: link)
        try manager.removeItem(at: link)
        try manager.removeItem(at: ephemeral)
        try equalContents(durable, bytes)
        let values = try durable.resourceValues(forKeys: [.isSymbolicLinkKey])
        precondition(values.isSymbolicLink != true)

        let results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { results.append(try store.copyFile(at: source, suggestedName: "same.bin")) }
            catch { results.fail(error) }
        }
        precondition(results.errors.isEmpty && results.urls.count == 12)
        precondition(Set(results.urls.map { $0.deletingLastPathComponent() }).count == 12,
                     "Concurrent imports must never share a directory or overwrite a previous import")
        for url in results.urls { try equalContents(url, bytes) }

        let image = try store.saveImage(data: orientedImage(), suggestedName: "Screenshot.tiff")
        precondition(image.lastPathComponent == "Screenshot.png" && tryMode(image) == 0o600)
        let imageData = try Data(contentsOf: image)
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            preconditionFailure("Saved staging images must be readable PNGs")
        }
        precondition((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2 &&
                     (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 3)
        precondition((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let importsBeforeFailures = try manager.contentsOfDirectory(atPath: root.path).sorted()
        for size in [32 * 1024 * 1024, 32 * 1024 * 1024 + 1] {
            do {
                _ = try store.saveImage(data: Data(repeating: 0, count: size))
                preconditionFailure("Invalid or oversized image data must be rejected")
            } catch HubImageImportError.invalid {
                precondition(size == 32 * 1024 * 1024, "Exactly 32 MiB is allowed through the encoded-size check")
            } catch HubImageImportError.tooLarge {
                precondition(size > 32 * 1024 * 1024)
            }
        }
        do {
            _ = try store.copyFile(at: base.appendingPathComponent("missing"))
            preconditionFailure("Missing temporary sources must fail")
        } catch { }
        do {
            _ = try store.copyFile(at: URL(string: "https://example.invalid/file")!)
            preconditionFailure("Remote URLs are not local provider files")
        } catch HubStagingImportError.invalidLocation { }
        do {
            _ = try store.copyFile(at: base)
            preconditionFailure("Copying an ancestor of the store must not recurse into its own output")
        } catch HubStagingImportError.recursiveCopy { }

        // Cause a real failure after creating the per-import container. root
        // can read permission-denied fixtures, so this one check needs a user UID.
        if geteuid() != 0 {
            let unreadable = base.appendingPathComponent("unreadable.bin")
            try bytes.write(to: unreadable)
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
            do {
                _ = try store.copyFile(at: unreadable)
                preconditionFailure("An unreadable provider file must fail without retaining a partial import")
            } catch { }
            precondition(manager.fileExists(atPath: unreadable.path), "Failure cleanup must never remove the original")
        }
        let importsAfterFailures = try manager.contentsOfDirectory(atPath: root.path).sorted()
        precondition(importsAfterFailures == importsBeforeFailures, "Failed imports must leave existing imports untouched and no empty container")
        try equalContents(first, bytes)
        try equalContents(source, bytes)
        print("PASS: arbitrary files, directories/packages, private permissions, temporary-source independence, safe names, parallel collisions, image orientation/limits and failure cleanup")
    }

    private static func equalContents(_ url: URL, _ expected: Data) throws {
        let contents = try Data(contentsOf: url)
        precondition(contents == expected)
    }

    private static func tryMode(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func orientedImage() throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw HubImageImportError.invalid }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            throw HubImageImportError.invalid
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw HubImageImportError.invalid }
        return data as Data
    }

    private final class ConcurrentResults: @unchecked Sendable {
        private let lock = NSLock()
        private var savedURLs: [URL] = []
        private var failures: [Error] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return savedURLs }
        var errors: [Error] { lock.lock(); defer { lock.unlock() }; return failures }
        func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; savedURLs.append(url) }
        func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; failures.append(error) }
    }
}
