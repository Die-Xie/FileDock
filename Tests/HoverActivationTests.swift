import Foundation
import CoreGraphics
import AppKit

@main
struct HoverActivationTests {
    @MainActor
    static func main() {
        testHoverGeometry()
        testVisibleCursorFootprint()
        testCursorRasterization()
        testStrictDwell()
        testSamplingAndPolicyChanges()
        let notch = "display-1:notch"
        var gate = HubHoverActivation()
        precondition(!gate.update(regionID: notch, now: 0, delay: 0.12))
        precondition(!gate.update(regionID: notch, now: 0.10, delay: 0.12))
        precondition(gate.update(regionID: notch, now: 0.125, delay: 0.12), "A normal dwell must trigger without an added minimum delay")
        precondition(!gate.update(regionID: notch, now: 1, delay: 0.12), "A continuous hover must only fire once")

        gate.reset()
        precondition(gate.update(regionID: notch, now: 2, delay: 0), "Zero delay must trigger on entry")
        precondition(!gate.update(regionID: notch, now: 2.1, delay: 0))
        precondition(!gate.update(regionID: nil, now: 2.2, delay: 0))
        precondition(!gate.update(regionID: nil, now: 2.26, delay: 0))
        precondition(gate.update(regionID: notch, now: 2.3, delay: 0), "A stable departure must rearm zero-delay entry")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 10, delay: 0.2))
        precondition(!gate.update(regionID: nil, now: 10.09, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 10.12, delay: 0.2))
        precondition(gate.update(regionID: notch, now: 10.205, delay: 0.2), "A 30ms edge excursion must preserve the dwell")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 20, delay: 0.2))
        precondition(!gate.update(regionID: nil, now: 20.10, delay: 0.2))
        precondition(!gate.update(regionID: nil, now: 20.16, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 20.17, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 20.30, delay: 0.2))
        precondition(gate.update(regionID: notch, now: 20.38, delay: 0.2), "An excursion beyond grace must start a fresh dwell")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 30, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 30.1, delay: 0.2, enabled: false))
        precondition(!gate.update(regionID: notch, now: 31, delay: 0.2), "Leaving a modal state must not reuse old hover time")
        precondition(gate.update(regionID: notch, now: 31.21, delay: 0.2))

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 35, delay: 0, enabled: false))
        precondition(gate.update(regionID: notch, now: 35.001, delay: 0), "Zero delay must fire immediately when modal suspension ends")
        gate.reset()
        precondition(!gate.update(regionID: notch, now: 36, delay: 0.3))
        precondition(!gate.update(regionID: notch, now: 36.1, delay: 0, enabled: false))
        precondition(gate.update(regionID: notch, now: 36.101, delay: 0), "Disabling during a pending dwell must not add a reenable delay at zero")

        gate.dismiss(regionID: notch, now: 40)
        precondition(!gate.update(regionID: notch, now: 40.1, delay: 0))
        precondition(!gate.update(regionID: nil, now: 40.2, delay: 0))
        precondition(!gate.update(regionID: notch, now: 40.23, delay: 0), "A dismiss lock must survive edge jitter")
        precondition(!gate.update(regionID: notch, now: 40.5, delay: 0, enabled: false))
        precondition(!gate.update(regionID: notch, now: 40.6, delay: 0), "Modal suspension must not clear a dismiss lock")
        precondition(!gate.update(regionID: nil, now: 40.7, delay: 0, enabled: false))
        precondition(!gate.update(regionID: nil, now: 40.76, delay: 0, enabled: false))
        precondition(gate.update(regionID: notch, now: 40.8, delay: 0))

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 50, delay: 0.2))
        precondition(!gate.update(regionID: "display-2:notch", now: 50.15, delay: 0.2))
        precondition(!gate.update(regionID: "display-2:notch", now: 50.3, delay: 0.2))
        precondition(gate.update(regionID: "display-2:notch", now: 50.36, delay: 0.2), "Display changes must not inherit the previous dwell")
        precondition(!gate.update(regionID: "display-2:topLeft", now: 50.4, delay: 0.2))
        precondition(gate.update(regionID: "display-2:topLeft", now: 50.61, delay: 0.2), "Changing the trigger region must reset and rearm")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 60, delay: 0.2))
        precondition(!gate.update(regionID: nil, now: 60.25, delay: 0.2), "Elapsed time must never fire while outside the trigger")
        gate.dismiss(regionID: nil, now: 60.3)
        precondition(!gate.update(regionID: notch, now: 60.4, delay: 0.2))
        precondition(gate.update(regionID: notch, now: 60.61, delay: 0.2))

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 70, delay: .nan))
        precondition(gate.update(regionID: notch, now: 70.13, delay: .nan), "Invalid delays must use a finite short default")
        gate.reset()
        precondition(gate.update(regionID: notch, now: 71, delay: -1))
        gate.reset()
        precondition(!gate.update(regionID: notch, now: 80, delay: 10))
        precondition(!gate.update(regionID: notch, now: 82.9, delay: 10))
        precondition(gate.update(regionID: notch, now: 83.01, delay: 10))

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 90, delay: 1))
        precondition(gate.update(regionID: notch, now: 90.15, delay: 0.12), "Lowering the delay must apply to the current dwell")
        gate.reset()
        precondition(!gate.update(regionID: notch, now: 100, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 99, delay: 0.2), "A backwards clock must safely reset")
        precondition(!gate.update(regionID: notch, now: 99.1, delay: 0.2))
        precondition(gate.update(regionID: notch, now: 99.31, delay: 0.2))

        var dismissal = HubHoverDismissal()
        precondition(!dismissal.update(outside: true, now: 0, delay: 0.55))
        precondition(!dismissal.update(outside: true, now: 0.54, delay: 0.55))
        precondition(dismissal.update(outside: true, now: 0.56, delay: 0.55))
        precondition(!dismissal.update(outside: true, now: 1, delay: 0.55), "An exit can only dismiss once")
        precondition(!dismissal.update(outside: false, now: 2, delay: 0))
        precondition(dismissal.update(outside: true, now: 2.1, delay: 0), "Zero exit delay must dismiss on departure")

        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 10, delay: 0.55))
        precondition(!dismissal.update(outside: false, now: 10.4, delay: 0.55))
        precondition(!dismissal.update(outside: true, now: 10.6, delay: 0.55), "Returning must cancel the old countdown")
        precondition(!dismissal.update(outside: true, now: 11.1, delay: 0.55))
        precondition(dismissal.update(outside: true, now: 11.2, delay: 0.55))

        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 20, delay: 1))
        precondition(!dismissal.update(outside: true, now: 20.8, delay: 1, enabled: false))
        precondition(!dismissal.update(outside: true, now: 21, delay: 1), "Suspension must cancel elapsed time")
        precondition(!dismissal.update(outside: true, now: 21.9, delay: 1))
        precondition(dismissal.update(outside: true, now: 22.1, delay: 1))

        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 30, delay: 1))
        precondition(dismissal.update(outside: true, now: 30.3, delay: 0.25), "A reduced delay applies to the pending exit")
        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 40, delay: 0.25))
        precondition(!dismissal.update(outside: true, now: 40.3, delay: 1), "An increased delay applies to the pending exit")
        precondition(dismissal.update(outside: true, now: 41.1, delay: 1))

        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 50, delay: .nan))
        precondition(dismissal.update(outside: true, now: 50.56, delay: .nan))
        dismissal.reset()
        precondition(dismissal.update(outside: true, now: 60, delay: -1))
        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 70, delay: 10))
        precondition(!dismissal.update(outside: true, now: 72.9, delay: 10))
        precondition(dismissal.update(outside: true, now: 73.1, delay: 10))

        dismissal.reset()
        precondition(!dismissal.update(outside: true, now: 80, delay: 0.55))
        precondition(!dismissal.update(outside: true, now: 79, delay: 0.55), "Clock reversal must cancel elapsed time")
        precondition(!dismissal.update(outside: true, now: .infinity, delay: 0.55))
        precondition(!dismissal.update(outside: true, now: 81, delay: 0.55))
        precondition(dismissal.update(outside: true, now: 81.6, delay: 0.55))
        testFileDragDismissal()

        print("PASS: visible cursor alpha, raster orientation and scale, inclusive screen edges, 75% overlap, strict dwell, sampling stalls, policy cancellation, dismiss lock and configurable mouse-exit dismissal")
    }

    private static func testFileDragDismissal() {
        var drag = HubFileDragDismissal()
        let first = UUID(), second = UUID()
        func update(_ time: Double, id: UUID? = nil, pressed: Bool = true, outside: Bool = true,
                    enabled: Bool = true, delay: Double = 0.55) -> Bool {
            drag.update(sessionID: id ?? first, mousePressed: pressed, outside: outside, now: time, delay: delay, enabled: enabled)
        }
        precondition(!drag.update(sessionID: nil, mousePressed: true, outside: true, now: 0, delay: 0, enabled: true),
                     "External drags and ordinary mouse presses have no local source session")
        precondition(!update(1, outside: false, delay: 0), "Cross-tab and in-panel drags never hide the panel")
        precondition(update(2, delay: 0), "Zero delay hides on file departure without waiting for mouse release")
        precondition(!update(3, delay: 0), "A drag departure fires only once")
        drag.reset()
        precondition(!update(10))
        precondition(!update(10.5, outside: false), "Returning to the panel cancels the pending drag exit")
        precondition(!update(11))
        precondition(!update(11.54))
        precondition(update(11.56))
        drag.reset()
        precondition(!update(20))
        precondition(!update(20.5, enabled: false), "Turning the preference off or presenting a dialog cancels elapsed time")
        precondition(!update(21))
        precondition(update(21.56))
        drag.reset()
        precondition(!update(30))
        precondition(!update(30.5, pressed: false), "A stale source ID after release must not hide the panel")
        precondition(!update(31))
        precondition(update(31.56))
        drag.reset()
        precondition(!update(40))
        precondition(!update(40.54, id: second), "Another drag session cannot reuse departure time")
        precondition(!update(41, id: second))
        precondition(update(41.1, id: second))
        drag.reset()
        precondition(!update(50))
        precondition(!update(49), "Clock reversal cancels a pending source drag exit")
        precondition(!update(51))
        precondition(update(51.56))
        for tracking in [false, true] {
            for session in [nil, first] {
                for pressed in [false, true] {
                    precondition(HubFileDragDismissal.menuBlocksDismissal(tracking: tracking, sessionID: session, mousePressed: pressed)
                                 == (tracking && !(session != nil && pressed)),
                                 "Only the held local drag may bypass eventTracking; real menus remain protected")
                }
            }
        }
        print("PASS: local file drag exit timing, return/disable/release/session/clock cancellation, one-shot dismissal and native tracking-mode menu distinction")
    }

    private static func testVisibleCursorFootprint() {
        // A padded image with only four opaque pixels: padding must contribute
        // no area, and the image's offset from its hotspot must be retained.
        let padded: [UInt8] = [0, 0, 0, 0,
                               0, 255, 255, 0,
                               0, 255, 255, 0,
                               0, 0, 0, 0]
        let footprint = HubCursorFootprint(alpha: padded, pixelsWide: 4, pixelsHigh: 4,
                                            imageSize: NSSize(width: 40, height: 40), hotSpot: NSPoint(x: 10, y: 10))!
        let notch = NSRect(x: 100, y: 100, width: 100, height: 32)
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 132), footprint: footprint, region: notch),
                     "At the physical top edge all visible pixels fit; transparent top padding must not disqualify them")
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 95, y: 132), footprint: footprint, region: notch))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 94.99, y: 132), footprint: footprint, region: notch),
                     "Visible area still needs at least 75%, with no expanded entry region")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 100), footprint: footprint, region: notch))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: CGFloat.nan, y: 132), footprint: footprint, region: notch))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: .zero, footprint: footprint, region: .zero))

        // Three fully visible pixels and one faint shadow pixel: alpha area,
        // rather than a filled bounding rectangle, defines the visible shape.
        let alpha: [UInt8] = [255, 255, 255, 1]
        let shaped = HubCursorFootprint(alpha: alpha, pixelsWide: 4, pixelsHigh: 1,
                                       imageSize: NSSize(width: 40, height: 10), hotSpot: .zero)!
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 110), footprint: shaped,
                                                     region: NSRect(x: 100, y: 100, width: 25, height: 10)),
                     "Soft shadow should have only its alpha-weighted influence")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 110), footprint: shaped,
                                                      region: NSRect(x: 100, y: 100, width: 22, height: 10)))

        let oneX = HubCursorFootprint(alpha: [255, 0, 255, 255], pixelsWide: 2, pixelsHigh: 2,
                                     imageSize: NSSize(width: 20, height: 20), hotSpot: NSPoint(x: 3, y: 2))!
        let twoX = HubCursorFootprint(alpha: [255,255,0,0, 255,255,0,0, 255,255,255,255, 255,255,255,255],
                                     pixelsWide: 4, pixelsHigh: 4, imageSize: NSSize(width: 20, height: 20), hotSpot: NSPoint(x: 3, y: 2))!
        for x in stride(from: CGFloat(80), through: 120, by: 0.5) {
            for y in stride(from: CGFloat(95), through: 140, by: 0.5) {
                let pointer = NSPoint(x: x, y: y)
                precondition(HubHoverGeometry.cursorQualifies(pointer: pointer, footprint: oneX, region: notch) ==
                             HubHoverGeometry.cursorQualifies(pointer: pointer, footprint: twoX, region: notch),
                             "Pixel resolution must not change point-space trigger geometry")
            }
        }
        precondition(HubCursorFootprint(alpha: [0], pixelsWide: 1, pixelsHigh: 1, imageSize: NSSize(width: 1, height: 1), hotSpot: .zero) == nil)
        precondition(HubCursorFootprint(alpha: [255], pixelsWide: 0, pixelsHigh: 1, imageSize: NSSize(width: 1, height: 1), hotSpot: .zero) == nil)
        precondition(HubCursorFootprint(alpha: [255], pixelsWide: Int.max, pixelsHigh: Int.max, imageSize: NSSize(width: 1, height: 1), hotSpot: .zero) == nil)
        precondition(HubCursorFootprint(alpha: [255], pixelsWide: 2, pixelsHigh: 2, imageSize: NSSize(width: 1, height: 1), hotSpot: .zero) == nil)
    }

    @MainActor
    private static func testCursorRasterization() {
        _ = NSApplication.shared
        // Explicitly asymmetric CGImage data catches vertical flips during
        // AppKit image extraction, not only in the pure coordinate helper.
        let bytes: [UInt8] = [255,255,255,255, 0,0,0,0,
                              0,0,0,0, 0,0,0,0]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cgImage = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let footprint = HubHoverCursor.makeFootprint(image: NSImage(cgImage: cgImage, size: NSSize(width: 20, height: 20)), hotSpot: .zero)!
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 100), footprint: footprint,
                                                     region: NSRect(x: 100, y: 90, width: 10, height: 10)),
                     "Top-left opaque source pixel must land immediately below and right of the hotspot")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 100), footprint: footprint,
                                                      region: NSRect(x: 100, y: 80, width: 10, height: 10)))
        let systemArrow = HubHoverCursor.footprint
        precondition(systemArrow != nil, "The shipped standard arrow must produce a usable silhouette without permissions")
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 800, y: 1000), footprint: systemArrow!,
                                                     region: NSRect(x: 700, y: 968, width: 200, height: 32)),
                     "The real standard arrow must qualify when pressed into the center of a 32-point notch")
    }

    private static func testHoverGeometry() {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 1600, y: 1000), NSPoint(x: 800, y: 1000), NSPoint(x: 1600, y: 500)] {
            precondition(HubHoverGeometry.containsTriggerPoint(point, in: screen), "Exact physical edges must be reachable")
        }
        for point in [NSPoint(x: -0.001, y: 0), NSPoint(x: 1600.001, y: 1000), NSPoint(x: 800, y: 1000.001), NSPoint(x: CGFloat.nan, y: 500)] {
            precondition(!HubHoverGeometry.containsTriggerPoint(point, in: screen), "Inclusive edges must not expand the trigger")
        }
        precondition(!HubHoverGeometry.containsTriggerPoint(.zero, in: .zero))
        let left = NSRect(x: 0, y: 968, width: 700, height: 32)
        let right = NSRect(x: 900, y: 968, width: 700, height: 32)
        precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32, left: left, right: right) == NSRect(x: 700, y: 968, width: 200, height: 32))
        precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32,
                                              left: NSRect(x: 0, y: 968.25, width: 700, height: 32), right: right) != nil,
                     "Subpoint auxiliary-area rounding must not disable a real screen notch")
        precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32,
                                              left: NSRect(x: 0, y: 968.51, width: 700, height: 32), right: right) == nil,
                     "The half-point geometry tolerance must not admit a genuinely displaced auxiliary area")
        let negativeScreen = NSRect(x: -1600, y: -200, width: 1600, height: 900)
        let negativeNotch = HubHoverGeometry.notchRect(screenFrame: negativeScreen, safeTop: 32,
                                                       left: NSRect(x: -1600, y: 668, width: 700, height: 32),
                                                       right: NSRect(x: -700, y: 668, width: 700, height: 32))
        precondition(negativeNotch == NSRect(x: -900, y: 668, width: 200, height: 32),
                     "Notch geometry must use screen points and preserve negative display coordinates")
        for safeTop in [CGFloat(0), -1, 1001, .nan, .infinity] {
            precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: safeTop, left: left, right: right) == nil)
        }
        precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32, left: nil, right: right) == nil)
        precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32, left: left, right: nil) == nil)
        for invalidLeft in [NSRect(x: 0, y: 968, width: 950, height: 32),
                            NSRect(x: 0, y: 968, width: 900, height: 32),
                            NSRect(x: -1, y: 968, width: 701, height: 32),
                            NSRect(x: 0, y: 100, width: 700, height: 32),
                            NSRect(x: 0, y: 968, width: 0, height: 32),
                            NSRect(x: CGFloat.nan, y: 968, width: 700, height: 32)] {
            precondition(HubHoverGeometry.notchRect(screenFrame: screen, safeTop: 32, left: invalidLeft, right: right) == nil,
                         "Missing, overlapping, off-screen or nonfinite auxiliary areas must never invent a notch")
        }
        precondition(HubHoverGeometry.notchRect(screenFrame: NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 1000),
                                              safeTop: 32, left: left, right: right) == nil)

        let size = NSSize(width: 20, height: 20)
        let region = NSRect(x: 100, y: 100, width: 100, height: 40)
        let hotSpot = NSPoint(x: 4, y: 5)
        precondition(HubHoverGeometry.cursorRect(pointer: NSPoint(x: 104, y: 115), imageSize: size, hotSpot: hotSpot) == NSRect(x: 100, y: 100, width: 20, height: 20),
                     "Hotspot Y must convert from top-left image coordinates to bottom-left screen coordinates")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 94, y: 120), imageSize: size, hotSpot: .zero, region: region),
                     "70% cursor overlap must not start a hover")
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 95, y: 120), imageSize: size, hotSpot: .zero, region: region),
                     "Exactly 75% cursor overlap must qualify")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 94.99, y: 120), imageSize: size, hotSpot: .zero, region: region))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 100, y: 100), imageSize: size, hotSpot: .zero, region: region),
                     "A hotspot at the edge does not qualify when the cursor image remains outside")
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 97, y: 117), imageSize: size, hotSpot: .zero, region: region),
                     "Corner overlap must multiply both clipped dimensions rather than test one edge")
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 97.5, y: 117.5), imageSize: size, hotSpot: .zero, region: region))
        precondition(HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: -905, y: 690), imageSize: size, hotSpot: .zero, region: negativeNotch!))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: -906, y: 690), imageSize: size, hotSpot: .zero, region: negativeNotch!))
        precondition(HubHoverGeometry.cursorRect(pointer: NSPoint(x: -104, y: -115), imageSize: size, hotSpot: hotSpot) == NSRect(x: -108, y: -130, width: 20, height: 20))
        for invalidSize in [NSSize(width: 0, height: 20), NSSize(width: -1, height: 20),
                            NSSize(width: 20, height: 0), NSSize(width: CGFloat.nan, height: 20), NSSize(width: 20, height: CGFloat.infinity)] {
            precondition(HubHoverGeometry.cursorRect(pointer: .zero, imageSize: invalidSize, hotSpot: .zero) == nil)
        }
        for invalidHotSpot in [NSPoint(x: -1, y: 0), NSPoint(x: 0, y: -1), NSPoint(x: 21, y: 0),
                               NSPoint(x: 0, y: 21), NSPoint(x: CGFloat.nan, y: 0), NSPoint(x: 0, y: CGFloat.infinity)] {
            precondition(HubHoverGeometry.cursorRect(pointer: .zero, imageSize: size, hotSpot: invalidHotSpot) == nil)
        }
        precondition(HubHoverGeometry.cursorRect(pointer: NSPoint(x: CGFloat.nan, y: 0), imageSize: size, hotSpot: .zero) == nil)
        precondition(HubHoverGeometry.cursorRect(pointer: NSPoint(x: CGFloat.greatestFiniteMagnitude, y: 0),
                                               imageSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 1), hotSpot: .zero) == nil)
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 110, y: 120), imageSize: size, hotSpot: .zero,
                                                     region: NSRect(x: 100, y: 100, width: -1, height: 40)))
        precondition(!HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: 110, y: 120), imageSize: size, hotSpot: .zero, region: .zero))
    }

    private static func testStrictDwell() {
        let notch = "display-1:notch"
        var gate = HubHoverActivation()
        precondition(!gate.update(regionID: notch, now: 0, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 0.09, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 0.12, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 0.205, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 0.319, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 0.321, delay: 0.2, strictDwell: true),
                     "Even a 30ms excursion below 75% must restart the full notch dwell")
        precondition(!gate.update(regionID: nil, now: 0.4, delay: 0, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 0.43, delay: 0, strictDwell: true),
                     "Strict dwell must not clear a fired or dismissed lock during edge jitter")
        precondition(!gate.update(regionID: nil, now: 0.8, delay: 0, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 0.86, delay: 0, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 0.9, delay: 0, strictDwell: true))

        gate.reset()
        let size = NSSize(width: 20, height: 20), region = NSRect(x: 0, y: 0, width: 100, height: 40)
        let outside = HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: -6, y: 20), imageSize: size, hotSpot: .zero, region: region)
        let inside = HubHoverGeometry.cursorQualifies(pointer: NSPoint(x: -5, y: 20), imageSize: size, hotSpot: .zero, region: region)
        precondition(!gate.update(regionID: outside ? notch : nil, now: 1, delay: 0, strictDwell: true))
        precondition(gate.update(regionID: inside ? notch : nil, now: 1.001, delay: 0, strictDwell: true),
                     "Zero configured delay still requires the cursor geometry to meet the threshold")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 2, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 2.1, delay: 0.2, enabled: false, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 2.3, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 2.51, delay: 0.2, strictDwell: true))
        gate.dismiss(regionID: notch, now: 3)
        precondition(!gate.update(regionID: notch, now: 3.1, delay: 0, enabled: false, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 3.2, delay: 0, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 3.3, delay: 0, enabled: false, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 3.33, delay: 0, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 3.4, delay: 0, enabled: false, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 3.46, delay: 0, enabled: false, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 3.47, delay: 0.1, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 3.58, delay: 0.1, strictDwell: true),
                     "Modal suspension preserves dismissal locks until a stable departure, then rearms normal dwell")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 5, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: "display-2:notch", now: 5.15, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: "display-2:notch", now: 5.31, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: "display-2:notch", now: 5.36, delay: 0.2, strictDwell: true),
                     "Strict notch dwell must not inherit elapsed time from another screen")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 10, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: nil, now: 10.09, delay: 0.2))
        precondition(!gate.update(regionID: notch, now: 10.12, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 10.205, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 10.321, delay: 0.2, strictDwell: true),
                     "A missing or excluded screen must cancel the prior notch dwell even when the caller supplies default strictness")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 20, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: "display-2:topLeft", now: 20.05, delay: 0.2))
        precondition(!gate.update(regionID: nil, now: 20.1, delay: 0.2))
        precondition(!gate.update(regionID: "display-2:topLeft", now: 20.13, delay: 0.2))
        precondition(gate.update(regionID: "display-2:topLeft", now: 20.26, delay: 0.2),
                     "Switching from a strict notch to an ordinary corner restores that corner's original edge grace")
    }

    private static func testSamplingAndPolicyChanges() {
        let notch = "display-1:notch"
        var gate = HubHoverActivation()
        precondition(!gate.update(regionID: notch, now: 0, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 1, delay: 0.2, strictDwell: true),
                     "A stalled loop cannot credit a second of unobserved pointer position")
        precondition(!gate.update(regionID: notch, now: 1.19, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 1.21, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 2, delay: 0, strictDwell: true),
                     "Sampling stalls must preserve the once-per-entry lock")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 3, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 4, delay: 0, strictDwell: true),
                     "A fresh qualifying sample may still trigger when the user explicitly selected zero delay")

        gate.reset()
        precondition(!gate.update(regionID: notch, now: 5, delay: 0.2, strictDwell: true))
        gate.cancelPendingDwell()
        precondition(!gate.update(regionID: notch, now: 5.1, delay: 0.2, strictDwell: true))
        precondition(!gate.update(regionID: notch, now: 5.21, delay: 0.2, strictDwell: true))
        precondition(gate.update(regionID: notch, now: 5.31, delay: 0.2, strictDwell: true))
        gate.dismiss(regionID: notch, now: 6)
        gate.cancelPendingDwell()
        precondition(!gate.update(regionID: notch, now: 6.1, delay: 0, strictDwell: true),
                     "Changing preferences must not clear a deliberate dismissal lock")

        gate.reset()
        precondition(!gate.update(regionID: "display-2:topLeft", now: 10, delay: 0.2))
        precondition(gate.update(regionID: "display-2:topLeft", now: 11, delay: 0.2),
                     "Unnotched hot corners retain their original timing policy")
    }
}
