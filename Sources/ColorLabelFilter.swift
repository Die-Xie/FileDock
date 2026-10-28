import SwiftUI

/// Uses the already loaded Finder label numbers. Rendering and selection never
/// read file metadata, refresh a directory, or write a file's tags.
struct HubColorLabelFilterBar: View {
    let selection: HubFinderLabel?
    let onSelect: (HubFinderLabel?) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                Button { onSelect(nil) } label: {
                    Text(L("全部")).font(.system(size: 10))
                        .frame(minWidth: 30, minHeight: 22)
                        .background(selection == nil ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(L("显示全部颜色标签"))
                    .accessibilityIdentifier("filedock.color-filter.all")
                ForEach(HubFinderLabel.colors + [.none]) { label in
                    Button { onSelect(selection == label ? nil : label) } label: {
                        ZStack {
                            if label == .none {
                                Circle().strokeBorder(Color.secondary, lineWidth: 1.2)
                                Image(systemName: "line.diagonal").font(.system(size: 9)).foregroundStyle(.secondary)
                            } else {
                                Circle().fill(Color(nsColor: label.color))
                            }
                            if selection == label {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(label == .none ? Color.primary : .white)
                            }
                        }.frame(width: 13, height: 13).frame(width: 22, height: 22)
                            .background(selection == label ? Color.primary.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L("筛选：\(label.name)"))
                        .accessibilityAddTraits(selection == label ? .isSelected : [])
                        .accessibilityIdentifier("filedock.color-filter.\(label.rawValue)")
                        .help(L("筛选：\(label.name)"))
                }
            }.fixedSize()
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
    }
}
