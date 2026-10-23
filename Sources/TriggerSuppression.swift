import AppKit
import ApplicationServices

struct HubTriggerForeground: Equatable, Sendable {
    var bundleID: String?
    var pid: pid_t?
    var systemFullScreen = false
    var windowFullScreen: Bool?
    // AX uses a top-left origin; the reader converts it to AppKit screen points.
    var windowFrame: CGRect?
}

struct HubTriggerApplicationState: Equatable, Sendable {
    var bundleID: String?
    var pid: pid_t
    var isHidden = false
    var isTerminated = false
}

enum HubTriggerSuppressionPolicy {
    static func effectiveForeground(frontmost: HubTriggerApplicationState?, previous: HubTriggerApplicationState?,
                                    ownBundleID: String, accessory: Bool, systemFullScreen: Bool,
                                    previousSystemFullScreen: Bool) -> HubTriggerForeground {
        if frontmost?.bundleID == ownBundleID, accessory, let previous,
           previous.bundleID != ownBundleID, !previous.isHidden, !previous.isTerminated {
            return HubTriggerForeground(bundleID: previous.bundleID, pid: previous.pid,
                                        systemFullScreen: systemFullScreen || previousSystemFullScreen)
        }
        return HubTriggerForeground(bundleID: frontmost?.bundleID, pid: frontmost?.pid,
                                    systemFullScreen: systemFullScreen)
    }

    static func normalizedBundleIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    static func shouldSuppress(_ foreground: HubTriggerForeground, ownBundleID: String,
                               blockedBundleIDs: [String], suppressFullScreen: Bool,
                               pointer: CGPoint, screens: [CGRect]) -> Bool {
        // An explicit invocation or settings window must never blacklist itself.
        guard foreground.bundleID != ownBundleID else { return false }
        if let bundleID = foreground.bundleID, blockedBundleIDs.contains(bundleID) { return true }
        guard suppressFullScreen, foreground.systemFullScreen || foreground.windowFullScreen == true else { return false }
        // Geometry is used only to locate a proven fullscreen window, never to
        // infer fullscreen from a maximized window or an automatically hidden Dock.
        guard let frame = foreground.windowFrame, valid(frame) else { return true }
        let validScreens = screens.filter(valid)
        // Use half-open ownership first at shared monitor edges, then include
        // the outer top/right edge where macOS can pin the pointer exactly.
        let pointerScreen = validScreens.first(where: { $0.contains(pointer) }) ?? validScreens.first(where: {
            pointer.x >= $0.minX && pointer.x <= $0.maxX && pointer.y >= $0.minY && pointer.y <= $0.maxY
        })
        let intersecting = validScreens.compactMap { screen -> (CGRect, CGFloat)? in
            let overlap = screen.intersection(frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return (screen, overlap.width * overlap.height)
        }
        guard let largest = intersecting.map(\.1).max() else { return true }
        return intersecting.contains { screen, area in
            // Tied screens support borderless fullscreen windows spanning displays.
            abs(area - largest) < 1 && screen == pointerScreen
        }
    }

    static func cocoaFrame(axPosition: CGPoint, size: CGSize, primaryScreenTop: CGFloat) -> CGRect? {
        let frame = CGRect(x: axPosition.x, y: primaryScreenTop - axPosition.y - size.height,
                           width: size.width, height: size.height)
        return valid(frame) ? frame : nil
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite &&
            frame.size.height.isFinite && frame.size.width > 0 && frame.size.height > 0 &&
            frame.maxX.isFinite && frame.maxY.isFinite
    }
}

private struct HubTriggerWindowProbe: Sendable {
    var fullScreen: Bool?
    var frame: CGRect?
}

/// Keeps at most one AX request outstanding, including across disable/enable
/// transitions. A completed request may publish only under its original policy.
struct HubTriggerProbeGate {
    private(set) var enabled = false
    private(set) var needsWindowProbe = false
    private var generation: UInt64 = 0
    private var inFlightGeneration: UInt64?

