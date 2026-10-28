import AppKit
import ApplicationServices
import Combine
import os

/// Quartz points are in display points with the primary display's top at y=0.
/// No cursor warping, event posting, private Dock API or global preference writes.
struct HubNotchDragFilter {
    var regions: [CGRect] = []
    private var previousTopRegion: CGRect?

    static func quartzRect(_ cocoa: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryTop - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    mutating func reset() { previousTopRegion = nil }

    mutating func filter(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .leftMouseDragged else { reset(); return false }
        let point = event.location
        guard point.x.isFinite, point.y.isFinite,
              let region = regions.first(where: {
                  !$0.isEmpty && !$0.isInfinite && !$0.isNull && $0.height > 1 &&
                  point.x >= $0.minX && point.x < $0.maxX &&
                  point.y == $0.minY
              }) else { reset(); return false }
        let wasAtSameEdge = previousTopRegion == region
        previousTopRegion = region
        // First arrival still contains real cursor movement. Finder's native
        // drag loop needs that complete delta to reach the same absolute point;
        // clearing it would leave its drag image below the physical pointer.
        // Only repeated, physically clamped edge events represent extra pressure.
        guard wasAtSameEdge else { return false }
        // Never rewrite location or inward/lateral motion, and never discard
        // events: native source tracking and its release must stay intact.
        var changed = false
        for field in [CGEventField.mouseEventDeltaY, .eventUnacceleratedPointerMovementY] {
            if event.getIntegerValueField(field) < 0 {
                event.setIntegerValueField(field, value: 0)
                changed = true
            }
        }
        return changed
    }
}

@MainActor
final class HubNotchDragGuard: ObservableObject {
    static let shared = HubNotchDragGuard()
    enum Status { case inactive, active, permissionRequired, unavailable }
    @Published private(set) var status: Status = .inactive
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var filter = HubNotchDragFilter()
    private var regions: [CGRect] = []
    private var enabled = false
    private var nextAttempt: TimeInterval = 0
    private var attemptsRemaining = 3
    private var lastTrusted: Bool?
    private var interrupted = false
    private var filteredDragCount = 0
    private let diagnostics = CommandLine.arguments.contains("--diagnose-notch-drag")
    private let logger = Logger(subsystem: "local.diexie.filedock", category: "NotchDragGuard")
    private let isTrusted: () -> Bool
    private let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         createTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort? = { mask, callback, context in
             CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                 eventsOfInterest: mask, callback: callback, userInfo: context)
         }) {
        self.isTrusted = isTrusted; self.createTap = createTap
    }

    func configure(regions: [CGRect]) {
        if self.regions != regions { retry(); filter.regions = []; filter.reset() }
        self.regions = regions
    }

    func update(enabled: Bool, temporarilySuspended: Bool, now: TimeInterval) {
        if self.enabled != enabled { retry() }
        self.enabled = enabled
        guard enabled, !regions.isEmpty else { stop(); return }
        if tap == nil, now >= nextAttempt {
            nextAttempt = now + 3
            let trusted = isTrusted()
            if lastTrusted != trusted { lastTrusted = trusted; attemptsRemaining = 3 }
            guard trusted else { setStatus(.permissionRequired); return }
            guard attemptsRemaining > 0 else { setStatus(.unavailable); return }
            attemptsRemaining -= 1
            let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let guardController = Unmanaged<HubNotchDragGuard>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        guardController.interrupted = true
                        guardController.filter.regions = []
                        guardController.filter.reset()
                    } else {
                        if guardController.filter.filter(type: type, event: event) { guardController.filteredDragCount += 1 }
                        if type == .leftMouseUp {
                            if guardController.diagnostics {
                                guardController.logger.notice("Drag ended; filtered notch events: \(guardController.filteredDragCount)")
                            }
                            guardController.filteredDragCount = 0
                        }
                    }
                    // Always pass the original event object, including mouseUp.
                    return Unmanaged.passUnretained(event)
                }
            }
            guard let port = createTap(mask, callback, Unmanaged.passUnretained(self).toOpaque()) else {
                setStatus(.unavailable); return
            }
            guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                setStatus(.unavailable); return
            }
            tap = port; source = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }
        if interrupted || (tap.map { !CGEvent.tapIsEnabled(tap: $0) } ?? false) {
            // Fail open; bounded retry instead of repeatedly enabling a tap
            // while the main run loop is stalled or permission is being revoked.
            tearDownTap()
            interrupted = false
            nextAttempt = now + 3
            setStatus(.unavailable)
        }
        filter.regions = temporarilySuspended ? [] : regions
        if temporarilySuspended { filter.reset() }
        if let tap {
            setStatus(CGEvent.tapIsEnabled(tap: tap) ? .active : .unavailable)
        }
    }

    func openPermissionSettings() {
        // A prompt is shown only in response to this explicit button action.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        retry()
    }

    func retry() { nextAttempt = 0; attemptsRemaining = 3 }

    func stop() {
        tearDownTap()
        filter.regions = []; filter.reset(); interrupted = false
        setStatus(.inactive)
    }

    private func setStatus(_ value: Status) {
        if status != value {
            status = value
            if diagnostics { logger.notice("Filter status: \(String(describing: value), privacy: .public)") }
        }
    }
    private func tearDownTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        filter.reset(); filteredDragCount = 0
    }
}
