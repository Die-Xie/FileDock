import AppKit
import QuartzCore
import SwiftUI

@MainActor struct HubMusicProgressTrack: NSViewRepresentable {
    let progress: HubMusicProgress?
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> HubMusicProgressView { HubMusicProgressView() }
    func updateNSView(_ view: HubMusicProgressView, context: Context) {
        view.update(progress: progress, active: active, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: HubMusicProgressView, coordinator: ()) { view.dispose() }
}

/// Two layers, no display timer or view-wide animation. Progress does not
/// intercept hover, clicks, file drags or native window movement.
@MainActor final class HubMusicProgressView: NSView {
    private let fill = CALayer()
    private var progress: HubMusicProgress?
    private var active = false, reduceMotion = false, disposed = false
    private var renderedSize = CGSize(width: -1, height: -1)
    private let animationKey = "filedock.music-progress"
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(fill)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L("音乐播放进度"))
        recolor()
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityValue() -> Any? {
        progress?.description
    }
    func update(progress: HubMusicProgress?, active: Bool, reduceMotion: Bool) {
        guard !disposed, self.progress != progress || self.active != active || self.reduceMotion != reduceMotion else { return }
        self.progress = progress; self.active = active; self.reduceMotion = reduceMotion
        render()
    }
    override func layout() {
        super.layout()
        guard renderedSize != bounds.size else { return }
        render()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); render() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); render() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor() }

    private func render() {
        guard !disposed else { return }
        renderedSize = bounds.size
        let now = ProcessInfo.processInfo.systemUptime
        let width = bounds.width.isFinite ? max(0, bounds.width) : 0
        let height = bounds.height.isFinite ? max(0, bounds.height) : 0
        fill.removeAnimation(forKey: animationKey)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = height / 2
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        fill.cornerRadius = height / 2; fill.contentsScale = layer?.contentsScale ?? 2
        fill.position = CGPoint(x: 0, y: height / 2)
        let start = width * CGFloat(progress?.fraction(at: now) ?? 0)
        fill.bounds = CGRect(x: 0, y: 0, width: start, height: height)
        if active, !reduceMotion, window != nil, width > 0, height > 0, let progress, progress.rate > 0 {
            let remaining = max(0, HubMusicProgress.maximumExtrapolation - max(0, now - progress.sampledAt))
            let duration = min(remaining, (progress.duration - progress.position(at: now)) / progress.rate)
            if duration > 0 {
                let end = width * CGFloat(progress.fraction(at: now + duration))
                fill.bounds.size.width = end
                let animation = CABasicAnimation(keyPath: "bounds.size.width")
                animation.fromValue = start; animation.toValue = end; animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                fill.add(animation, forKey: animationKey)
            }
        }
        CATransaction.commit()
    }
    private func recolor() {
        guard !disposed else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.65).cgColor
            CATransaction.commit()
        }
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true; fill.removeAllAnimations(); progress = nil
    }
}
