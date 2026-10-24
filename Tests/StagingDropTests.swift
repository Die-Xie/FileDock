import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct StagingDropTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FileDock-StagingDrop-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try await localFilesRemainReferences(root)
        try await mixedProvidersAndTemporaryLifetime(root)
        try await serializedLoading(root)
        try await svgDocuments(root)
        print("PASS: staging drop references, raw/web images, temporary file/folder representations, partial failure and serial loading")
    }

    @MainActor private static func svgDocuments(_ root: URL) async throws {
        let bytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\"><circle cx=\"6\" cy=\"6\" r=\"5\"/></svg>".utf8)
        let source = root.appendingPathComponent("original.svg")
        try bytes.write(to: source)
        let temporary = root.appendingPathComponent("promised.svg")
        try bytes.write(to: temporary)
        let promise = TemporaryFileProvider(url: temporary, type: UTType.svg.identifier, name: "vector.svg")
        let dataOnly = DataOnlyDocumentProvider(data: bytes, type: UTType.svg.identifier, name: "data-vector")
        let store = HubStagingImportStore(rootURL: root.appendingPathComponent("svg-imports"))
        let output = try await receive([localProvider(source), promise, dataOnly], store: store)
        precondition(output.failures.isEmpty && output.urls.count == 3 && output.urls[0] == source,
                     "Local SVGs remain references; file and data-only SVG representations must both be accepted")
        for url in output.urls {
            let saved = try Data(contentsOf: url)
            precondition(saved == bytes && url.pathExtension == "svg", "SVG must remain original vector bytes, not a failed PNG conversion")
        }
        precondition(!FileManager.default.fileExists(atPath: temporary.path) && FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor private static func localFilesRemainReferences(_ root: URL) async throws {
        let source = root.appendingPathComponent("原始文件.with-an-unknown-extension")
        let folder = root.appendingPathComponent("Folder.package", isDirectory: true)
        try Data("original bytes".utf8).write(to: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested bytes".utf8).write(to: folder.appendingPathComponent("nested.bin"))
        let store = HubStagingImportStore(rootURL: root.appendingPathComponent("local-imports"))
        let result = try await receive([localProvider(source), localProvider(folder)], store: store)
        precondition(result.urls == [source, folder] && result.failures.isEmpty,
                     "Every local file extension, folder and package must remain an original-path reference")
        let sourceBytes = try Data(contentsOf: source)
        precondition(sourceBytes == Data("original bytes".utf8))
        precondition(!FileManager.default.fileExists(atPath: store.rootURL.path), "Local references must not create imported copies")

        var invoked = false
        precondition(!HubStagingDropReceiver.receive([], store: store) { _, _ in invoked = true })
        precondition(!HubStagingDropReceiver.receive([NSItemProvider()], store: store) { _, _ in invoked = true })
        precondition(!invoked, "Rejected drops must not run a completion later")
    }

    @MainActor private static func mixedProvidersAndTemporaryLifetime(_ root: URL) async throws {
        let image = try tinyPNG()
        let local = root.appendingPathComponent("mixed-original.txt")
        try Data("keep source".utf8).write(to: local)
        let temporary = root.appendingPathComponent("provider-temporary.document")
        try Data("promised file bytes".utf8).write(to: temporary)
        let temporaryFolder = root.appendingPathComponent("provider-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        try Data("promised child".utf8).write(to: temporaryFolder.appendingPathComponent("child.txt"))
        let promise = TemporaryFileProvider(url: temporary, type: UTType.data.identifier, name: "Promise.document")
        let folderPromise = TemporaryFileProvider(url: temporaryFolder, type: UTType.folder.identifier, name: "Promised Folder")
        let missingPromise = TemporaryFileProvider(url: nil, type: UTType.data.identifier, name: "Unavailable document")
        let raw = dataProvider(image, type: UTType.png.identifier, name: "raw-picture.png")
        let broken = dataProvider(Data("invalid image".utf8), type: UTType.png.identifier, name: "bad-image.png")
        let webURL = URL(string: "https://fixture.invalid/image.jpg")!
        let web = NSItemProvider(item: webURL as NSURL, typeIdentifier: UTType.url.identifier)
        var fetched: [URL] = []
        let store = HubStagingImportStore(rootURL: root.appendingPathComponent("mixed-imports"))
        let result = try await receive([localProvider(local), raw, broken, promise, folderPromise, missingPromise, web, NSItemProvider()],
                                      store: store, fetch: { url, completion in
            fetched.append(url)
            completion(.success(image))
        })
        precondition(result.urls.count == 5 && result.failures.count == 3, "Failures must not discard successful providers in the same drop")
        precondition(result.urls[0] == local && fetched == [webURL])
        precondition(result.urls[1].lastPathComponent == "raw-picture.png")
        precondition(result.urls[2].lastPathComponent == "Promise.document")
        precondition(result.urls[3].lastPathComponent == "Promised Folder")
        precondition(result.urls[4].lastPathComponent == "image.png", "Successes must retain original provider order")
        for url in [result.urls[1], result.urls[4]] {
            let data = try Data(contentsOf: url)
            precondition(CGImageSourceCreateWithData(data as CFData, nil) != nil, "Raw and web pictures must become readable stored images")
        }
        let copiedBytes = try Data(contentsOf: result.urls[2])
        let copiedChild = try Data(contentsOf: result.urls[3].appendingPathComponent("child.txt"))
        precondition(copiedBytes == Data("promised file bytes".utf8) && copiedChild == Data("promised child".utf8))
        precondition(!FileManager.default.fileExists(atPath: temporary.path) && !FileManager.default.fileExists(atPath: temporaryFolder.path),
                     "The provider fixture must remove temporary representations immediately after each callback")
        precondition(FileManager.default.fileExists(atPath: local.path), "A successful mixed batch must preserve the local source")
        precondition(promise.copiedOffMainThread && folderPromise.copiedOffMainThread,
                     "Synchronous file providers must be started on the worker, not block the main actor while copying")
        precondition(result.failures[0].hasPrefix("bad-image.png") && result.failures[1].hasPrefix("Unavailable document"))

        let failure = try await receive([web, localProvider(local)], store: store, fetch: { _, completion in
            completion(.failure(FixtureError.expected))
        })
        precondition(failure.urls == [local] && failure.failures.count == 1, "An offline download failure must not stop later file references")
    }

    @MainActor private static func serializedLoading(_ root: URL) async throws {
        let image = try tinyPNG()
        let gate = DataLoadGate()
        let first = NSItemProvider()
        first.suggestedName = "first.png"
        first.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            gate.hold(completion)
            return nil
        }
        let secondStarted = LockedFlag()
        let second = NSItemProvider()
        second.suggestedName = "second.png"
        second.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            secondStarted.set()
            completion(image, nil)
            return nil
        }
        let store = HubStagingImportStore(rootURL: root.appendingPathComponent("serial-imports"))
        var output: ([URL], [String])?
        precondition(HubStagingDropReceiver.receive([first, second], store: store) { output = ($0, $1) })
        try await wait { gate.started }
        precondition(!secondStarted.value && output == nil, "The next provider must not load while the first is pending")
        gate.release(image)
        try await wait { output != nil }
        precondition(secondStarted.value && output!.1.isEmpty && output!.0.map(\.lastPathComponent) == ["first.png", "second.png"])
    }

    @MainActor private static func receive(_ providers: [NSItemProvider], store: HubStagingImportStore,
                                           fetch: @escaping HubStagingDropReceiver.WebFetch = { _, _ in preconditionFailure("Unexpected network request") }) async throws -> (urls: [URL], failures: [String]) {
        var output: ([URL], [String])?
        var completionCount = 0
        precondition(HubStagingDropReceiver.receive(providers, store: store, fetch: fetch) {
            completionCount += 1
            output = ($0, $1)
        })
        try await wait { output != nil }
        precondition(completionCount == 1)
        return (output!.0, output!.1)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FixtureError.timeout
    }

    private static func localProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }

    private static func dataProvider(_ data: Data, type: String, name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static func tinyPNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw FixtureError.expected }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw FixtureError.expected }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.expected }
        return data as Data
    }

    private enum FixtureError: Error { case expected, timeout }

    private final class DataOnlyDocumentProvider: NSItemProvider, @unchecked Sendable {
        let data: Data
        let type: String
        init(data: Data, type: String, name: String) {
            self.data = data; self.type = type
            super.init()
            suggestedName = name
        }
        required init?(coder: NSCoder) { nil }
        override var registeredTypeIdentifiers: [String] { [type] }
        override func hasItemConformingToTypeIdentifier(_ identifier: String) -> Bool {
            UTType(type).flatMap { actual in UTType(identifier).map { actual.conforms(to: $0) } } ?? false
        }
        override func loadFileRepresentation(forTypeIdentifier: String, completionHandler: @escaping (URL?, Error?) -> Void) -> Progress {
            completionHandler(nil, FixtureError.expected)
            return Progress(totalUnitCount: 1)
        }
        override func loadDataRepresentation(forTypeIdentifier: String, completionHandler: @escaping (Data?, Error?) -> Void) -> Progress {
            completionHandler(data, nil)
            return Progress(totalUnitCount: 1)
        }
    }

    /// Precisely models NSItemProvider's documented callback-only file lifetime.
    private final class TemporaryFileProvider: NSItemProvider, @unchecked Sendable {
        let source: URL?
        let type: String
        private let offMain = LockedFlag()
        var copiedOffMainThread: Bool { offMain.value }

        init(url: URL?, type: String, name: String) {
            source = url
            self.type = type
            super.init()
            suggestedName = name
        }

        required init?(coder: NSCoder) { nil }
        override var registeredTypeIdentifiers: [String] { [type] }
        override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
            type == typeIdentifier || (UTType(type).flatMap { actual in UTType(typeIdentifier).map { actual.conforms(to: $0) } } ?? false)
        }
        override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                             completionHandler: @escaping (URL?, Error?) -> Void) -> Progress {
            if !Thread.isMainThread { offMain.set() }
            completionHandler(source, source == nil ? FixtureError.expected : nil)
            if let source { try? FileManager.default.removeItem(at: source) }
            return Progress(totalUnitCount: 1)
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
        func set() { lock.lock(); storage = true; lock.unlock() }
    }

    private final class DataLoadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: ((Data?, Error?) -> Void)?
        var started: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
        func hold(_ callback: @escaping (Data?, Error?) -> Void) {
            lock.lock(); completion = callback; lock.unlock()
        }
        func release(_ data: Data) {
            lock.lock(); let callback = completion; completion = nil; lock.unlock()
            callback?(data, nil)
        }
    }
}
