import AppKit
import QuartzCore

@MainActor
private func preferDisplayRate(_ animation: CAAnimation, in window: NSWindow?) {
    let reported = window?.screen?.maximumFramesPerSecond ?? 60
    let maximum = min(240, max(30, reported > 0 ? reported : 60))
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(60, maximum)),
                                                        maximum: Float(maximum), preferred: Float(maximum))
}

@MainActor
private func currentContour(of layer: CAShapeLayer, animationKey: String, animating: Bool) -> CGPath? {
    if let path = layer.presentation()?.path { return path }
    if animating {
        // Before the first rendered frame there is no presentation layer; the
        // model already holds the destination. Reuse the unrendered animation's
        // origin so an immediate reversal cannot jump to that destination.
        if let basic = layer.animation(forKey: animationKey) as? CABasicAnimation,
           let path = contourValue(basic.fromValue) { return path }
        if let frames = layer.animation(forKey: animationKey) as? CAKeyframeAnimation,
           let path = contourValue(frames.values?.first) { return path }
    }
    return layer.path
}

private func contourValue(_ value: Any?) -> CGPath? {
    guard let value, CFGetTypeID(value as CFTypeRef) == CGPath.typeID else { return nil }
    return (value as! CGPath)
}

@MainActor
private func currentOpacity(of layer: CALayer?, animationKey: String, animating: Bool) -> Float {
    if let opacity = layer?.presentation()?.opacity { return opacity }
    if animating, let basic = layer?.animation(forKey: animationKey) as? CABasicAnimation,
       let opacity = basic.fromValue as? NSNumber { return opacity.floatValue }
    return layer?.opacity ?? 0
}

/// Keeps the hosted browser at its final size while a native mask unfolds from
/// the top edge. File icons and text are revealed, rather than being scaled.
@MainActor
final class HubNotchSurface: NSView {
    var effectiveAppearanceDidChange: (() -> Void)?
    private let hostedContent: NSView
    private let glassMaterial = HubGlassMaterialView(frame: .zero)
    private let revealMask = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var attached = true
    private var embedded = false
    private var sourceWidth: CGFloat = 200
    private var reduceMotion = false
    private var animationSpeed = 1.0
    private var presented = false
    private var generation: UInt64 = 0
    private var measuredSize = NSSize.zero
    private weak var shadowWindow: NSWindow?
    private var shadowBeforeAnimation: Bool?
    var animationStateChanged: (() -> Void)?
    private(set) var isAnimating = false { didSet { if oldValue != isAnimating { animationStateChanged?() } } }

    init(contentView: NSView) {
        hostedContent = contentView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = revealMask
        revealMask.fillColor = NSColor.black.cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        outline.lineWidth = 1
        outline.zPosition = 10
        layer?.addSublayer(outline)
        addSubview(glassMaterial)
        hostedContent.wantsLayer = true
        addSubview(hostedContent)
        hostedContent.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let shadowWindow, shadowWindow !== newWindow {
            if let shadowBeforeAnimation { shadowWindow.hasShadow = shadowBeforeAnimation }
            self.shadowBeforeAnimation = nil
            self.shadowWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.effectiveAppearanceDidChange?() }
    }

    func configure(attached: Bool, sourceWidth: CGFloat, bodyColor: NSColor, reduceMotion: Bool, animationSpeed: Double = 1, embedded: Bool = false, liquidGlass: Bool = false) {
        self.attached = attached
        self.embedded = attached && embedded
        self.sourceWidth = max(80, sourceWidth.isFinite ? sourceWidth : 200)
        self.reduceMotion = reduceMotion
        self.animationSpeed = HubNotchMotion.normalizedSpeed(animationSpeed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = liquidGlass ? NSColor.clear.cgColor : bodyColor.cgColor
        glassMaterial.configure(enabled: liquidGlass, cornerRadius: 21,
                                topExtension: attached && !embedded ? 24 : 0)
        // The bridge joins the middle of the body's top edge. A perimeter line
        // here would expose a horizontal seam between two otherwise joined parts.
        outline.isHidden = attached || liquidGlass
        if !isAnimating { applyRestingState() }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassMaterial.frame = bounds
        hostedContent.frame = bounds
        revealMask.frame = bounds
        outline.frame = bounds
        outline.path = roundedPath(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: 20)
        if measuredSize != bounds.size {
            measuredSize = bounds.size
            // Do not replace an in-flight mask when AppKit performs an otherwise
            // harmless layout pass. The completion resolves any changed bounds.
            if !isAnimating { applyRestingState() }
        }
        CATransaction.commit()
    }

    func setPresented(_ value: Bool, animated: Bool, completion: @escaping () -> Void) {
        layoutSubtreeIfNeeded()
        generation &+= 1
        let token = generation
        let fromPath = currentContour(of: revealMask, animationKey: "notchMorph", animating: isAnimating) ?? closedPath()
        let fromOpacity = currentOpacity(of: layer, animationKey: "notchSurfaceOpacity", animating: isAnimating)
        presented = value
        removeTransitionAnimations()

        let morph = attached && !reduceMotion
        let baseDuration = morph ? (value ? HubNotchMotion.openingDuration : HubNotchMotion.bodyClosingDuration) : 0.18
        let duration: CFTimeInterval = reduceMotion ? HubNotchMotion.reducedMotionDuration : HubNotchMotion.scaledDuration(baseDuration, speed: animationSpeed)
        let targetPath = value || !morph ? openPath() : closedPath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.path = targetPath
        layer?.opacity = morph ? 1 : (value ? 1 : 0)
        // Only the contour moves. Keeping file text/icons opaque and at their
        // final positions avoids the blur/trail caused by compositing a second
        // content fade or translation over the changing mask.
        hostedContent.layer?.opacity = 1
        hostedContent.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        guard animated, bounds.width > 0, bounds.height > 0 else {
            isAnimating = false
            applyRestingState()
            restoreWindowShadowIfVisible()
            completion()
            return
        }

        isAnimating = true
        suspendWindowShadow()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isAnimating = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.applyRestingState()
                CATransaction.commit()
                self.restoreWindowShadowIfVisible()
                completion()
            }
        }

