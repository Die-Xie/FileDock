import AppKit
import QuartzCore

/// Native layer-state checks only: the window is never ordered onscreen, and
/// these tests neither synthesize user input nor change accessibility settings.
@main
struct MusicMarqueeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 190, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HubMusicMarqueeView(frame: NSRect(x: 0, y: 0, width: 190, height: 20))
        window.contentView = view
        expect(!window.isVisible && view.window === window,
               "The test host must stay offscreen while attaching its native content")
        view.update(title: "芭乐", artist: "FunkyMo", active: true)
        view.layoutSubtreeIfNeeded()
        let strip = view.layer!.sublayers!.first!
        let texts = strip.sublayers!.compactMap { $0 as? CATextLayer }
        expect(texts.count == 2, "The scrolling line must have one matching duplicate")
        let first = texts[0]
        let duplicate = texts[1]
        expect(first.frame.width < view.bounds.width && first.frame.minX >= 0,
               "Short song information must fit without negative leading space")
        expect(abs(first.frame.midX - view.bounds.midX) <= 1,
               "Short song information must be centered in the available width")
        expect(duplicate.isHidden && noAnimations(strip),
               "A fitting song must not duplicate or animate its text")
        expect(view.hitTest(NSPoint(x: 95, y: 10)) == nil && !view.mouseDownCanMoveWindow,
               "Song information must leave hover and clicks to its parent controls")
        expect(view.accessibilityLabel() == "芭乐，FunkyMo",
               "Assistive readers must receive the complete song and artist")

        let longTitle = "渋谷駅前 (Acoustic Live Session) — 一首需要完整显示的很长歌曲名称"
        let artist = "Artist & Special Guests"
        view.update(title: longTitle, artist: artist, active: true)
        expect(first.frame.width > view.bounds.width && first.frame.minX == 0,
               "Overflow must start from the song beginning instead of a centered crop")
        let attributed = first.string as! NSAttributedString
        expect(attributed.string == "\(longTitle) · \(artist)",
               "The animated line must preserve complete, untruncated song information")
        expect((duplicate.string as? NSAttributedString)?.isEqual(to: attributed) == true,
               "The second line must repeat exactly the same measured text")

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            expect(noAnimations(strip) && duplicate.isHidden,
                   "The current Reduce Motion setting must suppress continuous scrolling")
            print("MusicMarqueeTests: motion checks skipped because Reduce Motion is enabled")
        } else {
            expect(!duplicate.isHidden && duplicate.frame.minX > first.frame.maxX,
                   "Overflow needs a separated second line to loop without an empty reset")
            let key = strip.animationKeys()!.first!
            let animation = strip.animation(forKey: key) as! CAKeyframeAnimation
            let values = animation.values as! [NSNumber]
            let times = animation.keyTimes!
            expect(animation.keyPath == "transform.translation.x" && values.count == 3 && times.count == 3,
                   "The marquee must move its rendered strip using one layer animation")
            expect(values[0].doubleValue == 0 && values[1].doubleValue == 0
                   && times[1].doubleValue > 0 && times[1].doubleValue < 1,
                   "A newly displayed song must pause before its first scrolling segment")
            expect(animation.calculationMode == .linear && animation.repeatCount == .infinity,
                   "Long information must loop at a constant speed")
            expect(abs(-values[2].doubleValue - Double(duplicate.frame.minX)) < 0.01,
                   "The loop distance must place the duplicate exactly at the first line's origin")
            expect(animation.duration.isFinite && animation.duration > 0,
                   "Overflow animation must have a finite, positive reading duration")

            // A unique animation start acts as a position marker. If a normal
            // polling update removes and recreates it, the marker is lost.
            let markedAnimation = animation.copy() as! CAKeyframeAnimation
            markedAnimation.beginTime = 123.25
            strip.add(markedAnimation, forKey: key)
            view.update(title: longTitle, artist: artist, active: true)
            view.layoutSubtreeIfNeeded()
            expect(strip.animation(forKey: key)?.beginTime == 123.25,
                   "Identical playback polling and layout must preserve the reading position")

            view.update(title: longTitle, artist: artist, active: false)
            expect(noAnimations(strip), "Hidden playback information must stop scrolling")
            view.update(title: longTitle, artist: artist, active: true)
            expect(!noAnimations(strip), "Visible overflowing information must restart scrolling")
            window.contentView = nil
            expect(view.window == nil && noAnimations(strip),
                   "Detaching the view from its window must remove continuous animation")
            window.contentView = view
            expect(!noAnimations(strip), "Reattaching active content must restore its marquee")

            view.frame.size.width = first.frame.width + 30
            view.layout()
            expect(noAnimations(strip) && duplicate.isHidden,
                   "A wider viewport that fits the song must stop its previous overflow animation")
        }

        view.dispose()
        view.dispose()
        expect(noAnimations(strip) && first.string == nil && duplicate.string == nil,
               "Disposal must be idempotent and release the attributed song strings")
        view.update(title: "Ignored after disposal", artist: "", active: true)
        expect(noAnimations(strip) && first.string == nil,
               "An already dismantled native view must not restart playback information")
        weak var releasedView: HubMusicMarqueeView?
        autoreleasepool {
            let temporary = HubMusicMarqueeView(frame: NSRect(x: 0, y: 0, width: 190, height: 20))
            releasedView = temporary
            temporary.update(title: longTitle, artist: artist, active: true)
            temporary.dispose()
        }
        expect(releasedView == nil, "Motion observers and layers must not retain a disposed native view")
        expect(!window.isVisible, "Native tests must never display their host window")
        print("MusicMarqueeTests: PASS")
    }

    private static func noAnimations(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).isEmpty
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
