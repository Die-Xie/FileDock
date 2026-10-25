import SwiftUI

enum HubHeaderDragRegion: Hashable {
    case header, controls, music
    case tab(UUID), viewport(UUID)
}
struct HubHeaderDragRegionKey: PreferenceKey {
    static var defaultValue: [HubHeaderDragRegion: Anchor<CGRect>] = [:]
    static func reduce(value: inout [HubHeaderDragRegion: Anchor<CGRect>], nextValue: () -> [HubHeaderDragRegion: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Partition only the header's blank space. Controls and clipped tab viewports
/// keep their own events; file content is never a window-drag surface.
enum HubHeaderDragGeometry {
    static func rectangles(in bounds: CGRect, regions: [HubHeaderDragRegion: CGRect]) -> [CGRect] {
        guard let header = regions[.header], usable(header), usable(bounds) else { return [] }
        let area = header.intersection(bounds)
        guard usable(area) else { return [] }
        let exclusions = regions.compactMap { region, frame -> CGRect? in
            let exclusion: CGRect
            switch region {
            case .header, .viewport: return nil
            case .controls, .music: exclusion = frame
            case .tab(let id):
                // No viewport means layout is incomplete: do not expose the
                // corresponding control as draggable in that intermediate frame.
                exclusion = regions[.viewport(id)].map { frame.intersection($0) } ?? frame
            }
            return usable(exclusion) ? exclusion : nil
        }.sorted {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.maxY != $1.maxY { return $0.maxY < $1.maxY }
            return $0.maxX < $1.maxX
        }
        var available = [area]
        for exclusion in exclusions { available = available.flatMap { subtract(exclusion, from: $0) } }
        return available.filter { $0.width >= 1 && $0.height >= 1 }
            .sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    private static func subtract(_ exclusion: CGRect, from area: CGRect) -> [CGRect] {
        let cut = area.intersection(exclusion)
        guard usable(cut) else { return [area] }
        return [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: cut.minY - area.minY),
            CGRect(x: area.minX, y: cut.maxY, width: area.width, height: area.maxY - cut.maxY),
            CGRect(x: area.minX, y: cut.minY, width: cut.minX - area.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: area.maxX - cut.maxX, height: cut.height)
        ].filter(usable)
    }
    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite &&
            rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
    }
}
