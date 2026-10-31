import AppKit

@main struct ExternalDropFocusTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { panel.close(); other.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        editor.isEditable = true
        panel.contentView!.addSubview(editor)
        precondition(panel.makeFirstResponder(editor))
        precondition(panel.firstResponder === editor && !panel.isVisible && !panel.isKeyWindow)
        var activations = 0, raises = 0
        let expected: pid_t = 1001, own: pid_t = 2002
        func restore(current: pid_t? = expected, active: Bool = false, key: NSWindow? = nil,
                     visible: Bool = true, blocked: Bool = false) -> Bool {
            HubExternalDropFocus.restore(panel: panel, expectedFrontmostPID: expected,
                currentFrontmostPID: current, ownPID: own, applicationIsActive: active,
                keyWindow: key, panelVisible: visible, blocked: blocked,
                activate: { activations += 1 }, raise: { raised in precondition(raised === panel); raises += 1 })
        }
        func rejected(_ condition: Bool) {
            precondition(!condition && activations == 0 && raises == 0 && panel.firstResponder === editor,
                         "A rejected handoff must not activate, raise, or change the actual responder")
        }
        rejected(restore(current: nil))
        rejected(restore(current: 3003))
        rejected(restore(active: true, key: other))
        rejected(restore(visible: panel.isVisible))
        rejected(restore(blocked: true)) // Includes active sheets, menus, preview and inline renaming.
        precondition(restore(), "An accepted external drop may regain focus if the original app remains frontmost")
        precondition(activations == 1 && raises == 1 && !(panel.firstResponder is NSTextView),
                     "The search field editor must release Cmd-Z before the panel is raised")
        precondition(!panel.isVisible && !panel.isKeyWindow,
                     "Injected actions test focus policy without disturbing any real user window")
        activations = 0; raises = 0
        precondition(restore(current: own, active: true, key: panel))
        precondition(activations == 0 && raises == 1, "An already active FileDock does not need another activation")
        print("PASS: hidden real NSPanel responder, frontmost PID changes, another key window, blocking dialogs/editors, hidden panel, allowed focus handoff and active-app behavior")
        print("LIMIT: injected actions avoid changing user focus; real WindowServer activation requires interactive verification")
    }
}
