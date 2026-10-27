import Foundation
import CoreGraphics

struct HubWorkspaceTabInsertion: Equatable {
    let before: UUID?
    let marker: CGRect

    /// The narrow edges/gaps create tabs; tab centers remain spring-loaded file
    /// destinations. All geometry is already clipped, and no view is relaid out.
    static func resolve(at point: CGPoint, header: CGRect, controls: CGRect,
                        music: CGRect? = nil, exclusion: CGRect? = nil,
                        frames: [UUID: CGRect], order: [UUID]) -> Self? {
        guard usable(header), usable(controls), point.x.isFinite, point.y.isFinite,
              header.contains(point), !controls.contains(point), music?.contains(point) != true,
              exclusion?.contains(point) != true else { return nil }
        var row = header.insetBy(dx: 10, dy: 3)
        let rowBottom = min(row.maxY, controls.maxY + 6)
        row.origin.y = max(row.minY, controls.minY - 6)
        row.size.height = rowBottom - row.minY
        guard usable(row), row.contains(point) else { return nil }
        var side = row
        if let exclusion, usable(exclusion) {
            if point.x < exclusion.minX { side.size.width = max(0, exclusion.minX - side.minX) }
            else if point.x >= exclusion.maxX {
                let end = side.maxX; side.origin.x = exclusion.maxX; side.size.width = max(0, end - side.minX)
            } else { return nil }
        }
        // Never draw an insertion marker across the action buttons.
        if controls.intersects(side), controls.minX > side.minX { side.size.width = min(side.width, controls.minX - side.minX) }
        guard usable(side), side.contains(point) else { return nil }
        let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let visible = frames.compactMap { id, rect -> (id: UUID, frame: CGRect)? in
            guard positions[id] != nil, usable(rect) else { return nil }
            let clipped = rect.intersection(side)
            return usable(clipped) ? (id, clipped) : nil
        }.sorted { positions[$0.id]! < positions[$1.id]! }
        if let hit = visible.first(where: { $0.frame.contains(point) }) {
            let edge = min(9, hit.frame.width * 0.2)
            guard point.x <= hit.frame.minX + edge || point.x >= hit.frame.maxX - edge else { return nil }
        }
        let boundary = visible.firstIndex { point.x < $0.frame.midX } ?? visible.count
        let before: UUID?
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
        if visible.isEmpty {
            // Incomplete anchors, or the unused right half of a notch layout,
            // cannot promise a visual insertion position that will land left.
            guard order.isEmpty, exclusion.map({ point.x < $0.minX }) != false else { return nil }
            before = nil
            x = min(side.maxX - 12, side.minX + 14)
            y = side.minY + 4; height = max(2, side.height - 8)
        } else {
            let union = visible.dropFirst().reduce(visible[0].frame) { $0.union($1.frame) }
            y = max(side.minY + 3, union.minY + 5)
            height = max(2, min(side.maxY - 3, union.maxY - 5) - y)
            if boundary < visible.count {
                before = visible[boundary].id
                x = boundary == 0 ? visible[0].frame.minX - 2
                    : (visible[boundary - 1].frame.maxX + visible[boundary].frame.minX) / 2
            } else {
                let last = visible.last!
                before = positions[last.id].flatMap { order.dropFirst($0 + 1).first }
                x = last.frame.maxX + 2
            }
        }
        let markerX = min(side.maxX - 1, max(side.minX + 1, x))
        return Self(before: before, marker: CGRect(x: markerX - 1, y: y, width: 2, height: height))
    }
    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite &&
            rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
    }
}
