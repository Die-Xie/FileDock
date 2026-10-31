import Foundation
import CoreGraphics

/// A cached cursor silhouette in screen points relative to the pointer hotspot.
/// Alpha weights count visible area without counting transparent image padding.
struct HubCursorFootprint {
    fileprivate struct Run {
        let rect: NSRect
        let alpha: CGFloat
    }
    fileprivate let runs: [Run]
    fileprivate let area: CGFloat
    fileprivate let bounds: NSRect

    /// Pixel rows are ordered from the top of the cursor image to the bottom.
    init?(alpha: [UInt8], pixelsWide: Int, pixelsHigh: Int, imageSize: NSSize, hotSpot: NSPoint) {
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 512, pixelsHigh <= 512,
              alpha.count == pixelsWide * pixelsHigh,
              HubHoverGeometry.cursorRect(pointer: .zero, imageSize: imageSize, hotSpot: hotSpot) != nil else { return nil }
        let dx = imageSize.width / CGFloat(pixelsWide), dy = imageSize.height / CGFloat(pixelsHigh)
        var runs: [Run] = [], area: CGFloat = 0
        // Merge adjacent equal-alpha pixels into row runs. The system arrow
        // generally needs only a few hundred runs, evaluated without AppKit.
        for y in 0..<pixelsHigh {
            var x = 0
            while x < pixelsWide {
                let start = x, value = alpha[y * pixelsWide + x]
                repeat { x += 1 } while x < pixelsWide && alpha[y * pixelsWide + x] == value
                guard value > 0 else { continue }
                let rect = NSRect(x: CGFloat(start) * dx - hotSpot.x,
                                  y: hotSpot.y - CGFloat(y + 1) * dy,
                                  width: CGFloat(x - start) * dx, height: dy)
                let weight = CGFloat(value) / 255
                guard HubHoverGeometry.valid(rect) else { return nil }
                area += rect.width * rect.height * weight
                runs.append(Run(rect: rect, alpha: weight))
            }
        }
        guard !runs.isEmpty, area.isFinite, area > 0 else { return nil }
        self.runs = runs
        self.area = area
        self.bounds = runs.reduce(NSRect.null) { $0.union($1.rect) }
    }
}

/// All coordinates are screen points. Cursor hotspots use top-left image
/// coordinates, while screen rectangles use the bottom-left screen origin.
enum HubHoverGeometry {
    private static let geometryTolerance: CGFloat = 0.5
    private static let overlapTolerance: CGFloat = 1e-9

    /// The physical screen edge is reachable. CGRect.contains uses a half-open
    /// rectangle, which otherwise rejects a pointer pressed against its top.
    static func containsTriggerPoint(_ point: NSPoint, in region: NSRect) -> Bool {
        valid(region) && point.x.isFinite && point.y.isFinite &&
            point.x >= region.minX && point.x <= region.maxX &&
            point.y >= region.minY && point.y <= region.maxY
    }

    static func notchRect(screenFrame: NSRect, safeTop: CGFloat, left: NSRect?, right: NSRect?) -> NSRect? {
        guard valid(screenFrame), safeTop.isFinite, safeTop > 0, safeTop <= screenFrame.height,
              let left, let right, valid(left), valid(right) else { return nil }
        let bottom = screenFrame.maxY - safeTop
        // Auxiliary areas must be actual top-of-screen areas, with a positive
        // gap between them. A menu-bar center without these areas is not a notch.
        for area in [left, right] {
            guard area.minX >= screenFrame.minX - geometryTolerance,
                  area.maxX <= screenFrame.maxX + geometryTolerance,
                  area.minY >= screenFrame.minY - geometryTolerance,
                  area.minY <= bottom + geometryTolerance,
                  abs(area.maxY - screenFrame.maxY) <= geometryTolerance else { return nil }
        }
        let result = NSRect(x: left.maxX, y: bottom, width: right.minX - left.maxX, height: safeTop)
        return valid(result) ? result : nil
    }

    static func cursorRect(pointer: NSPoint, imageSize: NSSize, hotSpot: NSPoint) -> NSRect? {
        guard pointer.x.isFinite, pointer.y.isFinite,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              hotSpot.x.isFinite, hotSpot.y.isFinite,
              hotSpot.x >= 0, hotSpot.y >= 0,
              hotSpot.x <= imageSize.width, hotSpot.y <= imageSize.height else { return nil }
        let result = NSRect(x: pointer.x - hotSpot.x,
                            y: pointer.y + hotSpot.y - imageSize.height,
                            width: imageSize.width, height: imageSize.height)
        return valid(result) ? result : nil
    }

