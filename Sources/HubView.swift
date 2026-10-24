import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Screen-derived layout is transient; it must not leak into saved preferences.
@MainActor
final class HubPresentationState: ObservableObject {
    struct Header: Equatable {
        var embedded = false
        var exclusionWidth: CGFloat = 0
        var topInset: CGFloat = 0
        var split = false
        var menuBarMayOverlap = false
    }
    @Published var header = Header()
    @Published var previewVisible = true
}

private struct HubMenuButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var action: () -> Void
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) { self.title = title; self.systemImage = systemImage; self.role = role; self.action = action }
    var body: some View { Button(role: role, action: action) { Label(title, systemImage: systemImage) } }
}

private struct HubWorkspaceControlsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor
struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var presentation: HubPresentationState
    let music: HubQQMusicController
    @Environment(\.colorScheme) private var colorScheme
    var onSettings: () -> Void
    var onClose: () -> Void
    @State private var editingWorkspace: Workspace?
    @State private var newFolder = false
    @State private var folderName = "新建文件夹"
    @State private var pendingTrash: [URL] = []
    @State private var dropTargeted = false
    @State private var stagingDropTargeted = false
    @State private var fileDropTarget: URL?
    @State private var hoveredWorkspace: UUID?
    @State private var hoverTask: DispatchWorkItem?
    @StateObject private var workspaceSpringLoader = HubWorkspaceSpringLoader()
    @State private var workspaceRevealPointer: NSPoint?
    @State private var workspaceControlsWidth: CGFloat = 0
    @State private var musicControlsFocused = false
    @State private var renameEntry: FileEntry?
    @State private var renameName = ""

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
            Divider().opacity(0.55)
            browserBar
            Divider().opacity(0.45)
            if model.directoryLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取文件信息，可切换工作区…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 7)
            }
            if let message = model.directoryLoadMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重试") { model.retryDirectoryLoad() }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.isStagingRoot { stagingActions }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted && !model.isRecentsRoot ? Color.accentColor : .clear, lineWidth: 2).padding(4))
                .onDrop(of: [hubFileDragType, .fileURL, .image, .url, .item], isTargeted: $dropTargeted) { receiveDrop($0, destination: model.currentURL) }
            Divider().opacity(0.45)
            if embeddedMusicLayout.placement == .bottom {
                HubQQMusicBar(controller: music)
                Divider().opacity(0.45)
            }
            footer
        }
        .font(.system(size: model.settings.fontSize))
        .background(backgroundColor)
        .background(HubKeyMonitor(handler: handleKey))
        .onReceive(NotificationCenter.default.publisher(for: hubFileDragDidEnd)) { _ in
            workspaceSpringLoader.cancel()
            fileDropTarget = nil
            dropTargeted = false
            stagingDropTargeted = false
        }
        .onReceive(NotificationCenter.default.publisher(for: hubWorkspaceDragDidEnd)) { _ in
            workspaceSpringLoader.cancel()
            hoverTask?.cancel()
            hoveredWorkspace = nil
            workspaceRevealPointer = NSEvent.mouseLocation
        }
        .onChange(of: presentation.previewVisible) { if !$0 { workspaceSpringLoader.cancel() } }
        .onDisappear { workspaceSpringLoader.cancel(); hoverTask?.cancel() }
        .onChange(of: model.search) { _ in model.selectedIDs = [] }
        .sheet(item: $editingWorkspace) { WorkspaceEditor(model: model, workspace: $0) }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("名称", text: $folderName)
            Button("取消", role: .cancel) { }
            Button("创建") { model.createFolder(named: folderName) }
        }
        .alert("重新命名", isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
            TextField("名称", text: $renameName)
            Button("取消", role: .cancel) { renameEntry = nil }
            Button("保存") { if let entry = renameEntry { model.rename(entry, to: renameName) }; renameEntry = nil }
        }
        .alert("移到废纸篓？", isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("取消", role: .cancel) { pendingTrash = [] }
            Button("移到废纸篓", role: .destructive) { let urls = pendingTrash; pendingTrash = []; model.trash(urls) }
        } message: { Text("将 \(pendingTrash.count) 个项目移到系统废纸篓。可以在访达中恢复。") }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var embeddedMusicLayout: HubEmbeddedMusicLayout {
        HubEmbeddedMusicLayout.make(enabled: model.settings.resolvedQQMusicEnabled,
                                    embedded: presentation.header.embedded, split: presentation.header.split,
                                    exclusionWidth: presentation.header.exclusionWidth,
                                    topInset: presentation.header.topInset, fontSize: model.settings.fontSize)
    }

    private var compactMusicBar: some View {
        HubQQMusicBar(controller: music, compact: true,
                      compactWidth: embeddedMusicLayout.displayWidth, isPresented: presentation.previewVisible,
                      onControlFocusChange: { musicControlsFocused = $0 })
    }

    private var toolbarTopInset: CGFloat {
        HubWorkspaceHeaderLayout.toolbarTopInset(embedded: presentation.header.embedded,
            split: presentation.header.split, safeTop: presentation.header.topInset,
            menuBarMayOverlap: presentation.header.menuBarMayOverlap)
    }

    @ViewBuilder private var workspaceBar: some View {
        VStack(spacing: 0) {
            workspaceHeader
            if embeddedMusicLayout.placement == .headerRow {
                compactMusicBar
                    .frame(maxWidth: .infinity)
                    .frame(height: HubEmbeddedMusicLayout.rowHeight)
            }
        }
    }

    @ViewBuilder private var workspaceHeader: some View {
        if presentation.header.embedded && presentation.header.split {
            GeometryReader { geometry in
                let sideWidth = max(0, (geometry.size.width - presentation.header.exclusionWidth - 24) / 2)
                let layout = HubWorkspaceHeaderLayout.make(tabWidths: model.tabWorkspaces.map(workspaceTabWidth),
                                                           sideWidth: sideWidth,
                                                           measuredControlsWidth: workspaceControlsWidth)
                let leftWorkspaces = Array(model.tabWorkspaces.prefix(layout.splitIndex))
                let rightWorkspaces = Array(model.tabWorkspaces.dropFirst(layout.splitIndex))
                HStack(spacing: 0) {
                    workspaceLeading(leftWorkspaces, availableWidth: sideWidth)
                        .padding(.top, toolbarTopInset)
                        .frame(width: sideWidth, alignment: .leading).clipped()
                    VStack(spacing: 0) {
                        if embeddedMusicLayout.placement == .notch {
                            Color.clear.frame(height: embeddedMusicLayout.controlTop)
                                .allowsHitTesting(false).accessibilityHidden(true)
                            compactMusicBar
                            Spacer(minLength: 4)
                        } else {
                            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }.frame(width: presentation.header.exclusionWidth, height: geometry.size.height)
                    HStack(spacing: 0) {
                        if !rightWorkspaces.isEmpty {
                            workspaceLeading(rightWorkspaces, availableWidth: layout.rightViewportWidth)
                                .frame(width: layout.rightViewportWidth, alignment: .leading).clipped()
                        }
                        HubWindowDragHandle().frame(width: layout.dragWidth, height: 30).help("拖动窗口")
                        HStack(spacing: 8) { workspaceControls }
                            .fixedSize()
                            .background(GeometryReader { controlsGeometry in
                                Color.clear.preference(key: HubWorkspaceControlsWidthKey.self,
                                                       value: controlsGeometry.size.width)
                            })
                            .frame(width: layout.controlsWidth, alignment: .trailing)
                            .contentShape(Rectangle()).clipped()
                    }.padding(.top, toolbarTopInset).frame(width: sideWidth).clipped()
                }.padding(.horizontal, 12).frame(height: geometry.size.height)
                    .onPreferenceChange(HubWorkspaceControlsWidthKey.self) { width in
                        if width.isFinite && width > 0 && abs(width - workspaceControlsWidth) > 0.5 {
                            workspaceControlsWidth = width
                        }
                    }
            }.frame(height: embeddedMusicLayout.headerHeight + toolbarTopInset)
        } else {
            HStack(spacing: 8) {
                workspaceLeading(model.tabWorkspaces)
                HubWindowDragHandle().frame(minWidth: 32, maxWidth: .infinity, minHeight: 30, maxHeight: 30).help("拖动窗口")
                workspaceControls
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .padding(.top, presentation.header.embedded ? presentation.header.topInset : 0)
        }
    }

    private func workspaceLeading(_ workspaces: [Workspace], availableWidth: CGFloat? = nil) -> some View {
        let tabWidthLimit = availableWidth.map { max(48, $0) }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(workspaces) { workspace in
                        workspaceTab(workspace, maximumWidth: tabWidthLimit).id(workspace.id)
                    }
                }.padding(.vertical, 3)
            }
            .contentShape(Rectangle()).clipped()
            .onHover { if !$0 { workspaceRevealPointer = nil } }
            .onAppear { revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: model.selectedWorkspaceID) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: workspaces.map(\.id)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: workspaces.map(\.name)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: workspaces.map(\.iconOnly)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: model.settings.fontSize) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: availableWidth) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
        }.frame(maxWidth: min(workspaceTabsWidth(workspaces), tabWidthLimit ?? workspaceTabsWidth(workspaces))).layoutPriority(1)
    }

    private func revealSelectedWorkspace(in workspaces: [Workspace], using proxy: ScrollViewProxy) {
        hoverTask?.cancel()
        hoveredWorkspace = nil
        guard let id = model.selectedWorkspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        // Position after SwiftUI has laid out new/renamed tabs. Use minimal
        // scrolling so a tab already under the pointer stays in place.
        DispatchQueue.main.async {
            guard model.selectedWorkspaceID == id else { return }
            workspaceRevealPointer = NSEvent.mouseLocation
            proxy.scrollTo(id)
        }
    }

    @State private var stagingHoverID = UUID()
    private func shortcutHover(_ entered: Bool, key: UUID, action: @escaping () -> Void) {
        guard entered else {
            if hoveredWorkspace == key { hoverTask?.cancel(); hoveredWorkspace = nil }
            return
        }
        hoverTask?.cancel()
        guard !HubWorkspaceDragState.isDragging, !HubFileDragState.isDragging, model.settings.switchDelay > 0 else { return }
        hoveredWorkspace = key
        let task = DispatchWorkItem {
            guard hoveredWorkspace == key, !HubWorkspaceDragState.isDragging, !HubFileDragState.isDragging else { return }
            action()
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.switchDelay, execute: task)
    }

    @ViewBuilder private var workspaceControls: some View {
        if let favorite = model.fixedFavoriteWorkspace {
            Button { model.selectWorkspace(favorite.id) } label: {
                HubWorkspaceShortcutLabel(symbol: model.selectedWorkspaceID == favorite.id ? "star.fill" : "star",
                                          selected: model.selectedWorkspaceID == favorite.id,
                                          targeted: workspaceSpringLoader.target == favorite.id)
            }.buttonStyle(.plain)
                .accessibilityLabel("收藏：\(favorite.name)")
                .help("\(favorite.name) · 右键可隐藏快捷入口")
                .onHover { shortcutHover($0, key: favorite.id, action: { model.selectWorkspace(favorite.id) }) }
                .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: workspaceFileDrop(favorite))
                .contextMenu {
                    HubMenuButton("编辑收藏…", systemImage: "pencil") { editingWorkspace = favorite }
                    HubMenuButton("隐藏收藏快捷入口", systemImage: "eye.slash") { model.setFavoriteShortcutVisible(false) }
                }
        }
        if model.settings.resolvedStagingEnabled {
            Button { model.openStagingWorkspace() } label: {
                HubWorkspaceShortcutLabel(symbol: model.stagedURLs.isEmpty ? "tray" : "tray.full.fill",
                                          count: model.stagedURLs.count, selected: model.isStagingWorkspace,
                                          targeted: stagingDropTargeted)
            }.buttonStyle(.plain)
                .accessibilityLabel("暂存区，\(model.stagedURLs.count) 个项目")
                .help("暂存区 · 拖入文件暂存引用，点击查看，右键快速转移")
                .onHover { shortcutHover($0, key: model.settings.stagingWorkspaceID ?? stagingHoverID, action: { model.openStagingWorkspace() }) }
                .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: HubWorkspaceFileDropDelegate(
                    id: model.settings.stagingWorkspaceID ?? stagingHoverID, loader: workspaceSpringLoader,
                    delay: model.settings.switchDelay,
                    canActivate: { presentation.previewVisible && model.settings.resolvedStagingEnabled && !HubWorkspaceDragState.isDragging },
                    activate: { if !model.isStagingWorkspace { model.openStagingWorkspace() } },
                    targeted: { stagingDropTargeted = $0 }, receive: receiveStagingDrop))
                .contextMenu {
                    HubMenuButton("打开暂存区", systemImage: "tray") { model.openStagingWorkspace() }
                    if model.currentURL != nil {
                        HubMenuButton("复制全部到当前文件夹", systemImage: "doc.on.doc") { model.transferStagingToCurrentFolder(copy: true) }
                            .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                        HubMenuButton("移动全部到当前文件夹", systemImage: "folder") { model.transferStagingToCurrentFolder(copy: false) }
                            .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                    }
                    HubMenuButton("复制全部到…", systemImage: "doc.on.doc") { model.chooseStagingTransfer(copy: true, urls: model.stagedURLs) }
                        .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                    HubMenuButton("移动全部到…", systemImage: "folder") { model.chooseStagingTransfer(copy: false, urls: model.stagedURLs) }
                        .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                    Divider()
                    HubMenuButton("清空暂存引用", systemImage: "minus.circle") { model.clearStagedFiles() }
                        .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                    HubMenuButton("关闭暂存区", systemImage: "eye.slash") { model.setStagingEnabled(false) }
                }
        }
        Menu {
            HubMenuButton("最近使用", systemImage: "clock") { model.addRecentWorkspace() }
            Divider()
            Toggle("固定收藏到右上角", isOn: Binding(
                get: { model.fixedFavoriteWorkspace != nil },
                set: { model.setFavoriteShortcutVisible($0) }))
            Toggle("显示文件暂存区", isOn: Binding(
                get: { model.settings.resolvedStagingEnabled },
                set: { model.setStagingEnabled($0) }))
            Divider()
            HubMenuButton("文件夹工作区…", systemImage: "folder.badge.plus") { model.chooseWorkspace(mode: .folder) }
            HubMenuButton("文件与文件夹合集…", systemImage: "square.stack.3d.up") { model.chooseWorkspace(mode: .references) }
        } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 27) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("添加工作区").help("添加工作区")
        Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24) }.buttonStyle(.plain).foregroundStyle(.secondary).help("收起 (Esc)")
    }

    private var stagingActions: some View {
        HStack(spacing: 10) {
            if model.stagingTransferInProgress {
                ProgressView().controlSize(.small)
                Text("正在转移文件…").foregroundStyle(.secondary)
            } else {
                Text("仅保存引用 · 清空暂存不会删除原文件").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(model.selectedURLs.isEmpty ? "复制全部到…" : "复制所选到…") { model.chooseStagingTransfer(copy: true) }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
            Button(model.selectedURLs.isEmpty ? "移动全部到…" : "移动所选到…") { model.chooseStagingTransfer(copy: false) }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
            Button { model.clearStagedFiles() } label: { Image(systemName: "minus.circle") }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                .help("清空暂存引用，保留原文件").accessibilityLabel("清空暂存引用")
        }.padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func workspaceTabWidth(_ workspace: Workspace) -> CGFloat {
        let font = NSFont.systemFont(ofSize: model.settings.fontSize)
        return 40 + (workspace.iconOnly == true || workspace.name.isEmpty ? 0 : 6 + (workspace.name as NSString).size(withAttributes: [.font: font]).width)
    }

    private func workspaceTabsWidth(_ workspaces: [Workspace]) -> CGFloat {
        workspaces.reduce(CGFloat(0)) { $0 + workspaceTabWidth($1) }
            + CGFloat(max(0, workspaces.count - 1)) * HubWorkspaceHeaderLayout.tabSpacing
    }

    private var fileDragContext: HubFileDragContext {
        HubFileDragContext(workspaceID: model.selectedWorkspaceID, directory: model.currentURL)
    }

    private func workspaceTab(_ workspace: Workspace, maximumWidth: CGFloat? = nil) -> some View {
        Button { model.selectWorkspace(workspace.id) } label: {
            HStack(spacing: 6) {
                workspaceIcon(workspace).frame(width: 16, height: 16)
                if workspace.iconOnly != true && !workspace.name.isEmpty { Text(workspace.name).lineLimit(1).truncationMode(.tail) }
            }
            .frame(maxWidth: maximumWidth.map { max(24, $0 - 24) }, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(model.selectedWorkspaceID == workspace.id ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name.isEmpty ? workspace.mode.title : workspace.name)
        .help(workspace.name + "\n" + (workspace.mode == .recents ? "自动更新最近使用的文件" : workspace.rootPath ?? "文件与文件夹合集"))
        .onHover { isOver in
            guard !HubWorkspaceDragState.isDragging, !HubFileDragState.isDragging else {
                hoverTask?.cancel()
                hoveredWorkspace = nil
                return
            }
            if !isOver {
                if hoveredWorkspace == workspace.id { hoverTask?.cancel(); hoveredWorkspace = nil }
                return
            }
            if let origin = workspaceRevealPointer {
                let pointer = NSEvent.mouseLocation
                // Ignore tracking updates caused by scrolling beneath a still
                // pointer; moving to another tab re-enables hover switching.
                if abs(pointer.x - origin.x) < 2 && abs(pointer.y - origin.y) < 2 { return }
                workspaceRevealPointer = nil
            }
            hoverTask?.cancel()
            hoveredWorkspace = workspace.id
            if model.settings.switchDelay > 0 {
                let task = DispatchWorkItem { if hoveredWorkspace == workspace.id && !HubWorkspaceDragState.isDragging && !HubFileDragState.isDragging { model.selectWorkspace(workspace.id) } }
                hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.switchDelay, execute: task)
            }
        }
        .contextMenu {
            HubMenuButton("编辑工作区…", systemImage: "pencil") { editingWorkspace = workspace }
            Toggle("仅显示图标", isOn: Binding(
                get: { model.workspaces.first(where: { $0.id == workspace.id })?.iconOnly == true },
                set: { model.setWorkspaceIconOnly(id: workspace.id, enabled: $0) }))
            if let index = model.tabWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
                HubMenuButton("向左移动", systemImage: "arrow.left") {
                    let tabs = model.tabWorkspaces
                    if let current = tabs.firstIndex(where: { $0.id == workspace.id }), current > 0 {
                        model.reorderWorkspace(workspace.id, relativeTo: tabs[current - 1].id, after: false)
                    }
                }.disabled(index == 0)
                HubMenuButton("向右移动", systemImage: "arrow.right") {
                    let tabs = model.tabWorkspaces
                    if let current = tabs.firstIndex(where: { $0.id == workspace.id }), current + 1 < tabs.count {
                        model.reorderWorkspace(workspace.id, relativeTo: tabs[current + 1].id, after: true)
                    }
                }.disabled(index == model.tabWorkspaces.count - 1)
            }
            Divider()
            HubMenuButton("移除工作区", systemImage: "minus.circle") { model.removeWorkspace(workspace.id) }
        }
        .overlay(HubWorkspaceDragBridge(
            workspaceID: workspace.id,
            title: workspace.name.isEmpty ? "工作区" : workspace.name,
            onSelect: { model.selectWorkspace(workspace.id) },
            onReorder: { source, target, after in model.reorderWorkspace(source, relativeTo: target, after: after) },
            onDragStateChanged: { _ in
                workspaceSpringLoader.cancel()
                hoverTask?.cancel()
                hoveredWorkspace = nil
                workspaceRevealPointer = NSEvent.mouseLocation
            }
        ))
        .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: workspaceFileDrop(workspace))
    }

    private func workspaceFileDrop(_ workspace: Workspace) -> HubWorkspaceFileDropDelegate {
        HubWorkspaceFileDropDelegate(
            id: workspace.id, loader: workspaceSpringLoader, delay: model.settings.switchDelay,
            canActivate: { presentation.previewVisible && !HubWorkspaceDragState.isDragging && model.workspaces.contains(where: { $0.id == workspace.id }) },
            activate: { if model.selectedWorkspaceID != workspace.id { model.selectWorkspace(workspace.id) } },
            acceptsDrop: workspace.mode != .recents,
            movesFiles: workspace.mode == .folder,
            receive: { providers in
                guard workspace.mode != .recents else { return false }
                // Releasing on a tab targets its root, never a stale directory
                // retained by the workspace that was visible before the dwell.
                model.selectWorkspace(workspace.id)
                return receiveDrop(providers, destination: workspace.rootURL, reorderLocal: false)
            })
    }

    @ViewBuilder private func workspaceIcon(_ workspace: Workspace) -> some View {
        if let path = workspace.customIconPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit() }
        else { Image(systemName: workspace.symbol.isEmpty ? "folder" : workspace.symbol).foregroundStyle(model.selectedWorkspaceID == workspace.id ? Color.accentColor : Color.secondary) }
    }

    private var browserBar: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", "后退", disabled: !model.canGoBack) { model.goBack() }
            iconButton("chevron.right", "前进", disabled: !model.canGoForward) { model.goForward() }
            HubPathBar(model: model)
                .frame(minWidth: 40, maxWidth: .infinity)
                .layoutPriority(1)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.isRecentsRoot ? "搜索最近使用" : "搜索当前文件夹", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 8).padding(.vertical, 6).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).frame(minWidth: 100, maxWidth: 210).layoutPriority(2)
            HStack(spacing: 1) {
                viewButton(.grid, symbol: "square.grid.2x2", label: "图标视图")
                viewButton(.list, symbol: "list.bullet", label: "列表视图")
                viewButton(.columns, symbol: "rectangle.split.3x1", label: "分栏视图")
            }.padding(2).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Menu {
                Picker("排序方式", selection: $model.sortKey) {
                    Text("名称").tag(SortKey.name); Text("种类").tag(SortKey.kind); Text("大小").tag(SortKey.size)
                    Text("修改日期").tag(SortKey.modified); Text("创建日期").tag(SortKey.created); Text("添加日期").tag(SortKey.added)
                }
                Divider()
                Toggle("升序", isOn: $model.ascending)
                Toggle("按手动顺序显示", isOn: Binding(get: { model.isManualEntryOrder }, set: { model.setManualEntryOrder($0) }))
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(model.isRecentsRoot ? "按最近使用时间排序" : "排序")
                .help(model.isRecentsRoot ? "最近使用按最近打开时间排列，最新的在前" : "排序")
                .disabled(model.isRecentsRoot)
        }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if model.selectedWorkspace == nil {
            VStack(spacing: 15) {
                Image(systemName: "folder.badge.plus").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                Text("把常用文件放到触手可及的地方").font(.system(size: 16, weight: .medium))
                Text("添加文件夹，或创建只保存文件引用的合集。").foregroundStyle(.secondary)
                HStack { Button("添加文件夹…") { model.chooseWorkspace(mode: .folder) }; Button("创建合集…") { model.chooseWorkspace(mode: .references) } }
                Text("可通过触发位置、菜单栏或自定义快捷键呼出").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.search.isEmpty ? model.isRecentsRoot ? "clock" : "tray" : "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                Text(emptyTitle).font(.system(size: 14, weight: .medium))
                Text(emptyDetail).foregroundStyle(.secondary)
                if model.search.isEmpty && model.selectedWorkspace?.mode == .references && model.currentURL == nil { Button("添加项目…") { model.addReferences() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu { backgroundMenu }
        } else {
            Group {
                switch model.viewMode {
                case .grid: grid
                case .list: list
                case .columns: columns
                }
            }.contextMenu { backgroundMenu }
        }
    }

    private var emptyTitle: String {
        if model.directoryLoading { return "正在读取文件信息…" }
        if model.directoryLoadMessage != nil { return "暂时无法读取内容" }
        if !model.search.isEmpty { return "没有匹配的项目" }
        if model.isRecentsRoot { return model.recentFilesLoading ? "正在读取最近使用…" : "暂无最近使用的文件" }
        return "这里还没有项目"
    }

    private var emptyDetail: String {
        if model.directoryLoading { return "文件读取在后台进行，你可以随时切换工作区。" }
        if model.directoryLoadMessage != nil { return "请稍后重试，或通过上方标签切换到其他工作区。" }
        if !model.search.isEmpty { return "试试其他名称" }
        if model.isRecentsRoot { return model.recentFilesMessage ?? "最近打开的文件会自动出现在这里。结果取决于系统索引。" }
        return model.isReferenceRoot ? "拖入文件或文件夹以添加引用" : "拖入文件以移动，按住 ⌥ 键以复制"
    }

    private var grid: some View {
        ScrollView(model.settings.horizontalScroll ? .horizontal : .vertical, showsIndicators: model.settings.showScrollbar) {
            if model.settings.horizontalScroll {
                LazyHGrid(rows: [GridItem(.adaptive(minimum: model.settings.iconSize + 46), spacing: 8)], alignment: .top, spacing: 8) {
                    ForEach(model.visibleEntries) { entry in gridCell(entry).frame(width: model.settings.iconSize + 52) }
                }.padding(14)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.settings.iconSize + 52), spacing: 10)], alignment: .leading, spacing: 12) {
                    ForEach(model.visibleEntries) { entry in gridCell(entry) }
                }.padding(14)
            }
        }
        .marqueeFileSelection(context: fileDragContext, selection: model.selectedIDs) { model.selectedIDs = $0 }
    }

    private func gridCell(_ entry: FileEntry) -> some View {
        VStack(spacing: 7) {
            HubFileIcon(entry: entry, size: model.settings.iconSize, allowsThumbnail: !model.isCloudPlaceholder(entry)).opacity(entry.exists ? 1 : 0.4)
            Text(entry.name).font(.system(size: model.settings.fontSize)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 29, alignment: .top)
        }
        .padding(.horizontal, 5).padding(.vertical, 9)
        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .help(entry.url.path)
        .contextMenu { fileMenu(entry) }
        .overlay(fileInteraction(for: entry))
        .overlay(dropIndicator(for: entry, beforeOnTop: model.settings.horizontalScroll))
        .onDrop(of: [hubFileDragType, .fileURL, .image, .url], isTargeted: dropBinding(for: entry.url)) { receiveItemDrop($0, entry: entry) }
        .fileSelectionBounds(entry.url)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text(model.isRecentsRoot ? "最近使用" : "修改日期").frame(width: 120, alignment: .leading)
                Text("种类").frame(width: 80, alignment: .leading)
                Text("大小").frame(width: 66, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 7).background(Color.primary.opacity(0.025))
            ScrollView(.vertical, showsIndicators: model.settings.showScrollbar) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 9) {
                            Image(nsImage: entry.icon).resizable().scaledToFit().frame(width: 22, height: 22)
                            Text(entry.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text((model.isRecentsRoot ? model.lastUsedDate(for: entry.url) : entry.modified)?.formatted(date: .abbreviated, time: .shortened) ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            Text(model.isCloudPlaceholder(entry) ? "仅在云端" : entry.kind).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(width: 80, alignment: .leading)
                            Text(entry.isDirectory || model.isCloudPlaceholder(entry) ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.025), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .contextMenu { fileMenu(entry) }.help(entry.url.path)
                        .overlay(fileInteraction(for: entry))
                        .overlay(dropIndicator(for: entry, beforeOnTop: true))
                        .onDrop(of: [hubFileDragType, .fileURL, .image, .url], isTargeted: dropBinding(for: entry.url)) { receiveItemDrop($0, entry: entry) }
                        .fileSelectionBounds(entry.url)
                    }
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }
            .marqueeFileSelection(context: fileDragContext, selection: model.selectedIDs) { model.selectedIDs = $0 }
        }
    }

    private var columns: some View {
        GeometryReader { geometry in
            let hasParent = model.currentURL.map { $0.path != "/" } ?? false
            let layout = HubColumnsLayout.make(availableWidth: geometry.size.width, hasParent: hasParent)
            ScrollView(.horizontal, showsIndicators: model.settings.showScrollbar) {
                HStack(spacing: 0) {
                    if let current = model.currentURL, current.path != "/" {
                        let parent = current.deletingLastPathComponent()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(parent.lastPathComponent.isEmpty ? "Macintosh HD" : parent.lastPathComponent).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(10)
                            Divider()
                            ScrollView(showsIndicators: model.settings.showScrollbar) {
                                LazyVStack(spacing: 1) {
                                    ForEach(parentDirectories(parent), id: \.self) { url in
                                        Button { model.navigate(to: url) } label: {
                                            HStack(spacing: 7) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18); Text(url.lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.system(size: 8)) }.padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
                                                .background(url == current ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(5)
                            }
                        }.frame(width: layout.parentWidth)
                        Divider().frame(width: layout.separatorWidth)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.currentURL?.lastPathComponent ?? model.selectedWorkspace?.name ?? "项目").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(10)
                        Divider()
                        ScrollView(showsIndicators: model.settings.showScrollbar) {
                            LazyVStack(spacing: 1) {
                                ForEach(model.visibleEntries) { entry in
                                    HStack(spacing: 7) {
                                        Image(nsImage: entry.icon).resizable().frame(width: 20, height: 20)
                                        Text(entry.name).lineLimit(1)
                                        Spacer()
                                        if entry.isDirectory && !entry.isPackage { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 9).padding(.vertical, 6)
                                        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                                        .contextMenu { fileMenu(entry) }
                                        .overlay(fileInteraction(for: entry, navigateOnClick: true))
                                        .overlay(dropIndicator(for: entry, beforeOnTop: true))
                                        .onDrop(of: [hubFileDragType, .fileURL, .image, .url], isTargeted: dropBinding(for: entry.url)) { receiveItemDrop($0, entry: entry) }
                                        .fileSelectionBounds(entry.url)
                                }
                            }.padding(5)
                        }
                        .marqueeFileSelection(context: fileDragContext, selection: model.selectedIDs) { model.selectedIDs = $0 }
                    }.frame(width: layout.directoryWidth)
                    Divider().frame(width: layout.separatorWidth)
                    if let entry = model.visibleEntries.first(where: { model.selectedIDs.contains($0.url) }) {
                        inlinePreview(entry).frame(width: layout.previewWidth)
                    } else {
                        VStack(spacing: 9) {
                            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32, weight: .light))
                            Text("选择文件以预览")
                        }.foregroundStyle(.tertiary).frame(width: layout.previewWidth, height: geometry.size.height)
                    }
                }
                .frame(width: layout.totalWidth, height: geometry.size.height)
            }
        }
    }

    private func inlinePreview(_ entry: FileEntry) -> some View {
        let candidate = HubInlinePreviewCandidate(url: entry.url, exists: entry.exists && !model.isCloudPlaceholder(entry),
                                                 isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                                                 size: entry.size, modified: entry.modified)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(model.isCloudPlaceholder(entry) ? "仅在云端" : entry.isDirectory ? entry.kind : "\(entry.kind) · \(entry.sizeText)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { preview([entry.url]) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("在独立窗口快速查看").accessibilityLabel("放大预览").disabled(!entry.exists || model.isCloudPlaceholder(entry))
                Button { model.openExternally(entry.url) } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("在默认应用中打开").accessibilityLabel("打开文件").disabled(!model.canOpen(entry))
            }.padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            switch HubInlinePreviewPolicy.disposition(for: candidate) {
            case .file(let identity):
                HubInlinePreview(item: presentation.previewVisible ? identity : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .directory:
                previewPlaceholder("folder", title: entry.name, detail: "在左侧选择文件以预览内容")
            case .unavailable:
                if model.isCloudPlaceholder(entry) {
                    previewPlaceholder("icloud.and.arrow.down", title: "文件尚未下载", detail: "点击右上角打开文件，由系统下载后查看")
                } else {
                    previewPlaceholder("doc.badge.ellipsis", title: "文件暂时不可用", detail: "文件可能已移动，或当前无法访问")
                }
            case .empty:
                previewPlaceholder("doc.text.magnifyingglass", title: "选择文件以预览", detail: "")
            }
        }
    }

    private func previewPlaceholder(_ symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light))
            Text(title).fontWeight(.medium).lineLimit(2)
            if !detail.isEmpty { Text(detail).font(.system(size: 11)) }
        }.foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            iconButton("arrow.up", "上一级", disabled: !model.canGoUp) { model.goUp() }
            Text(model.currentLocationDescription)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.currentURL?.path ?? (model.isRecentsRoot ? "最近使用不接收文件拖入，原文件保留在原位置" : ""))
            Spacer(minLength: 6)
            Text(model.selectedIDs.isEmpty ? "\(model.visibleEntries.count) 个项目" : "已选 \(model.selectedIDs.count) / \(model.visibleEntries.count)").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            iconButton("arrow.clockwise", "刷新") { model.refresh() }
            Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin").foregroundStyle(model.pinned ? Color.accentColor : Color.secondary).frame(width: 24, height: 23) }.buttonStyle(.plain).help(model.pinned ? "取消固定" : "固定窗口")
            iconButton("gearshape", "设置") { onSettings() }
        }.padding(.horizontal, 13).padding(.vertical, 7)
    }

    @ViewBuilder private var backgroundMenu: some View {
        if model.currentURL != nil { HubMenuButton("新建文件夹…", systemImage: "folder.badge.plus") { folderName = "新建文件夹"; newFolder = true }; HubMenuButton("粘贴文件", systemImage: "doc.on.clipboard") { model.pasteFiles() }; HubMenuButton("在访达中打开", systemImage: "folder") { if let url = model.currentURL { NSWorkspace.shared.open(url) } } }
        if model.selectedWorkspace?.mode == .references && model.currentURL == nil { HubMenuButton("添加项目…", systemImage: "plus") { model.addReferences() } }
        HubMenuButton("刷新", systemImage: "arrow.clockwise") { model.refresh() }
    }

    @ViewBuilder private func fileMenu(_ entry: FileEntry) -> some View {
        let urls = model.selectedIDs.contains(entry.url) && model.selectedIDs.count > 1 ? model.selectedURLs : [entry.url]
        HubMenuButton("打开", systemImage: "arrow.up.forward.square") { if urls.count == 1 { model.open(entry) } else { urls.forEach { NSWorkspace.shared.open($0) } } }
        if !entry.isDirectory || entry.isPackage {
            Menu("打开方式") {
                ForEach(NSWorkspace.shared.urlsForApplications(toOpen: entry.url), id: \.self) { application in
                    Button { NSWorkspace.shared.open([entry.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) } label: { Text(application.deletingPathExtension().lastPathComponent) }
                }
                Button("其他应用…") { chooseApplication(for: entry.url) }
            }
        }
        HubMenuButton("快速查看", systemImage: "eye") { preview(urls) }
        HubMenuButton("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        if urls.count == 1 { HubMenuButton("重新命名…", systemImage: "pencil") { renameName = entry.name; renameEntry = entry }.disabled(model.isStagingRoot && model.stagingTransferInProgress) }
        Divider()
        HubMenuButton("复制", systemImage: "doc.on.doc") { model.copyFiles(urls) }
        HubMenuButton("复制路径", systemImage: "link") { model.copyPath(urls) }
        if model.settings.resolvedStagingEnabled && !model.isStagingRoot {
            HubMenuButton("添加到暂存区", systemImage: "tray.and.arrow.down") { model.stageFiles(urls) }
                .disabled(model.stagingTransferInProgress)
        }
        if model.isStagingRoot {
            HubMenuButton("复制到文件夹…", systemImage: "doc.on.doc") { model.chooseStagingTransfer(copy: true, urls: urls) }
                .disabled(model.stagingTransferInProgress)
            HubMenuButton("移动到文件夹…", systemImage: "folder") { model.chooseStagingTransfer(copy: false, urls: urls) }
                .disabled(model.stagingTransferInProgress)
        }
        HubMenuButton("共享…", systemImage: "square.and.arrow.up") { NotificationCenter.default.post(name: Notification.Name("HubShare"), object: nil, userInfo: ["urls": urls]) }
        if model.selectedWorkspace?.mode == .references && model.currentURL == nil {
            Divider()
            if let paths = model.selectedWorkspace?.referencePaths, let index = paths.firstIndex(of: entry.url.path) {
                HubMenuButton("向前移动", systemImage: "arrow.left") { if index > 0 { model.reorderReference(entry.url, before: URL(fileURLWithPath: paths[index - 1])) } }.disabled(index == 0)
                HubMenuButton("向后移动", systemImage: "arrow.right") { if index + 1 < paths.count { model.reorderReference(URL(fileURLWithPath: paths[index + 1]), before: entry.url) } }.disabled(index + 1 >= paths.count)
            }
            HubMenuButton(model.isStagingRoot ? "从暂存区移除引用" : "从合集中移除引用", systemImage: "minus.circle") { model.removeReferences(urls) }
                .disabled(model.isStagingRoot && model.stagingTransferInProgress)
        }
        if !model.isStagingRoot {
            Divider()
            HubMenuButton("移到废纸篓…", systemImage: "trash", role: .destructive) { pendingTrash = urls }
        }
    }

    private func fileInteraction(for entry: FileEntry, navigateOnClick: Bool = false) -> some View {
        HubFileDragBridge(entryURL: entry.url, context: fileDragContext,
                          selectedURLs: { model.selectedURLs }, selectEntry: { selectForDrag(entry) },
                          onClick: { flags in
                              select(entry, flags: flags)
                              if navigateOnClick && entry.isDirectory && !entry.isPackage { model.navigate(to: entry.url) }
                          }, onOpen: { model.open(entry) })
    }

    private func select(_ entry: FileEntry, flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if model.selectedIDs.contains(entry.url) { model.selectedIDs.remove(entry.url) } else { model.selectedIDs.insert(entry.url) }
        } else if flags.contains(.shift), let anchor = model.visibleEntries.firstIndex(where: { model.selectedIDs.contains($0.url) }), let target = model.visibleEntries.firstIndex(where: { $0.url == entry.url }) {
            model.selectedIDs.formUnion(model.visibleEntries[min(anchor, target)...max(anchor, target)].map(\.url))
        } else { model.selectedIDs = [entry.url] }
    }

    private func selectForDrag(_ entry: FileEntry) { if !model.selectedIDs.contains(entry.url) { model.selectedIDs = [entry.url] } }
    private func preview(_ urls: [URL]) { NotificationCenter.default.post(name: Notification.Name("HubPreview"), object: nil, userInfo: ["urls": urls]) }
    private func parentDirectories(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private func chooseApplication(for url: URL) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "打开"
        if HubWindowPresentation.runModal(panel) == .OK, let application = panel.url { NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) }
    }

    private func dropBinding(for url: URL) -> Binding<Bool> {
        Binding(get: { !model.isRecentsRoot && fileDropTarget == url }, set: { targeted in
            guard !model.isRecentsRoot else { return }
            if targeted { fileDropTarget = url }
            else if fileDropTarget == url { fileDropTarget = nil }
        })
    }

    @ViewBuilder private func dropIndicator(for entry: FileEntry, beforeOnTop: Bool) -> some View {
        if !model.isRecentsRoot && fileDropTarget == entry.url {
            if let payload = HubFileDragState.current, HubFileDragData.shouldReorder(payload, in: fileDragContext) {
                if beforeOnTop {
                    Rectangle().fill(Color.accentColor).frame(height: 2).frame(maxHeight: .infinity, alignment: .top).allowsHitTesting(false)
                } else {
                    Rectangle().fill(Color.accentColor).frame(width: 2).frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
                }
            } else if entry.isDirectory && !entry.isPackage {
                RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    private func receiveItemDrop(_ providers: [NSItemProvider], entry: FileEntry) -> Bool {
        guard !model.isRecentsRoot else { return false }
        guard !HubFileDragState.isDragging || HubFileDragState.localPayload(for: providers) != nil else { return false }
        if let payload = HubFileDragState.localPayload(for: providers), HubFileDragData.shouldReorder(payload, in: fileDragContext) {
            // A folder is also an ordering target for a local drag. Never turn
            // rearrangement into a filesystem move into that folder or itself.
            model.reorderEntries(payload.urls, before: entry.url)
            fileDropTarget = nil
            return true
        }
        guard entry.isDirectory && !entry.isPackage else { return false }
        return receiveDrop(providers, destination: entry.url, reorderLocal: false)
    }

    private func receiveDrop(_ providers: [NSItemProvider], destination: URL?, reorderLocal: Bool = true) -> Bool {
        guard !model.isRecentsRoot else { return false }
        guard !HubFileDragState.isDragging || HubFileDragState.localPayload(for: providers) != nil else { return false }
        if reorderLocal, let payload = HubFileDragState.localPayload(for: providers), HubFileDragData.shouldReorder(payload, in: fileDragContext) {
            model.reorderEntries(payload.urls, before: nil)
            return true
        }
        if model.isStagingRoot { return receiveStagingDrop(providers) }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if fileProviders.isEmpty { return receiveImageDrop(providers, destination: destination) }
        let copy = NSEvent.modifierFlags.contains(.option)
        let workspaceID = model.selectedWorkspaceID
        let currentURL = model.currentURL
        let referenceRoot = model.isReferenceRoot
        let batch = HubDropBatch(count: fileProviders.count) { urls in
            guard model.selectedWorkspaceID == workspaceID, model.currentURL == currentURL, model.isReferenceRoot == referenceRoot else {
                model.errorMessage = "拖入期间工作区或文件夹已切换。未移动任何文件，请重新拖入。"
                return
            }
            guard !urls.isEmpty else { model.errorMessage = "无法读取拖入的文件地址。"; return }
            do { _ = try model.handleDrop(urls: urls, to: destination, copy: copy) } catch { model.errorMessage = error.localizedDescription }
        }
        for (index, provider) in fileProviders.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                batch.finish(index: index, url: url)
            }
        }
        return true
    }
    private func receiveStagingDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.settings.resolvedStagingEnabled, !model.stagingTransferInProgress else { return false }
        if let payload = HubFileDragState.localPayload(for: providers) { return model.stageFiles(payload.urls) }
        guard !HubFileDragState.isDragging else { return false }
        return HubStagingDropReceiver.receive(providers) { urls, failures in
            if !urls.isEmpty, !model.stageFiles(urls) {
                model.errorMessage = "暂存区当前不可用。导入的文件已保留，请重新开启暂存区后添加。"
            } else if !failures.isEmpty {
                model.errorMessage = failures.joined(separator: "\n")
            }
        }
    }
    private func receiveImageDrop(_ providers: [NSItemProvider], destination: URL?) -> Bool {
        let images = providers.compactMap { provider -> (NSItemProvider, String)? in
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
            return (provider, type)
        }
        guard !images.isEmpty else { return receiveWebImageDrop(providers, destination: destination) }
        guard let destination else { model.errorMessage = "请将图片拖入文件夹工作区，或合集中某个文件夹。"; return true }
        let workspaceID = model.selectedWorkspaceID
        let currentURL = model.currentURL
        let referenceRoot = model.isReferenceRoot
        for (provider, type) in images {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                DispatchQueue.main.async {
                    let result: Result<Data, Error> = data.map { .success($0) } ?? .failure(error ?? HubImageImportError.invalid)
                    processImageDrop(result, destination: destination, workspaceID: workspaceID, currentURL: currentURL, referenceRoot: referenceRoot)
                }
            }
        }
        return true
    }

    private func receiveWebImageDrop(_ providers: [NSItemProvider], destination: URL?) -> Bool {
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        guard !urls.isEmpty else { return false }
        guard let destination else { model.errorMessage = "请将网页图片拖入文件夹。"; return true }
        let workspaceID = model.selectedWorkspaceID, currentURL = model.currentURL, referenceRoot = model.isReferenceRoot
        for provider in urls {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                DispatchQueue.main.async {
                    guard model.selectedWorkspaceID == workspaceID, model.currentURL == currentURL, model.isReferenceRoot == referenceRoot else { return }
                    guard let url else { model.errorMessage = "无法读取网页图片地址。"; return }
                    HubWebImageLoader.fetch(url: url) { result in
                        processImageDrop(result, destination: destination, workspaceID: workspaceID, currentURL: currentURL, referenceRoot: referenceRoot)
                    }
                }
            }
        }
        return true
    }

    private func processImageDrop(_ input: Result<Data, Error>, destination: URL, workspaceID: UUID?, currentURL: URL?, referenceRoot: Bool) {
        HubImageImport.workerQueue.async {
            let result = input.flatMap { data in Result { try HubImageImport.pngData(from: data) } }
            DispatchQueue.main.async {
                guard model.selectedWorkspaceID == workspaceID, model.currentURL == currentURL, model.isReferenceRoot == referenceRoot else {
                    model.errorMessage = "拖入期间工作区已切换，未保存图片。"; return
                }
                do {
                    let png = try result.get()
                    // Once accepted, finish in the captured destination even if
                    // navigation changes. Slow disks must not block animation.
                    HubImageImport.workerQueue.async {
                        let saved = Result {
                            let file = HubFileOperations.uniqueDestination(for: URL(fileURLWithPath: "拖入的图片.png"), in: destination)
                            try png.write(to: file, options: .withoutOverwriting)
                        }
                        DispatchQueue.main.async {
                            if case .failure(let error) = saved { model.errorMessage = error.localizedDescription }
                            else if model.selectedWorkspaceID == workspaceID, model.currentURL == currentURL,
                                    model.isReferenceRoot == referenceRoot { model.refreshInBackground() }
                        }
                    }
                } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }
    private var backgroundColor: Color {
        if model.settings.resolvedBackgroundTheme == "liquidGlass" { return .clear }
        let dark = model.settings.appearance == "dark" || (model.settings.appearance == "system" && colorScheme == .dark)
        let value = (dark ? model.settings.darkBackgroundHex : model.settings.lightBackgroundHex).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let number = UInt32(value, radix: 16), value.count == 6 else { return Color(nsColor: .windowBackgroundColor) }
        return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }
    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 23, height: 23) }.buttonStyle(.plain).disabled(disabled).help(help)
    }
    private func viewButton(_ mode: HubViewMode, symbol: String, label: String) -> some View {
        Button { model.viewMode = mode } label: { Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).background(model.viewMode == mode ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4)) }.buttonStyle(.plain).help(label)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        if HubMarqueeSelectionState.isSelecting {
            if event.keyCode == 53 { HubMarqueeSelectionState.cancel() }
            return true
        }
        guard !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging, !musicControlsFocused else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        if command && event.charactersIgnoringModifiers == "a" { model.selectedIDs = Set(model.visibleEntries.map(\.url)); return true }
        if command && event.charactersIgnoringModifiers == "c" { if flags.contains(.option) { model.copySelectedPaths() } else { model.copySelectedFiles() }; return true }
        if command && event.charactersIgnoringModifiers == "v" { model.pasteFiles(); return true }
        if command && event.keyCode == 51 {
            if model.isStagingRoot { model.removeStagedFiles(model.selectedURLs) }
            else { pendingTrash = model.selectedURLs }
            return true
        }
        if command && event.keyCode == 125 { model.openSelected(); return true }
        if command && event.keyCode == 126 { model.goUp(); return true }
        let plainCommand = flags.intersection([.command, .shift, .option, .control]) == .command
        if plainCommand && (event.charactersIgnoringModifiers == "[" || event.keyCode == 33) { model.goBack(); return true }
        if plainCommand && (event.charactersIgnoringModifiers == "]" || event.keyCode == 30) { model.goForward(); return true }
        if command && event.charactersIgnoringModifiers == "r" { model.refresh(); return true }
        if command && flags.contains(.shift) && event.charactersIgnoringModifiers == "n" { folderName = "新建文件夹"; newFolder = true; return true }
        if flags.contains(.option) && !command && event.keyCode == 123 { model.goBack(); return true }
        if flags.contains(.option) && !command && event.keyCode == 124 { model.goForward(); return true }
        guard !command && !flags.contains(.control) && !flags.contains(.option) else { return false }
        if event.keyCode == 49 { if !model.selectedURLs.isEmpty { preview(model.selectedURLs) }; return true }
        if event.keyCode == 36 { model.openSelected(); return true }
        if event.keyCode == 53 { onClose(); return true }
        if [123,124,125,126].contains(event.keyCode), !model.visibleEntries.isEmpty {
            let current = model.visibleEntries.firstIndex(where: { model.selectedIDs.contains($0.url) }) ?? -1
            let step = (event.keyCode == 123 || event.keyCode == 126) ? -1 : 1
            let next = min(max(current + step, 0), model.visibleEntries.count - 1)
            if flags.contains(.shift) { model.selectedIDs.insert(model.visibleEntries[next].url) } else { model.selectedIDs = [model.visibleEntries[next].url] }
            return true
        }
        return false
    }
}

