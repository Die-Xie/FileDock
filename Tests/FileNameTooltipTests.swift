import AppKit
import SwiftUI

@main
struct FileNameTooltipTests {
    @MainActor static func main() async {
        let short = "报告🚀.txt"
        let long = String(repeating: "完整文件名🚀-", count: 15) + ".svg"
        precondition(!HubFileNameTooltip.isTruncated(short, fontSize: 12, lines: 1, size: NSSize(width: 500, height: 20)))
        precondition(HubFileNameTooltip.isTruncated(long, fontSize: 12, lines: 1, size: NSSize(width: 80, height: 20)))
        precondition(HubFileNameTooltip.isTruncated(long, fontSize: 12, lines: 2, size: NSSize(width: 110, height: 32)))
        precondition(!HubFileNameTooltip.isTruncated("two words", fontSize: 12, lines: 2, size: NSSize(width: 45, height: 40)))
        precondition(!HubFileNameTooltip.isTruncated("", fontSize: 12, lines: 1, size: NSSize(width: 5, height: 20)))
        precondition(!HubFileNameTooltip.isTruncated(long, fontSize: 12, lines: 1, size: .zero))
        let view = HubFileNameTooltip.TrackingView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        precondition(view.hitTest(.zero) == nil, "Tooltip overlays must never intercept drag, click or drop input")
        view.updateTrackingAreas(); view.updateTrackingAreas()
        precondition(view.trackingAreas.count == 1, "Resizing must replace tracking regions")
        print("PASS: filename truncation, multiline Unicode and non-intercepting tracking")
    }
}
