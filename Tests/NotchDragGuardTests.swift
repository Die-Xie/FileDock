import AppKit

@main struct NotchDragGuardTests {
    @MainActor static func main() {
        var filter = HubNotchDragFilter()
        filter.regions = [CGRect(x: 600, y: 0, width: 180, height: 32),
                          CGRect(x: -800, y: -900, width: 160, height: 28)]
        func drag(_ point: CGPoint, dy: Int64 = -12) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                mouseCursorPosition: point, mouseButton: .left)!
            event.flags = [.maskAlternate, .maskShift]
            event.setIntegerValueField(.mouseEventDeltaX, value: 7)
            event.setIntegerValueField(.mouseEventDeltaY, value: dy)
            event.setIntegerValueField(.eventUnacceleratedPointerMovementX, value: 3)
            event.setIntegerValueField(.eventUnacceleratedPointerMovementY, value: dy)
            event.setIntegerValueField(.eventSourceUserData, value: 491)
            return event
        }
        // Constructed events are NEVER posted, so these tests cannot move the
        // real cursor, trigger Mission Control, or interact with user files.
        for point in [CGPoint(x: 600, y: 0), CGPoint(x: 779.5, y: 0), CGPoint(x: -700, y: -900)] {
            filter.reset()
            let arrival = drag(point)
            precondition(!filter.filter(type: .leftMouseDragged, event: arrival))
            precondition(arrival.location == point && arrival.getIntegerValueField(.mouseEventDeltaY) == -12,
                         "The first arrival must retain its full real movement")
            let event = drag(point)
            precondition(filter.filter(type: .leftMouseDragged, event: event))
            precondition(event.location == point, "A notch drag must never move or bounce the cursor")
            precondition(event.flags == [.maskAlternate, .maskShift])
            precondition(event.getIntegerValueField(.mouseEventDeltaX) == 7)
            precondition(event.getIntegerValueField(.mouseEventDeltaY) == 0)
            precondition(event.getDoubleValueField(.eventUnacceleratedPointerMovementY) == 0)
            precondition(event.getIntegerValueField(.eventUnacceleratedPointerMovementX) == 3)
            precondition(event.getIntegerValueField(.eventSourceUserData) == 491)
            precondition(event.type == .leftMouseDragged)
        }
        for point in [CGPoint(x: 599.9, y: 0), CGPoint(x: 780, y: 0), CGPoint(x: 700, y: 1),
                      CGPoint(x: 700, y: 20), CGPoint(x: 700, y: 0.5), CGPoint(x: 700, y: -0.5), CGPoint(x: -700, y: -899),
                      CGPoint(x: 700, y: 900), CGPoint(x: CGFloat.nan, y: 0)] {
            let event = drag(point)
            let before = event.location
            precondition(!filter.filter(type: .leftMouseDragged, event: event))
            // CGEvent may normalize NaN itself; compare the stored event value.
            precondition((event.location.x == before.x || (event.location.x.isNaN && before.x.isNaN)) && event.location.y == before.y)
            precondition(event.getIntegerValueField(.mouseEventDeltaY) == -12)
            precondition(event.getDoubleValueField(.eventUnacceleratedPointerMovementY) == -12)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDragged, .mouseMoved, .scrollWheel, .keyDown] {
            let event = drag(CGPoint(x: 700, y: 0))
            precondition(!filter.filter(type: type, event: event))
            precondition(event.location == CGPoint(x: 700, y: 0))
        }
        for dy in [Int64(0), 4] {
            let event = drag(CGPoint(x: 700, y: 0), dy: dy)
            precondition(!filter.filter(type: .leftMouseDragged, event: event))
            precondition(event.getIntegerValueField(.mouseEventDeltaY) == dy)
            precondition(event.getDoubleValueField(.eventUnacceleratedPointerMovementY) == Double(dy))
            precondition(event.location == CGPoint(x: 700, y: 0))
        }
        let held = drag(CGPoint(x: 700, y: 0))
        precondition(filter.filter(type: .leftMouseDragged, event: held))
        precondition(!filter.filter(type: .leftMouseDragged, event: held), "Already filtered events are idempotent")
        precondition(!filter.filter(type: .leftMouseUp, event: held))
        precondition(held.location == CGPoint(x: 700, y: 0))
        let rawOnly = drag(CGPoint(x: 700, y: 0), dy: 0)
        rawOnly.setIntegerValueField(.eventUnacceleratedPointerMovementY, value: -2)
        precondition(!filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: 700, y: 0))))
        precondition(filter.filter(type: .leftMouseDragged, event: rawOnly))
        precondition(rawOnly.getDoubleValueField(.eventUnacceleratedPointerMovementY) == 0 && rawOnly.location == CGPoint(x: 700, y: 0))

        // Model an external native source tracking its drag image from relative
        // motion. After every sample it must agree with the absolute pointer,
        // including fast first arrival, repeated pressure, exit and re-entry.
        filter.reset()
        var relativeImageY: Int64 = 90
        let trace: [(Int64, Int64, Bool)] = [(50, -40, false), (18, -32, false), (0, -40, false),
            (0, -22, true), (0, -8, true), (4, 4, false), (0, -4, false), (0, -100, true),
            (30, 30, false), (0, -30, false), (0, -20, true)]
        for (y, delta, shouldFilter) in trace {
            let event = drag(CGPoint(x: 700, y: Int(y)), dy: delta)
            precondition(filter.filter(type: .leftMouseDragged, event: event) == shouldFilter)
            relativeImageY = max(0, relativeImageY + event.getIntegerValueField(.mouseEventDeltaY))
            precondition(relativeImageY == y, "External relative drag image must not be left below the physical pointer")
            precondition(event.location == CGPoint(x: 700, y: Int(y)))
            precondition(event.getIntegerValueField(.mouseEventDeltaX) == 7)
        }
        // Leaving the region, release/cancel or a suspension starts a fresh
        // arrival; never reuse the clamped-edge state from a previous drag.
        for type in [CGEventType.leftMouseUp, .leftMouseDown, .mouseMoved] {
            _ = filter.filter(type: type, event: drag(CGPoint(x: 700, y: 0)))
            let reentered = drag(CGPoint(x: 700, y: 0), dy: -40)
            precondition(!filter.filter(type: .leftMouseDragged, event: reentered))
            precondition(reentered.getIntegerValueField(.mouseEventDeltaY) == -40)
        }
        filter.reset()
        precondition(!filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: -700, y: -900))))
        precondition(filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: -700, y: -900))))
        precondition(!filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: 700, y: 0))),
                     "A different display must receive its own complete arrival")
        filter.regions = []
        precondition(!filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: 700, y: 0))))
        let cocoa = CGRect(x: -800, y: 1772, width: 160, height: 28)
        precondition(HubNotchDragFilter.quartzRect(cocoa, primaryTop: 900) == CGRect(x: -800, y: -900, width: 160, height: 28))
        let converted = HubNotchDragFilter.quartzRect(CGRect(x: 600, y: 868, width: 180, height: 32), primaryTop: 900)
        precondition(converted == CGRect(x: 600, y: 0, width: 180, height: 32))
        for invalid in [CGRect.null, .infinite, .zero, CGRect(x: 600, y: 0, width: 180, height: 1)] {
            filter.regions = [invalid]
            precondition(!filter.filter(type: .leftMouseDragged, event: drag(CGPoint(x: 700, y: 0))))
        }
        // Exercise the hot callback path without AppKit, AX, file reads or UI.
        filter.regions = [converted]
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100_000 {
            held.setDoubleValueField(.mouseEventDeltaY, value: -4)
            _ = filter.filter(type: .leftMouseDragged, event: held)
            precondition(held.location == CGPoint(x: 700, y: 0))
        }
        print("Notch drag filter: 100000 events in \(ProcessInfo.processInfo.systemUptime - start)s")
        let controller = HubNotchDragGuard.shared
        controller.configure(regions: [converted])
        controller.update(enabled: false, temporarilySuspended: false, now: 0)
        precondition(controller.status == .inactive)
        controller.stop()
        var trusted = false, creations = 0
        let failing = HubNotchDragGuard(isTrusted: { trusted }, createTap: { mask, _, _ in
            let expected = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            precondition(mask == expected, "Never register keyboard, scroll or other mouse buttons")
            creations += 1; return nil
        })
        failing.configure(regions: [converted])
        for now in 0..<100 { failing.update(enabled: true, temporarilySuspended: false, now: Double(now)) }
        precondition(creations == 0 && failing.status == .permissionRequired)
        trusted = true
        for now in 100..<200 { failing.update(enabled: true, temporarilySuspended: false, now: Double(now)) }
        precondition(creations == 3 && failing.status == .unavailable, "Creation failure must not cause an unlimited Mach-port retry loop")
        failing.retry()
        failing.update(enabled: true, temporarilySuspended: false, now: 200)
        precondition(creations == 4)
        failing.update(enabled: false, temporarilySuspended: false, now: 201)
        precondition(failing.status == .inactive)
        failing.configure(regions: [])
        failing.update(enabled: true, temporarilySuspended: false, now: 202)
        precondition(creations == 4 && failing.status == .inactive, "Non-notched displays must not install a tap")
        failing.stop()
        print("PASS: complete native edge arrival, relative drag image alignment, outward-only pressure, display/session isolation, unchanged coordinates/events and bounded tap retries")
    }
}
