import Foundation

enum HubEmbeddedMusicPlacement: Equatable {
    case hidden, bottom, notch, headerRow
}

/// Keeps music controls below the physical cutout while preserving the normal
/// bottom bar for panels that are not embedded in the screen's top edge.
struct HubEmbeddedMusicLayout {
    static let controlHeight: CGFloat = 20
    static let barHeight: CGFloat = 25
    static let controlWidth: CGFloat = 110
    static let rowHeight: CGFloat = 28

    let placement: HubEmbeddedMusicPlacement
    let headerHeight: CGFloat
    let controlTop: CGFloat
    let displayWidth: CGFloat

    static func make(enabled: Bool, embedded: Bool, split: Bool,
                     exclusionWidth: CGFloat, topInset: CGFloat,
                     fontSize: CGFloat) -> HubEmbeddedMusicLayout {
        let inset = topInset.isFinite ? max(0, topInset) : 0
        let font = fontSize.isFinite ? max(0, fontSize) : 13
        let width = exclusionWidth.isFinite ? max(0, exclusionWidth) : 0
        let baseHeight = max(52, font + 36, inset + 12)
        let controlTop = inset + 2

        let placement: HubEmbeddedMusicPlacement
        if !enabled {
            placement = .hidden
        } else if !embedded {
            placement = .bottom
        } else if split && width >= controlWidth {
            placement = .notch
        } else {
            placement = .headerRow
        }

        let height = placement == .notch
            ? max(baseHeight, controlTop + barHeight + 4)
            : baseHeight
        let displayWidth = placement == .notch ? max(controlWidth, width - 8) : 240
        return HubEmbeddedMusicLayout(placement: placement, headerHeight: height,
                                      controlTop: controlTop, displayWidth: displayWidth)
    }
}
