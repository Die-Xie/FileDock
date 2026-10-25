import AppKit
import ApplicationServices
import Carbon

// Values are persisted; names and bundle identifiers are deliberately separate.
enum HubMusicPlayer: String, CaseIterable, Sendable {
    case qqMusic, appleMusic, neteaseMusic
    var name: String {
        switch self { case .qqMusic: return "QQ 音乐"; case .appleMusic: return "音乐"; case .neteaseMusic: return "网易云音乐" }
    }
    var bundleID: String {
        switch self {
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .appleMusic: return "com.apple.Music"
        case .neteaseMusic: return "com.netease.163music"
        }
    }
}

enum HubMusicPlayerSelection: String, CaseIterable, Sendable {
    case automatic, qqMusic, appleMusic, neteaseMusic
    var player: HubMusicPlayer? { HubMusicPlayer(rawValue: rawValue) }
    var title: String { player?.name ?? "自动选择" }
}

struct HubMusicCandidate: Sendable {
    let player: HubMusicPlayer
    let probe: HubQQMusicProbe
    let result: Result<HubQQMusicSnapshot, HubQQMusicFailure>?
    var snapshot: HubQQMusicSnapshot? {
        guard probe.installed, probe.trusted, case .success(let snapshot) = result, snapshot.pid == probe.pid else { return nil }
        return snapshot
    }
}

enum HubMusicSelectionPolicy {
    static func choose(_ candidates: [HubMusicCandidate], previous: HubMusicPlayer) -> HubMusicCandidate? {
        // Keep the active player when several are playing. A paused player must
        // yield to a playing one, but a transient failure must not launch apps.
        let playing = candidates.filter { $0.snapshot?.isPlaying == true }
        if !playing.isEmpty { return playing.first { $0.player == previous } ?? playing.first }
        let connected = candidates.filter { $0.snapshot != nil }
        if !connected.isEmpty { return connected.first { $0.player == previous } ?? connected.first }
        let running = candidates.filter { $0.probe.pid != nil }
        if !running.isEmpty { return running.first { $0.player == previous } ?? running.first }
        let installed = candidates.filter { $0.probe.installed }
        return installed.first { $0.player == previous } ?? installed.first ?? candidates.first
    }
}

// Apple's Music.sdef exposes these public events/properties. Targeting the PID
// rather than a bundle URL is essential: polling must never start an application.
final class HubAppleMusicBackend: HubQQMusicBackend {
    static func code(_ value: String) -> OSType {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
    static func property(_ code: OSType, container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let descriptor = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw HubQQMusicFailure.unavailable("暂时无法读取音乐。")
        }
        return descriptor
    }
    static func actionCode(_ action: HubQQMusicAction) -> OSType {
        switch action { case .toggle: return code("PlPs"); case .previous: return code("Prev"); case .next: return code("Next") }
    }
    func probe() -> HubQQMusicProbe {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HubMusicPlayer.appleMusic.bundleID) != nil
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: HubMusicPlayer.appleMusic.bundleID).first { !$0.isTerminated }
        return HubQQMusicProbe(installed: installed || app != nil, pid: app?.processIdentifier,
                               trusted: app.map { permission(for: $0.processIdentifier, prompt: false) == noErr } ?? false)
    }
    func requestAccess() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: HubMusicPlayer.appleMusic.bundleID).first(where: { !$0.isTerminated }) else { return false }
        return permission(for: app.processIdentifier, prompt: true) == noErr
    }
    private func permission(for pid: pid_t, prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
    }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            let state = try get(Self.property(Self.code("pPlS")), pid: pid, deadline: deadline).enumCodeValue
            let playing: Bool
            switch state {
            case Self.code("kPSP"), Self.code("kPSF"), Self.code("kPSR"): playing = true
            case Self.code("kPSS"), Self.code("kPSp"): playing = false
            default: throw HubQQMusicFailure.unavailable("音乐当前未提供播放状态。")
            }
            let track = try Self.property(Self.code("pTrk"))
            var title = "", artist = ""
            var progress: HubMusicProgress?
            // A stopped/empty library has no current track. That is a usable
            // connected state, not a permission failure or a reason to launch it.
            if state != Self.code("kPSS") {
                title = try get(Self.property(Self.code("pnam"), container: track), pid: pid, deadline: deadline).stringValue ?? ""
                artist = try get(Self.property(Self.code("pArt"), container: track), pid: pid, deadline: deadline).stringValue ?? ""
                // Progress is optional: a stream or unsupported property cannot
                // turn a usable playback connection into an error.
                let progressDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.3)
                if [Self.code("kPSP"), Self.code("kPSp")].contains(state),
                   let elapsed = try? get(Self.property(Self.code("pPos")), pid: pid, deadline: progressDeadline).doubleValue {
                    let sampledAt = ProcessInfo.processInfo.systemUptime
                    if let duration = try? get(Self.property(Self.code("pDur"), container: track), pid: pid, deadline: progressDeadline).doubleValue {
                        progress = HubMusicProgress(elapsed: elapsed, duration: duration, rate: playing ? 1 : 0, sampledAt: sampledAt)
                    }
                }
            }
            try validate(pid)
            return .success(HubQQMusicSnapshot(pid: pid, title: title, artist: artist, isPlaying: playing, progress: progress))
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable("音乐暂时没有响应，请稍后重试。")) }
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        do {
            _ = try send(eventClass: Self.code("hook"), eventID: Self.actionCode(action), directObject: nil,
                         pid: pid, deadline: ProcessInfo.processInfo.systemUptime + 0.8)
            // Never retry a command after a timeout: it may already have run.
            return snapshot(for: pid)
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable("音乐暂时没有响应，请稍后重试。")) }
    }
    private func validate(_ pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw HubQQMusicFailure.notRunning }
        guard app.bundleIdentifier == HubMusicPlayer.appleMusic.bundleID else { throw HubQQMusicFailure.wrongTarget }
    }
    private func get(_ object: NSAppleEventDescriptor, pid: pid_t, deadline: TimeInterval) throws -> NSAppleEventDescriptor {
        try send(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), directObject: object, pid: pid, deadline: deadline)
            .paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }
    private func send(eventClass: AEEventClass, eventID: AEEventID, directObject: NSAppleEventDescriptor?,
                      pid: pid_t, deadline: TimeInterval) throws -> NSAppleEventDescriptor {
        try validate(pid)
        guard permission(for: pid, prompt: false) == noErr else { throw HubQQMusicFailure.permission }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw HubQQMusicFailure.unavailable("音乐响应较慢，请稍后重试。") }
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                                          targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let directObject { event.setParam(directObject, forKeyword: AEKeyword(keyDirectObject)) }
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: min(0.5, remaining))
            let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
            guard code == 0 else { throw failure(code) }
            return reply
        } catch let error as HubQQMusicFailure { throw error }
        catch { throw failure(OSStatus((error as NSError).code)) }
    }
    private func failure(_ code: OSStatus) -> HubQQMusicFailure {
        if code == errAEEventNotPermitted || code == -1744 { return .permission }
        if code == procNotFound { return .notRunning }
        return .unavailable("音乐暂时没有响应，请稍后重试。")
    }
}
