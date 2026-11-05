import AppKit
import SwiftUI

@MainActor private final class MenuPickerProbeApplication: NSApplication {
    var injectedEvent: NSEvent?
    override var currentEvent: NSEvent? { injectedEvent ?? super.currentEvent }
}

/// Opt-in visible native regression. Uses the real SwiftUI background menu's
/// target/action and real open panels, but never posts user input to the OS.
/// Every picker is automatically cancelled; user configuration is never read.
@main struct ContextMenuPickerLifecycleTests {
    @MainActor static func main() throws {
        let app = MenuPickerProbeApplication.shared as! MenuPickerProbeApplication
        app.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-MenuPicker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.md")
        try Data("fixture".utf8).write(to: file)
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        model.addWorkspace(name: "References", mode: .references, urls: [file])
        let presentation = HubPresentationState(); presentation.previewVisible = true
        let browser = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 720, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        browser.level = .statusBar
        let host = NSHostingView(rootView: HubView(model: model, presentation: presentation,
            music: HubQQMusicController(), onSettings: {}, onClose: {}))
        browser.contentView = host
        browser.orderFrontRegardless()
        HubWindowPresentation.backgroundWindows = { [browser] }
        defer {
            HubWindowPresentation.backgroundWindows = nil
            HubWindowPresentation.modalStateDidChange = nil
            app.injectedEvent = nil
            browser.orderOut(nil); browser.contentView = nil; browser.close()
        }
        func settle() {
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let frame = browser.frame, pinned = model.pinned
        var transitions: [Bool] = []
        var launchModes: [RunLoop.Mode?] = []
        HubWindowPresentation.modalStateDidChange = { active in
            transitions.append(active)
            if active { launchModes.append(RunLoop.current.currentMode) }
        }

        func check(_ menu: NSMenu, at itemIndex: Int) {
            let before = transitions.count
            var observed = false
            var failure: String?
            let cancel = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let picker = NSApp.modalWindow as? NSOpenPanel, picker.isVisible else { return }
                    observed = true
                    if picker.level.rawValue <= browser.level.rawValue { failure = "Picker behind browser" }
                    if browser.frame != frame || model.pinned != pinned { failure = "Picker moved or pinned browser" }
                    picker.cancel(nil)
                }
            }
            let timeout = Timer(timeInterval: 8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let picker = NSApp.modalWindow as? NSSavePanel { picker.cancel(nil) }
                    else if let window = NSApp.modalWindow { NSApp.abortModal(); window.orderOut(nil) }
                }
            }
            for runMode in [RunLoop.Mode.common, .modalPanel] {
                RunLoop.main.add(cancel, forMode: runMode); RunLoop.main.add(timeout, forMode: runMode)
            }
            var invoked = false
            let invoke: @MainActor () -> Void = { menu.performActionForItem(at: itemIndex); invoked = true }
            RunLoop.main.perform(inModes: [.eventTracking]) { MainActor.assumeIsolated { invoke() } }
            for _ in 0..<3 { RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01)) }
            precondition(invoked && transitions.count == before,
                         "Real menu action must return without opening a picker in tracking mode")
            let deadline = Date().addingTimeInterval(10)
            while transitions.count < before + 2 && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            cancel.invalidate(); timeout.invalidate()
            precondition(observed && failure == nil, failure ?? "Picker did not appear")
            precondition(Array(transitions.suffix(2)) == [true, false] && !HubWindowPresentation.isPresentingDialog && NSApp.modalWindow == nil,
                         "Cancellation releases the complete modal scope")
            precondition(!NSApp.windows.contains { $0.attachedSheet != nil }, "No sheet can hold auto-hide after completion")
            precondition(browser.frame == frame && model.pinned == pinned && browser.level == .statusBar)
        }

        for mode in [HubViewMode.grid, .list, .columns] {
            model.viewMode = mode
            settle()
            guard let area = descendants(host).compactMap({ $0 as? HubMarqueeSelectionBridge.SelectionView }).first else {
                preconditionFailure("Missing real selection surface")
            }
            let bounds = host.convert(area.bounds.intersection(area.visibleRect), from: area)
            var menu: NSMenu?
            for fx in [0.8, 0.5, 0.2] where menu == nil {
                let point = NSPoint(x: bounds.minX + bounds.width * fx, y: bounds.minY + bounds.height * 0.85)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: host.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: browser.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
                app.injectedEvent = event
                let candidate = host.menu(for: event)
                if candidate?.items.contains(where: { $0.title == "添加项目…" }) == true { menu = candidate }
            }
            app.injectedEvent = nil
            guard let menu, let itemIndex = menu.items.firstIndex(where: { $0.title == "添加项目…" }) else {
                preconditionFailure("Missing real Add Items action in \(mode)")
            }

            // Two consecutive selections exercise retained picker/menu state.
            for _ in 0..<2 { check(menu, at: itemIndex) }
        }
        model.viewMode = .grid
        model.settings.stagingEnabled = true
        model.stageFiles([file])
        model.openStagingWorkspace()
        settle()
        guard let item = descendants(host).compactMap({ $0 as? HubFileDragBridge.FileDragView }).first(where: { $0.entryURL == file }) else {
            preconditionFailure("Missing real staged file")
        }
        let rect = host.convert(item.bounds.intersection(item.visibleRect), from: item)
        let event = NSEvent.mouseEvent(with: .rightMouseDown,
            location: host.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: browser.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        app.injectedEvent = event
        let fileMenu = host.menu(for: event)
        app.injectedEvent = nil
        guard let fileMenu else { preconditionFailure("Missing real staged file context menu") }
        func action(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
            if let index = menu.items.firstIndex(where: { $0.title == title }) { return (menu, index) }
            for item in menu.items {
                if let submenu = item.submenu, let result = action(title, in: submenu) { return result }
            }
            return nil
        }
        for title in ["复制到文件夹…", "移动到文件夹…", "其他应用…"] {
            guard let (menu, index) = action(title, in: fileMenu) else { preconditionFailure("Missing \(title)") }
            check(menu, at: index)
        }
        precondition(model.stagedURLs.map(\.path) == [file.path], "Cancelling transfer must retain staged references")
        precondition(launchModes.count == 9 && launchModes.allSatisfy { $0 == .default })
        print("PASS: actual grid/list/column background menu actions wait for tracking to finish; nine real add/transfer/open-with pickers stay above browser and cancel without retained modal state, geometry or pin changes")
        print("LIMIT: native target/action and visible picker lifecycle are exercised without synthesizing WindowServer menu input; installed hover/auto-hide needs UI verification")
    }
}
