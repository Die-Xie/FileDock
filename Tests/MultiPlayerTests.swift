import AppKit
import ApplicationServices
import Combine
import Carbon

private final class PlayerFixture: HubQQMusicBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var value: HubQQMusicProbe
    private var result: Result<HubQQMusicSnapshot, HubQQMusicFailure>
    private var gate: DispatchSemaphore?
    private var readCounter = 0, actionCounter = 0, permissionCounter = 0
    init(pid: pid_t, playing: Bool?, title: String) {
        value = HubQQMusicProbe(installed: true, pid: pid, trusted: true)
        result = .success(HubQQMusicSnapshot(pid: pid, title: title, artist: "Artist", isPlaying: playing))
    }
    func configure(probe: HubQQMusicProbe? = nil, snapshot: HubQQMusicSnapshot? = nil,
                   failure: HubQQMusicFailure? = nil, gate: DispatchSemaphore? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let probe { value = probe }
        if let snapshot { result = .success(snapshot) }
        if let failure { result = .failure(failure) }
        self.gate = gate
    }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCounter }
    var actions: Int { lock.lock(); defer { lock.unlock() }; return actionCounter }
    var prompts: Int { lock.lock(); defer { lock.unlock() }; return permissionCounter }
    func probe() -> HubQQMusicProbe { lock.lock(); defer { lock.unlock() }; return value }
    func requestAccess() -> Bool { lock.lock(); defer { lock.unlock() }; permissionCounter += 1; return value.trusted }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        lock.lock(); readCounter += 1
        let result = result, gate = gate
        self.gate = nil
        lock.unlock()
        if let gate { precondition(gate.wait(timeout: .now() + 5) == .success) }
        return result
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        lock.lock(); defer { lock.unlock() }; actionCounter += 1; return result
    }
}

