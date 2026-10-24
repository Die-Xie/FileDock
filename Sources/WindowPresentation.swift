import AppKit

/// Keep embedded chrome above the menu bar, and raise its own auxiliary UI
/// above it. Lowering the browser would expose the menu over its top edge.
@MainActor
enum HubWindowPresentation {
    static var backgroundWindows: (() -> [NSWindow])?
    static var modalStateDidChange: ((Bool) -> Void)?
    private static var dialogStack: [NSWindow] = []

    static var isPresentingDialog: Bool { !dialogStack.isEmpty }

    /// Embedded chrome stays in place above the menu bar. Its own settings,
    /// preview and modal windows receive higher levels instead of exposing it.
    static func browserLevel(embedded: Bool) -> NSWindow.Level {
        embedded ? .statusBar : .floating
    }

    static func auxiliaryLevel(above browserLevel: NSWindow.Level) -> NSWindow.Level {
        browserLevel.rawValue >= NSWindow.Level.statusBar.rawValue
            ? NSWindow.Level(rawValue: browserLevel.rawValue + 1) : .floating
    }

    static func modalLevel(above levels: [NSWindow.Level]) -> NSWindow.Level {
        NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue,
            (levels.map(\.rawValue).max() ?? NSWindow.Level.normal.rawValue) + 1))
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
        let targetLevel = modalLevel(above: windows.map(\.level))
        dialog.level = targetLevel
        // NSSavePanel.runModal resets its level to .modalPanel while ordering
        // in, after our initial assignment. Its first display update must repair
        // that reset even before it becomes key (e.g. while the app is inactive).
        let tokens = [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: dialog, queue: .main) { [weak dialog] _ in
                MainActor.assumeIsolated {
                    guard let dialog, dialog.level.rawValue < targetLevel.rawValue else { return }
                    dialog.level = targetLevel
                }
            }
        }
        defer {
            tokens.forEach(NotificationCenter.default.removeObserver)
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

/// Temporary elevations for settings, color panels and Sparkle windows. A
/// weak snapshot restores only levels still owned by this coordinator.
@MainActor final class HubAuxiliaryWindowLevels {
    private struct Snapshot {
        weak var window: NSWindow?
        var original: NSWindow.Level
        var elevated: NSWindow.Level
    }
    private var snapshots: [ObjectIdentifier: Snapshot] = [:]

    func synchronize(_ candidates: [NSWindow], excluding excludedWindows: [NSWindow] = [],
                     above browserLevel: NSWindow.Level) {
        guard !HubWindowPresentation.isPresentingDialog else { return }
        let excluded = Set(excludedWindows.map(ObjectIdentifier.init))
        let windows = candidates.filter { !excluded.contains(ObjectIdentifier($0)) }
        let target = HubWindowPresentation.auxiliaryLevel(above: browserLevel)
        let ids = Set(windows.map(ObjectIdentifier.init))
        for (id, snapshot) in snapshots {
            guard let window = snapshot.window else { snapshots.removeValue(forKey: id); continue }
            if !ids.contains(id) || snapshot.elevated != target || window.level != snapshot.elevated {
                if window.level == snapshot.elevated { window.level = snapshot.original }
                snapshots.removeValue(forKey: id)
            }
        }
        for window in windows where window.level.rawValue < target.rawValue {
            let id = ObjectIdentifier(window)
            snapshots[id] = Snapshot(window: window, original: window.level, elevated: target)
            window.level = target
        }
    }
}
