import AppKit

/// Restore the file panel's keyboard focus after an accepted external color
/// drop, but never take focus from a window the user selected afterwards.
@MainActor enum HubExternalDropFocus {
    @discardableResult
    static func restore(panel: NSPanel, expectedFrontmostPID: pid_t, currentFrontmostPID: pid_t?, ownPID: pid_t,
                        applicationIsActive: Bool, keyWindow: NSWindow?, panelVisible: Bool, blocked: Bool,
                        activate: () -> Void, raise: (NSPanel) -> Void) -> Bool {
        guard panelVisible, !blocked, let currentFrontmostPID,
              currentFrontmostPID == expectedFrontmostPID || currentFrontmostPID == ownPID,
              !applicationIsActive || keyWindow == nil || keyWindow === panel else { return false }
        // An external file drop finishes the prior search interaction. Do not
        // leave the field editor intercepting Cmd-Z intended for this drop.
        if let editor = panel.firstResponder as? NSTextView, editor.isEditable,
           !panel.makeFirstResponder(nil) { return false }
        if !applicationIsActive { activate() }
        if !applicationIsActive || !panel.isKeyWindow { raise(panel) }
        return true
    }
}
