import AppKit

/// Keeps the app's floating browser chrome behind its own modal UI. Using the
/// same floating level for the browser and settings also lets system color
/// panels become frontmost through ordinary key-window ordering.
@MainActor
enum HubWindowPresentation {
    static let auxiliaryLevel = NSWindow.Level.floating
    static var backgroundWindows: (() -> [NSWindow])?
    static var modalStateDidChange: ((Bool) -> Void)?
    private static var dialogStack: [NSWindow] = []

    static var isPresentingDialog: Bool { !dialogStack.isEmpty }

    /// Embedded chrome needs to cover the menu bar, but must yield to its own
    /// settings and modal UI before they are ordered onscreen. Quick Look uses
    /// its own level above embedded chrome instead of exposing the menu bar.
    static func browserLevel(embedded: Bool, auxiliaryVisible: Bool) -> NSWindow.Level {
        embedded && !auxiliaryVisible ? .statusBar : .floating
    }

    /// A lower window level cannot cover the system menu bar. Move the entire
    /// embedded surface into the safe area instead of padding only its controls.
    /// Always derive from the attachment frame so repeated yields cannot drift.
    static func embeddedFrame(_ attachmentFrame: CGRect, screenFrame: CGRect,
                              visibleFrame: CGRect, safeTop: CGFloat, menuBarHeight: CGFloat = 0,
                              yielding: Bool) -> CGRect {
        guard yielding else { return attachmentFrame }
        let inset = safeTop.isFinite ? max(0, safeTop) : 0
        let menu = menuBarHeight.isFinite ? max(0, menuBarHeight) : 0
        // Auto-hidden menu bars can report the full screen as visibleFrame.
        let top = min(visibleFrame.maxY, screenFrame.maxY - max(inset, menu)) - 4
        let bottom = visibleFrame.minY + 12
        let height = min(attachmentFrame.height, max(1, top - bottom))
        return CGRect(x: attachmentFrame.minX, y: top - height,
                      width: attachmentFrame.width, height: height)
    }

    static func previewLevel(browserLevel: NSWindow.Level) -> NSWindow.Level {
        browserLevel.rawValue >= NSWindow.Level.statusBar.rawValue
            ? NSWindow.Level(rawValue: browserLevel.rawValue + 1) : .floating
    }

    static func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        return withModalWindow(panel) {
            NSApp.activate(ignoringOtherApps: true)
            defer { panel.orderOut(nil) }
            return panel.runModal()
        }
    }

    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        return withModalWindow(alert.window) {
            NSApp.activate(ignoringOtherApps: true)
            defer { alert.window.orderOut(nil) }
            return alert.runModal()
        }
    }

    /// A scoped policy, separate from displaying a panel so its restoration and
    /// nesting behavior can be tested with windows that are never ordered in.
    static func withModalWindow<Result>(_ dialog: NSWindow, perform operation: () throws -> Result) rethrows -> Result {
        let windows = descendants(of: (backgroundWindows?() ?? []) + dialogStack, excluding: dialog)
        let snapshots = windows.map { WindowLevel(window: $0, level: $0.level) }
        let previousDialogLevel = dialog.level
        dialogStack.append(dialog)
        if dialogStack.count == 1 { modalStateDidChange?(true) }
        for window in windows { window.level = .normal }
        dialog.level = .modalPanel
        defer {
            dialog.level = previousDialogLevel
            // Parents precede children: restoring a parent can change a child's
            // level, so explicitly restore every child's recorded value after it.
            for snapshot in snapshots { snapshot.window?.level = snapshot.level }
            dialogStack.removeLast()
            if dialogStack.isEmpty { modalStateDidChange?(false) }
        }
        return try operation()
    }

    private static func descendants(of roots: [NSWindow], excluding dialog: NSWindow) -> [NSWindow] {
        var result: [NSWindow] = []
        var visited: Set<ObjectIdentifier> = []
        func append(_ window: NSWindow) {
            guard window !== dialog, visited.insert(ObjectIdentifier(window)).inserted else { return }
            result.append(window)
            // SwiftUI's workspace editor is an attached sheet, and may itself
            // open an image picker. Include it without detaching or ending it.
            if let sheet = window.attachedSheet { append(sheet) }
            for child in window.childWindows ?? [] { append(child) }
        }
        roots.forEach(append)
        return result
    }

    private struct WindowLevel {
        weak var window: NSWindow?
        let level: NSWindow.Level
    }
}