    @discardableResult
    mutating func configure(enabled: Bool, needsWindowProbe: Bool) -> Bool {
        let needsProbe = enabled && needsWindowProbe
        guard self.enabled != enabled || self.needsWindowProbe != needsProbe else { return false }
        self.enabled = enabled
        self.needsWindowProbe = needsProbe
        invalidate()
        return true
    }

    mutating func invalidate() { generation &+= 1 }

    mutating func begin() -> UInt64? {
        guard enabled, needsWindowProbe, inFlightGeneration == nil else { return nil }
        generation &+= 1
        inFlightGeneration = generation
        return generation
    }

    mutating func finish(_ token: UInt64) -> Bool {
        guard inFlightGeneration == token else { return false }
        inFlightGeneration = nil
        return enabled && needsWindowProbe && generation == token
    }
}

private enum HubTriggerAccessibility {
    static func read(pid: pid_t, primaryScreenTop: CGFloat) -> HubTriggerWindowProbe {
        // Never prompt for permission or traverse window contents. The existing
        // grant is optional: the public system presentation flag still works.
        guard AXIsProcessTrusted() else { return HubTriggerWindowProbe() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return HubTriggerWindowProbe()
        }
        AXUIElementSetMessagingTimeout(window, 0.06)
        let fullScreen = value(window, "AXFullScreen") as? Bool
        var position = CGPoint.zero, size = CGSize.zero
        var frame: CGRect?
        if let positionValue = value(window, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
           let sizeValue = value(window, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            let axPosition = unsafeBitCast(positionValue, to: AXValue.self)
            let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
            if AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize,
               AXValueGetValue(axPosition, .cgPoint, &position), AXValueGetValue(axSize, .cgSize, &size) {
                frame = HubTriggerSuppressionPolicy.cocoaFrame(axPosition: position, size: size,
                                                              primaryScreenTop: primaryScreenTop)
            }
        }
        return HubTriggerWindowProbe(fullScreen: fullScreen, frame: frame)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }
}

/// Accessibility messages can block for an unresponsive game. Read them on a
/// serial worker, outside the 60 Hz animation/hover path, and discard stale replies.
@MainActor
final class HubTriggerSuppressionMonitor {
    private let ownBundleID: String
    private let worker = DispatchQueue(label: "local.diexie.folderhub.trigger-context", qos: .utility)
    private var foreground = HubTriggerForeground()
    private var screens: [CGRect] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var presentationObserver: NSKeyValueObservation?
    private var probeGate = HubTriggerProbeGate()
    private var running = false
    private var lastProbeTime: TimeInterval = 0
    private var previousExternalApplication: NSRunningApplication?
    private var previousExternalSystemFullScreen = false
    private var lastObservedFrontmostPID: pid_t?

    init(ownBundleID: String = Bundle.main.bundleIdentifier ?? "local.diexie.folderhub-replica") {
        self.ownBundleID = ownBundleID
    }

    func configure(enabled: Bool, needsWindowProbe: Bool) {
        let changed = probeGate.configure(enabled: enabled, needsWindowProbe: needsWindowProbe)
        guard enabled else { stop(); return }
        if changed {
            foreground.windowFullScreen = nil
            foreground.windowFrame = nil
            lastProbeTime = 0
        }
        if !running { start() }
        else if changed { refresh() }
    }

