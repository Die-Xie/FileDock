import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct HubColorFilterPlateKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A click following hover confirms the color. A deliberate second click can
/// clear it without stationary hover immediately selecting it again.
struct HubColorLabelFilterInput {
    private var hoverSelection: Int?
    private var blocked: Int?
    private func key(_ label: HubFinderLabel?) -> Int { label?.rawValue ?? -1 }
    func permitsHover(_ label: HubFinderLabel?) -> Bool { blocked != key(label) }
    mutating func hovered(_ label: HubFinderLabel?) { hoverSelection = key(label) }
    mutating func click(_ label: HubFinderLabel?, current: HubFinderLabel?) -> HubFinderLabel? {
        let target = key(label), confirmsHover = hoverSelection == target
        blocked = target; hoverSelection = nil
        return confirmsHover ? label : current == label ? nil : label
    }
    mutating func exit(_ label: HubFinderLabel?) {
        if blocked == key(label) { blocked = nil }
        if hoverSelection == key(label) { hoverSelection = nil }
    }
}

/// Uses the already loaded Finder label numbers. Rendering and selection never
/// read file metadata, refresh a directory, or write a file's tags.
struct HubColorLabelFilterBar: View {
    let selection: HubFinderLabel?
    let onSelect: (HubFinderLabel?) -> Void
    var nativeDropHint: (HubFinderLabel) -> String? = { _ in nil }
    var movesDroppedFilesToCurrentDirectory = false
    var hoverDelay: TimeInterval = 0.1
    var hoverEnabled = true
    var canHover: () -> Bool = { true }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hubInterfaceMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = HubWorkspaceHoverController()
    @State private var input = HubColorLabelFilterInput()
    private static let hoverIDs = (0..<9).map { _ in UUID() }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Button { click(nil) } label: {
                    Text(L("全部")).font(.system(size: 10))
                        .frame(minWidth: 34, minHeight: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("显示全部颜色标签"))
                    .accessibilityIdentifier("filedock.color-filter.all")
                    .onContinuousHover(coordinateSpace: CoordinateSpace.local) { updateHover($0, label: nil) }
                    .anchorPreference(key: HubColorFilterPlateKey.self, value: .bounds) { [-1: $0] }
                ForEach(HubFinderLabel.colors + [.none]) { label in
                    colorButton(label)
                }
            }.fixedSize()
                .backgroundPreferenceValue(HubColorFilterPlateKey.self) { anchors in
                    GeometryReader { geometry in
                        HubSelectionPlate(selectionFrame: anchors[selection?.rawValue ?? -1].map { geometry[$0] },
                            cornerRadius: 5, motion: filterMotion)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            Menu {
                Button(L("全部")) { onSelect(nil) }
                ForEach(HubFinderLabel.colors + [.none]) { label in
                    Button { onSelect(selection == label ? nil : label) } label: {
                        Label { Text(label.name) } icon: {
                            Image(systemName: selection == label ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(Color(nsColor: label.color))
                        }
                    }
                }
            } label: {
                Label(selection?.name ?? L("颜色标签"), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
            }.menuStyle(.borderlessButton).fixedSize()
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(L("颜色标签筛选"))
            .onChange(of: selection) { _ in hover.cancel() }
            .onChange(of: hoverDelay) { _ in hover.cancel() }
            .onChange(of: hoverEnabled) { if !$0 { hover.cancel() } }
            .onChange(of: isEnabled) { if !$0 { hover.cancel() } }
            .onDisappear { hover.cancel() }
    }

    private var filterMotion: HubInterfaceMotion {
        HubInterfaceMotion(enabled: motion.enabled && !reduceMotion && isEnabled, speed: motion.speed)
    }

    private func colorButton(_ label: HubFinderLabel) -> some View {
        let hint = nativeDropHint(label)
        return Button { click(label) } label: {
            colorDot(label)
                .frame(width: 13, height: 13).frame(width: 28, height: 28)
                .background(hint != nil && selection != label ? Color.primary.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(hint == nil ? Color.clear : Color.accentColor, lineWidth: 1.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(L("筛选：\(label.name)"))
            .accessibilityAddTraits(selection == label ? .isSelected : [])
            .accessibilityIdentifier("filedock.color-filter.\(label.rawValue)")
            .help(movesDroppedFilesToCurrentDirectory
                  ? L("\(label.name)：悬停筛选；拖入设色，外部文件移入当前文件夹，按 ⌥ 复制")
                  : L("\(label.name)：悬停筛选，拖入文件设置标签"))
            .onContinuousHover(coordinateSpace: CoordinateSpace.local) { updateHover($0, label: label) }
            .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.colorLabel(label.rawValue): $0] }
            .anchorPreference(key: HubColorFilterPlateKey.self, value: .bounds) { [label.rawValue: $0] }
    }

    private func colorDot(_ label: HubFinderLabel) -> some View {
        ZStack {
            if label == .none {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.2)
                Image(systemName: "line.diagonal").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Circle().fill(Color(nsColor: label.color))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            if selection == label {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(label == .none ? Color.primary :
                        [.yellow, .orange, .green].contains(label) ? Color.black.opacity(0.85) : .white)
                    .transition(.opacity)
            }
        }.animation(filterMotion.feedback, value: selection)
            .animation(nil, value: filterMotion.enabled)
    }

    private func click(_ label: HubFinderLabel?) {
        hover.cancel()
        onSelect(input.click(label, current: selection))
    }
    private func updateHover(_ phase: HoverPhase, label: HubFinderLabel?) {
        let id = Self.hoverIDs[(label?.rawValue ?? -1) + 1]
        switch phase {
        case .ended:
            hover.cancel(target: id); input.exit(label)
        case .active:
            guard hoverDelay.isFinite, hoverDelay >= 0, hoverEnabled, isEnabled, canHover(), selection != label, input.permitsHover(label) else {
                hover.cancel(target: id); return
            }
            hover.update(target: id, pointer: NSEvent.mouseLocation, delay: hoverDelay,
                canActivate: { hoverEnabled && isEnabled && canHover() && input.permitsHover(label) },
                activate: { input.hovered(label); onSelect(label) })
        }
    }
}
