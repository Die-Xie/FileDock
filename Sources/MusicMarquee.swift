import AppKit
import QuartzCore
import SwiftUI

/// A single, measured line of song information. Core Animation moves the already
/// rendered text so routine playback-state updates do not restart its position.
@MainActor
struct HubMusicMarquee: NSViewRepresentable {
    let title: String
    let artist: String
    let active: Bool

    func makeNSView(context: Context) -> HubMusicMarqueeView {
        HubMusicMarqueeView()
    }

    func updateNSView(_ view: HubMusicMarqueeView, context: Context) {
        view.update(title: title, artist: artist, active: active)
    }

    static func dismantleNSView(_ view: HubMusicMarqueeView, coordinator: ()) {
        view.dispose()
    }
}

@MainActor
final class HubMusicMarqueeView: NSView {
    private let strip = CALayer()
    private let first = CATextLayer()
    private let duplicate = CATextLayer()
    private let motionNotifications = NSWorkspace.shared.notificationCenter
    private var title = ""
    private var artist = ""
    private var active = false
    private var textSize = NSSize.zero
    private var laidOutSize = NSSize(width: -1, height: -1)
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var isDisposed = false
    private let spacing: CGFloat = 28
    private let animationKey = "hub.song-marquee"

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
        for textLayer in [first, duplicate] {
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
            strip.addSublayer(textLayer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        motionNotifications.addObserver(self,
            selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        updateScale()
    }

    required init?(coder: NSCoder) { nil }

    // The parent owns hovering and its playback buttons. This text should not
    // introduce a native view that intercepts either interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(title: String, artist: String, active: Bool) {
        guard !isDisposed else { return }
        let changedText = self.title != title || self.artist != artist
        let changedActivity = self.active != active
        self.title = title
        self.artist = artist
        self.active = active
        if changedText {
            updateText()
            arrangeText(restartAnimation: true)
        } else if changedActivity {
            updateAnimation()
        }
    }

    override func layout() {
        super.layout()
        guard !isDisposed, laidOutSize != bounds.size else { return }
        arrangeText(restartAnimation: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isDisposed else { return }
        updateScale()
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !isDisposed else { return }
        // Recolor existing layers without changing their animated transform.
        updateText()
    }

    private func updateText() {
        var primary = NSColor.labelColor
        var secondary = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            primary = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            secondary = NSColor(cgColor: NSColor.secondaryLabelColor.cgColor) ?? .secondaryLabelColor
        }
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: primary
        ])
        if !artist.isEmpty {
            text.append(NSAttributedString(string: " · \(artist)", attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: secondary
            ]))
        }
        let measured = text.size()
        textSize = NSSize(width: ceil(measured.width), height: ceil(measured.height) + 2)
        withoutImplicitAnimations {
            first.string = text
            duplicate.string = text
        }
        setAccessibilityLabel(artist.isEmpty ? title : "\(title)，\(artist)")
    }

    private func arrangeText(restartAnimation: Bool) {
        laidOutSize = bounds.size
        let overflowing = textSize.width > bounds.width
        let originX = overflowing ? 0 : floor((bounds.width - textSize.width) / 2)
        let originY = floor((bounds.height - textSize.height) / 2)
        withoutImplicitAnimations {
            strip.frame = NSRect(x: 0, y: 0,
                                 width: max(bounds.width, (textSize.width + spacing) * 2),
                                 height: bounds.height)
            first.frame = NSRect(origin: NSPoint(x: originX, y: originY), size: textSize)
            duplicate.frame = NSRect(origin: NSPoint(x: textSize.width + spacing, y: originY), size: textSize)
            duplicate.isHidden = !overflowing || reduceMotion
        }
        if restartAnimation { strip.removeAnimation(forKey: animationKey) }
        updateAnimation()
    }

    private func updateAnimation() {
        guard !isDisposed else { return }
        let shouldMove = active && window != nil && !reduceMotion
            && bounds.width > 0 && bounds.height > 0 && textSize.width > bounds.width
        guard shouldMove else {
            strip.removeAnimation(forKey: animationKey)
            return
        }
        guard strip.animation(forKey: animationKey) == nil else { return }
        let distance = textSize.width + spacing
        let pause = 0.8
        let duration = Double(distance / 28) + pause
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -Double(distance)]
        animation.keyTimes = [0, NSNumber(value: pause / duration), 1]
        animation.duration = duration
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        strip.add(animation, forKey: animationKey)
    }

    @objc private func displayOptionsChanged() {
        let updated = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard updated != reduceMotion, !isDisposed else { return }
        reduceMotion = updated
        arrangeText(restartAnimation: true)
    }

    private func updateScale() {
        guard !isDisposed else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        withoutImplicitAnimations {
            first.contentsScale = scale
            duplicate.contentsScale = scale
        }
    }

    private func withoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        strip.removeAllAnimations()
        motionNotifications.removeObserver(self)
        first.string = nil
        duplicate.string = nil
    }

    deinit {
        motionNotifications.removeObserver(self)
    }
}