    static func cursorQualifies(pointer: NSPoint, imageSize: NSSize, hotSpot: NSPoint, region: NSRect,
                                entryThreshold: CGFloat = 0.75, screenTop: CGFloat? = nil) -> Bool {
        guard entryThreshold.isFinite, entryThreshold > 0, entryThreshold <= 2,
              validScreenTop(screenTop, region: region),
              valid(region), let cursor = cursorRect(pointer: pointer, imageSize: imageSize, hotSpot: hotSpot) else { return false }
        let overlap = cursor.intersection(region)
        guard valid(overlap) else { return false }
        let visibleHeight = screenTop.map { min(cursor.maxY, $0) - cursor.minY } ?? cursor.height
        guard visibleHeight > 0 else { return false }
        // Ratios avoid overflowing an area multiplication for large but finite
        // coordinates. The tiny tolerance absorbs subtraction roundoff at an
        // exact percentage boundary, including complete coverage at 100%.
        return (overlap.width / cursor.width) * (overlap.height / visibleHeight) + overlapTolerance >= min(1, entryThreshold) &&
            hasRequiredDepth(pointer: pointer, relativeBottom: hotSpot.y - imageSize.height, region: region, threshold: entryThreshold)
    }

    static func cursorQualifies(pointer: NSPoint, footprint: HubCursorFootprint, region: NSRect,
                                entryThreshold: CGFloat = 0.75, screenTop: CGFloat? = nil) -> Bool {
        guard entryThreshold.isFinite, entryThreshold > 0, entryThreshold <= 2,
              validScreenTop(screenTop, region: region),
              valid(region), pointer.x.isFinite, pointer.y.isFinite else { return false }
        var covered: CGFloat = 0
        // Pixels above the physical screen are not visible. Without this,
        // the real arrow's upper shadow can make 100–200% unreachable at the edge.
        let clipped = screenTop.map { pointer.y + footprint.bounds.maxY > $0 } ?? false
        var visibleArea: CGFloat = clipped ? 0 : footprint.area
        for run in footprint.runs {
            let rect = run.rect.offsetBy(dx: pointer.x, dy: pointer.y)
            guard valid(rect) else { return false }
            let overlap = rect.intersection(region)
            if valid(overlap) { covered += overlap.width * overlap.height * run.alpha }
            if clipped, let screenTop {
                let height = max(0, min(rect.maxY, screenTop) - rect.minY)
                visibleArea += rect.width * height * run.alpha
            }
        }
        return visibleArea.isFinite && visibleArea > 0 && covered.isFinite &&
            covered / visibleArea + overlapTolerance >= min(1, entryThreshold) &&
            hasRequiredDepth(pointer: pointer, relativeBottom: footprint.bounds.minY, region: region, threshold: entryThreshold)
    }

    private static func validScreenTop(_ screenTop: CGFloat?, region: NSRect) -> Bool {
        guard let screenTop else { return true }
        return screenTop.isFinite && abs(screenTop - region.maxY) < 1e-7
    }

    /// Above 100%, interpolate the remaining reachable upward travel after
    /// full visible entry. 200% means the pointer reaches the screen's top edge,
    /// even with transparent cursor padding or a shallow physical notch.
    private static func hasRequiredDepth(pointer: NSPoint, relativeBottom: CGFloat, region: NSRect, threshold: CGFloat) -> Bool {
        guard threshold > 1 else { return true }
        let entryY = region.minY - relativeBottom
        let travel = max(0, region.maxY - entryY)
        let requiredY = entryY + travel * (threshold - 1)
        return requiredY.isFinite && pointer.y + 1e-7 >= requiredY
    }

    fileprivate static func valid(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0 &&
            rect.maxX.isFinite && rect.maxY.isFinite
    }
}

/// A monotonic-time hover gate, independent of AppKit polling and window state.
/// Region identities include both the display and the configured trigger area.
struct HubHoverActivation {
    let edgeGrace: TimeInterval
    private let maximumStrictSampleGap: TimeInterval = 0.25
    private var currentRegionID: String?
    private var enteredAt: TimeInterval?
    private var departedAt: TimeInterval?
    private var blockedRegionID: String?
    private var lastTime: TimeInterval?

    init(edgeGrace: TimeInterval = 0.05) {
        self.edgeGrace = edgeGrace.isFinite ? max(0, edgeGrace) : 0.05
    }

    /// Returns true once per continuous hover. Edge grace preserves a pending
    /// dwell unless strictDwell is enabled; neither mode can fire while outside.
    mutating func update(regionID: String?, now: TimeInterval, delay: TimeInterval, enabled: Bool = true, strictDwell: Bool = false) -> Bool {
        guard now.isFinite, lastTime == nil || now >= lastTime! else {
            reset()
            return false
        }
        if strictDwell, let lastTime, now - lastTime > maximumStrictSampleGap {
            // A stalled main loop cannot prove the pointer stayed inside.
            // Start a new dwell, retaining any dismissal/once-per-entry lock.
            enteredAt = nil
        }
        lastTime = now
        guard let regionID else {
            if strictDwell { enteredAt = nil }
            if currentRegionID != nil {
                if departedAt == nil { departedAt = now }
                if now - departedAt! >= edgeGrace {
                    currentRegionID = nil
                    enteredAt = nil
                    departedAt = nil
                    blockedRegionID = nil
                }
            }
            if !enabled { enteredAt = nil }
            return false
        }

        if currentRegionID != regionID {
            currentRegionID = regionID
            enteredAt = nil
            blockedRegionID = nil
        } else if let departedAt {
            // The caller may not know which policy applies while outside every
            // eligible screen. Strict re-entry still starts a fresh dwell.
            if strictDwell || now - departedAt >= edgeGrace { enteredAt = nil }
            if now - departedAt >= edgeGrace { blockedRegionID = nil }
        }
        departedAt = nil

        guard enabled else { enteredAt = nil; return false }
        guard blockedRegionID != regionID else { return false }
        if enteredAt == nil { enteredAt = now }
        let dwell = min(3, max(0, delay.isFinite ? delay : 0.12))
        guard now - enteredAt! >= dwell else { return false }
        blockedRegionID = regionID
        enteredAt = nil
        return true
    }