@main struct MultiPlayerTests {
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Player fixture did not finish")
    }
    private static func candidate(_ player: HubMusicPlayer, playing: Bool?, pid: pid_t = 10) -> HubMusicCandidate {
        HubMusicCandidate(player: player, probe: HubQQMusicProbe(installed: true, pid: pid, trusted: true),
                          result: .success(HubQQMusicSnapshot(pid: pid, title: "Song", artist: "", isPlaying: playing)))
    }
    @MainActor static func main() async throws {
        precondition(Set(HubMusicPlayer.allCases.map(\.bundleID)).count == 3)
        precondition(HubMusicPlayerSelection.automatic.player == nil)
        precondition(HubMusicPlayerSelection(rawValue: "appleMusic")?.player == .appleMusic)
        let qq = candidate(.qqMusic, playing: false), music = candidate(.appleMusic, playing: true)
        precondition(HubMusicSelectionPolicy.choose([qq, music], previous: .qqMusic)?.player == .appleMusic)
        precondition(HubMusicSelectionPolicy.choose([candidate(.qqMusic, playing: true), music], previous: .qqMusic)?.player == .qqMusic)
        precondition(HubMusicSelectionPolicy.choose([qq, candidate(.appleMusic, playing: false)], previous: .appleMusic)?.player == .appleMusic)
        let wrong = HubMusicCandidate(player: .appleMusic, probe: HubQQMusicProbe(installed: true, pid: 11, trusted: true), result: music.result)
        precondition(wrong.snapshot == nil)
        let unauthorizedSnapshot = HubMusicCandidate(player: .appleMusic, probe: HubQQMusicProbe(installed: true, pid: 10, trusted: false), result: music.result)
        precondition(unauthorizedSnapshot.snapshot == nil)
        precondition(HubMusicSelectionPolicy.choose([wrong, qq], previous: .appleMusic)?.player == .qqMusic)

        // Check public Music object-specifier encodings, including the current
        // track container. These tests neither start Music nor request TCC.
        let name = try HubAppleMusicBackend.property(HubAppleMusicBackend.code("pnam"), container: HubAppleMusicBackend.property(HubAppleMusicBackend.code("pTrk")))
        precondition(name.descriptorType == typeObjectSpecifier)
        precondition(name.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == HubAppleMusicBackend.code("pnam"))
        precondition(name.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == HubAppleMusicBackend.code("pTrk"))
        precondition(HubAppleMusicBackend.actionCode(.toggle) == HubAppleMusicBackend.code("PlPs"))
        precondition(HubAppleMusicBackend.actionCode(.previous) == HubAppleMusicBackend.code("Prev"))
        precondition(HubAppleMusicBackend.actionCode(.next) == HubAppleMusicBackend.code("Next"))

        let labels = [(role: kAXMenuItemRole as String, title: "播放/暂停", enabled: true),
                      (role: kAXMenuItemRole as String, title: "上一首", enabled: true),
                      (role: kAXMenuItemRole as String, title: "下一首", enabled: true)]
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.toggle, in: labels) == 0)
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.previous, in: labels) == 1)
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.next, in: labels) == 2)
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.next, in: labels + [labels[2]]) == nil)
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.toggle, in: [(kAXStaticTextRole, "播放", true)]) == nil)
        precondition(HubNetEaseMusicAccessibility.uniqueCommand(.toggle, in: [(kAXMenuItemRole, "播放", false)]) == nil)
        precondition(!HubNetEaseMusicAccessibility.matches(.toggle, title: "播放全部"))
        precondition(HubNetEaseMusicAccessibility.state("播放/暂停") == nil)
        precondition(HubNetEaseMusicAccessibility.state("暂停") == true)
        precondition(HubNetEaseMusicAccessibility.track(from: "Song - Live - Artist - 网易云音乐")?.title == "Song - Live")
        precondition(HubNetEaseMusicAccessibility.track(from: "我的歌单") == nil)
        precondition(HubNetEaseMusicAccessibility.track(from: "Song - Artist") == nil)

        let first = PlayerFixture(pid: 101, playing: false, title: "QQ"), second = PlayerFixture(pid: 202, playing: true, title: "Music")
        let third = PlayerFixture(pid: 303, playing: true, title: "NetEase")
        third.configure(probe: HubQQMusicProbe(installed: false, pid: nil, trusted: true))
        let controller = HubQQMusicController(pollInterval: 3600, openAccessSettings: {}, backends: [.qqMusic: first, .appleMusic: second, .neteaseMusic: third])
        controller.setEnabled(true); controller.setVisible(true)
        try await wait { controller.status == .ready }
        precondition(controller.activePlayer == .qqMusic && second.reads == 0 && third.reads == 0, "Legacy selection must remain QQ")
        controller.setPlayerSelection(.automatic)
        try await wait { controller.activePlayer == .appleMusic && controller.status == .ready }
        precondition(third.reads == 0 && first.prompts == 0 && second.prompts == 0 && third.prompts == 0)
        controller.togglePlayback()
        try await wait { second.actions == 1 }
        precondition(first.actions == 0 && third.actions == 0, "Commands only go to the displayed player")

        // Unchanged readbacks must not invalidate every SwiftUI view each poll.
        try await Task.sleep(nanoseconds: 20_000_000)
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        let previousReads = second.reads
        controller.reconnect()
        try await wait { second.reads > previousReads }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(publications == 0, "Unchanged polling must not publish UI mutations")
        withExtendedLifetime(subscription) {}

        // Switching while a passive read is delayed discards its metadata and
        // cancels a pending command before it reaches either player.
        let gate = DispatchSemaphore(value: 0)
        controller.setPlayerSelection(.qqMusic)
        try await wait { controller.activePlayer == .qqMusic && controller.status == .ready }
        first.configure(gate: gate)
        let initialReads = first.reads
        controller.reconnect()
        try await wait { first.reads > initialReads }
        controller.nextTrack()
        controller.setPlayerSelection(.appleMusic)
        gate.signal()
        try await wait { controller.status == .ready && controller.title == "Music" }
        precondition(first.actions == 0 && second.actions == 1)
        second.configure(probe: HubQQMusicProbe(installed: true, pid: 204, trusted: true))
        controller.nextTrack()
        try await wait { controller.status == .unavailable }
        precondition(second.actions == 1, "Restarted processes cannot inherit commands")

        // Manual selection stays fixed even when the chosen player is closed,
        // missing or unauthorized. No fallback may steal the user's command.
        controller.setPlayerSelection(.neteaseMusic)
        try await wait { controller.status == .notInstalled }
        precondition(controller.activePlayer == .neteaseMusic && third.reads == 0)
        third.configure(probe: HubQQMusicProbe(installed: true, pid: nil, trusted: false))
        controller.reconnect()
        try await wait { controller.status == .notRunning }
        third.configure(probe: HubQQMusicProbe(installed: true, pid: 303, trusted: false))
        controller.reconnect()
        try await wait { controller.status == .needsPermission }
        precondition(third.prompts == 0 && third.reads == 0)
        controller.requestAccess()
        try await wait { third.prompts == 1 && controller.status == .needsPermission }
        precondition(first.prompts == 0 && second.prompts == 0)
        third.configure(probe: HubQQMusicProbe(installed: true, pid: 303, trusted: true))
        controller.reconnect()
        try await wait { controller.status == .ready }
        third.configure(failure: .permission)
        controller.reconnect()
        try await wait { controller.status == .needsPermission && controller.connectionProbe?.trusted == false }
        precondition(third.prompts == 1, "A read failure must not request authorization implicitly")
        controller.setVisible(false)
        let hiddenReads = first.reads + second.reads + third.reads
        controller.reconnect(); controller.requestAccess(); controller.togglePlayback()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(first.reads + second.reads + third.reads == hiddenReads && third.prompts == 1)
        print("PASS: Multi-player identity, stable auto selection, manual isolation, stopped-player/no-prompt polling, stale reads and commands, PID restart, unchanged UI, Apple public descriptors, and strict NetEase menu matching")
        print("LIMIT: Native Apple Music permission/playback and NetEase client layouts require installed-player validation; fixtures never control the user's players")
    }
}