private final class HubDropBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [Int: URL] = [:]
    private let completion: @MainActor ([URL]) -> Void
    init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) { remaining = count; self.completion = completion }
    func finish(index: Int, url: URL?) {
        lock.lock(); if let url, url.isFileURL { urls[index] = url }; remaining -= 1
        let ready = remaining == 0; let result = ready ? urls.sorted { $0.key < $1.key }.map(\.value) : []; lock.unlock()
        if ready { DispatchQueue.main.async { self.completion(result) } }
    }
}

private struct HubKeyMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyboardView { let view = KeyboardView(); view.handler = handler; return view }
    func updateNSView(_ view: KeyboardView, context: Context) { view.handler = handler }
    final class KeyboardView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, self.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                    if HubInlinePreviewFocus.contains(self.window?.firstResponder) { return event }
                    if let text = self.window?.firstResponder as? NSTextView, text.isEditable { return event }
                    return self.handler?(event) == true ? nil : event
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

@MainActor private struct WorkspaceEditor: View {
    @ObservedObject var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State var workspace: Workspace
    @State private var symbolSearch = ""
    private let symbols = ["folder", "folder.fill", "folder.badge.gearshape", "tray.and.arrow.down", "desktopcomputer", "doc", "doc.text", "doc.richtext", "photo", "photo.on.rectangle", "music.note", "play.rectangle", "hammer", "terminal", "chevron.left.forwardslash.chevron.right", "book", "books.vertical", "pencil", "paintpalette", "briefcase", "archivebox", "square.stack.3d.up", "star", "heart", "bookmark", "house", "globe", "paperplane", "cloud", "externaldrive", "internaldrive", "server.rack", "person", "person.2", "lightbulb", "sparkles", "calendar", "clock", "checkmark.circle", "flag", "bolt", "leaf", "pawprint", "gamecontroller", "graduationcap", "brain", "chart.bar", "chart.pie", "camera", "film", "gift", "cart", "building.2", "network", "link", "shippingbox", "note.text", "list.bullet", "square.grid.2x2", "rectangle.stack", "cube", "atom", "app", "gearshape", "wrench.and.screwdriver", "scissors", "paperclip", "tag", "pin", "map", "location", "airplane", "car", "bicycle", "figure.walk", "sun.max", "moon", "flame", "drop", "snowflake", "tree", "mountain.2", "waveform", "headphones", "mic", "keyboard", "display", "iphone", "ipad", "laptopcomputer", "printer", "scanner", "wifi", "antenna.radiowaves.left.and.right", "lock", "key", "shield", "hand.thumbsup", "face.smiling", "cup.and.saucer", "fork.knife", "bed.double", "cross.case", "stethoscope"]
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("编辑工作区").font(.title3.bold())
            HStack(spacing: 12) {
                if let path = workspace.customIconPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36) } else { Image(systemName: workspace.symbol).font(.system(size: 30)).foregroundStyle(Color.accentColor).frame(width: 42) }
                TextField("工作区名称", text: $workspace.name).textFieldStyle(.roundedBorder)
            }
            Text(workspace.mode == .folder ? "文件夹：\(workspace.rootPath ?? "未选择")" : workspace.mode == .recents ? "最近使用 · 自动更新最近打开的文件" : "文件与文件夹合集 · \(workspace.referencePaths.count) 个引用").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("搜索图标名称，或直接输入 SF Symbol 名称", text: $symbolSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 9) {
                    ForEach(symbols.filter { symbolSearch.isEmpty || $0.localizedCaseInsensitiveContains(symbolSearch) }, id: \.self) { symbol in
                        Button { workspace.symbol = symbol; workspace.customIconPath = nil } label: { Image(systemName: symbol).font(.system(size: 19)).frame(width: 36, height: 32).background(workspace.symbol == symbol && workspace.customIconPath == nil ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).help(symbol)
                    }
                }
            }.frame(height: 165)
            HStack {
                Button("自定义图片…") { chooseImage() }
                if !symbolSearch.isEmpty, NSImage(systemSymbolName: symbolSearch, accessibilityDescription: nil) != nil { Button("使用此符号") { workspace.symbol = symbolSearch; workspace.customIconPath = nil } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { workspace.name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines); model.updateWorkspace(workspace); dismiss() }.keyboardShortcut(.defaultAction).disabled(workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workspace.symbol.isEmpty && workspace.customIconPath == nil)
            }
        }.padding(24).frame(width: 460)
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        if HubWindowPresentation.runModal(panel) == .OK, let url = panel.url { workspace.customIconPath = url.path }
    }
}
