import Foundation

@main
struct WorkspaceHeaderLayoutTests {
    private static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
    }

    private static func check(_ widths: [CGFloat], side: CGFloat, controls: CGFloat = 0) -> HubWorkspaceHeaderLayout {
        let layout = HubWorkspaceHeaderLayout.make(tabWidths: widths, sideWidth: side,
                                                   measuredControlsWidth: controls)
        precondition(layout.splitIndex >= 0 && layout.splitIndex <= widths.count)
        precondition(layout.leftViewportWidth.isFinite && layout.leftViewportWidth >= 0)
        precondition(layout.rightViewportWidth.isFinite && layout.rightViewportWidth >= 0)
        precondition(layout.leftViewportWidth <= side)
        near(layout.rightViewportWidth + layout.dragWidth + layout.controlsWidth, side,
             "The right viewport, drag area and controls must fit exactly inside the safe side")
        precondition(layout.dragWidth >= min(side, HubWorkspaceHeaderLayout.minimumDragWidth))
        let ids = Array(widths.indices)
        precondition(Array(ids.prefix(layout.splitIndex)) + Array(ids.dropFirst(layout.splitIndex)) == ids,
                     "Both segments must preserve each tab exactly once in its saved order")
        return layout
    }

    static func main() {
        let example = check([110, 100, 80, 120], side: 310, controls: 110)
        precondition(example.splitIndex == 3, "The fourth whole tab should flow onto the right")
        near(example.leftViewportWidth, 300, "The left strip keeps intrinsic tab widths")
        near(example.rightViewportWidth, 120, "The right side continues the same strip")
        near(example.dragWidth, 80, "Remaining right-side space remains available to move the window")

        precondition(check([100, 100, 100], side: 310, controls: 110).splitIndex == 3,
                     "A strip fitting exactly on the left must not move its final tab")
        precondition(check([100, 100, 100], side: 309, controls: 110).splitIndex == 2,
                     "A tab exceeding the left edge must move whole to the other side")
        let longNames = check([900, 800, 700], side: 310, controls: 110)
        precondition(longNames.splitIndex == 1, "An oversized first tab is capped without losing it")
        near(longNames.leftViewportWidth, 310, "A long left tab is contained by its viewport")
        near(longNames.rightViewportWidth, 168, "Long right tabs scroll inside the reserved capacity")

        let empty = check([], side: 310, controls: 110)
        precondition(empty.splitIndex == 0)
        near(empty.rightViewportWidth, 0, "An empty strip adds no right viewport")
        near(empty.dragWidth, 200, "An empty header keeps the unused area draggable")
        precondition(check([110], side: 310, controls: 110).splitIndex == 1)
        let many = check(Array(repeating: 80, count: 20), side: 310, controls: 110)
        precondition(many.splitIndex == 3)
        near(many.rightViewportWidth, 168, "Overflow remains in the right scroll viewport")

        let widerControls = check([110, 100, 80, 120], side: 310, controls: 180)
        near(widerControls.rightViewportWidth, 98, "Wider controls reduce tab capacity before the safe edge")
        near(widerControls.dragWidth, 32, "Controls must retain an explicit window drag area")
        precondition(check([80, 80, 80], side: 180, controls: 115).splitIndex == 3,
                     "Insufficient right space keeps one usable scrolling strip on the left")
        near(check([], side: 310).controlsWidth, 132, "First layout reserves a safe control-width fallback")
        near(check([], side: 310, controls: .nan).controlsWidth, 132, "Invalid measurements use the fallback")
        near(check([], side: 310, controls: -10).controlsWidth, 132, "Negative measurements use the fallback")
        near(check([], side: 180, controls: 1_000).controlsWidth, 148, "Oversized measurements cannot invade the drag region")

        let resized = check([110, 100, 80, 120], side: 430, controls: 110)
        precondition(resized.splitIndex == 4, "Resizing flows tabs back to the left when all fit")
        let largerFont = check([140, 125, 100, 155], side: 310, controls: 110)
        precondition(largerFont.splitIndex == 2, "Larger measured labels recompute the whole-tab cutoff")
        let invalid = HubWorkspaceHeaderLayout.make(tabWidths: [.nan, -.infinity, -10], sideWidth: .nan)
        near(invalid.leftViewportWidth + invalid.rightViewportWidth + invalid.controlsWidth + invalid.dragWidth, 0,
             "Transient invalid geometry cannot propagate non-finite view sizes")
        print("PASS: Workspace header flows ordered tabs around the notch and reserves controls and window dragging")
    }
}