        if morph {
            if value {
                let shape = CABasicAnimation(keyPath: "path")
                shape.fromValue = fromPath
                shape.toValue = targetPath
                // The connecting curve shares this timing. File content stays
                // fixed while both masks widen without lateral overshoot.
                shape.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.90, 0.22, 1)
                // An embedded surface already meets the physical top edge,
                // so it needs no wait for the separate connecting neck.
                let lead = !embedded && fromPath.boundingBoxOfPath.height <= 0.01 ? HubNotchMotion.scaledDuration(HubNotchMotion.bodyOpeningLead, speed: animationSpeed) : 0
                shape.duration = duration - lead
                shape.beginTime = CACurrentMediaTime() + lead
                shape.fillMode = .backwards
                preferDisplayRate(shape, in: window)
                revealMask.add(shape, forKey: "notchMorph")
            } else {
                let shape = CABasicAnimation(keyPath: "path")
                shape.fromValue = fromPath
                shape.toValue = targetPath
                shape.duration = duration
                shape.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 0, 0.45, 1)
                preferDisplayRate(shape, in: window)
                revealMask.add(shape, forKey: "notchMorph")
            }
        } else {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = fromOpacity
            opacity.toValue = value ? 1 : 0
            opacity.duration = duration
            opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            preferDisplayRate(opacity, in: window)
            layer?.add(opacity, forKey: "notchSurfaceOpacity")
        }
        CATransaction.commit()
    }

    /// Used when the user begins manually moving/resizing the panel. The content
    /// becomes a normal fully interactive floating surface without a stale hide.
    func cancelAnimationsAndShow() {
        generation &+= 1
        removeTransitionAnimations()
        presented = true
        isAnimating = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRestingState()
        CATransaction.commit()
        restoreWindowShadowIfVisible()
    }

    func containsVisiblePoint(_ point: NSPoint) -> Bool {
        guard (layer?.presentation()?.opacity ?? layer?.opacity ?? 0) > 0.05 else { return false }
        let path = revealMask.presentation()?.path ?? revealMask.path
        return path?.contains(point, using: .winding, transform: .identity) ?? false
    }

    private func applyRestingState() {
        revealMask.path = presented || !attached || reduceMotion ? openPath() : closedPath()
        layer?.opacity = presented ? 1 : 0
        hostedContent.layer?.opacity = presented ? 1 : 0
        hostedContent.layer?.transform = CATransform3DIdentity
    }

    private func removeTransitionAnimations() {
        revealMask.removeAnimation(forKey: "notchMorph")
        layer?.removeAnimation(forKey: "notchSurfaceOpacity")
        hostedContent.layer?.removeAnimation(forKey: "notchContentOpacity")
        hostedContent.layer?.removeAnimation(forKey: "notchContentTranslation")
    }

    private func suspendWindowShadow() {
        guard let window else { return }
        if let oldWindow = shadowWindow, oldWindow !== window {
            if let shadowBeforeAnimation { oldWindow.hasShadow = shadowBeforeAnimation }
            self.shadowBeforeAnimation = nil
        }
        if shadowBeforeAnimation == nil { shadowBeforeAnimation = window.hasShadow }
        shadowWindow = window
        // WindowServer's dynamic alpha shadow can lag a rapidly changing mask.
        // Suspend it for the short reveal; no frame-by-frame invalidation needed.
        if window.hasShadow { window.hasShadow = false }
    }

    private func restoreWindowShadowIfVisible() {
        guard presented, let shadowBeforeAnimation else { return }
        if let shadowWindow {
            shadowWindow.hasShadow = shadowBeforeAnimation
            if shadowBeforeAnimation { shadowWindow.invalidateShadow() }
        }
        self.shadowBeforeAnimation = nil
        shadowWindow = nil
    }

    private func openPath() -> CGPath { roundedPath(in: bounds, radius: 21) }
    private func closedPath() -> CGPath {
        let width = min(bounds.width, sourceWidth + (embedded ? 0 : 12))
        // Zero area means a fresh reveal needs no body-wide delayed opacity
        // fade to conceal a visible pill while the neck is still extending.
        return roundedPath(in: CGRect(x: bounds.midX - width / 2, y: bounds.maxY, width: width, height: 0), radius: 0)
    }

    // Both resting shapes use the same four lines and four cubic curves. Core
    // Animation therefore interpolates corresponding control points smoothly.
    private func roundedPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        let k: CGFloat = 0.552284749831
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control1: CGPoint(x: rect.maxX - r + r * k, y: rect.maxY), control2: CGPoint(x: rect.maxX, y: rect.maxY - r + r * k))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        p.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY), control1: CGPoint(x: rect.maxX, y: rect.minY + r - r * k), control2: CGPoint(x: rect.maxX - r + r * k, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control1: CGPoint(x: rect.minX + r - r * k, y: rect.minY), control2: CGPoint(x: rect.minX, y: rect.minY + r - r * k))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control1: CGPoint(x: rect.minX, y: rect.maxY - r + r * k), control2: CGPoint(x: rect.minX + r - r * k, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A separate click-through window hosts the wide curve. Only its source-width
/// stem reaches the menu bar; the shoulders flatten before the body's corners.
@MainActor
final class HubNotchBridgeView: NSView {
    var sourceWidth: CGFloat = 200 { didSet { updateAppearanceAndGeometry() } }
    var bodyColor: NSColor = .black { didSet { updateAppearanceAndGeometry() } }
    private let glassMaterial = HubGlassMaterialView(frame: .zero)
    private let colorLayer = CAGradientLayer()
    private let liquidMask = CAShapeLayer()
    private var reduceMotion = false
    private var animationSpeed = 1.0
    private var presented = false
    private var generation: UInt64 = 0
    private var liquidGlass = false
    var animationStateChanged: (() -> Void)?
    private(set) var isAnimating = false { didSet { if oldValue != isAnimating { animationStateChanged?() } } }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.mask = liquidMask
        liquidMask.fillColor = NSColor.black.cgColor
        addSubview(glassMaterial)
        colorLayer.startPoint = CGPoint(x: 0.5, y: 0)
        colorLayer.endPoint = CGPoint(x: 0.5, y: 1)
        colorLayer.zPosition = 1
        layer?.addSublayer(colorLayer)
        updateAppearanceAndGeometry()
    }

    required init?(coder: NSCoder) { nil }

    func configure(sourceWidth: CGFloat, bodyColor: NSColor, reduceMotion: Bool, animationSpeed: Double = 1, liquidGlass: Bool = false) {
        self.reduceMotion = reduceMotion
        self.animationSpeed = HubNotchMotion.normalizedSpeed(animationSpeed)
        self.liquidGlass = liquidGlass
        self.sourceWidth = max(80, sourceWidth.isFinite ? sourceWidth : 200)
        self.bodyColor = bodyColor
        updateAppearanceAndGeometry()
    }

    override func layout() {
        super.layout()
        updateAppearanceAndGeometry()
    }

    func setPresented(_ value: Bool, animated: Bool, completion: @escaping () -> Void) {
        layoutSubtreeIfNeeded()
        generation &+= 1
        let token = generation
        let fromPath = currentContour(of: liquidMask, animationKey: "liquidNeck", animating: isAnimating) ?? path(.closed)
        let fromOpacity = currentOpacity(of: layer, animationKey: "liquidFade", animating: isAnimating)
        let depth = min(HubNotchMotion.neckDepth, bounds.height)
        let pathBottom = fromPath.boundingBoxOfPath.minY
        let currentExtent = depth > 0 && pathBottom.isFinite ? min(1, max(0, (bounds.minY + depth - pathBottom) / depth)) : 0
        let stemWidth = HubNotchMotion.stemWidth(in: bounds, sourceWidth: sourceWidth)
        let currentFlare = max(0, (fromPath.boundingBoxOfPath.width - stemWidth) / 2)
        let availableFlare = HubNotchMotion.connectionFlare(in: bounds, sourceWidth: sourceWidth)
        let currentShoulder = currentExtent > 0 && availableFlare > 0 ? min(1, currentFlare / (availableFlare * currentExtent)) : 0
        presented = value
        liquidMask.removeAnimation(forKey: "liquidNeck")
        layer?.removeAnimation(forKey: "liquidFade")
        let baseDuration = value ? HubNotchMotion.openingDuration : HubNotchMotion.closingDuration
        let duration = reduceMotion ? HubNotchMotion.reducedMotionDuration : HubNotchMotion.scaledDuration(baseDuration, speed: animationSpeed)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liquidMask.path = path(value || reduceMotion ? .open : .closed)
        // Retain the connecting material for the whole closing morph. Its tail
        // is only hidden after it has been absorbed back into the notch.
        layer?.opacity = reduceMotion ? (value ? 1 : 0) : 1
        CATransaction.commit()
        guard animated, bounds.width > 0, bounds.height > 0 else {
            isAnimating = false
            settle()
            completion()
            return
        }

        isAnimating = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isAnimating = false
                self.settle()
                completion()
            }
        }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = value ? 1 : 0
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            preferDisplayRate(fade, in: window)
            layer?.add(fade, forKey: "liquidFade")
        } else {
            let shape = CAKeyframeAnimation(keyPath: "path")
            if value {
                // First reach the body at source width. Only then widen, using
                // the body's exact lead/duration/easing so no unsupported wings
                // appear beside a browser that is still narrow.
                if currentExtent < 0.999 || currentShoulder <= 0.001 {
                    let lead = HubNotchMotion.bodyOpeningLead / HubNotchMotion.openingDuration
                    shape.values = [fromPath, path(.init(extent: 1, shoulder: 0)), path(.open)]
                    shape.keyTimes = [0, NSNumber(value: lead), 1]
                    shape.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.14, 0.85, 0.30, 1),
                                             CAMediaTimingFunction(controlPoints: 0.16, 0.90, 0.22, 1)]
                } else {
                    shape.values = [fromPath, path(.open)]
                    shape.keyTimes = [0, 1]
                    shape.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.16, 0.90, 0.22, 1)]
                }
            } else if currentExtent < 0.999 {
                // Reversing before the neck has reached the body must absorb
                // the existing material, not complete its opening first.
                shape.values = [fromPath,
                                path(.init(extent: currentExtent * 0.60, shoulder: currentShoulder)),
                                path(.closed)]
                shape.keyTimes = [0, 0.68, 1]
                shape.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
            } else {
                // Narrow in step with the body's top edge, then absorb the
                // source-width stem after the browser has finished closing.
                let contraction = HubNotchMotion.bodyClosingDuration / HubNotchMotion.closingDuration
                shape.values = [fromPath, path(.init(extent: 1, shoulder: 0)), path(.closed)]
                shape.keyTimes = [0, NSNumber(value: contraction), 1]
                shape.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.30, 0, 0.45, 1),
                                         CAMediaTimingFunction(name: .easeOut)]
            }
            shape.duration = duration
            shape.calculationMode = .linear
            preferDisplayRate(shape, in: window)
            liquidMask.add(shape, forKey: "liquidNeck")
        }
        CATransaction.commit()
    }

    func cancelAnimationsAndShow() {
        generation &+= 1
        liquidMask.removeAnimation(forKey: "liquidNeck")
        layer?.removeAnimation(forKey: "liquidFade")
        presented = true
        isAnimating = false
        settle()
    }

    func containsVisiblePoint(_ point: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(point),
              currentOpacity(of: layer, animationKey: "liquidFade", animating: isAnimating) > 0.05 else { return false }
        let contour = currentContour(of: liquidMask, animationKey: "liquidNeck", animating: isAnimating)
        return contour?.contains(point, using: .winding, transform: .identity) ?? false
    }

    private func path(_ state: HubNotchMotion.NeckState) -> CGPath {
        HubNotchMotion.neckPath(in: bounds, sourceWidth: sourceWidth, state: state)
    }

    private func updateAppearanceAndGeometry() {
        guard layer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liquidMask.frame = bounds
        glassMaterial.frame = bounds
        glassMaterial.configure(enabled: liquidGlass, cornerRadius: 0, topExtension: 24, bottomExtension: 24)
        colorLayer.frame = bounds
        colorLayer.colors = [liquidGlass ? NSColor.clear.cgColor : bodyColor.usingColorSpace(.deviceRGB)?.cgColor ?? bodyColor.cgColor,
                             NSColor.black.cgColor]
        colorLayer.locations = [0, NSNumber(value: min(1, 14 / max(1, bounds.height)))]
        // Settings and incidental layout passes must not reset an active morph.
        if !isAnimating {
            liquidMask.path = path(presented || reduceMotion ? .open : .closed)
            layer?.opacity = presented ? 1 : 0
        }
        CATransaction.commit()
    }

    private func settle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liquidMask.path = path(presented || reduceMotion ? .open : .closed)
        layer?.opacity = presented ? 1 : 0
        CATransaction.commit()
    }
}
