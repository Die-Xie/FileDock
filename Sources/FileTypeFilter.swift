import SwiftUI

private enum HubFileTypePlateTarget: Hashable {
    case all, type(String), clear, more
}
private struct HubFileTypePlateKey: PreferenceKey {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("文件类型筛选"))
        .sheet(isPresented: $showsEditor) {
            HubFileTypeShortcutEditor(shortcuts: shortcuts, onSave: onUpdateShortcuts)
        }
    }

    private func selectionPlate(anchors: [HubFileTypePlateTarget: Anchor<CGRect>], target: HubFileTypePlateTarget) -> some View {
        GeometryReader { geometry in
            HubSelectionPlate(selectionFrame: anchors[target].map { geometry[$0] }, cornerRadius: 5,
                motion: HubInterfaceMotion(enabled: motion.enabled && !reduceMotion && isEnabled, speed: motion.speed))
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                .allowsHitTesting(false))
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
