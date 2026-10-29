import AppKit
import SwiftUI

@main struct ColorLabelDropTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-ColorDrop-\(UUID())")
        let folder = root.appendingPathComponent("files", isDirectory: true)
        let child = folder.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var file = folder.appendingPathComponent("sample.svg")
        let bytes = Data("<svg><title>keep source</title></svg>".utf8)
        try bytes.write(to: file)
        var tags = URLResourceValues(); tags.tagNames = ["keep custom tag"]
        try file.setResourceValues(tags)
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        model.settings.switchDelay = 0 // Disabling hover never disables click/filter drops.
        let workspace = model.addWorkspace(name: "Drop fixture", mode: .folder, urls: [folder])!
        let state = HubPresentationState(); state.previewVisible = true
        let music = HubQQMusicController() // Never visible; no polling or authorization.
        let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: music,
            onSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let destination = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first!
        let y = host.bounds.height - 21
        let row = stride(from: CGFloat(0), to: host.bounds.width, by: 1).filter {
            destination.contains(CGPoint(x: $0, y: y))
        }
        precondition(row.count == 8 * 28, "All eight footer targets must publish their full rectangular bounds")
        let start = row.min()!
        func point(_ index: Int) -> CGPoint { CGPoint(x: start + CGFloat(index * 28) + 14, y: y) }
        precondition(destination.contains(CGPoint(x: start + 2, y: y + 11)),
                     "Drag hit testing must include target padding well outside the colored dot")
        let order = model.fileOrderURLs
        precondition(destination.operation?(point(1), [file, child], nil, false) == .copy,
                     "Finder drops onto a label must never advertise a destructive move")
        precondition(destination.receive?([file, child], nil, point(1), false) == true)
        precondition(!model.applyDroppedColorLabel(6, urls: [file]), "Overlapping metadata operations must not race on the same files")
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 7 && FileEntry(url: child).labelNumber == 7)
        precondition(FileEntry(url: file).tagNames.contains("keep custom tag"))
        let afterFinderDrop = try Data(contentsOf: file)
        precondition(afterFinderDrop == bytes)
        precondition(model.fileOrderURLs == order && fm.fileExists(atPath: child.path))

        let payload = HubFileDragPayload(id: UUID(), context: .init(workspaceID: workspace.id, directory: folder), urls: [file])
        HubFileDragState.begin(payload)
        precondition(destination.operation?(point(4), [file], payload, false) == .copy)
        precondition(destination.receive?([file], payload, point(4), false) == true)
        HubFileDragState.end(payload.id)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 4 && model.fileOrderURLs == order,
                     "A local same-folder drag must assign color rather than reorder or move the file")
        precondition(destination.receive?([file], nil, point(7), true) == true)
        try await wait(model)
        precondition(FileEntry(url: file).labelNumber == 0 && FileEntry(url: file).tagNames.contains("keep custom tag"))
        let afterRemoval = try Data(contentsOf: file)
        precondition(afterRemoval == bytes)
        precondition(!model.applyDroppedColorLabel(99, urls: [file]))
        precondition(!model.applyDroppedColorLabel(6, urls: [URL(string: "https://example.com/file")!]))
        model.settings.colorLabelFilterEnabled = false
        precondition(!model.applyDroppedColorLabel(6, urls: [file]), "Disabled settings reject a stale drop callback")
        settle(host)
        precondition(!destination.contains(point(0)) && destination.receive?([file], nil, point(0), false) == false)
        precondition(FileEntry(url: file).labelNumber == 0 && model.fileOrderURLs == order)
        print("PASS: real HubView native footer geometry, padded targets, Finder/local drop routing, metadata-only color/removal, preserved contents/location/order/custom tags, disabled/stale/invalid rejection")
        print("LIMIT: Hidden native callbacks do not reproduce a physical WindowServer drag session")
    }
    @MainActor private static func wait(_ model: HubModel) async throws {
        for _ in 0..<1000 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.fileOperationsInProgress == 0)
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
}
