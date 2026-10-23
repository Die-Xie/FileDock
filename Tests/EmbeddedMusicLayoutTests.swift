import Foundation

@main
struct EmbeddedMusicLayoutTests {
    private static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
    }

    private static func layout(enabled: Bool = true, embedded: Bool = true,
                               split: Bool = true, width: CGFloat = 236,
                               inset: CGFloat = 38, font: CGFloat = 13) -> HubEmbeddedMusicLayout {
        let result = HubEmbeddedMusicLayout.make(enabled: enabled, embedded: embedded,
                                                split: split, exclusionWidth: width,
                                                topInset: inset, fontSize: font)
        precondition(result.headerHeight.isFinite && result.headerHeight >= 52,
                     "Header dimensions must stay finite and nonnegative")
        precondition(result.controlTop.isFinite && result.controlTop >= 2,
                     "Controls must not rise above the normalized screen inset")
        precondition(result.displayWidth.isFinite && result.displayWidth >= HubEmbeddedMusicLayout.controlWidth,
                     "The music display must stay finite and fit its playback controls")
        if result.placement == .notch {
            precondition(result.controlTop + HubEmbeddedMusicLayout.controlHeight
                         <= result.headerHeight - 4,
                         "The entire control row must fit below the cutout with bottom clearance")
            precondition(result.displayWidth <= width,
                         "The music display must stay inside the central exclusion region")
        } else {
            near(result.displayWidth, 240, "Non-notch placements use the safe fallback display width")
        }
        return result
    }

    static func main() {
        near(HubEmbeddedMusicLayout.controlHeight, 20, "Compact buttons have an explicit height")
        near(HubEmbeddedMusicLayout.controlWidth, 110, "The central controls require a usable width")
        near(HubEmbeddedMusicLayout.rowHeight, 28, "Fallback rows reserve their own safe space")

        let notch = layout()
        precondition(notch.placement == .notch)
        near(notch.controlTop, 40, "Controls must start below the 38-point hardware inset")
        near(notch.headerHeight, 64, "The header must grow enough to expose the whole control row")
        near(notch.displayWidth, 228, "The display fills the center with four-point side clearances")

        let disabled = layout(enabled: false)
        precondition(disabled.placement == .hidden)
        near(disabled.headerHeight, 52, "Disabled music must retain the original header height")
        precondition(layout(enabled: false, embedded: false).placement == .hidden,
                     "The disabled setting takes precedence over panel placement")

        let connected = layout(embedded: false)
        precondition(connected.placement == .bottom,
                     "Curve-connected and detached windows must retain the bottom music bar")
        near(connected.headerHeight, 52, "Ordinary panels must not grow a notch music region")
        precondition(layout(embedded: false, split: false, width: 0).placement == .bottom)

        let fallback = layout(split: false)
        precondition(fallback.placement == .headerRow,
                     "A narrow or unestablished cutout must use a separate safe header row")
        near(fallback.headerHeight, 52, "The view adds the fallback row separately")
        precondition(layout(split: false, width: 0, inset: 0).placement == .headerRow,
                     "An unnotched embedded display still keeps music in the header")
        precondition(layout(width: 109.999).placement == .headerRow,
                     "A central region that is even slightly too narrow cannot clip controls")
        precondition(layout(width: 110).placement == .notch,
                     "Exactly fitting controls can use the central region")
        near(layout(width: 110).displayWidth, 110,
             "An exactly fitting center retains the minimum playback control width")
        near(layout(width: 118).displayWidth, 110,
             "Side clearances must not shrink the display below its playback control width")
        near(layout(width: 300).displayWidth, 292,
             "A wider hardware center exposes more track text instead of leaving it unused")
        precondition(layout(width: 84).placement == .headerRow,
                     "A split header alone does not establish enough central music width")

        let largerFont = layout(font: 40)
        near(largerFont.headerHeight, 76, "Music must not shrink a header enlarged by text")
        near(layout(enabled: false, inset: 60).headerHeight, 72,
             "Disabled music preserves the existing inset-based header height")
        near(layout(inset: 60).headerHeight, 86,
             "Taller hardware cutouts must push controls and the header down together")
        near(layout(inset: 0).headerHeight, 52,
             "A zero-depth cutout does not create an unnecessary taller header")

        for invalidWidth in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            precondition(layout(width: invalidWidth).placement == .headerRow,
                         "Invalid central widths must use the safe fallback")
        }
        for invalidInset in [CGFloat.nan, .infinity, -.infinity, -38] {
            near(layout(inset: invalidInset).controlTop, 2,
                 "Invalid or negative insets normalize to the top edge")
        }
        for invalidFont in [CGFloat.nan, .infinity, -.infinity, -13] {
            near(layout(enabled: false, font: invalidFont).headerHeight, 52,
                 "Invalid or negative font inputs cannot corrupt header dimensions")
        }

        let transitions = [
            layout().placement,
            layout(embedded: false).placement,
            layout(enabled: false).placement,
            layout(split: false).placement,
            layout().placement
        ]
        precondition(transitions == [.notch, .bottom, .hidden, .headerRow, .notch],
                     "Switching modes must derive placement without stale state")
        print("PASS: Embedded music stays below the notch with safe width, mode and invalid-geometry fallbacks")
    }
}
