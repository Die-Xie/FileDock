import AppKit
import Foundation

@main struct FileAppearanceTests {
    @MainActor static func main() throws {
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
        let red = first.icon
        precondition(first.icon === red, "An unchanged icon revision must be served from cache")
        let redPixel = center(red)
        precondition(redPixel.redComponent > redPixel.blueComponent + 0.2,
                     "The effective icon must include a custom Finder icon")

        precondition(NSWorkspace.shared.setIcon(icon(.blue), forFile: folder.path, options: []))
        model.refresh()
        let second = model.entries.first { $0.url == folder.standardizedFileURL }!
        precondition(second.snapshotSignature != first.snapshotSignature,
                     "Metadata-only appearance changes must invalidate the published entry")
        precondition(second.icon !== red, "A changed icon revision must not reuse the old image")
        let blue = second.icon
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
        let restored = newEntry.icon
        let restoredPixel = center(restored)
        precondition(restored !== generic && restoredPixel.redComponent > restoredPixel.blueComponent + 0.2,
                     "Ending a drag restores the actual custom icon; the generic placeholder never poisons the revision cache")
        print("PASS: Finder icon pixel changes, metadata refresh, label invalidation and bounded revision cache")
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
