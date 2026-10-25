import AppKit
import SwiftUI
import QuartzCore

private final class MusicProgressFixture: HubQQMusicBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var timingAvailable = true
    func removeTiming() { lock.lock(); timingAvailable = false; lock.unlock() }
    func probe() -> HubQQMusicProbe { .init(installed: true, pid: 4242, trusted: true) }
    func requestAccess() -> Bool { preconditionFailure("Fixture must never prompt") }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        lock.lock(); defer { lock.unlock() }
        return .success(.init(pid: pid, title: "蝴蝶 (Demo)", artist: "魏诗莹 (Wishbao)", isPlaying: false,
                       progress: timingAvailable ? HubMusicProgress(elapsed: 100, duration: 240, rate: 0) : nil))
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        preconditionFailure("Fixture must never control playback")
    }
}

@main struct MusicProgressTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let paused = HubMusicProgress(elapsed: 100, duration: 400, rate: 0, sampledAt: 1000)!
        precondition(paused.position(at: 2000) == 100 && paused.fraction(at: 2000) == 0.25)
        let playing = HubMusicProgress(elapsed: 100, duration: 400, rate: 1, sampledAt: 1000)!
        precondition(playing.position(at: 1002) == 102 && playing.position(at: 2000) == 105)
        precondition(playing.position(at: 999) == 100 && playing.position(at: .nan) == 100)
        precondition(HubMusicProgress(elapsed: 399, duration: 400, rate: 4, sampledAt: 1000)!.position(at: 1005) == 400)
        precondition(HubMusicProgress(elapsed: 401, duration: 400, rate: 0)!.elapsed == 400)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            precondition(HubMusicProgress(elapsed: invalid, duration: 400, rate: 1) == nil)
            precondition(HubMusicProgress(elapsed: 1, duration: invalid, rate: 1) == nil)
            precondition(HubMusicProgress(elapsed: 1, duration: 400, rate: invalid) == nil)
        }
        precondition(HubMusicProgress(elapsed: 500, duration: 400, rate: 0) == nil)
        precondition(HubMusicProgress(elapsed: 1, duration: 0, rate: 0) == nil)
        precondition(HubMusicProgress(elapsed: 1, duration: 604_801, rate: 0) == nil)
        precondition(HubMusicProgress.clock(65) == "1:05" && HubMusicProgress.clock(3665) == "1:01:05")
        precondition(paused.matches(HubMusicProgress(elapsed: 100, duration: 400, rate: 0, sampledAt: 2000)!))
        precondition(!playing.matches(HubMusicProgress(elapsed: 100, duration: 400, rate: 1, sampledAt: 2000)!))

        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 20), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = HubMusicProgressView(frame: CGRect(x: 0, y: 0, width: 200, height: 2))
        panel.contentView = view
        view.update(progress: paused, active: true, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let fill = view.layer!.sublayers![0]
        precondition(abs(fill.bounds.width - 50) < 0.1 && fill.animationKeys()?.isEmpty != false)
        precondition(view.hitTest(.zero) == nil && view.accessibilityValue() as? String == "1:40 / 6:40")
        let current = HubMusicProgress(elapsed: 100, duration: 400, rate: 1)!
        view.update(progress: current, active: true, reduceMotion: false)
        let animation = fill.animation(forKey: "filedock.music-progress") as! CABasicAnimation
        precondition(animation.duration > 0 && animation.duration <= 5)
        precondition((animation.toValue as! CGFloat) <= 52.6)
        view.update(progress: current, active: false, reduceMotion: false)
        precondition(fill.animationKeys()?.isEmpty != false)
        view.update(progress: current, active: true, reduceMotion: true)
        precondition(fill.animationKeys()?.isEmpty != false)
        view.update(progress: nil, active: true, reduceMotion: false)
        precondition(fill.bounds.width == 0 && view.accessibilityValue() == nil)
        view.dispose(); view.update(progress: current, active: true, reduceMotion: false)
        precondition(fill.animationKeys()?.isEmpty != false && !panel.isVisible)
        panel.contentView = nil; panel.close()
        let fixture = MusicProgressFixture()
        let controller = HubQQMusicController(pollInterval: 3600, backends: [.appleMusic: fixture])
        controller.setPlayerSelection(.appleMusic)
        controller.setEnabled(true); controller.setVisible(true)
        let deadline = Date().addingTimeInterval(3)
        while controller.status != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(controller.status == .ready && controller.progress?.elapsed == 100)
        var layoutHeights: [Bool: CGFloat] = [:]
        for timingAvailable in [true, false] {
            if !timingAvailable {
                fixture.removeTiming(); controller.reconnect()
                let deadline = Date().addingTimeInterval(3)
                while controller.progress != nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(controller.status == .ready && controller.progress == nil,
                             "Missing timing must clear old progress without disconnecting")
            }
            for compact in [true, false] {
                let width: CGFloat = compact ? 240 : 683, height: CGFloat = compact ? 25 : 60
                let host = NSHostingView(rootView: HubQQMusicBar(controller: controller, compact: compact, compactWidth: width)
                    .frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                settle(host)
                if let expected = layoutHeights[compact] {
                    precondition(abs(host.fittingSize.height - expected) < 0.01,
                                 "Timing appearance/disappearance must never reflow either music layout")
                } else { layoutHeights[compact] = host.fittingSize.height }
                let tracks = descendants(host).compactMap { $0 as? HubMusicProgressView }
                precondition(tracks.count == (timingAvailable ? 1 : 0) && !window.isVisible,
                             "Unsupported timing must produce no track or placeholder")
                if let track = tracks.first {
                    let frame = host.convert(track.bounds, from: track)
                    precondition(frame.minY >= 0 && frame.maxY <= host.bounds.height && frame.width > 100 && frame.height == 2,
                                 "Both music placements must fully contain the thin progress track")
                }
                if let folder = ProcessInfo.processInfo.environment["FILEDOCK_MUSIC_CAPTURE_DIR"] {
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = (compact ? "compact" : "bottom") + (timingAvailable ? "" : "-unsupported") + ".png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
                }
                window.contentView = nil; window.close()
            }
        }
        controller.setVisible(false)
        print("PASS: real progress normalization, bounded monotonic advancement, pause/clock formatting, invalid and missing timing, unsupported track absence, native timer-free animation, hidden/reduced-motion/disposal and event pass-through")
    }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
