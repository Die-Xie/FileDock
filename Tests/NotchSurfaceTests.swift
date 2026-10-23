import AppKit
import QuartzCore

/// Offscreen state tests: no windows are ordered onscreen and no user input is generated.
/// These verify animation lifecycle and layout contracts, not rendered timing,
/// visual spring quality, hardware-notch alignment, or frame-rate performance.
@main
struct NotchSurfaceTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let content = NSView(frame: .zero)
        let surface = HubNotchSurface(contentView: content)
        surface.frame = NSRect(x: 0, y: 0, width: 820, height: 460)
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        surface.layoutSubtreeIfNeeded()
        expect(!surface.isAnimating, "A new hidden surface must be at rest")
        expect(surface.layer?.opacity == 0, "A new surface must not flash its body")
        expect(content.layer?.opacity == 0, "Hidden file content must not be visible")
        let fixedFrame = content.frame
        expect(fixedFrame == surface.bounds, "The browser must receive its final layout before revealing")

        var immediateCompletion = 0
        surface.setPresented(true, animated: false) { immediateCompletion += 1 }
        expect(immediateCompletion == 1 && !surface.isAnimating, "Immediate show must settle and complete once")
        expect(surface.layer?.opacity == 1 && content.layer?.opacity == 1, "Immediate show must expose the browser")
        expect(maskBounds(surface) == surface.bounds, "An expanded surface must expose its complete body")
        expect(surface.containsVisiblePoint(NSPoint(x: 410, y: 230)), "The visible body must participate in hit testing")

        surface.setPresented(false, animated: false) { immediateCompletion += 1 }
        expect(immediateCompletion == 2 && surface.layer?.opacity == 0, "Immediate close must settle and complete once")
        expect(!surface.containsVisiblePoint(NSPoint(x: 410, y: 230)), "Hidden body must not count as a pointer destination")
        expect(maskBounds(surface).height == 0, "Attached collapse must have no visible seed before the neck arrives")
        expect(abs(maskBounds(surface).maxY - surface.bounds.maxY) < 0.01, "The collapse seed must remain anchored to the top")

        var animatedOpenCompletions = 0
        surface.setPresented(true, animated: true) { animatedOpenCompletions += 1 }
        expect(surface.isAnimating, "Animated show must expose an in-flight state")
        expect(content.frame == fixedFrame, "Opening must not resize or reflow browser content")
        expect((content.layer?.animationKeys() ?? []).isEmpty && CATransform3DIsIdentity(content.layer!.transform) && content.layer?.opacity == 1,
               "Text and icons must be revealed at full opacity with no trailing content motion")
        expect((surface.layer?.animationKeys() ?? []).isEmpty, "Attached body must not cross-fade over its contour reveal")
        let bodyMotion = animations(surface.layer?.mask).first!
        expect(endDelay(bodyMotion) <= 0.33, "Fresh body opening must finish within the lightweight response budget")
        expect(bodyMotion.preferredFrameRateRange.maximum >= 30 && bodyMotion.preferredFrameRateRange.maximum <= 240,
               "Contour animation must request an explicit bounded display refresh rate")
        drainMainRunLoop(for: 0.40)
        expect(animatedOpenCompletions == 1 && !surface.isAnimating, "An uninterrupted open must complete exactly once and return to rest")
        expect(content.frame == fixedFrame, "Animation completion must preserve final browser dimensions")

        // A close completion typically orders the NSPanel out. Reversing a
        // transition must invalidate it so it cannot hide the newly open panel.
        var obsoleteCloseCompletions = 0
        var reopenedCompletions = 0
        surface.setPresented(true, animated: false) { }
        surface.setPresented(false, animated: true) { obsoleteCloseCompletions += 1 }
        expect(surface.isAnimating, "Animated close must expose an in-flight state")
        expect(content.frame == fixedFrame, "Closing must not resize or reflow browser content")
        expect(content.layer?.opacity == 1 && (content.layer?.animationKeys() ?? []).isEmpty,
               "Closing must preserve sharp static content until the mask conceals it")
        expect(animations(surface.layer?.mask).allSatisfy { endDelay($0) <= 0.24 }, "Body closing must not retain a long tail")
        surface.setPresented(true, animated: false) { reopenedCompletions += 1 }
        drainMainRunLoop(for: 0.35)
        expect(obsoleteCloseCompletions == 0, "A reversed close must never execute its stale completion")
        expect(reopenedCompletions == 1, "The current show completion must execute exactly once")
        expect(surface.layer?.opacity == 1 && maskBounds(surface) == surface.bounds, "Reversal must leave a fully open surface")
        expect(content.frame == fixedFrame, "Rapid reversal must preserve the browser's final dimensions")

        var interruptedAnimatedCloseCompletions = 0
        var animatedReopenCompletions = 0
        surface.setPresented(false, animated: true) { interruptedAnimatedCloseCompletions += 1 }
        surface.setPresented(true, animated: true) { animatedReopenCompletions += 1 }
        expect(surface.isAnimating, "Animated reversal must remain in flight until the new transition settles")
        expect(content.frame == fixedFrame, "Animated reversal must not reflow file content")
        drainMainRunLoop(for: 0.40)
        expect(interruptedAnimatedCloseCompletions == 0, "Animated reopening must suppress the interrupted close callback")
        expect(animatedReopenCompletions == 1 && !surface.isAnimating,
               "Only the new animated reopen may complete, exactly once")
        expect(surface.layer?.opacity == 1 && content.layer?.opacity == 1 && maskBounds(surface) == surface.bounds,
               "Animated reopening must settle in a fully visible, expanded state")

        var cancelledCloseCompletions = 0
        surface.setPresented(false, animated: true) { cancelledCloseCompletions += 1 }
        surface.cancelAnimationsAndShow()
        drainMainRunLoop(for: 0.30)
        expect(cancelledCloseCompletions == 0, "Dragging a retracting panel must cancel its old hide completion")
        expect(!surface.isAnimating && surface.layer?.opacity == 1 && content.layer?.opacity == 1,
               "Cancelling animation for manual movement must produce an interactive visible surface")

        for (attached, reduced, title) in [(true, true, "Reduce Motion"), (false, false, "Floating")] {
            surface.configure(attached: attached, sourceWidth: 200, bodyColor: .black, reduceMotion: reduced)
            surface.setPresented(false, animated: false) { }
            surface.setPresented(true, animated: true) { }
            expect(maskBounds(surface) == surface.bounds, "\(title) must use a full-size mask rather than an expanding crop")
            expect(content.frame == fixedFrame, "\(title) must preserve browser layout")
            if reduced {
                let durations = surface.layer?.animationKeys()?.compactMap { surface.layer?.animation(forKey: $0)?.duration } ?? []
                expect(!durations.isEmpty && durations.allSatisfy { $0 <= 0.15 }, "Reduce Motion must use only a short fade")
            }
            surface.cancelAnimationsAndShow()
            surface.setPresented(false, animated: true) { }
            expect(content.layer?.opacity == 1, "\(title) close must fade the whole surface without popping file content away first")
            expect(maskBounds(surface) == surface.bounds, "\(title) close must not retract into a notch shape")
            surface.setPresented(false, animated: false) { }
            expect(surface.layer?.opacity == 0 && content.layer?.opacity == 0, "\(title) must end fully hidden")
        }

        // Changing layout while hidden must recompute the top-anchored seed;
        // reopening must reveal the new size without keeping the old clip.
        surface.configure(attached: true, sourceWidth: 240, bodyColor: .black, reduceMotion: false)
        surface.frame.size = NSSize(width: 980, height: 540)
        surface.layoutSubtreeIfNeeded()
        surface.setPresented(true, animated: false) { }
        expect(content.frame == surface.bounds && maskBounds(surface) == surface.bounds,
               "A resized panel must reveal the current bounds and content layout")

        testLiquidBridge()
        testConnectionBodySynchronization()
        testNoInwardNeckGeometry()
        testAnimationSpeed()
        testZeroFrameReversal()
        testWindowShadowLifecycle()
        testEmbeddedSurface()
        testGlassMaterial()

        print("PASS: continuous connection curves, no inward/outward bulges, animation-speed limits, static content, zero-frame reversal, reduced motion, window-shadow lifecycle, passive fixed dark glass")
        print("LIMIT: offscreen layers do not establish rendered spring smoothness, display timing, or physical-notch alignment")
    }

    @MainActor private static func maskBounds(_ surface: HubNotchSurface) -> CGRect {
        (surface.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath ?? .null
    }

    @MainActor private static func testGlassMaterial() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        parent.appearance = NSAppearance(named: .aqua)
        let material = HubGlassMaterialView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        parent.addSubview(material)
        material.configure(enabled: true, topExtension: 24, reduceTransparency: false)
        material.layoutSubtreeIfNeeded()
        expect(material.hitTest(NSPoint(x: 100, y: 100)) == nil && !material.acceptsFirstResponder,
               "Glass must not intercept file dragging, clicks or keyboard focus")
        expect(material.layer?.backgroundColor?.alpha == 0 && !material.isOpaque,
               "The glass must have no opaque fill covering the native material")
        expect(material.subviews.count == 1 && material.subviews[0].frame == NSRect(x: 0, y: 0, width: 700, height: 424),
               "A connecting material must overscan its top without moving hosted content")
        if #available(macOS 26.0, *) {
            expect(material.renderingMode == .nativeGlass && material.subviews[0] is NSGlassEffectView,
                   "macOS 26 must use the system's native Liquid Glass")
            let native = material.subviews[0] as! NSGlassEffectView
            expect(native.style == .regular && native.tintColor == nil && native.cornerRadius == 21 && native.contentView != nil &&
                   native.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                   "A light parent must still show fixed dark regular glass, using the supported content slot")
            parent.appearance = NSAppearance(named: .darkAqua)
            expect(native.style == .regular && native.tintColor == nil &&
                   native.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                   "Changing the parent appearance must preserve the fixed dark glass without reconfiguration")
            parent.appearance = NSAppearance(named: .aqua)
            expect(native.style == .regular && native.tintColor == nil && material.alphaValue == 1 && native.alphaValue == 1 &&
                   native.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                   "Returning the parent to light mode must preserve dark glass without fading content")
        } else {
            expect(material.renderingMode == .visualEffect && material.subviews[0] is NSVisualEffectView,
                   "Earlier macOS must use its supported native visual material")
            let native = material.subviews[0] as! NSVisualEffectView
            expect(native.material == .hudWindow && native.blendingMode == .behindWindow && native.state == .active &&
                   native.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                   "The compatibility material must also stay dark and blend with windows behind this panel")
        }
        let nativeMaterial = material.subviews[0]
        parent.appearance = NSAppearance(named: .aqua)
        material.configure(enabled: true, reduceTransparency: true)
        let light = NSColor(cgColor: material.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!
        expect(material.renderingMode == .solid && material.isOpaque && nativeMaterial.isHidden && light.alphaComponent == 1,
               "Reduce Transparency must replace glass with a readable, fully opaque semantic color")
        parent.appearance = NSAppearance(named: .darkAqua)
        material.configure(enabled: true, reduceTransparency: true)
        let dark = NSColor(cgColor: material.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!
        expect(light == dark && dark.redComponent + dark.greenComponent + dark.blueComponent < 1,
               "Reduced-transparency fallback must remain an opaque dark semantic color when its parent's appearance changes")
        material.configure(enabled: true, reduceTransparency: false)
        expect(nativeMaterial === material.subviews[0] && !nativeMaterial.isHidden && material.layer?.backgroundColor?.alpha == 0,
               "Restoring transparency must reuse the native material and remove the accessibility fill")
        expect(nativeMaterial.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
               "Restored native glass must retain the fixed dark appearance")
        material.configure(enabled: false, reduceTransparency: false)
        expect(material.isHidden && nativeMaterial.isHidden && material.renderingMode == .hidden,
               "Disabling glass must stop rendering its native material")

        let content = NSView(frame: .zero)
        let surface = HubNotchSurface(contentView: content)
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 460)
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false, liquidGlass: true)
        surface.layoutSubtreeIfNeeded()
        surface.setPresented(true, animated: false) { }
        let contentFrame = content.frame
        let glass = surface.subviews[0] as! HubGlassMaterialView
        expect(surface.subviews.last === content && surface.layer?.backgroundColor?.alpha == 0 && !glass.isHidden,
               "The unchanged browser must stay above a clear native material background")
        surface.setPresented(false, animated: true) { }
        let mask = surface.layer?.mask
        let keys = mask?.animationKeys()
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .white, reduceMotion: false, liquidGlass: false)
        expect(surface.isAnimating && mask?.animationKeys() == keys && content.frame == contentFrame && glass.isHidden,
               "Switching material must not cancel a contour animation or reflow file content")
        expect(surface.layer?.backgroundColor?.alpha == 1,
               "Returning to the solid theme must restore its opaque background")
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false, embedded: true, liquidGlass: true)
        surface.cancelAnimationsAndShow()
        surface.layoutSubtreeIfNeeded()
        expect((glass.renderingMode == .solid || glass.subviews.first?.frame == surface.bounds) && content.frame == contentFrame,
               "Embedded glass must use the body's real outline without a curved-bridge overscan")

        let bridge = HubNotchBridgeView(frame: NSRect(x: 0, y: 0, width: 800, height: 64))
        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false, liquidGlass: true)
        bridge.layoutSubtreeIfNeeded()
        bridge.setPresented(true, animated: false) { }
        let bridgeGlass = bridge.subviews[0] as! HubGlassMaterialView
        expect(!bridgeGlass.isHidden && (bridgeGlass.renderingMode == .solid || bridgeGlass.subviews.first?.frame == NSRect(x: 0, y: -24, width: 800, height: 112)),
               "The connecting glass must extend beyond both clipped edges to avoid a native rim at the seam")
        expect(bridgeGlass.hitTest(NSPoint(x: 400, y: 20)) == nil,
               "The connecting material must remain click-through")
        let gradient = bridge.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        let colors = gradient?.colors as? [CGColor]
        expect(colors?.first?.alpha == 0 && colors?.last?.alpha == 1,
               "Glass should transition continuously from transparent material to the physical black notch")
        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false, liquidGlass: false)
        expect(bridgeGlass.isHidden && bridge.containsVisiblePoint(NSPoint(x: 400, y: 10)),
               "Disabling glass must preserve the existing bridge contour and hit region")
    }

    @MainActor private static func testEmbeddedSurface() {
        let content = NSView(frame: .zero)
        let surface = HubNotchSurface(contentView: content)
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 480)
        surface.configure(attached: true, sourceWidth: 212, bodyColor: .black, reduceMotion: false, embedded: true)
        surface.layoutSubtreeIfNeeded()
        let fixedFrame = content.frame
        let mask = surface.layer?.mask as! CAShapeLayer
        let collapsed = mask.path!
        expect(collapsed.boundingBoxOfPath.height == 0 && collapsed.boundingBoxOfPath.width == 212,
               "An embedded reveal must begin at the hardware-width top seed without a visible pill")
        expect(collapsed.boundingBoxOfPath.maxY == surface.bounds.maxY,
               "An embedded reveal must originate at the physical top edge")

        surface.setPresented(true, animated: false) { }
        let expanded = mask.path!
        expect(expanded.boundingBoxOfPath == surface.bounds && topFlatWidth(expanded) == surface.bounds.width - 42,
               "The embedded surface must meet the screen top while retaining its 21-point outer corners")
        expect(!surface.containsVisiblePoint(NSPoint(x: 2, y: 475)) && !surface.containsVisiblePoint(NSPoint(x: 898, y: 475)),
               "Embedded top outer corners must retain the existing rounded window silhouette")
        expect(!surface.containsVisiblePoint(NSPoint(x: 2, y: 2)) && !surface.containsVisiblePoint(NSPoint(x: 898, y: 2)),
               "Embedded bottom outer corners must remain rounded")
        expect(surface.containsVisiblePoint(NSPoint(x: 450, y: 479)),
               "The embedded central top edge must remain filled beside the hardware cutout")
        expect(pathCommands(collapsed) == pathCommands(expanded),
               "Embedded open and closed paths must retain matching interpolation commands")

        for speed in [0.5, 1.0, 2.0] {
            surface.configure(attached: true, sourceWidth: 212, bodyColor: .black, reduceMotion: false, animationSpeed: speed, embedded: true)
            surface.setPresented(false, animated: false) { }
            surface.setPresented(true, animated: true) { }
            let opening = animations(mask).first as! CABasicAnimation
            expect(abs(opening.duration - HubNotchMotion.openingDuration / speed) < 0.0001,
                   "Embedded opening must use the selected full duration without a neck lead")
            expect(content.frame == fixedFrame && content.layer?.opacity == 1 && CATransform3DIsIdentity(content.layer!.transform),
                   "Embedded motion must keep file content sharp, opaque and at its final size")
            expect(animations(content.layer).isEmpty && animations(surface.layer).isEmpty,
                   "Embedded motion must animate only the contour, without a content or surface fade")
            expect(pathCommands(opening.fromValue as! CGPath) == pathCommands(opening.toValue as! CGPath),
                   "Embedded contour animations must retain compatible path commands")
            surface.cancelAnimationsAndShow()
            surface.setPresented(false, animated: true) { }
            expect(abs(animations(mask).first!.duration - HubNotchMotion.bodyClosingDuration / speed) < 0.0001,
                   "Embedded closing must respect the selected animation speed")
        }

        surface.setPresented(false, animated: false) { }
        var obsolete = 0, settled = 0
        surface.setPresented(true, animated: true) { obsolete += 1 }
        surface.setPresented(false, animated: true) { settled += 1 }
        let reversed = animations(mask).first as! CABasicAnimation
        expect((reversed.fromValue as! CGPath).boundingBoxOfPath.height == 0,
               "Zero-frame embedded reversal must not flash the unrendered expanded body")
        drainMainRunLoop(for: 0.30)
        expect(obsolete == 0 && settled == 1 && surface.layer?.opacity == 0 && !surface.isAnimating,
               "Only the latest embedded transition may complete")

        surface.configure(attached: true, sourceWidth: 212, bodyColor: .black, reduceMotion: true, animationSpeed: 0.5, embedded: true)
        surface.setPresented(true, animated: true) { }
        expect(animations(mask).isEmpty && maskBounds(surface) == surface.bounds,
               "Reduced-motion embedded mode must retain its full-size silhouette")
        expect(!animations(surface.layer).isEmpty && animations(surface.layer).allSatisfy { $0.duration <= 0.10 },
               "Reduced-motion embedded mode must use only a short fade")
        surface.cancelAnimationsAndShow()
        expect(!surface.containsVisiblePoint(NSPoint(x: 2, y: 475)) && surface.containsVisiblePoint(NSPoint(x: 450, y: 479)),
               "Reduced motion must preserve rounded embedded outer corners and the top-anchored central edge")

        // Detaching restores the ordinary floating outline even if a caller
        // passes the embedded preference along with attached=false.
        surface.configure(attached: false, sourceWidth: 212, bodyColor: .black, reduceMotion: false, embedded: true)
        expect(!surface.containsVisiblePoint(NSPoint(x: 2, y: 475)),
               "Detached floating panels must retain rounded top corners")
        expect(content.frame == fixedFrame, "Switching attachment style must not resize file content")
        surface.setPresented(false, animated: false) { }
    }

    @MainActor private static func testLiquidBridge() {
        let bridge = HubNotchBridgeView(frame: NSRect(x: 0, y: 0, width: 820, height: 64))
        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        bridge.layoutSubtreeIfNeeded()
        expect(!bridge.isAnimating && bridge.layer?.opacity == 0, "A new connecting neck must remain hidden")
        expect(!bridge.containsVisiblePoint(NSPoint(x: 410, y: 40)), "A hidden neck must not keep the panel open")
        let mask = bridge.layer?.mask as! CAShapeLayer
        let collapsed = mask.path!
        expect(collapsed.boundingBoxOfPath.minY > 0, "Collapsed neck material must be absorbed above the body")

        bridge.setPresented(true, animated: true) { }
        let motion = pathAnimation(mask)
        let shapes = motion?.values as? [CGPath] ?? []
        expect(shapes.count >= 3, "The connection must extend before the body appears, then remain steady")
        expect(shapes.first?.boundingBoxOfPath == collapsed.boundingBoxOfPath,
               "A fresh neck animation must start at its existing collapsed contour")
        expect(shapes.last?.boundingBoxOfPath.minY == 0, "The expanded neck must reach the body with no vertical gap")
        expect(shapes[1].boundingBoxOfPath.width == 200 && shapes[1].boundingBoxOfPath.minY == 0,
               "The neck must reach the body at source width before expanding across the panel")
        expect(abs(shapes.last!.boundingBoxOfPath.width - 756) < 0.001,
               "The final curve must span the panel top except for 32-point corner margins")
        for shape in shapes { expectNoInwardNeck(shape, in: bridge.bounds, sourceWidth: 200) }
        expect(shapes.allSatisfy { $0.boundingBoxOfPath.width <= shapes.last!.boundingBoxOfPath.width + 0.001 },
               "No opening frame may bulge beyond the resting connection width")
        let commands = shapes.map(pathCommands)
        expect(commands.dropFirst().allSatisfy { $0 == commands.first! },
               "All liquid contours must preserve interpolation topology")
        expect(motion?.calculationMode == .linear,
               "Interpolating outward control points must preserve their outward bounds between keyframes")
        expect(endDelay(motion!) <= 0.33, "The connecting extension must complete promptly")

        bridge.configure(sourceWidth: 200, bodyColor: .darkGray, reduceMotion: false)
        bridge.needsLayout = true
        bridge.layoutSubtreeIfNeeded()
        expect(bridge.isAnimating && pathAnimation(mask) != nil,
               "Theme/layout updates must not discard an in-flight neck morph")

        var oldClose = 0, currentOpen = 0
        bridge.setPresented(false, animated: true) { oldClose += 1 }
        bridge.setPresented(true, animated: true) { currentOpen += 1 }
        drainMainRunLoop(for: 0.40)
        expect(oldClose == 0 && currentOpen == 1 && !bridge.isAnimating,
               "A liquid-neck reversal must cancel the old hide and complete the new show once")
        expect(bridge.layer?.opacity == 1 && mask.path?.boundingBoxOfPath.minY == 0,
               "Reversed neck must settle fully joined to the body")
        expect(bridge.containsVisiblePoint(NSPoint(x: 410, y: 40)), "The visible stem must count as a pointer destination")
        expect(!bridge.containsVisiblePoint(NSPoint(x: 10, y: 40)), "Transparent space beside the stem must not keep the panel open")
        bridge.isHidden = true
        expect(!bridge.containsVisiblePoint(NSPoint(x: 410, y: 40)), "A hidden bridge view must reject pointer destinations")
        bridge.isHidden = false

        var close = 0
        bridge.setPresented(false, animated: true) { close += 1 }
        expect(bridge.layer?.opacity == 1, "Closing material must remain visible until its absorption finishes")
        let closingShapes = pathAnimation(mask)?.values as? [CGPath] ?? []
        expect(closingShapes.count >= 3 && closingShapes[1].boundingBoxOfPath.minY == 0,
               "Closing must keep the neck joined while the body first retracts")
        expect(closingShapes[1].boundingBoxOfPath.width == 200,
               "Closing must narrow the shoulders in step with the body before absorbing the stem")
        for shape in closingShapes { expectNoInwardNeck(shape, in: bridge.bounds, sourceWidth: 200) }
        expect(endDelay(pathAnimation(mask)!) <= 0.24, "Neck absorption must not linger after the browser retracts")
        drainMainRunLoop(for: 0.32)
        expect(close == 1 && !bridge.isAnimating && bridge.layer?.opacity == 0,
               "The neck must hide and complete once after absorption")

        bridge.cancelAnimationsAndShow()
        let partial = HubNotchMotion.neckPath(in: bridge.bounds, sourceWidth: 200,
                                              state: .init(extent: 0.25, shoulder: 0.2))
        mask.path = partial
        bridge.setPresented(false, animated: true) { }
        let earlyCloseShapes = pathAnimation(mask)?.values as? [CGPath] ?? []
        expect(!earlyCloseShapes.isEmpty && earlyCloseShapes.allSatisfy { $0.boundingBoxOfPath.minY >= partial.boundingBoxOfPath.minY },
               "An early reversal must retract the partial neck rather than stretch it fully open first")
        expect(earlyCloseShapes.allSatisfy { $0.boundingBoxOfPath.width <= partial.boundingBoxOfPath.width + 0.001 },
               "Early closing must not swell sideways before it retracts")
        for shape in earlyCloseShapes { expectNoInwardNeck(shape, in: bridge.bounds, sourceWidth: 200) }
        bridge.setPresented(false, animated: false) { }

        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: true)
        bridge.setPresented(true, animated: true) { }
        expect(pathAnimation(mask) == nil, "Reduce Motion must disable neck stretching")
        let fades = bridge.layer?.animationKeys()?.compactMap { bridge.layer?.animation(forKey: $0) } ?? []
        expect(!fades.isEmpty && fades.allSatisfy { $0.duration <= 0.15 }, "Reduced-motion neck must only use a short fade")
        bridge.cancelAnimationsAndShow()
        expect(!bridge.isAnimating && bridge.layer?.opacity == 1, "Manual detach must cancel liquid motion and keep its state visible")
        bridge.setPresented(false, animated: false) { }
        expect(bridge.layer?.opacity == 0, "Immediate bridge hide must remain deterministic")
    }

    private static func testNoInwardNeckGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 64)
        let states: [HubNotchMotion.NeckState] = [.closed, .open,
            .init(extent: 0.3, shoulder: 0.3),
            .init(extent: 1, shoulder: .nan),
            .init(extent: 1, shoulder: -0.5),
            .init(extent: 1, shoulder: 4),
            .init(extent: 0.08, shoulder: 1)]
        for state in states {
            let contour = HubNotchMotion.neckPath(in: bounds, sourceWidth: 200, state: state)
            expectNoInwardNeck(contour, in: bounds, sourceWidth: 200)
        }
    }

    private static func expectNoInwardNeck(_ path: CGPath, in bounds: CGRect, sourceWidth: CGFloat) {
        let left = bounds.midX - sourceWidth / 2, right = bounds.midX + sourceWidth / 2
        let maximumFlare = HubNotchMotion.connectionFlare(in: bounds, sourceWidth: sourceWidth)
        var controlPoints: [CGPoint] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for index in 0..<count { controlPoints.append(element.points[index]) }
        }
        expect(!controlPoints.isEmpty && controlPoints.allSatisfy { point in
            point.x.isFinite && point.y.isFinite && (point.x <= left + 0.001 || point.x >= right - 0.001) &&
            point.x >= left - maximumFlare - 0.001 && point.x <= right + maximumFlare + 0.001
        }, "The contour and handles must stay between source and final body edges without an inward or outward bulge")
        expectSmoothSideCurves(path)

        let bottom = path.boundingBoxOfPath.minY
        let top = min(bounds.maxY, bounds.minY + HubNotchMotion.neckDepth)
        guard top - bottom > 0.01 else { return }
        var previousWidth = sourceWidth - 1
        for index in 0..<32 {
            let y = top - (top - bottom) * (CGFloat(index) + 0.5) / 32
            let measured = width(of: path, at: y)
            expect(measured >= sourceWidth - 1.1 && measured >= previousWidth - 1.1,
                   "The connecting sides must remain straight or gradually widen toward the body")
            previousWidth = measured
        }
    }

    private static func expectSmoothSideCurves(_ path: CGPath) {
        var position = CGPoint.zero
        var curves: [(CGPoint, CGPoint, CGPoint, CGPoint)] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint: position = element.points[0]
            case .addCurveToPoint:
                curves.append((position, element.points[0], element.points[1], element.points[2]))
                position = element.points[2]
            default: break
            }
        }
        expect(curves.count == 2, "Each side must be one continuous curve, without a middle waist joint")
        for (start, first, second, end) in curves {
            let verticalStart = abs(start.x - first.x) < 0.001
            let horizontalEnd = abs(second.y - end.y) < 0.001
            let horizontalStart = abs(start.y - first.y) < 0.001
            let verticalEnd = abs(second.x - end.x) < 0.001
            expect((verticalStart && horizontalEnd) || (horizontalStart && verticalEnd),
                   "The side must join the hub vertically and the body horizontally")
            var curvatureSign: CGFloat = 0
            for index in 0...20 {
                let t = CGFloat(index) / 20, u = 1 - t
                let dx = 3 * (u * u * (first.x - start.x) + 2 * u * t * (second.x - first.x) + t * t * (end.x - second.x))
                let dy = 3 * (u * u * (first.y - start.y) + 2 * u * t * (second.y - first.y) + t * t * (end.y - second.y))
                let ddx = 6 * (u * (second.x - 2 * first.x + start.x) + t * (end.x - 2 * second.x + first.x))
                let ddy = 6 * (u * (second.y - 2 * first.y + start.y) + t * (end.y - 2 * second.y + first.y))
                let cross = dx * ddy - dy * ddx
                if abs(cross) > 0.0001 {
                    if curvatureSign == 0 { curvatureSign = cross > 0 ? 1 : -1 }
                    expect(cross * curvatureSign >= -0.0001, "Side curvature must not reverse into an S-shaped notch or outer bulge")
                }
            }
        }
    }

    @MainActor private static func testConnectionBodySynchronization() {
        let surface = HubNotchSurface(contentView: NSView(frame: .zero))
        surface.frame = NSRect(x: 0, y: 0, width: 820, height: 460)
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        let bridge = HubNotchBridgeView(frame: NSRect(x: 0, y: 0, width: 820, height: 64))
        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        surface.setPresented(false, animated: false) { }
        let started = CACurrentMediaTime()
        surface.setPresented(true, animated: true) { }
        let bodyOpen = animations(surface.layer?.mask).first as! CABasicAnimation
        let bridgeStarted = CACurrentMediaTime()
        bridge.setPresented(true, animated: true) { }
        let bridgeOpen = pathAnimation(bridge.layer?.mask as! CAShapeLayer)!
        let bodyLead = bodyOpen.beginTime - started
        let bridgeLead = bridgeStarted - started
        for index in 0...100 {
            let time = Double(index) * 0.30 / 100
            let bodyWidth = animatedMetric(bodyOpen, at: time - bodyLead, metric: topFlatWidth)
            let bridgeWidth = animatedMetric(bridgeOpen, at: time - bridgeLead) { $0.boundingBoxOfPath.width }
            expect(bridgeWidth <= bodyWidth + 0.5,
                   "Opening connection must stay within the body's current flat top, without unsupported wings")
        }

        surface.cancelAnimationsAndShow()
        bridge.cancelAnimationsAndShow()
        surface.setPresented(false, animated: true) { }
        bridge.setPresented(false, animated: true) { }
        let bodyClose = animations(surface.layer?.mask).first as! CABasicAnimation
        let bridgeClose = pathAnimation(bridge.layer?.mask as! CAShapeLayer)!
        for index in 0...100 {
            let time = Double(index) * 0.22 / 100
            let bodyWidth = animatedMetric(bodyClose, at: time, metric: topFlatWidth)
            let bridgeWidth = animatedMetric(bridgeClose, at: time) { $0.boundingBoxOfPath.width }
            expect(bridgeWidth <= bodyWidth + 0.5,
                   "Closing shoulders must contract within the body's top before the final stem retracts")
        }
        surface.setPresented(false, animated: false) { }
        bridge.setPresented(false, animated: false) { }
    }

    /// Evaluates configured CA timing offscreen. It tests the relationship
    /// between the two independently installed contours, not rendered frames.
    private static func animatedMetric(_ animation: CAAnimation, at elapsed: TimeInterval,
                                       metric: (CGPath) -> CGFloat) -> CGFloat {
        let progress = min(1, max(0, elapsed / animation.duration))
        if let basic = animation as? CABasicAnimation {
            let from = metric(basic.fromValue as! CGPath), to = metric(basic.toValue as! CGPath)
            return from + (to - from) * eased(progress, by: basic.timingFunction)
        }
        let frames = animation as! CAKeyframeAnimation
        let contours = frames.values as! [CGPath]
        let times = frames.keyTimes!.map(\.doubleValue)
        let segment = min(contours.count - 2, max(0, times.lastIndex { $0 <= progress } ?? 0))
        let local = (progress - times[segment]) / (times[segment + 1] - times[segment])
        let from = metric(contours[segment]), to = metric(contours[segment + 1])
        return from + (to - from) * eased(local, by: frames.timingFunctions?[segment])
    }

    private static func eased(_ progress: Double, by function: CAMediaTimingFunction?) -> CGFloat {
        guard let function else { return CGFloat(progress) }
        var first = [Float](repeating: 0, count: 2), second = first
        first.withUnsafeMutableBufferPointer { function.getControlPoint(at: 1, values: $0.baseAddress!) }
        second.withUnsafeMutableBufferPointer { function.getControlPoint(at: 2, values: $0.baseAddress!) }
        func cubic(_ parameter: Double, _ a: Float, _ b: Float) -> Double {
            let u = 1 - parameter
            return 3 * u * u * parameter * Double(a) + 3 * u * parameter * parameter * Double(b) + parameter * parameter * parameter
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let midpoint = (low + high) / 2
            if cubic(midpoint, first[0], second[0]) < progress { low = midpoint } else { high = midpoint }
        }
        return CGFloat(cubic((low + high) / 2, first[1], second[1]))
    }

    private static func topFlatWidth(_ path: CGPath) -> CGFloat {
        var first: CGPoint?, width: CGFloat = 0
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            if first == nil && element.type == .moveToPoint { first = element.points[0] }
            else if width == 0, let first, element.type == .addLineToPoint {
                width = abs(element.points[0].x - first.x)
            }
        }
        return width
    }

    @MainActor private static func testAnimationSpeed() {
        let cases: [(Double, Double)] = [(0.5, 0.5), (1, 1), (2, 2), (0, 0.5), (-1, 0.5),
                                         (99, 2), (.nan, 1), (.infinity, 1), (-.infinity, 1)]
        for (requested, normalized) in cases {
            expect(HubNotchMotion.normalizedSpeed(requested) == normalized,
                   "Animation speed must clamp finite values and replace non-finite input with the default")
            let surface = HubNotchSurface(contentView: NSView(frame: .zero))
            surface.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false, animationSpeed: requested)
            surface.setPresented(false, animated: false) { }
            let started = CACurrentMediaTime()
            surface.setPresented(true, animated: true) { }
            let opening = animations(surface.layer?.mask).first!
            let scheduledOpening = max(0, opening.beginTime - started) + opening.duration
            expect(abs(scheduledOpening - 0.30 / normalized) < 0.025,
                   "Both the body duration and the connecting lead must follow the selected speed")
            surface.cancelAnimationsAndShow()
            surface.setPresented(false, animated: true) { }
            expect(abs(animations(surface.layer?.mask).first!.duration - 0.18 / normalized) < 0.0001,
                   "Body closing must use the same speed factor")
            surface.setPresented(false, animated: false) { }

            surface.configure(attached: false, sourceWidth: 200, bodyColor: .black, reduceMotion: false, animationSpeed: requested)
            surface.setPresented(true, animated: true) { }
            expect(abs(animations(surface.layer).first!.duration - 0.18 / normalized) < 0.0001,
                   "Floating-window motion must respect the speed setting too")
            surface.setPresented(false, animated: false) { }

            let bridge = HubNotchBridgeView(frame: NSRect(x: 0, y: 0, width: 268, height: 64))
            bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false, animationSpeed: requested)
            bridge.setPresented(true, animated: true) { }
            expect(abs(pathAnimation(bridge.layer?.mask as! CAShapeLayer)!.duration - 0.30 / normalized) < 0.0001,
                   "The bridge must stay synchronized with the body's selected opening speed")
            bridge.cancelAnimationsAndShow()
            bridge.setPresented(false, animated: true) { }
            expect(abs(pathAnimation(bridge.layer?.mask as! CAShapeLayer)!.duration - 0.22 / normalized) < 0.0001,
                   "The bridge's absorption must follow the selected speed")
            bridge.setPresented(false, animated: false) { }

            surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: true, animationSpeed: requested)
            surface.setPresented(true, animated: true) { }
            expect(animations(surface.layer).allSatisfy { $0.duration <= 0.10 },
                   "Reduced motion must stay short even when normal animation speed is slow")
            surface.setPresented(false, animated: false) { }
            bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: true, animationSpeed: requested)
            bridge.setPresented(true, animated: true) { }
            expect(animations(bridge.layer).allSatisfy { $0.duration <= 0.10 },
                   "The reduced-motion bridge must ignore slow normal-animation timing")
            bridge.setPresented(false, animated: false) { }
        }
    }

    @MainActor private static func testWindowShadowLifecycle() {
        // This synthetic window is never displayed. It only supplies AppKit's
        // real shadow property and view/window lifecycle for cancellation tests.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        let surface = HubNotchSurface(contentView: NSView(frame: .zero))
        window.contentView = surface
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        surface.setPresented(true, animated: false) { }
        var obsolete = 0
        surface.setPresented(false, animated: true) { obsolete += 1 }
        expect(!window.hasShadow, "Moving contours must suspend WindowServer's stale alpha shadow")
        surface.setPresented(true, animated: true) { }
        drainMainRunLoop(for: 0.40)
        expect(obsolete == 0 && window.hasShadow, "Rapid reversal must restore the original shadow only after the new show settles")
        surface.setPresented(false, animated: true) { obsolete += 1 }
        surface.cancelAnimationsAndShow()
        drainMainRunLoop(for: 0.30)
        expect(obsolete == 0 && window.hasShadow, "Manual cancellation must restore shadow and suppress the old hide")
        surface.setPresented(false, animated: true) { }
        drainMainRunLoop(for: 0.30)
        expect(!window.hasShadow, "Closing must not restore a rectangular shadow before the panel is ordered out")
        surface.setPresented(true, animated: false) { }
        expect(window.hasShadow, "An immediate reopen must also restore the saved shadow preference")
        window.hasShadow = false
        surface.setPresented(false, animated: true) { }
        surface.setPresented(true, animated: false) { }
        expect(!window.hasShadow, "A window configured without shadows must remain without them")
        window.contentView = nil
        window.close()
    }

    @MainActor private static func testZeroFrameReversal() {
        let surface = HubNotchSurface(contentView: NSView(frame: .zero))
        surface.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        surface.configure(attached: true, sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        surface.setPresented(false, animated: false) { }
        var staleOpen = 0, lastClose = 0
        surface.setPresented(true, animated: true) { staleOpen += 1 }
        surface.setPresented(false, animated: true) { lastClose += 1 }
        let closing = animations(surface.layer?.mask).compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "path" }
        let bodyOrigin = closing?.fromValue.map { $0 as! CGPath }
        expect(bodyOrigin?.boundingBoxOfPath.height == 0,
               "A zero-frame reversal must not use the unrendered full-size model destination")
        drainMainRunLoop(for: 0.30)
        expect(staleOpen == 0 && lastClose == 1 && surface.layer?.opacity == 0,
               "A zero-frame body reversal must finish hidden without its obsolete show callback")

        let bridge = HubNotchBridgeView(frame: NSRect(x: 0, y: 0, width: 268, height: 64))
        bridge.configure(sourceWidth: 200, bodyColor: .black, reduceMotion: false)
        let original = (bridge.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath
        var staleNeckOpen = 0, lastNeckClose = 0
        bridge.setPresented(true, animated: true) { staleNeckOpen += 1 }
        bridge.setPresented(false, animated: true) { lastNeckClose += 1 }
        let shapes = pathAnimation(bridge.layer?.mask as! CAShapeLayer)?.values as? [CGPath] ?? []
        expect(!shapes.isEmpty && shapes.allSatisfy { $0.boundingBoxOfPath.minY >= original!.minY },
               "A zero-frame neck reversal must never flash material down to the body")
        drainMainRunLoop(for: 0.32)
        expect(staleNeckOpen == 0 && lastNeckClose == 1 && bridge.layer?.opacity == 0,
               "A zero-frame neck reversal must finish absorbed with only the current callback")
    }

    private static func animations(_ layer: CALayer?) -> [CAAnimation] {
        layer?.animationKeys()?.compactMap { layer?.animation(forKey: $0) } ?? []
    }

    private static func endDelay(_ animation: CAAnimation) -> TimeInterval {
        max(0, animation.beginTime == 0 ? 0 : animation.beginTime - CACurrentMediaTime()) + animation.duration
    }

    private static func pathAnimation(_ layer: CAShapeLayer) -> CAKeyframeAnimation? {
        layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CAKeyframeAnimation }.first { $0.keyPath == "path" }
    }

    private static func pathCommands(_ path: CGPath) -> [Int32] {
        var commands: [Int32] = []
        path.applyWithBlock { commands.append($0.pointee.type.rawValue) }
        return commands
    }

    private static func width(of path: CGPath, at y: CGFloat) -> CGFloat {
        let bounds = path.boundingBoxOfPath
        let xs = stride(from: bounds.minX, through: bounds.maxX, by: 0.5).filter {
            path.contains(CGPoint(x: $0, y: y))
        }
        return (xs.last ?? 0) - (xs.first ?? 0)
    }

    @MainActor private static func drainMainRunLoop(for seconds: TimeInterval) {
        CATransaction.flush()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
