import AppKit
import Foundation
import UniformTypeIdentifiers

private final class ClipboardGate: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return starts }
    func enter() {
        precondition(!Thread.isMainThread)
        lock.lock(); starts += 1; lock.unlock()
        precondition(gate.wait(timeout: .now() + 10) == .success)
    }
}

@main struct ClipboardTests {
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Clipboard work did not complete")
    }
    @MainActor private static func idle(_ model: HubModel) async throws {
        try await wait { !HubImportActivity.isBusy && model.fileOperationsInProgress == 0 && HubClipboardReader.activeWorkers == 0 }
    }
    @MainActor private static func image(_ format: NSBitmapImageRep.FileType) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<3 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.6, blue: 0.3, alpha: 1), atX: x, y: y) } }
        return bitmap.representation(using: format, properties: [:])!
    }
    @MainActor private static func write(_ objects: [NSPasteboardWriting], to board: NSPasteboard) {
        board.clearContents(); precondition(board.writeObjects(objects))
    }
    @MainActor private static func read(_ board: NSPasteboard) async throws -> HubClipboardContents {
        var result: Result<HubClipboardContents, Error>?
        precondition(HubClipboardReader.receive(from: board) { result = $0 })
        try await wait { result != nil }
        return try result!.get()
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-Clipboard-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let svg = source.appendingPathComponent("一张图.svg"), folder = source.appendingPathComponent("folder")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"3\" height=\"2\"><rect width=\"3\" height=\"2\"/></svg>".utf8)
        try svgData.write(to: svg); try Data("child".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let sourceTab = model.addWorkspace(name: "Source", mode: .folder, urls: [source])!
        let targetTab = model.addWorkspace(name: "Target", mode: .folder, urls: [destination])!
        let references = model.addWorkspace(name: "收藏", mode: .references, urls: [])!
        let store = HubStagingImportStore(rootURL: root.appendingPathComponent("imports"))

        // Read real private pasteboards, never the user's general clipboard.
        write([svg as NSURL, folder as NSURL], to: board)
        let files = try await read(board)
        precondition(files.fileURLs == [svg, folder])
        model.selectWorkspace(targetTab.id)
        model.pasteFiles(from: board, store: store)
        precondition(HubImportActivity.isBusy, "System clipboard reads must not block the UI")
        model.selectWorkspace(sourceTab.id)
        try await idle(model)
        let copiedSVG = try Data(contentsOf: destination.appendingPathComponent(svg.lastPathComponent))
        precondition(copiedSVG == svgData)
        precondition(manager.fileExists(atPath: destination.appendingPathComponent("folder/child.txt").path))
        precondition(!manager.fileExists(atPath: source.appendingPathComponent("folder copy").path))
        precondition(manager.fileExists(atPath: svg.path), "Paste into folders copies instead of removing the source")
        model.selectWorkspace(targetTab.id); model.pasteFiles(from: board, store: store)
        try await idle(model)
        precondition(manager.fileExists(atPath: destination.appendingPathComponent("一张图 copy.svg").path))
        model.selectWorkspace(references.id); model.pasteFiles(from: board, store: store)
        try await idle(model)
        precondition(model.selectedWorkspace!.referencePaths == [svg.path, folder.path])
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.selectedWorkspace!.referencePaths.count == 2, "Reference paste must deduplicate")
        model.openStagingWorkspace(); let stagingID = model.selectedWorkspaceID!
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.stagedURLs.map(\.path) == [svg.path, folder.path])

        // File URLs beat raster fallback data, even when the local file is SVG.
        let png = image(.png), tiff = image(.tiff)
        let representedFile = NSPasteboardItem()
        representedFile.setString(svg.absoluteString, forType: .fileURL)
        representedFile.setData(png, forType: .png)
        write([representedFile], to: board)
        let preferredFile = try await read(board)
        precondition(preferredFile.fileURLs == [svg])
        let corrupt = NSPasteboardItem()
        corrupt.setString("https://example.invalid/fake.svg", forType: .fileURL)
        corrupt.setData(png, forType: .png)
        write([corrupt], to: board)
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.errorMessage != nil && model.stagedURLs.map(\.path) == [svg.path, folder.path])
        precondition(!manager.fileExists(atPath: store.rootURL.path), "Invalid file URLs cannot fall back to image imports")

        // Screenshot-style TIFF is materialized into a private persistent PNG.
        func screenshot() -> NSPasteboardItem { let item = NSPasteboardItem(); item.setData(tiff, forType: .tiff); return item }
        write([screenshot()], to: board); model.errorMessage = nil
        model.selectWorkspace(stagingID); model.pasteFiles(from: board, store: store)
        model.selectWorkspace(sourceTab.id)
        try await idle(model)
        let stagedImage = model.stagedURLs.first { $0.pathExtension == "png" }!
        let stagedPixels = try Data(contentsOf: stagedImage), normalized = try HubImageImport.pngData(from: tiff)
        precondition(stagedPixels == normalized)
        precondition(model.selectedWorkspaceID == sourceTab.id && model.errorMessage == nil)
        let attributes = try manager.attributesOfItem(atPath: stagedImage.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        write([screenshot()], to: board); model.selectWorkspace(targetTab.id)
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(manager.fileExists(atPath: destination.appendingPathComponent("剪贴板图片.png").path))
        model.selectWorkspace(references.id); model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.selectedWorkspace!.referencePaths.contains { $0.hasSuffix("剪贴板图片.png") })

        // A read ticket must hand off to the image writer even while another
        // import occupies the second shared slot.
        model.selectWorkspace(stagingID); write([screenshot()], to: board)
        let previousStagedCount = model.stagedURLs.count, otherTicket = HubImportActivity.begin()!
        model.pasteFiles(from: board, store: store)
        try await wait { model.stagedURLs.count == previousStagedCount + 1 }
        HubImportActivity.end(otherTicket); try await idle(model)

        let vector = NSPasteboardItem(); vector.setData(svgData, forType: .init(UTType.svg.identifier))
        write([vector], to: board); model.selectWorkspace(stagingID)
        model.pasteFiles(from: board, store: store); try await idle(model)
        let vectorURL = model.stagedURLs.first { $0.lastPathComponent == "剪贴板图片.svg" }!
        let storedVector = try Data(contentsOf: vectorURL)
        precondition(storedVector == svgData)
        let savedPaths = model.stagedURLs
        board.clearContents(); board.setString("ordinary text", forType: .string)
        model.errorMessage = nil; model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.errorMessage != nil && model.stagedURLs == savedPaths, "Text must not silently turn into a file")
        board.clearContents(); model.errorMessage = nil
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.errorMessage != nil && model.stagedURLs == savedPaths)
        let unsupported = NSPasteboardItem(); unsupported.setString("text", forType: .string)
        write([svg as NSURL, unsupported], to: board); model.errorMessage = nil
        model.pasteFiles(from: board, store: store); try await idle(model)
        precondition(model.errorMessage != nil && model.stagedURLs == savedPaths,
                     "Malformed mixed clipboard batches must not paste only their valid subset")
        do {
            let oversized = NSPasteboardItem()
            oversized.setData(Data(repeating: 0, count: 32 * 1024 * 1024 + 1), forType: .png)
            write([oversized], to: board); model.errorMessage = nil
            model.pasteFiles(from: board, store: store); try await idle(model)
            precondition(model.errorMessage == HubClipboardError.tooLarge.localizedDescription && model.stagedURLs == savedPaths)
        }
        let removedFolder = root.appendingPathComponent("removed-target")
        try manager.createDirectory(at: removedFolder, withIntermediateDirectories: false)
        let removed = model.addWorkspace(name: "Removed", mode: .folder, urls: [removedFolder])!
        model.selectWorkspace(removed.id); write([svg as NSURL], to: board)
        model.errorMessage = nil; model.pasteFiles(from: board, store: store)
        model.removeWorkspace(removed.id); try await idle(model)
        precondition(model.errorMessage != nil && !manager.fileExists(atPath: removedFolder.appendingPathComponent(svg.lastPathComponent).path),
                     "Removing a paste target before its read completes must prevent file writes")
        let recent = model.addRecentWorkspace()!; model.selectWorkspace(recent.id)
        precondition(!model.canPasteFiles)
        model.pasteFiles(from: board, store: store)
        precondition(!HubImportActivity.isBusy && model.errorMessage != nil)

        // A changed clipboard rejects the entire read, including otherwise valid
        // earlier items. A timed-out reader cannot add imports on its late return.
        write([svg as NSURL], to: board)
        let changedGate = ClipboardGate()
        var changedResult: Result<HubClipboardContents, Error>?
        precondition(HubClipboardReader.receive(from: board, read: { _, _ in
            changedGate.enter(); return HubClipboardContents(items: [.file(svg)])
        }) { changedResult = $0 })
        try await wait { changedGate.count == 1 }
        write([folder as NSURL], to: board); changedGate.gate.signal()
        try await wait { changedResult != nil && HubClipboardReader.activeWorkers == 0 }
        if case .failure(let error) = changedResult { precondition(error as? HubClipboardError == .changed) }
        else { preconditionFailure("Changed clipboard was accepted") }
        let stalled = ClipboardGate(); var callbacks = 0
        for _ in 0..<2 {
            precondition(HubClipboardReader.receive(from: board, timeout: 0.05, read: { name, cancelled in
                stalled.enter()
                precondition(cancelled(), "A timed-out read must stop before requesting any more clipboard data")
                return try HubClipboardContents.read(name: name, cancelled: cancelled)
            }) { result in
                if case .failure(let error) = result { precondition(error as? HubClipboardError == .timedOut) }
                else { preconditionFailure("Stalled read must time out") }
                callbacks += 1
            })
        }
        try await wait { stalled.count == 2 && callbacks == 2 }
        precondition(!HubImportActivity.isBusy && HubClipboardReader.activeWorkers == 2)
        precondition(!HubClipboardReader.receive(from: board) { _ in preconditionFailure("Timed-out workers cannot flood the queue") })
        stalled.gate.signal(); stalled.gate.signal()
        try await wait { HubClipboardReader.activeWorkers == 0 }
        precondition(callbacks == 2 && model.stagedURLs == savedPaths)

        for modifier: NSEvent.ModifierFlags in [.command, .control, [.command, .capsLock]] {
            precondition(HubClipboardShortcut.resolve(keyCode: 8, modifiers: modifier) == .copy)
            precondition(HubClipboardShortcut.resolve(keyCode: 9, modifiers: modifier) == .paste)
        }
        precondition(HubClipboardShortcut.resolve(keyCode: 8, modifiers: [.command, .option]) == .copyPaths)
        for modifier: NSEvent.ModifierFlags in [[], [.control, .option], [.command, .shift], [.command, .control]] {
            precondition(HubClipboardShortcut.resolve(keyCode: 9, modifiers: modifier) == nil)
        }
        print("PASS: native clipboard file/folder/SVG priority, folder copy/collisions, favorite/staging references, TIFF/PNG/vector persistence, captured destination, unsupported/invalid content, clipboard changes, bounded stalled workers, late-result isolation and Command/Control shortcuts")
    }
}
