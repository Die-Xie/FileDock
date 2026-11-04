import SwiftUI
import AppKit
import QuartzCore

enum HubFileTypePlateTarget: Hashable {
    case all, type(String), clear, more
}
struct HubFileTypePlateKey: PreferenceKey {
    static var defaultValue: [HubFileTypePlateTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [HubFileTypePlateTarget: Anchor<CGRect>], nextValue: () -> [HubFileTypePlateTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Presentation-only controls. Type options come from the loaded snapshot and
/// never inspect files or participate in native drop routing.
struct HubFileTypeFilterBar: View {
    let shortcuts: [String]
    let selection: String?
    let available: [HubFileTypeOption]
    let totalCount: Int
    let onSelect: (String?) -> Void
    let onUpdateShortcuts: ([String]) -> Void
    @State private var showsEditor = false
    @Environment(\.hubInterfaceMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let displayedShortcuts = HubFileType.displayedShortcuts(preferred: shortcuts, available: available)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 1) {
                allButton
                ForEach(displayedShortcuts, id: \.self) { typeButton($0) }
                moreMenu(markSelected: selection.map { !displayedShortcuts.contains($0) } ?? false)
            }.backgroundPreferenceValue(HubFileTypePlateKey.self) { anchors in
                selectionPlate(anchors: anchors, target: selection.map {
                    displayedShortcuts.contains($0) ? .type($0) : .more
                } ?? .all)
            }.modifier(HubFileTypeSegmentContainer()).fixedSize()
            HStack(spacing: 1) {
                if let selection { compactClearButton(selection) } else { allButton }
                moreMenu(markSelected: false)
            }.backgroundPreferenceValue(HubFileTypePlateKey.self) { anchors in
                selectionPlate(anchors: anchors, target: selection == nil ? .all : .clear)
            }.modifier(HubFileTypeSegmentContainer()).fixedSize()
        }
        // Buttons adopt their final layout immediately. Only this decorative
        // surface and the text inside each fixed hit region interpolate.
        .background(HubFileTypeAvailabilitySurface(emptySnapshot: available.isEmpty && totalCount == 0,
            motion: HubInterfaceMotion(enabled: motion.enabled && !reduceMotion && isEnabled, speed: motion.speed)))
        .modifier(HubFileTypeAvailabilityRevealModifier(types: displayedShortcuts,
            enabled: motion.enabled && !reduceMotion && isEnabled, speed: motion.speed))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("文件类型筛选"))
        .sheet(isPresented: $showsEditor) {
            HubFileTypeShortcutEditor(shortcuts: shortcuts, onSave: onUpdateShortcuts)
        }
    }

