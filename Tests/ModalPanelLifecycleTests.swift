import AppKit
import CoreGraphics

/// Opt-in native regression: displays disposable windows and auto-cancels every
/// picker. No user files are selected, modified or added to FileDock.
@main struct ModalPanelLifecycleTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let browser = NSPanel(contentRect: NSRect(x: 300, y: 400, width: 600, height: 260),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        browser.level = .statusBar
        browser.isReleasedWhenClosed = false
        browser.orderFrontRegardless()
        let frame = browser.frame
        HubWindowPresentation.backgroundWindows = { [browser] }
        var transitions: [Bool] = []
        HubWindowPresentation.modalStateDidChange = { transitions.append($0) }
        defer {
            browser.orderOut(nil)
            HubWindowPresentation.backgroundWindows = nil
            HubWindowPresentation.modalStateDidChange = nil
        }

        let folder = NSOpenPanel()
        folder.canChooseFiles = false; folder.canChooseDirectories = true
        check(folder, browser: browser, name: "workspace folder")
        let references = NSOpenPanel()
        references.canChooseFiles = true; references.canChooseDirectories = true
        references.allowsMultipleSelection = true
        check(references, browser: browser, name: "favorites/staging references")
        check(references, browser: browser, name: "repeated presentation")
        check(folder, browser: browser, name: "staging transfer destination")

        let settings = NSWindow(contentRect: NSRect(x: 350, y: 350, width: 400, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.level = HubWindowPresentation.auxiliaryLevel(above: browser.level)
        settings.orderFrontRegardless()
        HubWindowPresentation.backgroundWindows = { [browser, settings] }
        let save = NSSavePanel()
        save.nameFieldStringValue = "FileDock-test-unused.json"
        check(save, browser: browser, name: "settings export", above: settings.level)
        settings.orderOut(nil)

        browser.level = .floating
        HubWindowPresentation.backgroundWindows = { [browser] }
        check(folder, browser: browser, name: "detached browser")
        expect(browser.frame == frame, "Presenting a picker must never move the browser")
        expect(transitions == Array(repeating: [true, false], count: 6).flatMap { $0 },
               "Every presentation must release its modal scope")
        print("PASS: real open/save modal lifecycle, WindowServer ordering, repeated presentation, settings and detached levels, automatic cancellation and restoration")
    }

    @MainActor private static func check(_ panel: NSSavePanel, browser: NSWindow, name: String,
                                        above otherLevel: NSWindow.Level? = nil) {
        panel.title = "FileDock 自动层级测试（自动关闭）"
        let original = panel.level, browserLevel = browser.level, frame = browser.frame
        let highest = max(browserLevel.rawValue, otherLevel?.rawValue ?? browserLevel.rawValue)
        var observed = false, failure: String?
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard panel.isVisible, NSApp.modalWindow === panel else { return }
                observed = true
                if panel.level.rawValue <= highest { failure = "\(name): native modal reset left picker behind browser" }
                // Check the actual compositor layer as well as the proxy's property.
                let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
                let match = windows.first { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
                if let layer = match?[kCGWindowLayer as String] as? Int {
                    if layer <= highest { failure = "\(name): WindowServer layer is below browser" }
                } else { failure = "\(name): modal window missing from WindowServer" }
                if browser.level != browserLevel || browser.frame != frame {
                    failure = "\(name): browser moved or lost menu-bar protection"
                }
                panel.cancel(nil)
            }
        }
        let timeout = Timer(timeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated { panel.cancel(nil) }
        }
        for mode in [RunLoop.Mode.common, .modalPanel] {
            RunLoop.main.add(timer, forMode: mode)
            RunLoop.main.add(timeout, forMode: mode)
        }
        let response = HubWindowPresentation.runModal(panel)
        timer.invalidate(); timeout.invalidate()
        expect(observed, "\(name): no native modal presentation observed")
        expect(failure == nil, failure ?? "")
        expect(response == .cancel && !panel.isVisible && !HubWindowPresentation.isPresentingDialog,
               "\(name): cancellation must dismiss picker and resume the browser")
        expect(panel.level == original, "\(name): original panel level must restore")
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: panel)
        expect(panel.level == original, "\(name): no observers can survive dismissal")
        print("PASS: \(name)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
