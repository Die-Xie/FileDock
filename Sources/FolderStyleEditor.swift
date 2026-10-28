import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor struct HubFolderStyleEditor: View {
    let entry: FileEntry
    let onApply: (Int, HubFolderIconChange) -> Void
    @Environment(\.dismiss) private var dismiss
    enum IconMode: String, CaseIterable { case existing, system, symbol, emoji, picture }
    @State private var label: HubFinderLabel
    @State private var mode = IconMode.existing
    @State private var symbol = "star.fill"
    @State private var emoji = "📁"
    @State private var picture: Data?
    @State private var rendered: Data?
    @State private var loading = false
    @State private var imageRequest = UUID()
    @State private var message: String?
    @FocusState private var emojiFocused: Bool
    private let symbols = ["star.fill", "heart.fill", "doc.text.fill", "photo.fill", "camera.fill", "music.note", "briefcase.fill", "book.fill", "graduationcap.fill", "hammer.fill", "code", "archivebox.fill"]

    init(entry: FileEntry, initialMode: IconMode = .existing, onApply: @escaping (Int, HubFolderIconChange) -> Void) {
        self.entry = entry; self.onApply = onApply
        _label = State(initialValue: HubFinderLabel(rawValue: entry.labelNumber) ?? .none)
        _mode = State(initialValue: initialMode)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Group {
                    if let rendered, let image = NSImage(data: rendered) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(nsImage: entry.icon).resizable().scaledToFit() }
                }.frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("自定义文件夹")).font(.title2.bold())
                    Text(entry.name).lineLimit(2).foregroundStyle(.secondary)
                        .help(entry.url.lastPathComponent)
                    Text(L("更改会同步到访达及其他应用。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(L("颜色标签")).font(.headline)
            HStack(spacing: 13) {
                colorButton(.none)
                ForEach(HubFinderLabel.colors) { colorButton($0) }
            }
            Picker(L("图标"), selection: $mode) {
                Text(L("保留当前图标")).tag(IconMode.existing)
                Text(L("系统图标")).tag(IconMode.system)
                Text(L("图案")).tag(IconMode.symbol)
                Text(L("表情")).tag(IconMode.emoji)
                Text(L("图片")).tag(IconMode.picture)
            }.pickerStyle(.menu)
            Group {
                switch mode {
                case .existing:
                    Text(L("仅更改颜色标签，保留已有自定义图标。macOS 26 可将标签颜色用于文件夹外观。")).font(.callout).foregroundStyle(.secondary)
                case .system:
                    Text(L("移除图片图标，恢复访达提供的文件夹图标。")).font(.callout).foregroundStyle(.secondary)
                case .symbol:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(symbols, id: \.self) { value in
                            Button { symbol = value } label: {
                                Image(systemName: value).font(.system(size: 18)).frame(maxWidth: .infinity).frame(height: 32)
                                    .background(symbol == value ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel(value).accessibilityAddTraits(symbol == value ? .isSelected : [])
                        }
                    }
                case .emoji:
                    HStack {
                        TextField(L("输入一个表情"), text: $emoji).textFieldStyle(.roundedBorder).frame(width: 100).focused($emojiFocused)
                        Button(L("表情与符号…")) {
                            emojiFocused = true
                            DispatchQueue.main.async {
                                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                                NSApp.orderFrontCharacterPalette(nil)
                            }
                        }
                    }
                case .picture:
                    HStack {
                        Button(L("选择图片…"), action: chooseImage).disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                        Text(picture == nil ? L("支持常见图片格式，最大 16 MiB。") : L("图片已准备好")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 72, alignment: .topLeading)
            if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(3) }
            Divider()
            HStack {
                Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("应用")) { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(loading || (mode == .picture && picture == nil) || ((mode == .symbol || mode == .emoji || mode == .picture) && rendered == nil))
            }
        }.padding(24).frame(width: 500).background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: updatePreview)
            .onChange(of: label) { _ in updatePreview() }
            .onChange(of: mode) { value in
                if value != .picture { imageRequest = UUID(); loading = false; message = nil }
                updatePreview()
            }
            .onChange(of: symbol) { _ in updatePreview() }
            .onChange(of: emoji) { value in
                if value.count > 1 { emoji = String(value.suffix(1)) }
                updatePreview()
            }
            .onChange(of: picture) { _ in updatePreview() }
            .onDisappear { imageRequest = UUID() }
    }
    private func colorButton(_ value: HubFinderLabel) -> some View {
        Button { label = value } label: {
            ZStack {
                Circle().fill(value == .none ? Color.secondary.opacity(0.15) : Color(nsColor: value.color))
                if value == .none { Image(systemName: "slash").font(.system(size: 13)).foregroundStyle(.secondary) }
                if label == value { Circle().strokeBorder(Color.primary.opacity(0.8), lineWidth: 2).padding(-4) }
            }.frame(width: 25, height: 25).padding(4)
        }.buttonStyle(.plain).help(value.name).accessibilityLabel(value.name).accessibilityAddTraits(label == value ? .isSelected : [])
    }
    private func updatePreview() {
        switch mode {
        case .existing:
            if #available(macOS 26, *), !entry.folderAppearance.customIcon, label.rawValue != entry.labelNumber {
                rendered = HubFolderArtwork.render(label: label)
            } else { rendered = nil }
        case .system:
            if #available(macOS 26, *) { rendered = HubFolderArtwork.render(label: label) }
            else { rendered = HubFolderArtwork.render(label: .none) }
        case .symbol: rendered = HubFolderArtwork.render(label: label, symbol: symbol)
        case .emoji: rendered = HubFolderArtwork.render(label: label, emoji: emoji)
        case .picture: rendered = picture.flatMap { HubFolderArtwork.render(label: label, picture: $0) }
        }
    }
    private func apply() {
        let change: HubFolderIconChange
        switch mode {
        case .existing: change = .unchanged
        case .system: change = .system
        case .symbol, .emoji, .picture:
            guard let rendered else { return }
            change = .artwork(rendered)
        }
        onApply(label.rawValue, change); dismiss()
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        let id = UUID(); imageRequest = id; loading = true; message = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Result { try HubFolderArtwork.readImage(url) } }.value
            guard imageRequest == id else { return }
            loading = false
            switch result {
            case .success(let data): picture = data
            case .failure(let error): message = error.localizedDescription
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard imageRequest == id, loading else { return }
            imageRequest = UUID(); loading = false; message = L("读取图片超时，请检查图片位置后重试。")
        }
    }
}