    private func selectionPlate(anchors: [HubFileTypePlateTarget: Anchor<CGRect>], target: HubFileTypePlateTarget) -> some View {
        GeometryReader { geometry in
            HubSelectionPlate(selectionFrame: anchors[target].map { geometry[$0] }, cornerRadius: 5,
                motion: HubInterfaceMotion(enabled: motion.enabled && !reduceMotion && isEnabled, speed: motion.speed),
                tracksContainerPosition: true, duration: HubFileTypeAvailabilityReveal.duration(speed: motion.speed))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func select(_ type: String?) {
        NotificationCenter.default.post(name: Notification.Name("HubPanelFilterInteraction"), object: nil)
        onSelect(type)
    }

    private var allButton: some View {
        Button { select(nil) } label: {
            Text(L("全部")).font(.system(size: 10))
                .foregroundStyle(selection == nil ? Color.primary : Color.secondary)
                .padding(.horizontal, 7).frame(minWidth: 28, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filedock.type-filter.all")
        .accessibilityAddTraits(selection == nil ? .isSelected : [])
        .accessibilityLabel(L("全部类型"))
        .help(L("清除类型筛选"))
        .anchorPreference(key: HubFileTypePlateKey.self, value: .bounds) { [.all: $0] }
    }

    private func compactClearButton(_ type: String) -> some View {
        Button { select(nil) } label: {
            HStack(spacing: 4) {
                Text(HubFileType.title(for: type)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 60)
                    .modifier(HubFileTypeAvailabilityLabel())
                Image(systemName: "xmark").font(.system(size: 8, weight: .medium))
            }
            .font(.system(size: 10)).foregroundStyle(Color.primary)
            .padding(.horizontal, 7).frame(minWidth: 28, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filedock.type-filter.clear")
        .accessibilityLabel(L("清除类型筛选"))
        .help(L("筛选：\(HubFileType.title(for: type))") + "\n" + L("清除类型筛选"))
        .anchorPreference(key: HubFileTypePlateKey.self, value: .bounds) { [.clear: $0] }
    }

    private func typeButton(_ type: String) -> some View {
        let selected = selection == type
        return Button {
            select(selected ? nil : type)
        } label: {
            Text(HubFileType.title(for: type)).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 10))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: 90)
                .modifier(HubFileTypeAvailabilityLabel())
                .padding(.horizontal, 7).frame(minWidth: 28, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filedock.type-filter.\(type)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(HubFileType.title(for: type))
        .help(L("再次点按已选类型可清除类型筛选。"))
        .anchorPreference(key: HubFileTypePlateKey.self, value: .bounds) { [.type(type): $0] }
    }

    private func moreMenu(markSelected: Bool) -> some View {
        return Menu {
            Button { select(nil) } label: {
                Label(L("全部类型（\(totalCount)）"), systemImage: selection == nil ? "checkmark" : "line.3.horizontal.decrease")
            }
            Divider()
            if available.isEmpty {
                Text(L("当前面板暂无可筛选类型"))
            }
            ForEach(available) { option in
                Button { select(selection == option.id ? nil : option.id) } label: {
                    Label(L("\(option.title)（\(option.count)）"), systemImage: selection == option.id ? "checkmark" : "doc")
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Divider()
            Button(L("自定义快捷类型…")) { showsEditor = true }
            Button(L("恢复默认类型")) { onUpdateShortcuts(HubFileType.defaultShortcuts) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                .foregroundStyle(markSelected ? Color.primary : Color.secondary)
                .frame(width: 23, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 23, height: 24)
        .accessibilityIdentifier("filedock.type-filter.more")
        .accessibilityLabel(L("更多文件类型"))
        .help(L("筛选：\(selection.map(HubFileType.title(for:)) ?? L("全部类型"))") + "\n" + L("选择当前面板中的类型，或自定义快捷类型。"))
        .anchorPreference(key: HubFileTypePlateKey.self, value: .bounds) { [.more: $0] }
    }
}

private struct HubFileTypeSegmentContainer: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(2).frame(height: 28)
    }
}

/// One lifetime above ViewThatFits: inactive full/compact candidates cannot
/// retain old decorative surfaces or delay their actual controls disappearing.
struct HubFileTypeAvailabilitySurface: NSViewRepresentable {
    let emptySnapshot: Bool
    let motion: HubInterfaceMotion
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {
        view.update(emptySnapshot: emptySnapshot, motion: motion,
                    color: colorScheme == .dark ? .white : .black)
    }

    final class SurfaceView: NSView {
        private(set) var surfaceLayer = CALayer()
        private var motion = HubInterfaceMotion(enabled: false)
        private var emptySnapshot = false
        private var hasDrawn = false
        private var pending: DispatchWorkItem?
        private var generation: UInt64 = 0
        private var pendingWidth: CGFloat?
        var presentationWidth: CGFloat { surfaceLayer.presentation()?.bounds.width ?? surfaceLayer.bounds.width }
        var presentationFrame: CGRect { surfaceLayer.presentation()?.frame ?? surfaceLayer.frame }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            surfaceLayer.anchorPoint = CGPoint(x: 1, y: 0.5)
            surfaceLayer.cornerRadius = 7
            surfaceLayer.borderWidth = 0.5
            layer?.masksToBounds = false
            layer?.addSublayer(surfaceLayer)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelPending(); surfaceLayer.removeAllAnimations(); hasDrawn = false }
        }
        deinit { pending?.cancel() }

        func update(emptySnapshot: Bool, motion: HubInterfaceMotion, color: NSColor) {
            self.emptySnapshot = emptySnapshot; self.motion = motion
            if !emptySnapshot || !motion.enabled { cancelPending() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            surfaceLayer.backgroundColor = color.withAlphaComponent(0.04).cgColor
            surfaceLayer.borderColor = color.withAlphaComponent(0.06).cgColor
            CATransaction.commit()
            needsLayout = true
            if !motion.enabled { install(width: bounds.width, animated: false) }
        }

        override func layout() {
            super.layout()
            let width = bounds.width
            guard width.isFinite, width > 0, bounds.height.isFinite, bounds.height > 0 else { return }
            // The NSView itself already has its final width/origin. Keep the
            // decorative right edge anchored there even during an empty hold.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            surfaceLayer.position = CGPoint(x: bounds.maxX, y: bounds.midY)
            CATransaction.commit()
            if !hasDrawn || !motion.enabled { cancelPending(); install(width: width, animated: false); return }
            if emptySnapshot && width < surfaceLayer.bounds.width {
                // A cold tab can publish an empty first batch. Coalesce only
                // its empty backdrop for 60 ms; old buttons/menu options are
                // already gone and never accept clicks in the new directory.
                if pendingWidth != width {
                    cancelPending(); pendingWidth = width
                    let token = generation
                    let task = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == token, self.emptySnapshot else { return }
                        self.pending = nil; self.pendingWidth = nil
                        self.install(width: self.bounds.width, animated: self.motion.enabled)
                    }
                    pending = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: task)
                }
                return
            }
            cancelPending(); install(width: width, animated: true)
        }

        private func cancelPending() { generation &+= 1; pending?.cancel(); pending = nil; pendingWidth = nil }
        private func install(width: CGFloat, animated: Bool) {
            guard width.isFinite, width > 0, bounds.height.isFinite, bounds.height > 0 else { return }
            let current = presentationWidth
            let changed = surfaceLayer.bounds.width != width
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if changed || !animated { surfaceLayer.removeAllAnimations() }
            surfaceLayer.position = CGPoint(x: bounds.maxX, y: bounds.midY)
            surfaceLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            CATransaction.commit()
            let animate = animated && motion.enabled && hasDrawn && changed && abs(current - width) > 0.25
            hasDrawn = true
            guard animate else { return }
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = current; animation.toValue = width
            animation.duration = HubFileTypeAvailabilityReveal.duration(speed: motion.speed)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.35, 0.30, 1)
            surfaceLayer.add(animation, forKey: "availability")
        }
    }
}

/// At most a seed and endpoint publish for a type batch. Closely spaced A/B/C
/// visits and directory batches share one reveal instead of flashing the text.
@MainActor final class HubFileTypeAvailabilityReveal: ObservableObject {
    @Published private(set) var phase: Double = 1
    private var types: [String]?
    private var deadline: TimeInterval?
    private var pendingDuration: TimeInterval?
    static func duration(speed: Double) -> TimeInterval {
        let speed = speed.isFinite ? min(2, max(0.5, speed)) : 1
        return min(0.42, max(0.26, 0.36 / speed))
    }
    func observe(types: [String], enabled: Bool, speed: Double) {
        let previous = self.types
        self.types = types
        guard enabled else { settle(); return }
        guard let previous, previous != types, !types.isEmpty, pendingDuration == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard deadline.map({ now >= $0 }) ?? true else { return }
        let duration = Self.duration(speed: speed)
        deadline = now + duration; pendingDuration = duration
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { phase = 0 }
    }
    func animateSeededReveal() {
        guard let duration = pendingDuration, phase < 1 else { return }
        pendingDuration = nil; deadline = ProcessInfo.processInfo.systemUptime + duration
        withAnimation(.timingCurve(0.25, 0.35, 0.30, 1, duration: duration)) { phase = 1 }
    }
    func settle() {
        deadline = nil; pendingDuration = nil
        if phase != 1 {
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { phase = 1 }
        }
    }
}

private struct HubFileTypeAvailabilityPhase {
    var value: Double = 1
    var enabled = false
}
private struct HubFileTypeAvailabilityPhaseKey: EnvironmentKey {
    static let defaultValue = HubFileTypeAvailabilityPhase()
}
private extension EnvironmentValues {
    var hubFileTypeAvailabilityPhase: HubFileTypeAvailabilityPhase {
        get { self[HubFileTypeAvailabilityPhaseKey.self] }
        set { self[HubFileTypeAvailabilityPhaseKey.self] = newValue }
    }
}

struct HubFileTypeLabelEffect: AnimatableModifier {
    var phase: Double
    let enabled: Bool
    var animatableData: Double { get { phase } set { phase = newValue } }
    var effectiveOffset: CGFloat { enabled ? 4 * CGFloat(1 - min(1, max(0, phase))) : 0 }
    var effectiveOpacity: Double { enabled ? 0.25 + 0.75 * min(1, max(0, phase)) : 1 }
    func body(content: Content) -> some View { content.opacity(effectiveOpacity).offset(y: effectiveOffset) }
}
struct HubFileTypeAvailabilityLabel: ViewModifier {
    @Environment(\.hubFileTypeAvailabilityPhase) private var phase
    func body(content: Content) -> some View {
        content.modifier(HubFileTypeLabelEffect(phase: phase.value, enabled: phase.enabled))
    }
}

@MainActor struct HubFileTypeAvailabilityRevealModifier: ViewModifier {
    let types: [String]
    let enabled: Bool
    let speed: Double
    @StateObject private var reveal: HubFileTypeAvailabilityReveal
    init(types: [String], enabled: Bool, speed: Double, reveal: HubFileTypeAvailabilityReveal? = nil) {
        self.types = types; self.enabled = enabled; self.speed = speed
        _reveal = StateObject(wrappedValue: reveal ?? HubFileTypeAvailabilityReveal())
    }
    func body(content: Content) -> some View {
        content.environment(\.hubFileTypeAvailabilityPhase, .init(value: reveal.phase, enabled: enabled))
            .animation(nil, value: enabled)
            .onAppear { reveal.observe(types: types, enabled: enabled, speed: speed) }
            .onChange(of: types) { reveal.observe(types: $0, enabled: enabled, speed: speed) }
            .onChange(of: reveal.phase) { if $0 < 1 && enabled { reveal.animateSeededReveal() } }
            .onChange(of: enabled) { if !$0 { reveal.settle() } }
            .onDisappear { reveal.settle() }
    }
}

private struct HubFileTypeShortcutEditor: View {
    let onSave: ([String]) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(shortcuts: [String], onSave: @escaping ([String]) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: HubFileType.editingText(for: shortcuts))
    }

    private var parsed: [String] { HubFileType.parseShortcuts(draft) }
    private var invalidDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("自定义快捷类型")).font(.headline)
            Text(L("用逗号、空格或换行分隔，例如 md, pdf, zip, folder。folder 表示文件夹，none 表示无扩展名。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("按最后一个扩展名匹配，例如 tar.gz 使用 gz。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("当前面板不存在的快捷类型会由其他已有类型补位，不会更改你的设置。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { draft }, set: {
                draft = String(decoding: $0.utf8.prefix(HubFileType.maximumEditorBytes), as: UTF8.self)
            }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6).frame(height: 64)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(L("快捷类型，按显示顺序排列"))
                .accessibilityIdentifier("filedock.type-filter.editor-input")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("预览")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Group {
                        if invalidDraft {
                            Text(L("请输入扩展名，如 md、pdf；无效内容不会保存。"))
                                .foregroundStyle(.red)
                        } else {
                            Text(parsed.isEmpty ? L("仍可通过“…”选择当前面板中的所有类型。") : parsed.map(HubFileType.title(for:)).joined(separator: " · "))
                        }
                    }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 48)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(L("最多保留 12 种快捷类型；留空可隐藏快捷按钮。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("恢复默认类型")) { draft = HubFileType.editingText(for: HubFileType.defaultShortcuts) }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { onSave(parsed); dismiss() }.keyboardShortcut(.defaultAction).disabled(invalidDraft)
            }
        }.padding(16).frame(width: 350)
    }
}
