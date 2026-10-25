import Foundation
import CoreGraphics

/// Screen-space geometry. The body stays below the menu bar; a click-through
/// connector curves from the notch into the flat portion of the body's top.
struct HubNotchPlacement {
    let bodyFrame: CGRect
    let bridgeFrame: CGRect
    let sourceWidth: CGFloat

    static func make(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                     leftAuxiliary: CGRect?, rightAuxiliary: CGRect?, requestedSize: CGSize) -> HubNotchPlacement {
        let menuInset = max(0, screenFrame.maxY - visibleFrame.maxY)
        let inset = max(10, max(safeTop, menuInset))
        let top = screenFrame.maxY - inset - HubNotchMotion.neckDepth
        // Side docks can make the visible frame asymmetric. Limit the two
        // shoulders symmetrically so their stem remains below the hardware hub.
        let centeredWidth = max(1, 2 * min(screenFrame.midX - visibleFrame.minX - 12,
                                          visibleFrame.maxX - screenFrame.midX - 12))
        let width = min(max(600, requestedSize.width), max(1, visibleFrame.width - 24), centeredWidth)
        let height = min(max(300, requestedSize.height), max(1, top - visibleFrame.minY - 12))
        let x = min(max(screenFrame.midX - width / 2, visibleFrame.minX + 12), visibleFrame.maxX - width - 12)
        let body = CGRect(x: x, y: top - height, width: width, height: height)
        let hardwareWidth: CGFloat
        if let left = leftAuxiliary, let right = rightAuxiliary, right.minX - left.maxX > 60 {
            hardwareWidth = right.minX - left.maxX
        } else { hardwareWidth = 186 }
        let sourceWidth = min(max(100, hardwareWidth), max(100, width - 100))
        // One point of overlap prevents a separate compositing surface exposing a seam.
        // Matching the body's coordinate space leaves the curve endpoints 32 pt
        // inside its corners, instead of making a small local shoulder at the hub.
        let bridge = CGRect(x: body.minX, y: top - 1,
                            width: body.width, height: inset + HubNotchMotion.neckDepth + 1)
        return HubNotchPlacement(bodyFrame: body, bridgeFrame: bridge, sourceWidth: sourceWidth)
    }
}

/// A second attachment style places the panel around the hardware cutout,
/// rather than below it. Header controls can occupy the two safe side regions;
/// narrow panels instead put their complete toolbar below `topInset`.
struct HubEmbeddedPlacement {
    let bodyFrame: CGRect
    let sourceWidth: CGFloat
    let topInset: CGFloat
    let headerExclusionWidth: CGFloat
    let usesSplitHeader: Bool

    static func make(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                     leftAuxiliary: CGRect?, rightAuxiliary: CGRect?, requestedSize: CGSize) -> HubEmbeddedPlacement {
        let centeredWidth = max(1, 2 * min(screenFrame.midX - visibleFrame.minX - 12,
                                          visibleFrame.maxX - screenFrame.midX - 12))
        let requestedWidth = requestedSize.width.isFinite ? requestedSize.width : 900
        let requestedHeight = requestedSize.height.isFinite ? requestedSize.height : 480
        let width = min(max(600, requestedWidth), max(1, visibleFrame.width - 24), centeredWidth)
        let height = min(max(300, requestedHeight), max(1, screenFrame.maxY - visibleFrame.minY - 12))
        let body = CGRect(x: screenFrame.midX - width / 2,
                          y: screenFrame.maxY - height, width: width, height: height)

        let auxiliaryGap: CGFloat
        if let left = leftAuxiliary, let right = rightAuxiliary {
            let gap = right.minX - left.maxX
            auxiliaryGap = gap.isFinite && gap > 60 ? gap : 0
        } else { auxiliaryGap = 0 }
        let hardwareWidth = auxiliaryGap > 0 ? auxiliaryGap : 186
        let sourceWidth = min(max(100, hardwareWidth), max(100, width - 100))
        let menuInset = max(0, screenFrame.maxY - visibleFrame.maxY)
        let safeInset = safeTop.isFinite ? max(0, safeTop) : 0
        let hasHardwareCutout = safeInset > 0 && auxiliaryGap > 0
        // NSScreen can omit auxiliary regions while still reporting the hardware
        // safe inset. Never place the fallback toolbar behind that known inset.
        let topInset = max(safeInset, menuInset)
        let exclusion = hasHardwareCutout ? min(auxiliaryGap + 24, max(0, width - 24)) : 0
        let leftUsableWidth = (width - exclusion) / 2 - 12
        let rightUsableWidth = (width - exclusion) / 2 - 12
        // Reserve the natural width of all six possible header shortcuts.
        // Narrower shoulders use the complete toolbar below the safe inset.
        let splitHeader = hasHardwareCutout && leftUsableWidth >= 200 && rightUsableWidth >= 200
        return HubEmbeddedPlacement(bodyFrame: body, sourceWidth: sourceWidth, topInset: topInset,
                                    headerExclusionWidth: exclusion, usesSplitHeader: splitHeader)
    }
}
