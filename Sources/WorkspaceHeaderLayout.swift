import Foundation

/// A single ordered tab strip can flow around the hardware exclusion. The
/// cut point is independent of selection so choosing a tab never moves it.
struct HubWorkspaceHeaderLayout {
    static let tabSpacing: CGFloat = 5
    static let minimumTabWidth: CGFloat = 48
    static let minimumDragWidth: CGFloat = 32
    static let fallbackControlsWidth: CGFloat = 148

    let splitIndex: Int
    let leftViewportWidth: CGFloat
    let rightViewportWidth: CGFloat
    let controlsWidth: CGFloat
    let dragWidth: CGFloat

    static func toolbarTopInset(embedded: Bool, split: Bool, safeTop: CGFloat,
                                menuBarMayOverlap: Bool) -> CGFloat {
        guard embedded, split, menuBarMayOverlap, safeTop.isFinite else { return 0 }
        return max(0, safeTop)
    }

    static func make(tabWidths: [CGFloat], sideWidth: CGFloat,
                     measuredControlsWidth: CGFloat = 0) -> HubWorkspaceHeaderLayout {
        let side = sideWidth.isFinite ? max(0, sideWidth) : 0
        let requestedControls = measuredControlsWidth.isFinite && measuredControlsWidth > 0
            ? measuredControlsWidth : fallbackControlsWidth
        let controls = min(requestedControls, max(0, side - minimumDragWidth))
        let rightCapacity = max(0, side - controls - minimumDragWidth)
        let widths = tabWidths.map { $0.isFinite ? max(minimumTabWidth, $0) : minimumTabWidth }

        // When the right side cannot fit even one usable tab, keep the full
        // strip on the left rather than exposing a clipped sliver on the right.
        var split = widths.count
        if side >= minimumTabWidth && rightCapacity >= minimumTabWidth {
            var used: CGFloat = 0
            split = 0
            for width in widths {
                let next = min(width, side) + (split == 0 ? 0 : tabSpacing)
                guard used + next <= side else { break }
                used += next
                split += 1
            }
        }

        func stripWidth(_ values: ArraySlice<CGFloat>, limit: CGFloat) -> CGFloat {
            values.reduce(0) { $0 + min($1, limit) }
                + CGFloat(max(0, values.count - 1)) * tabSpacing
        }
        let leftWidth = min(side, stripWidth(widths.prefix(split), limit: side))
        let rightWidth = min(rightCapacity, stripWidth(widths.dropFirst(split), limit: rightCapacity))
        return HubWorkspaceHeaderLayout(splitIndex: split, leftViewportWidth: leftWidth,
                                        rightViewportWidth: rightWidth, controlsWidth: controls,
                                        dragWidth: max(0, side - controls - rightWidth))
    }
}