    private func start() {
        guard !running else { return }
        running = true
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidateWindowAndRefresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.previousExternalApplication = nil
                self?.previousExternalSystemFullScreen = false
                self?.invalidateWindowAndRefresh()
            }
        })
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.invalidateWindowAndRefresh() }
        }
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        poll.tolerance = 0.08
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        refresh()
    }

    func stop() {
        running = false
        probeGate.configure(enabled: false, needsWindowProbe: false)
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        presentationObserver = nil
        foreground = HubTriggerForeground()
        screens = []
        lastProbeTime = 0
        previousExternalApplication = nil
        previousExternalSystemFullScreen = false
        lastObservedFrontmostPID = nil
    }

    func shouldSuppressHover(at pointer: NSPoint, blockedBundleIDs: [String], suppressFullScreen: Bool) -> Bool {
        guard running else { return false }
        // Workspace activation notifications arrive asynchronously. Check only
        // this cheap process identity at the hover boundary so zero-delay mode
        // cannot outrun a newly frontmost blacklisted app. AX remains on worker.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != lastObservedFrontmostPID { refresh() }
        return HubTriggerSuppressionPolicy.shouldSuppress(foreground, ownBundleID: ownBundleID,
                                                   blockedBundleIDs: blockedBundleIDs,
                                                   suppressFullScreen: suppressFullScreen,
                                                   pointer: pointer, screens: screens)
    }

    func refresh() {
        guard running else { return }
        let actualFrontmost = NSWorkspace.shared.frontmostApplication
        lastObservedFrontmostPID = actualFrontmost?.processIdentifier
        let context = effectiveContext(frontmost: actualFrontmost)
        if foreground.pid != context.pid || foreground.bundleID != context.bundleID {
            probeGate.invalidate()
            foreground = context
            lastProbeTime = 0
        }
        let newScreens = NSScreen.screens.map(\.frame)
        if newScreens != screens {
            probeGate.invalidate()
            foreground.windowFullScreen = nil
            foreground.windowFrame = nil
            screens = newScreens
        }
        foreground.systemFullScreen = context.systemFullScreen
        // Blacklisting needs only the current application identity. Do not
        // query accessibility trust or send any AX messages in that mode.
        guard probeGate.needsWindowProbe else { return }
        if ProcessInfo.processInfo.systemUptime - lastProbeTime > 1.5 {
            foreground.windowFullScreen = nil
            foreground.windowFrame = nil
        }
        guard let pid = foreground.pid, foreground.bundleID != ownBundleID else { return }
        guard AXIsProcessTrusted() else {
            foreground.windowFullScreen = nil; foreground.windowFrame = nil
            return
        }
        guard let request = probeGate.begin() else { return }
        let primaryTop = screens.first?.maxY ?? 0
        worker.async { [weak self] in
            let probe = HubTriggerAccessibility.read(pid: pid, primaryScreenTop: primaryTop)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentRequest = self.probeGate.finish(request)
                guard self.running else { return }
                guard currentRequest, self.foreground.pid == pid,
                      self.effectiveContext(frontmost: NSWorkspace.shared.frontmostApplication).pid == pid else {
                    if self.probeGate.needsWindowProbe { self.refresh() }
                    return
                }
                self.foreground.windowFullScreen = probe.fullScreen
                self.foreground.windowFrame = probe.frame
                self.lastProbeTime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func invalidateWindowAndRefresh() {
        guard running else { return }
        probeGate.invalidate()
        foreground.windowFullScreen = nil
        foreground.windowFrame = nil
        refresh()
    }

    private func effectiveContext(frontmost: NSRunningApplication?) -> HubTriggerForeground {
        let systemFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        if let frontmost, frontmost.bundleIdentifier != ownBundleID {
            previousExternalApplication = frontmost.activationPolicy == .regular ? frontmost : nil
            previousExternalSystemFullScreen = previousExternalApplication != nil && systemFullScreen
        }
        // An accessory panel can remain the active app after orderOut. Its last
        // external app is still behind it; keep blocking that app after a manual
        // visit to the panel. Space changes discard this inference completely.
        func state(_ app: NSRunningApplication?) -> HubTriggerApplicationState? {
            app.map { HubTriggerApplicationState(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier,
                                                 isHidden: $0.isHidden, isTerminated: $0.isTerminated) }
        }
        return HubTriggerSuppressionPolicy.effectiveForeground(frontmost: state(frontmost), previous: state(previousExternalApplication),
                                                              ownBundleID: ownBundleID, accessory: NSApp.activationPolicy() == .accessory,
                                                              systemFullScreen: systemFullScreen,
                                                              previousSystemFullScreen: previousExternalSystemFullScreen)
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
