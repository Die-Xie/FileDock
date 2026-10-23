import AppKit
import ApplicationServices

// Configuration and operation counters are shared with the worker only under lock.
private final class MockQQMusicBackend: HubQQMusicBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var currentProbe = HubQQMusicProbe(installed: true, pid: 101, trusted: true)
    private var currentSnapshot = HubQQMusicSnapshot(pid: 101, title: "Ton Chin Kan", artist: "AKASAKI", isPlaying: false)
    private var counts = (reads: 0, actions: 0, requests: 0)
    private var nextReadGate: DispatchSemaphore?
    private var nextActionGate: DispatchSemaphore?

    func configure(probe: HubQQMusicProbe? = nil, snapshot: HubQQMusicSnapshot? = nil,
                   gate: DispatchSemaphore? = nil, actionGate: DispatchSemaphore? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let probe { currentProbe = probe }
        if let snapshot { currentSnapshot = snapshot }
        nextReadGate = gate
        nextActionGate = actionGate
    }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return counts.reads }
    var actionCount: Int { lock.lock(); defer { lock.unlock() }; return counts.actions }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return counts.requests }

    func probe() -> HubQQMusicProbe { lock.lock(); defer { lock.unlock() }; return currentProbe }
    func requestAccess() -> Bool {
        lock.lock(); defer { lock.unlock() }
        counts.requests += 1
        return currentProbe.trusted
    }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        lock.lock()
        counts.reads += 1
        let snapshot = currentSnapshot, gate = nextReadGate
        nextReadGate = nil
        lock.unlock()
        if let gate { precondition(gate.wait(timeout: .now() + 5) == .success, "Test must release its mock read") }
        return .success(snapshot)
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        lock.lock()
        counts.actions += 1
        let snapshot = currentSnapshot, gate = nextActionGate
        nextActionGate = nil
        lock.unlock()
        if let gate { precondition(gate.wait(timeout: .now() + 5) == .success, "Test must release its mock action") }
        return .success(snapshot)
    }
}