    /// Closing while still over the trigger cannot immediately reopen it.
    /// The lock survives disabled/modal intervals until the pointer leaves.
    mutating func dismiss(regionID: String?, now: TimeInterval) {
        reset()
        guard let regionID, now.isFinite else { return }
        currentRegionID = regionID
        blockedRegionID = regionID
        lastTime = now
    }

    /// Relevant preferences changing must not reuse time accumulated under a
    /// different trigger policy, or clear a deliberate dismissal's lock.
    mutating func cancelPendingDwell() {
        enteredAt = nil
    }

    mutating func reset() {
        currentRegionID = nil
        enteredAt = nil
        departedAt = nil
        blockedRegionID = nil
        lastTime = nil
    }
}

/// Counts only continuous time outside an eligible, visible panel. Returning to
/// the panel or suspending auto-hide cancels the pending dismissal entirely.
struct HubHoverDismissal {
    private var departedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var fired = false
    private var pointerEntered = false

    /// A manual opening stays available until the pointer visits the panel or
    /// focus leaves. Suspending the countdown (for example during sharing)
    /// must not erase the fact that the pointer already entered it.
    mutating func beginPresentation() { pointerEntered = false; reset() }
    mutating func notePointerEntered() { pointerEntered = true }
    func mayDismissAfterOpening(shownFromHover: Bool, panelIsKey: Bool) -> Bool {
        shownFromHover || pointerEntered || !panelIsKey
    }

    mutating func update(outside: Bool, now: TimeInterval, delay: TimeInterval, enabled: Bool = true) -> Bool {
        guard now.isFinite, lastTime == nil || now >= lastTime! else {
            reset()
            return false
        }
        guard enabled && outside else {
            reset()
            return false
        }
        lastTime = now
        guard !fired else { return false }
        if departedAt == nil { departedAt = now }
        let dwell = delay.isFinite ? min(3, max(0, delay)) : 0.55
        guard now - departedAt! >= dwell else { return false }
        fired = true
        return true
    }

    mutating func reset() {
        departedAt = nil
        lastTime = nil
        fired = false
    }
}

/// A source drag may outlive the browser window's visibility. Track its own
/// departure so ordinary mouse exits and other drag sessions cannot donate
/// elapsed time. The caller supplies only FileDock's local file-session ID.
struct HubFileDragDismissal {
    private var sessionID: UUID?
    private var dismissal = HubHoverDismissal()

    mutating func update(sessionID: UUID?, mousePressed: Bool, outside: Bool,
                         now: TimeInterval, delay: TimeInterval, enabled: Bool) -> Bool {
        guard let sessionID, mousePressed, enabled else { reset(); return false }
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            dismissal.reset()
        }
        return dismissal.update(outside: outside, now: now, delay: delay)
    }

    mutating func reset() { sessionID = nil; dismissal.reset() }

    /// AppKit file dragging also runs in eventTracking mode. Only a live local
    /// source with its mouse still pressed may bypass that menu-mode proxy.
    static func menuBlocksDismissal(tracking: Bool, sessionID: UUID?, mousePressed: Bool) -> Bool {
        tracking && !(sessionID != nil && mousePressed)
    }
}

/// Only the source session that automatically hid the panel may bring it back.
/// A separate gate intentionally bypasses the ordinary post-dismissal lock,
/// while retaining the configured region's dwell and strict notch geometry.
struct HubFileDragReentry {
    private var hiddenSessionID: UUID?
    private var activation = HubHoverActivation(edgeGrace: 0)
    var isArmed: Bool { hiddenSessionID != nil }

    mutating func arm(sessionID: UUID) { hiddenSessionID = sessionID; activation.reset() }
    mutating func reset() { hiddenSessionID = nil; activation.reset() }
    mutating func cancelPendingDwell() { activation.cancelPendingDwell() }

    mutating func update(sessionID: UUID?, mousePressed: Bool, regionID: String?,
                         now: TimeInterval, delay: TimeInterval, strictDwell: Bool, enabled: Bool) -> Bool {
        guard let hiddenSessionID else { return false }
        guard sessionID == hiddenSessionID, mousePressed, enabled else { reset(); return false }
        guard activation.update(regionID: regionID, now: now, delay: delay, strictDwell: strictDwell) else { return false }
        reset()
        return true
    }
}
