import AppKit
import Foundation
import Darwin

@main struct FileAppearanceTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("HubIconTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = makeTestModel(storageURL: base.appendingPathComponent("config.json"))
        model.addWorkspace(name: "Fixture", mode: .folder, urls: [base])
        model.navigate(to: base)

        precondition(NSWorkspace.shared.setIcon(icon(.red), forFile: folder.path, options: []))
        model.refresh()
        let first = model.entries.first { $0.url == folder.standardizedFileURL }!
        let red = try await loadedIcon(first)
        precondition(first.icon === red, "An unchanged icon revision must be served from cache")
        let redPixel = center(red)
        precondition(redPixel.redComponent > redPixel.blueComponent + 0.2,
                     "The effective icon must include a custom Finder icon")

        precondition(NSWorkspace.shared.setIcon(icon(.blue), forFile: folder.path, options: []))
        model.refresh()
        let second = model.entries.first { $0.url == folder.standardizedFileURL }!
        precondition(second.snapshotSignature != first.snapshotSignature,
                     "Metadata-only appearance changes must invalidate the published entry")

        let blue = try await loadedIcon(second)
        precondition(blue !== red)
        let bluePixel = center(blue)
        precondition(bluePixel.blueComponent > bluePixel.redComponent + 0.2,
                     "The icon cache must refresh the actual pixels after a customization")

        var resourceURL = folder
        var values = URLResourceValues(); values.labelNumber = 6
        try resourceURL.setResourceValues(values)
        model.refresh()
        let labeled = model.entries.first { $0.url == folder.standardizedFileURL }!
        precondition(labeled.labelNumber == 6 && labeled.snapshotSignature != second.snapshotSignature,
                     "Finder label changes must be detected even without a content change")
        let uncached = base.appendingPathComponent("new-folder")
        try fm.createDirectory(at: uncached, withIntermediateDirectories: true)
        precondition(NSWorkspace.shared.setIcon(icon(.red), forFile: uncached.path, options: []))
        let newEntry = FileEntry(url: uncached)
        HubFileIconCache.prefersLightweight = true
        precondition(second.icon === blue, "Valid detailed icons remain cached while dragging")
        let generic = newEntry.icon
        precondition(newEntry.icon === generic, "Uncached entries share a cheap type icon while dragging")
        HubFileIconCache.prefersLightweight = false
        let restored = try await loadedIcon(newEntry)
        let restoredPixel = center(restored)
        precondition(restored !== generic && restoredPixel.redComponent > restoredPixel.blueComponent + 0.2,
                     "Ending a drag restores the actual custom icon; the generic placeholder never poisons the revision cache")
        // Native Tahoe colors do not produce a custom bitmap through setIcon.
        // Test real Finder label metadata and rendered pixels separately.
        precondition(NSWorkspace.shared.setIcon(nil, forFile: uncached.path, options: []))
        var coloredURL = uncached
        var greenValues = URLResourceValues(); greenValues.labelNumber = 2
        try coloredURL.setResourceValues(greenValues)
        let greenEntry = FileEntry(url: uncached)
        let greenIcon = try await loadedIcon(greenEntry)
        var redValues = URLResourceValues(); redValues.labelNumber = 6
        try coloredURL.setResourceValues(redValues)
        let redEntry = FileEntry(url: uncached)
        let redIcon = try await loadedIcon(redEntry)
        if #available(macOS 26, *) {
            let green = center(greenIcon), red = center(redIcon)
            precondition(green.greenComponent > green.redComponent)
            precondition(red.redComponent > red.greenComponent)
        }
        precondition(greenEntry.snapshotSignature != redEntry.snapshotSignature)
        let bytes = Data("{\"sym\":\"camera.viewfinder\"}".utf8)
        let changed = bytes.withUnsafeBytes { setxattr(uncached.path, "com.apple.icon.folder#S", $0.baseAddress, bytes.count, 0, 0) }
        precondition(changed == 0)
        let symbolEntry = FileEntry(url: uncached)
        precondition(symbolEntry.folderAppearance.symbol == "camera.viewfinder")
        precondition(symbolEntry.snapshotSignature != redEntry.snapshotSignature)
        _ = try await loadedIcon(symbolEntry)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<500 { _ = symbolEntry.icon }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 0.5, "Cached icon renders must not read the filesystem")
        print("Cached icon lookup x500: \(String(format: "%.4f", elapsed))s")
        print("PASS: Finder icon pixel changes, metadata refresh, label invalidation and bounded revision cache")
    }

    @MainActor private static func loadedIcon(_ entry: FileEntry) async throws -> NSImage {
        for _ in 0..<500 {
            let image = entry.icon
            if HubFileIconCache.isCurrent(entry) { return image }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Icon load timed out")
    }

    @MainActor private static func icon(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
            color.setFill(); bounds.fill(); return true
        }
    }

    @MainActor private static func center(_ image: NSImage) -> NSColor {
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)!.usingColorSpace(.deviceRGB)!
    }
}
