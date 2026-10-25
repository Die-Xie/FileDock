import AppKit

/// System sharing UI can live in another process, below a notch-level panel.
/// Temporarily hide our own windows without changing their geometry or levels.
@MainActor final class HubSharingWindowSuspension {
    private final class Snapshot {
        weak var window: NSWindow?
        var closed = false
        init(_ window: NSWindow) { self.window = window }
    }
    private var snapshots: [Snapshot] = []
    private var closeObserver: NSObjectProtocol?
    private(set) var isActive = false

    func begin(_ windows: [NSWindow]) {
        guard !isActive else { return }
        isActive = true
        var seen = Set<ObjectIdentifier>()
        snapshots = windows.filter { $0.isVisible && seen.insert(ObjectIdentifier($0)).inserted }.map(Snapshot.init)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                self?.snapshots.first { $0.window === window }?.closed = true
            }
        }
        snapshots.forEach { $0.window?.orderOut(nil) }
    }

    func end(restoring: Bool) {
        guard isActive else { return }
        isActive = false
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let saved = snapshots
        snapshots.removeAll()
        guard restoring else { return }
        // The caller supplies back-to-front order, so settings remain above the
        // browser. Do not activate the app or take focus from the recipient UI.
        for snapshot in saved where !snapshot.closed { snapshot.window?.orderFront(nil) }
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
