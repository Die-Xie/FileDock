import AppKit

@MainActor final class SharingTestWindow: NSWindow {
    var testVisible = false
    var orderedOut = 0
    var orderedIn = 0
    override var isVisible: Bool { testVisible }
    override func orderOut(_ sender: Any?) { testVisible = false; orderedOut += 1 }
    override func orderFront(_ sender: Any?) { testVisible = true; orderedIn += 1 }
}

@main struct SharingWindowTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func window(_ level: NSWindow.Level, visible: Bool = true) -> SharingTestWindow {
            let window = SharingTestWindow(contentRect: NSRect(x: 120, y: 170, width: 620, height: 430), styleMask: .borderless, backing: .buffered, defer: true)
            window.level = level; window.testVisible = visible
            window.isReleasedWhenClosed = false
            return window
        }
        let browser = window(.statusBar), settings = window(NSWindow.Level(rawValue: 26)), hidden = window(.floating, visible: false)
        let frame = browser.frame
        let policy = HubSharingWindowSuspension()
        policy.begin([browser, settings, browser, hidden])
        precondition(policy.isActive && !browser.isVisible && !settings.isVisible)
        precondition(browser.orderedOut == 1 && hidden.orderedOut == 0)
        policy.begin([browser])
        precondition(browser.orderedOut == 1)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        policy.end(restoring: true)
        precondition(browser.isVisible && !settings.isVisible && !hidden.isVisible)
        precondition(browser.frame == frame && browser.level == .statusBar && settings.level.rawValue == 26)
        policy.end(restoring: true)
        precondition(browser.orderedIn == 1)
        policy.begin([browser])
        policy.end(restoring: false)
        precondition(!browser.isVisible && browser.orderedIn == 1)
        browser.testVisible = true
        policy.begin([browser])
        policy.end(restoring: true)
        precondition(browser.isVisible && browser.orderedIn == 2)
        print("PASS: sharing window suspension preserves geometry, levels, cancellation and closed windows")
    }
}
