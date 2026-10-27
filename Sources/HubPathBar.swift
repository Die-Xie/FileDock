import SwiftUI

/// A path is navigation, so each ancestor has its own button and target.
/// The current location stays in view when the path is wider than the toolbar.
@MainActor
struct HubPathBar: View {
    @ObservedObject var model: HubModel
    @State private var hoveredID: String?
    @State private var revealTask: Task<Void, Never>?
    @Environment(\.hubInterfaceMotion) private var motion

    var body: some View {
        let components = model.pathComponents
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        let current = index == components.count - 1
                        Button { model.navigatePathComponent(component) } label: {
                            Text(component.title)
                                .font(.system(size: 11, weight: current ? .medium : .regular))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 6)
                                .foregroundStyle(current ? .primary : .secondary)
                                .background(Color.primary.opacity(hoveredID == component.id && !current ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
                                .animation(motion.feedback, value: hoveredID == component.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(current)
                        .help(component.url?.path ?? component.title)
                        .accessibilityLabel(current ? L("当前位置：\(component.title)") : L("前往\(component.title)"))
                        .onHover { hoveredID = $0 ? component.id : nil }
                        .id(component.id)
                    }
                    if components.isEmpty {
                        Text(L("未选择工作区")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle()).clipped()
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width) { _ in revealCurrent(components, using: proxy) }
            })
            .onAppear { revealCurrent(components, using: proxy) }
            .onChange(of: components) { revealCurrent($0, using: proxy) }
            .onDisappear { revealTask?.cancel() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("当前位置路径"))
    }

    private func revealCurrent(_ components: [HubPathComponent], using proxy: ScrollViewProxy) {
        revealTask?.cancel()
        guard let current = components.last else { return }
        revealTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, model.pathComponents.last?.id == current.id else { return }
            withAnimation(motion.feedback) { proxy.scrollTo(current.id, anchor: .trailing) }
        }
    }
}