@main
struct QQMusicTests {
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Asynchronous mock operation did not finish")
    }

    @MainActor private static func visibleController(_ backend: MockQQMusicBackend, pollInterval: TimeInterval = 3600) -> HubQQMusicController {
        let controller = HubQQMusicController(backend: backend, pollInterval: pollInterval)
        controller.setEnabled(true)
        controller.setVisible(true)
        return controller
    }

    @MainActor static func main() async throws {
        let track = HubQQMusicAccessibility.parseTrack("歌曲名：Ton Chin Kan - 歌手名：AKASAKI")
        precondition(track?.title == "Ton Chin Kan" && track?.artist == "AKASAKI")
        let unicode = HubQQMusicAccessibility.parseTrack(" 歌曲名： 春天 - Live 🌸 - 歌手名：歌手 A / 歌手 B \n")
        precondition(unicode?.title == "春天 - Live 🌸" && unicode?.artist == "歌手 A / 歌手 B")
        precondition(HubQQMusicAccessibility.parseTrack("收藏的歌曲名：Song - 歌手名：Artist") == nil)
        precondition(HubQQMusicAccessibility.parseTrack("歌曲名： - 歌手名：Artist") == nil)
        precondition(HubQQMusicAccessibility.parseTrack("歌曲名：无歌手信息") == nil)

        precondition(HubQQMusicAccessibility.isPlaybackPanel(role: kAXGroupRole, names: ["播放控制栏"]))
        precondition(HubQQMusicAccessibility.isPlaybackPanel(role: kAXUnknownRole, names: ["播放控制栏"]))
        precondition(!HubQQMusicAccessibility.isPlaybackPanel(role: kAXUnknownRole, names: ["个人中心"]))
        precondition(!HubQQMusicAccessibility.isPlaybackPanel(role: "AXWebArea", names: ["播放控制栏"]))
        precondition(!HubQQMusicAccessibility.isPlaybackPanel(role: kAXGroupRole, names: ["我的播放控制栏"]))
        precondition(HubQQMusicAccessibility.isNativeButton(role: kAXButtonRole, roleDescription: ""))
        precondition(HubQQMusicAccessibility.isNativeButton(role: kAXUnknownRole, roleDescription: "按钮"))
        precondition(HubQQMusicAccessibility.isNativeButton(role: kAXUnknownRole, roleDescription: "Button"))
        precondition(!HubQQMusicAccessibility.isNativeButton(role: kAXUnknownRole, roleDescription: "面板"))
        precondition(!HubQQMusicAccessibility.isNativeButton(role: kAXStaticTextRole, roleDescription: "按钮"))
        precondition(HubQQMusicAccessibility.matches(.toggle, role: kAXButtonRole, names: ["暂停"]))
        precondition(HubQQMusicAccessibility.matches(.previous, role: kAXButtonRole, names: ["上一首"]))
        precondition(!HubQQMusicAccessibility.matches(.next, role: kAXStaticTextRole, names: ["下一首"]))
        precondition(!HubQQMusicAccessibility.matches(.toggle, role: kAXButtonRole, names: ["播放全部"]))
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["暂停"]) == true)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["暂停播放"]) == true)
        precondition(HubQQMusicAccessibility.matches(.toggle, role: kAXButtonRole, names: ["暂停播放"]))
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["播放"]) == false)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["未知"]) == nil)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["播放", "暂停"]) == nil)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["播放", "暂停播放"]) == nil)
        precondition(!HubQQMusicAccessibility.matches(.toggle, role: kAXButtonRole, names: ["播放", "暂停播放"]))
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["暂停播放全部"]) == nil)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXButtonRole, names: ["暂时暂停播放"]) == nil)
        precondition(HubQQMusicAccessibility.playbackState(role: kAXStaticTextRole, names: ["暂停播放"]) == nil)
        let controls = [(role: kAXButtonRole, names: ["上一首"]), (role: kAXButtonRole, names: ["播放"])]
        precondition(HubQQMusicAccessibility.uniqueControlIndex(for: .toggle, controls: controls) == 1)
        precondition(HubQQMusicAccessibility.playbackState(controls: controls) == false)
        let ambiguous = controls + [(role: kAXButtonRole, names: ["暂停"])]
        precondition(HubQQMusicAccessibility.uniqueControlIndex(for: .toggle, controls: ambiguous) == nil)
        precondition(HubQQMusicAccessibility.playbackState(controls: ambiguous) == nil)
        let duplicateNext = [(role: kAXButtonRole, names: ["下一首"]), (role: kAXButtonRole, names: ["下一首"])]
        precondition(HubQQMusicAccessibility.uniqueControlIndex(for: .next, controls: duplicateNext) == nil)

        let topMenus = [(role: kAXMenuBarItemRole, title: "窗口"), (role: kAXMenuBarItemRole, title: "播放控制")]
        precondition(HubQQMusicAccessibility.uniquePlaybackMenuIndex(in: topMenus) == 1)
        precondition(HubQQMusicAccessibility.uniquePlaybackMenuIndex(in: topMenus + [topMenus[1]]) == nil)
        precondition(HubQQMusicAccessibility.uniquePlaybackMenuIndex(in: [(role: kAXMenuItemRole, title: "播放控制")]) == nil)
        let menuItems = [(role: kAXMenuItemRole, title: "播放"), (role: kAXMenuItemRole, title: "上一首"), (role: kAXMenuItemRole, title: "下一首")]
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .toggle, in: menuItems, isPlaying: false) == 0)
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .previous, in: menuItems, isPlaying: nil) == 1)
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .next, in: menuItems, isPlaying: nil) == 2)
        precondition(!HubQQMusicAccessibility.matchesMenuCommand(.toggle, role: kAXButtonRole, title: "播放"))
        precondition(!HubQQMusicAccessibility.matchesMenuCommand(.toggle, role: kAXMenuItemRole, title: "播放全部"))
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .next, in: menuItems + [menuItems[2]], isPlaying: nil) == nil)
        let separatePlayPause = menuItems + [(role: kAXMenuItemRole, title: "暂停")]
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .toggle, in: separatePlayPause, isPlaying: nil) == nil)
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .toggle, in: separatePlayPause, isPlaying: true) == 3)
        precondition(HubQQMusicAccessibility.uniqueMenuCommandIndex(for: .toggle, in: separatePlayPause, isPlaying: false) == 0)

        let missing = MockQQMusicBackend()
        missing.configure(probe: HubQQMusicProbe(installed: false, pid: nil, trusted: false))
        let missingController = visibleController(missing)
        try await wait { missingController.status == .notInstalled }
        precondition(missing.readCount == 0 && missing.requestCount == 0)
        missingController.setVisible(false)

        let stopped = MockQQMusicBackend()
        stopped.configure(probe: HubQQMusicProbe(installed: true, pid: nil, trusted: true))
        let stoppedController = visibleController(stopped)
        try await wait { stoppedController.status == .notRunning }
        precondition(stopped.readCount == 0 && stopped.actionCount == 0)
        stoppedController.setVisible(false)

        let unauthorized = MockQQMusicBackend()
        unauthorized.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: false))
        let permissionController = visibleController(unauthorized)
        try await wait { permissionController.status == .needsPermission }
        permissionController.setVisible(false)
        permissionController.setVisible(true)
        precondition(permissionController.status == .needsPermission, "Passive refresh must retain its useful permission state without button flicker")
        permissionController.togglePlayback()
        precondition(unauthorized.readCount == 0 && unauthorized.actionCount == 0 && unauthorized.requestCount == 0,
                     "Opening the panel must neither traverse AX without permission nor ask for access")
        permissionController.requestAccess()
        try await wait { unauthorized.requestCount == 1 && permissionController.status == .needsPermission }
        precondition(unauthorized.readCount == 0)
        unauthorized.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: true))
        permissionController.requestAccess()
        try await wait { permissionController.status == .ready }
        precondition(permissionController.title == "Ton Chin Kan" && permissionController.artist == "AKASAKI")
        precondition(permissionController.isPlaying == false && unauthorized.requestCount == 2)

        // System permission changes must be noticed by passive polling, without
        // asking again, and revocation must immediately disable stale controls.
        let changingPermission = MockQQMusicBackend()
        changingPermission.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: false))
        let recoveringController = visibleController(changingPermission, pollInterval: 1)
        try await wait { recoveringController.status == .needsPermission }
        precondition(changingPermission.readCount == 0 && changingPermission.requestCount == 0)
        changingPermission.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: true))
        try await wait { recoveringController.status == .ready }
        precondition(recoveringController.title == "Ton Chin Kan" && changingPermission.requestCount == 0)
        changingPermission.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: false))
        try await wait { recoveringController.status == .needsPermission }
        precondition(recoveringController.title.isEmpty && recoveringController.isPlaying == nil)
        let readsBeforeRevocation = changingPermission.readCount
        recoveringController.togglePlayback()
        recoveringController.reconnect()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(changingPermission.actionCount == 0 && changingPermission.readCount == readsBeforeRevocation)
        precondition(changingPermission.requestCount == 0)
        changingPermission.configure(probe: HubQQMusicProbe(installed: true, pid: 101, trusted: true))
        try await wait { recoveringController.status == .ready }
        precondition(changingPermission.requestCount == 0)
        recoveringController.setVisible(false)

        // A successful action without a changed readback must not fabricate new state.
        permissionController.togglePlayback()
        try await wait { unauthorized.actionCount == 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(permissionController.isPlaying == false)
        unauthorized.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Next song", artist: "Artist", isPlaying: true))
        permissionController.nextTrack()
        try await wait { permissionController.title == "Next song" }
        precondition(permissionController.isPlaying == true)

        // A relaunched process may be displayed on the next poll but must never inherit a queued command.
        let actionCount = unauthorized.actionCount
        unauthorized.configure(probe: HubQQMusicProbe(installed: true, pid: 202, trusted: true))
        permissionController.previousTrack()
        try await wait { permissionController.status == .unavailable }
        precondition(unauthorized.actionCount == actionCount)
        permissionController.setVisible(false)

        let wrongPID = MockQQMusicBackend()
        wrongPID.configure(snapshot: HubQQMusicSnapshot(pid: 404, title: "Wrong process", artist: "", isPlaying: true))
        let wrongController = visibleController(wrongPID)
        try await wait { wrongController.status == .unavailable }
        precondition(wrongController.title.isEmpty && wrongController.isPlaying == nil)
        wrongPID.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Reconnected", artist: "Artist", isPlaying: false))
        wrongController.reconnect()
        try await wait { wrongController.status == .ready }
        precondition(wrongController.title == "Reconnected" && wrongPID.requestCount == 0,
                     "Retrying a player failure must not request Accessibility permission")
        wrongController.setVisible(false)

        // A click during a passive poll must run after the read instead of
        // disappearing. The superseded read must not publish its stale track.
        let pollingBackend = MockQQMusicBackend(), pollingGate = DispatchSemaphore(value: 0)
        let queuedActionGate = DispatchSemaphore(value: 0)
        let pollingController = visibleController(pollingBackend)
        try await wait { pollingController.status == .ready }
        pollingBackend.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Stale poll", artist: "", isPlaying: false),
                                 gate: pollingGate)
        pollingController.reconnect()
        try await wait { pollingBackend.readCount == 2 }
        pollingBackend.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Action after poll", artist: "", isPlaying: true),
                                 actionGate: queuedActionGate)
        pollingController.togglePlayback()
        pollingController.togglePlayback()
        pollingController.nextTrack()
        precondition(pollingBackend.actionCount == 0, "Actions must remain serialized behind an in-flight read")
        pollingGate.signal()
        try await wait { pollingBackend.actionCount == 1 }
        precondition(pollingController.title == "Ton Chin Kan", "A superseded poll must not publish stale track information")
        queuedActionGate.signal()
        try await wait { pollingController.title == "Action after poll" }
        precondition(pollingBackend.actionCount == 1 && pollingController.isPlaying == true,
                     "The first click during a poll runs exactly once; further clicks cannot queue toggles")
        pollingController.setVisible(false)

        // A queued click belongs to the visible/enabled session that accepted
        // it. Hiding or disabling must invalidate it before the backend acts.
        for disable in [false, true] {
            let queuedBackend = MockQQMusicBackend(), readGate = DispatchSemaphore(value: 0)
            let queuedController = visibleController(queuedBackend)
            try await wait { queuedController.status == .ready }
            queuedBackend.configure(gate: readGate)
            queuedController.reconnect()
            try await wait { queuedBackend.readCount == 2 }
            queuedController.nextTrack()
            if disable { queuedController.setEnabled(false) }
            else { queuedController.setVisible(false) }
            queuedBackend.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Fresh session", artist: "", isPlaying: false))
            if disable { queuedController.setEnabled(true) }
            else { queuedController.setVisible(true) }
            readGate.signal()
            try await wait { queuedController.title == "Fresh session" }
            precondition(queuedBackend.actionCount == 0, "A cancelled session must not leave a queued playback command")
            queuedController.setVisible(false)
        }

        let restartedBackend = MockQQMusicBackend(), restartGate = DispatchSemaphore(value: 0)
        let restartedController = visibleController(restartedBackend)
        try await wait { restartedController.status == .ready }
        restartedBackend.configure(gate: restartGate)
        restartedController.reconnect()
        try await wait { restartedBackend.readCount == 2 }
        restartedController.previousTrack()
        restartedBackend.configure(probe: HubQQMusicProbe(installed: true, pid: 202, trusted: true),
                                   snapshot: HubQQMusicSnapshot(pid: 202, title: "New process", artist: "", isPlaying: false))
        restartGate.signal()
        try await wait { restartedController.status == .unavailable }
        precondition(restartedBackend.actionCount == 0, "A click queued during a poll must not act on a replacement process")
        restartedController.setVisible(false)

        // Repeated clicks during a native action must not enqueue multiple
        // toggles or invalidate its readback. A later click can act normally.
        let busyBackend = MockQQMusicBackend(), actionGate = DispatchSemaphore(value: 0)
        let busyController = visibleController(busyBackend)
        try await wait { busyController.status == .ready }
        busyBackend.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Completed action", artist: "Artist", isPlaying: true),
                              actionGate: actionGate)
        busyController.togglePlayback()
        try await wait { busyBackend.actionCount == 1 }
        busyController.togglePlayback()
        busyController.previousTrack()
        busyController.nextTrack()
        busyController.reconnect()
        precondition(busyBackend.actionCount == 1)
        actionGate.signal()
        try await wait { busyController.title == "Completed action" }
        precondition(busyBackend.actionCount == 1)
        busyController.nextTrack()
        try await wait { busyBackend.actionCount == 2 }
        busyController.setVisible(false)

        // Completion of an in-flight read after hiding must not update the UI.
        let delayed = MockQQMusicBackend(), gate = DispatchSemaphore(value: 0)
        delayed.configure(gate: gate)
        let delayedController = visibleController(delayed)
        try await wait { delayed.readCount == 1 }
        delayedController.setVisible(false)
        gate.signal()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(delayedController.title.isEmpty && delayedController.isPlaying == nil)
        delayed.configure(snapshot: HubQQMusicSnapshot(pid: 101, title: "Fresh read", artist: "New artist", isPlaying: nil))
        delayedController.setVisible(true)
        try await wait { delayedController.status == .ready }
        precondition(delayedController.title == "Fresh read" && delayedController.isPlaying == nil)
        delayedController.setEnabled(false)
        delayedController.nextTrack()
        delayedController.requestAccess()
        delayedController.reconnect()
        precondition(delayed.actionCount == 0 && delayed.requestCount == 0)

        print("PASS: QQ track parsing, exact AX control recognition, permission recovery, clicks during polling, queued-action cancellation, busy action rejection, PID validation, visibility gating and readback-only playback state")
        print("LIMIT: Tests use a simulated backend; native QQ Music AX compatibility and system authorization require explicit UI verification")
    }
}
