import AppKit

@main
struct TriggerSuppressionTests {
    static let own = "local.diexie.filedock"
    static let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let secondary = CGRect(x: -1920, y: 100, width: 1920, height: 1080)

    @MainActor static func main() {
        testBlacklist()
        testFullscreenEvidence()
        testScreensAndCoordinates()
        testAccessoryForegroundRetention()
        testProbeConfigurationAndStaleResults()
        testMouseWakeFallback()
        testClickInput()
        print("PASS: trigger suppression (blacklist, optional fullscreen evidence, screen isolation, disabled polling and stale probe results)")
    }

    static func testMouseWakeFallback() {
        let game = HubTriggerForeground(bundleID: "com.example.game", pid: 123)
        let fullscreen = HubTriggerForeground(bundleID: "com.example.player", pid: 321, windowFullScreen: true, windowFrame: primary)
        let normal = HubTriggerForeground(bundleID: "com.example.editor", pid: 456)
        for foreground in [game, fullscreen] {
            let blocked = suppress(foreground, blocked: ["com.example.game"])
            precondition(blocked)
            for normalClick in [false, true] {
                precondition(HubMouseWakeMode.resolve(mouseEnabled: true, normalClick: normalClick, suppressed: blocked, clickFallback: false) == .disabled,
                             "Existing exceptions continue to disable both hover and normal notch click by default")
                precondition(HubMouseWakeMode.resolve(mouseEnabled: true, normalClick: normalClick, suppressed: blocked, clickFallback: true) == .click,
                             "Fullscreen and blacklist may independently fall back to click without enabling hover")
            }
        }
        precondition(HubMouseWakeMode.resolve(mouseEnabled: true, normalClick: false, suppressed: suppress(normal), clickFallback: true) == .hover,
                     "Returning to a normal environment restores hover, not a permanently changed setting")
        precondition(HubMouseWakeMode.resolve(mouseEnabled: true, normalClick: true, suppressed: false, clickFallback: true) == .click,
                     "Normal notch click preference remains intact")
        precondition(HubMouseWakeMode.resolve(mouseEnabled: false, normalClick: true, suppressed: true, clickFallback: true) == .disabled,
                     "Keyboard-only mode cannot be bypassed by the exception fallback")
        let onOtherDisplay = suppress(fullscreen, pointer: CGPoint(x: -900, y: 1179))
        precondition(!onOtherDisplay && HubMouseWakeMode.resolve(mouseEnabled: true, normalClick: false, suppressed: onOtherDisplay, clickFallback: true) == .hover,
                     "Fullscreen on another display cannot turn this display's normal hover into click")
    }

