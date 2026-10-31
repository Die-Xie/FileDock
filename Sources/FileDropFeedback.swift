import SwiftUI

/// Geometry, rather than separate drop receivers, identifies the destination.
/// Clip scrolled tabs to their own viewport so hidden tabs cannot accept a drop.
enum HubFileDropRegion: Hashable {
    case content, workspace(UUID), staging, airDrop, item(URL), tabViewport(UUID)
    case header, headerControls, headerMusic, colorLabel(Int)

    func visibleFrame(in regions: [Self: CGRect]) -> CGRect {
        let frame = regions[self] ?? .zero
        if case .workspace(let id) = self, let viewport = regions[.tabViewport(id)] { return frame.intersection(viewport) }
        return frame
    }

    static func at(_ point: CGPoint, in regions: [Self: CGRect]) -> Self? {
        // Sharing is independent of tab/content semantics, including at any
        // transient overlap while header geometry is being remeasured.
        if regions[.airDrop]?.contains(point) == true { return .airDrop }
        // Header destinations take priority over the content only at boundaries.
        for region in regions.keys {
            switch region {
            case .workspace, .staging, .colorLabel:
                if region.visibleFrame(in: regions).contains(point) { return region }
            default: break
            }
        }
        return regions[.content]?.contains(point) == true ? .content : nil
    }


}

struct HubFileDropRegionKey: PreferenceKey {
    static var defaultValue: [HubFileDropRegion: Anchor<CGRect>] = [:]
    static func reduce(value: inout [HubFileDropRegion: Anchor<CGRect>], nextValue: () -> [HubFileDropRegion: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct HubFileDropPlan {
    enum Action { case move, copy, reference, reorder, groupedReorderBlocked, airDrop, createWorkspace, colorLabel, colorLabelMove, colorLabelCopy }
    var workspaceID: UUID?
    var directory: URL?
    var item: URL?
    var title: String
    var action: Action
    var slot: HubFileInsertionSlot? = nil
    var workspaceInsertion: HubWorkspaceTabInsertion? = nil
    var groupID: String? = nil
}

struct HubFileDropFeedback: Equatable {
    var rect: CGRect
    var title: String
    var count: Int
    var action: HubFileDropPlan.Action
    var insertion: Bool

    private var verb: String {
        switch action {
        case .move: return L("移动")
        case .copy: return L("复制")
        case .reference: return L("添加引用")
        case .reorder: return L("调整顺序")
        case .groupedReorderBlocked: return L("调整顺序")
        case .airDrop: return L("通过 AirDrop 发送")
        case .createWorkspace: return L("创建标签")
        case .colorLabel, .colorLabelMove, .colorLabelCopy: return L("设置颜色标签")
        }
    }
    private var symbol: String {
        switch action {
        case .move: return "arrow.right.doc.on.clipboard"
        case .copy: return "plus.square.on.square"
        case .reference: return "link"
        case .reorder: return "arrow.up.arrow.down"
        case .groupedReorderBlocked: return "nosign"
        case .airDrop: return "airplayaudio"
        case .createWorkspace: return "folder.badge.plus"
        case .colorLabel, .colorLabelMove, .colorLabelCopy: return "tag"
        }
    }
    var prompt: String {
        if action == .groupedReorderBlocked { return L("只能在同一群组内调整顺序") }
        if action == .createWorkspace { return L("松开以将文件夹添加为标签 · 数量：\(count)") }
        if action == .colorLabel { return L("松开以设置 \(count) 项的颜色标签：\(title)") }
        if action == .colorLabelMove { return L("松开以移入并设色 \(count) 项 · \(title)；当前文件夹内仅设色") }
        if action == .colorLabelCopy { return L("松开以拷入并设色 \(count) 项 · \(title)；当前文件夹内仅设色") }
        return action == .airDrop ? L("松开以通过 AirDrop 发送 \(count) 项") : L("松开以\(verb) \(count) 项 · \(title)")
    }
    func overlay(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if insertion {
                Capsule().fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                if action == .createWorkspace {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.65)))
                        .position(x: min(max(14, rect.midX), max(14, size.width - 14)), y: rect.maxY)
                }
            } else if action != .groupedReorderBlocked {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .frame(width: max(0, rect.width - 8), height: max(0, rect.height - 8))
                    .offset(x: rect.minX + 4, y: rect.minY + 4)
            }
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(prompt).lineLimit(1).truncationMode(.middle)
                if action == .move || action == .colorLabelMove { Text(L("⌥ 复制")).foregroundStyle(.secondary) }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            .frame(maxWidth: max(0, size.width - 32))
            .position(x: size.width / 2, y: max(24, size.height - 58))
        }.frame(width: size.width, height: size.height, alignment: .topLeading).allowsHitTesting(false)
    }
}

struct HubFileInsertionSlot {
    var before: URL?
    var rect: CGRect
    var horizontal: Bool

    /// Resolve positions between visible items, including gaps and the tail.
    /// Excluding the dragged group keeps its old cells from becoming targets.
    static func resolve(at point: CGPoint, frames: [URL: CGRect], order: [URL],
                        content: CGRect, horizontal: Bool, excluding: Set<URL> = []) -> Self? {
        guard let url = nearestItem(at: point, frames: frames, content: content, candidates: order, excluding: excluding),
              let frame = frames[url], let index = order.firstIndex(of: url) else { return nil }
        let after = horizontal ? point.y >= frame.midY : point.x >= frame.midX
        let before = after ? order.dropFirst(index + 1).first(where: { !excluding.contains($0) }) : url
        let marker: CGRect
        if horizontal {
            let y = min(max(after ? frame.maxY : frame.minY, content.minY + 1), content.maxY - 1)
            marker = CGRect(x: max(frame.minX, content.minX) + 4, y: y - 1,
                            width: max(2, min(frame.maxX, content.maxX) - max(frame.minX, content.minX) - 8), height: 2)
        } else {
            let x = min(max(after ? frame.maxX + 4 : frame.minX - 4, content.minX + 1), content.maxX - 1)
            marker = CGRect(x: x - 1, y: max(frame.minY, content.minY) + 5, width: 2,
                            height: max(2, min(frame.maxY, content.maxY) - max(frame.minY, content.minY) - 10))
        }
        return Self(before: before, rect: marker, horizontal: horizontal)
    }

    static func nearestItem(at point: CGPoint, frames: [URL: CGRect], content: CGRect,
                            candidates: [URL], excluding: Set<URL> = []) -> URL? {
        candidates.filter { url in
            guard !excluding.contains(url), let frame = frames[url] else { return false }
            return !frame.intersection(content).isEmpty
        }.min { distance(point, to: frames[$0]!) < distance(point, to: frames[$1]!) }
    }
    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
