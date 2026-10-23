import Foundation
import CoreGraphics

/// Corner presentation uses the usable desktop for the panel and the physical
/// screen for the trigger. A narrow corridor joins them across menu/Dock gaps.
struct HubCornerPlacement {
    let bodyFrame: CGRect
    let keepAliveFrame: CGRect

    static func make(corner: String, screenFrame: CGRect, visibleFrame: CGRect,
                     requestedSize: CGSize) -> HubCornerPlacement? {
        guard ["topLeft", "topRight", "bottomLeft", "bottomRight"].contains(corner),
              valid(screenFrame), valid(visibleFrame),
              visibleFrame.minX >= screenFrame.minX, visibleFrame.maxX <= screenFrame.maxX,
              visibleFrame.minY >= screenFrame.minY, visibleFrame.maxY <= screenFrame.maxY else { return nil }
        let left = corner == "topLeft" || corner == "bottomLeft"
        let top = corner == "topLeft" || corner == "topRight"
        // Extremely small displays still receive a positive, contained panel.
        let marginX = min(8, visibleFrame.width / 4)
        let marginY = min(8, visibleFrame.height / 4)
        let requestedWidth = requestedSize.width.isFinite ? max(600, requestedSize.width) : 900
        let requestedHeight = requestedSize.height.isFinite ? max(300, requestedSize.height) : 480
        let width = min(requestedWidth, visibleFrame.width - 2 * marginX)
        let height = min(requestedHeight, visibleFrame.height - 2 * marginY)
        let body = CGRect(x: left ? visibleFrame.minX + marginX : visibleFrame.maxX - marginX - width,
                          y: top ? visibleFrame.maxY - marginY - height : visibleFrame.minY + marginY,
                          width: width, height: height)
        guard valid(body) else { return nil }

        let triggerWidth = min(18, screenFrame.width)
        let triggerHeight = min(12, screenFrame.height)
        let trigger = CGRect(x: left ? screenFrame.minX : screenFrame.maxX - triggerWidth,
                             y: top ? screenFrame.maxY - triggerHeight : screenFrame.minY,
                             width: triggerWidth, height: triggerHeight)
        let insetX = min(14, body.width / 4)
        let insetY = min(14, body.height / 4)
        let entryWidth = min(32, body.width - 2 * insetX)
        let entryHeight = min(32, body.height - 2 * insetY)
        let entry = CGRect(x: left ? body.minX + insetX : body.maxX - insetX - entryWidth,
                           y: top ? body.maxY - insetY - entryHeight : body.minY + insetY,
                           width: entryWidth, height: entryHeight)
        let corridor = trigger.union(entry)
        guard valid(corridor) else { return nil }
        return HubCornerPlacement(bodyFrame: body, keepAliveFrame: corridor)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.size.width > 0 && rect.size.height > 0 &&
            rect.maxX.isFinite && rect.maxY.isFinite
    }
}