    @MainActor static func testClickInput() {
        precondition(HubTriggerClick.accepts(type: .leftMouseDown, modifiers: []))
        for modifier in [NSEvent.ModifierFlags.control, .command, .option, .shift] {
            precondition(!HubTriggerClick.accepts(type: .leftMouseDown, modifiers: modifier), "Modified clicks remain with the foreground app")
        }
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp, .rightMouseDown] {
            precondition(!HubTriggerClick.accepts(type: type, modifiers: []))
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -700, y: 180, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let local = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 12, y: 34), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        precondition(HubTriggerClick.screenPoint(for: local) == window.convertPoint(toScreen: local.locationInWindow))
        let point = CGPoint(x: -1870, y: 1150)
        let external = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        precondition(external.window == nil && HubTriggerClick.screenPoint(for: external) == point,
                     "Global click coordinates must come from the event, never a later moved pointer")
        precondition(!window.isVisible)
        print("PASS: exception click fallback/restoration, keyboard-only and screen isolation, modified-click exclusions and real hidden-window/global event coordinate conversion")
    }

    static func suppress(_ foreground: HubTriggerForeground, blocked: [String] = [], enabled: Bool = true,
                         pointer: CGPoint = CGPoint(x: 750, y: 981), screens: [CGRect] = [primary, secondary]) -> Bool {
        HubTriggerSuppressionPolicy.shouldSuppress(foreground, ownBundleID: own,
                                                   blockedBundleIDs: blocked, suppressFullScreen: enabled,
                                                   pointer: pointer, screens: screens)
    }

    static func testBlacklist() {
        let game = HubTriggerForeground(bundleID: "com.example.game", pid: 123)
        precondition(!suppress(game))
        precondition(suppress(game, blocked: ["com.example.game"]), "A windowed game must be blockable without AX permission")
        precondition(suppress(game, blocked: ["com.example.game"], enabled: false), "Fullscreen toggle must not disable the independent blacklist")
        precondition(!suppress(game, blocked: ["com.example"]), "Bundle IDs match exactly, never by prefix")
        precondition(!suppress(game, blocked: ["com.example.game2"]))
        precondition(!suppress(HubTriggerForeground(), blocked: ["com.example.game"]), "Unknown foreground must not accidentally match a blacklist")
        let selfApp = HubTriggerForeground(bundleID: own, pid: 999, systemFullScreen: true, windowFullScreen: true)
        precondition(!suppress(selfApp, blocked: [own]), "The panel's own app is exempt even from imported self-blacklist entries")
        precondition(HubTriggerSuppressionPolicy.normalizedBundleIDs(["  com.example.game\n", "", "com.example.game", "\t", "com.example.player"]) == ["com.example.game", "com.example.player"])
    }

    static func testFullscreenEvidence() {
        var app = HubTriggerForeground(bundleID: "com.example.player", pid: 321)
        precondition(!suppress(app), "Unavailable AX and unknown system fullscreen must fail open without prompting")
        app.windowFrame = primary
        precondition(!suppress(app), "Screen-sized/maximized geometry alone must never suppress")
        app.windowFullScreen = false
        precondition(!suppress(app))
        app.windowFullScreen = true
        precondition(suppress(app), "AXFullscreen is positive evidence even when the system option is unavailable")
        precondition(!suppress(app, enabled: false), "Disabling automatic fullscreen suppression must take effect")
        app.windowFullScreen = nil
        app.systemFullScreen = true
        precondition(suppress(app), "The public presentation flag works even with no AX grant")
        app.windowFrame = nil
        precondition(suppress(app), "A proven fullscreen app with unknown screen must remain suppressed")
        app.systemFullScreen = false
        precondition(!suppress(app), "An unknown frame must not imply fullscreen")
        app.windowFullScreen = true
        app.windowFrame = CGRect(x: CGFloat.nan, y: 0, width: 1512, height: 982)
        precondition(suppress(app), "Invalid geometry falls back to existing fullscreen evidence")
    }

    static func testScreensAndCoordinates() {
        var app = HubTriggerForeground(bundleID: "com.example.player", pid: 321, windowFullScreen: true, windowFrame: primary)
        precondition(suppress(app))
        precondition(suppress(app, pointer: CGPoint(x: 750, y: primary.maxY)), "A pointer pinned to the exact top edge must remain suppressed")
        precondition(suppress(app, pointer: CGPoint(x: primary.maxX, y: primary.maxY)), "The exact outer upper-right corner must remain suppressed")
        precondition(!suppress(app, pointer: CGPoint(x: -900, y: 1179)), "Fullscreen on the primary display must not block another display")
        app.windowFrame = secondary
        precondition(!suppress(app, pointer: CGPoint(x: 0, y: 700)), "Half-open ownership must assign a shared edge to the primary display first")
        precondition(!suppress(app), "A fullscreen video on the secondary display must not block the primary notch")
        precondition(suppress(app, pointer: CGPoint(x: -900, y: 1179)))
        app.windowFrame = CGRect(x: -1900, y: 130, width: 1880, height: 1030)
        precondition(!suppress(app), "Slightly inset AX bounds still identify the correct display")
        precondition(suppress(app, pointer: CGPoint(x: -900, y: 1179)))
        app.windowFrame = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        precondition(suppress(app), "Disconnected/unknown screen geometry does not negate proven fullscreen")

        let equalScreens = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        app.windowFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        precondition(suppress(app, pointer: CGPoint(x: 50, y: 99), screens: equalScreens))
        precondition(suppress(app, pointer: CGPoint(x: 150, y: 99), screens: equalScreens), "A spanning window must suppress both equally covered screens")
        let converted = HubTriggerSuppressionPolicy.cocoaFrame(axPosition: CGPoint(x: -1920, y: -198), size: secondary.size, primaryScreenTop: 982)
        precondition(converted == secondary, "AX top-left coordinates must convert using the primary display, including displays above it")
        precondition(HubTriggerSuppressionPolicy.cocoaFrame(axPosition: .zero, size: CGSize(width: -1, height: 20), primaryScreenTop: 982) == nil)
        precondition(HubTriggerSuppressionPolicy.cocoaFrame(axPosition: .zero, size: CGSize(width: 1, height: CGFloat.infinity), primaryScreenTop: 982) == nil)
    }

    static func testAccessoryForegroundRetention() {
        let panel = HubTriggerApplicationState(bundleID: own, pid: 1)
        let game = HubTriggerApplicationState(bundleID: "com.example.game", pid: 2)
        func context(_ actual: HubTriggerApplicationState?, previous: HubTriggerApplicationState? = game,
                     accessory: Bool = true, rememberedFullscreen: Bool = true) -> HubTriggerForeground {
            HubTriggerSuppressionPolicy.effectiveForeground(frontmost: actual, previous: previous,
                                                           ownBundleID: own, accessory: accessory,
                                                           systemFullScreen: false, previousSystemFullScreen: rememberedFullscreen)
        }
        precondition(context(panel).bundleID == game.bundleID)
        precondition(context(panel).systemFullScreen, "A manual panel visit must not erase prior fullscreen proof when AX is unavailable")
        precondition(suppress(context(panel), blocked: ["com.example.game"]))
        precondition(context(game).pid == game.pid && !context(game).systemFullScreen,
                     "Once the external app is actually frontmost, its current system state replaces remembered proof")
        precondition(context(panel, previous: nil).bundleID == own,
                     "Space changes clear the remembered app and must drop inferred suppression")
        var unavailableGame = game
        unavailableGame.isHidden = true
        precondition(context(panel, previous: unavailableGame).bundleID == own)
        unavailableGame.isHidden = false; unavailableGame.isTerminated = true
        precondition(context(panel, previous: unavailableGame).bundleID == own)
        precondition(context(panel, accessory: false).bundleID == own)
        precondition(context(nil).pid == nil, "No active app must not reuse arbitrary previous context")
        let browser = HubTriggerApplicationState(bundleID: "com.example.browser", pid: 3)
        precondition(context(browser).bundleID == browser.bundleID && !context(browser).systemFullScreen)
        precondition(!context(panel, rememberedFullscreen: false).systemFullScreen)
        precondition(context(panel, previous: panel).bundleID == own, "Self must never be its own remembered external app")
    }

    static func testProbeConfigurationAndStaleResults() {
        var gate = HubTriggerProbeGate()
        precondition(gate.begin() == nil, "The monitor must not start AX work before automatic triggering is enabled")
        gate.configure(enabled: false, needsWindowProbe: true)
        precondition(!gate.enabled && !gate.needsWindowProbe && gate.begin() == nil,
                     "A saved fullscreen preference cannot enable probing in keyboard-only mode")
        gate.configure(enabled: true, needsWindowProbe: false)
        precondition(gate.enabled && !gate.needsWindowProbe && gate.begin() == nil,
                     "Blacklist-only mode must maintain foreground context without scheduling AX work")

        gate.configure(enabled: true, needsWindowProbe: true)
        let first = gate.begin()!
        precondition(gate.begin() == nil, "Polling must not queue another request while the previous AX call is blocked")
        precondition(!gate.configure(enabled: true, needsWindowProbe: true), "Unrelated settings updates must preserve valid pending requests")
        precondition(gate.finish(first), "An unchanged policy may accept its outstanding result")

        let stopped = gate.begin()!
        gate.configure(enabled: false, needsWindowProbe: false)
        precondition(gate.begin() == nil)
        precondition(!gate.finish(stopped), "Disabling automatic triggering must discard the outstanding result")

        gate.configure(enabled: true, needsWindowProbe: true)
        let priorRun = gate.begin()!
        gate.configure(enabled: false, needsWindowProbe: false)
        gate.configure(enabled: true, needsWindowProbe: true)
        precondition(gate.begin() == nil, "Restarting must not accumulate AX requests behind a blocked prior run")
        precondition(!gate.finish(priorRun), "A prior run must not publish after automatic triggering is re-enabled")
        let restarted = gate.begin()!
        precondition(!gate.finish(priorRun), "A stale completion must not release a newer request's slot")
        precondition(gate.begin() == nil && gate.finish(restarted), "The restarted monitor must resume after old work is drained")

        let fullScreen = gate.begin()!
        gate.configure(enabled: true, needsWindowProbe: false)
        precondition(!gate.finish(fullScreen) && gate.begin() == nil,
                     "Turning off fullscreen suppression must invalidate AX results while retaining blacklist mode")
        gate.configure(enabled: true, needsWindowProbe: true)
        let changedContext = gate.begin()!
        gate.invalidate()
        precondition(!gate.finish(changedContext), "Display, Space and foreground changes must still invalidate window geometry")
        let recovered = gate.begin()!
        precondition(gate.finish(recovered), "Probing must recover normally after a context invalidation")
    }
}
