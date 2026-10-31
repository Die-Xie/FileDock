import AppKit
import SwiftUI

@MainActor private final class ContextMenuProbeApplication: NSApplication {
    var injectedEvent: NSEvent?
    override var currentEvent: NSEvent? { injectedEvent ?? super.currentEvent }
}

@main struct BackgroundContextMenuTests {
    @MainActor static func main() throws {
        let app = ContextMenuProbeApplication.shared as! ContextMenuProbeApplication
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-ContextMenu-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = folder.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let model = makeTestModel(storageURL: root.appendingPathComponent("settings.json"))
        model.addWorkspace(name: "Folder", mode: .folder, urls: [folder])
        let state = HubPresentationState(); state.previewVisible = true
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: HubQQMusicController(), onSettings: {}, onClose: {}))
        window.contentView = host
        defer { app.injectedEvent = nil; window.contentView = nil; window.close() }
        func settle() { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menu(at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSMenu? {
            let event = NSEvent.mouseEvent(with: flags.contains(.control) ? .leftMouseDown : .rightMouseDown,
                location: host.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            app.injectedEvent = event
            return host.menu(for: event)
        }
        func names(_ menu: NSMenu?) -> [String] { menu?.items.map { $0.title } ?? [] }
        settle()
        precondition(model.visibleEntries.contains { $0.url == file })
        for mode in [HubViewMode.grid, .list, .columns] {
            model.viewMode = mode; settle()
            let all = descendants(host)
            guard let selection = all.compactMap({ $0 as? HubMarqueeSelectionBridge.SelectionView }).first,
                  let item = all.compactMap({ $0 as? HubFileDragBridge.FileDragView }).first(where: { $0.entryURL == file }) else {
                preconditionFailure("Each populated view must have a selection area and real file target")
            }
            let area = host.convert(selection.bounds.intersection(selection.visibleRect), from: selection)
            let fileRect = host.convert(item.bounds.intersection(item.visibleRect), from: item)
            let fileNames = names(menu(at: NSPoint(x: fileRect.midX, y: fileRect.midY)))
            precondition(fileNames.contains("打开") && fileNames.contains("重新命名…") && !fileNames.contains("新建文件夹…"),
                         "File right-click must retain the file menu in \(mode)")
            var blank: NSPoint?
            for fy in [0.85, 0.65, 0.45] where blank == nil {
                for fx in [0.5, 0.8, 0.2] {
                    let point = NSPoint(x: area.minX + area.width * fx, y: area.minY + area.height * fy)
                    guard !fileRect.contains(point) else { continue }
                    if names(menu(at: point)).contains("新建文件夹…") { blank = point; break }
                }
            }
            guard let blank, let background = menu(at: blank) else { preconditionFailure("A visible blank area must expose the directory menu in \(mode)") }
            let titles = names(background)
            for title in ["新建文件夹…", "显示简介", "显示", "排序方式", "在访达中打开", "显示选项…"] {
                precondition(titles.contains(title), "Missing \(title) from the real background menu in \(mode)")
            }
            precondition(!titles.contains("打开") && !titles.contains("重新命名…"), "Blank space must not open an item menu")
            precondition(names(menu(at: blank, flags: .control)).contains("新建文件夹…"), "Control-click must expose the same background menu")
            if mode == .columns {
                let parentPoint = NSPoint(x: max(5, area.minX - 15), y: blank.y)
                precondition(!names(menu(at: parentPoint)).contains("新建文件夹…"), "Parent column blank space must not act on the current folder")
            }
        }
        print("PASS: real hidden SwiftUI host resolves folder background and item menus separately in grid, list and columns; Control-click and parent-column exclusion")
        print("LIMIT: Hidden native menus do not verify visible WindowServer presentation or menu actions")
    }
}
