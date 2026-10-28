import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

private struct HubShortcutReorderRegions {
    var frames: [UUID: Anchor<CGRect>] = [:]
    var viewports: [Anchor<CGRect>] = []
}

private struct HubShortcutReorderRegionKey: PreferenceKey {
    static var defaultValue = HubShortcutReorderRegions()
    static func reduce(value: inout HubShortcutReorderRegions, nextValue: () -> HubShortcutReorderRegions) {
        let next = nextValue()
        value.frames.merge(next.frames, uniquingKeysWith: { _, new in new })
        value.viewports += next.viewports
    }
}

@MainActor
struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var presentation: HubPresentationState
    let music: HubQQMusicController
    private var locale: Locale { model.settings.resolvedLanguage.locale }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var leftTabSelection
    @Namespace private var rightTabSelection
    @Namespace private var floatingTabSelection
    @Namespace private var shortcutSelection
    @Namespace private var viewModeSelection
    var onSettings: () -> Void
    var onClose: () -> Void
    @State private var editingWorkspace: Workspace?
    @State private var folderStyleEntry: FileEntry?
    @State private var newFolder = false
    @State private var folderName = L("新建文件夹")
    @State private var pendingTrash: [URL] = []
    @State private var dropTargeted = false
    @State private var stagingDropTargeted = false
    @State private var airDropTargeted = false
    @State private var showsAirDropHint = false
    @State private var fileDropTarget: URL?
    @State private var fileDropFeedback: HubFileDropFeedback?
    @State private var hoveredWorkspace: UUID?
    @State private var hoverTask: DispatchWorkItem?
    @StateObject private var parentDirectory = HubParentDirectory()
    @StateObject private var workspaceSpringLoader = HubWorkspaceSpringLoader()
    @State private var workspaceRevealPointer: NSPoint?
    @State private var hoverSelection = HubWorkspaceHoverSelection()
    @State private var workspaceControlsWidth: CGFloat = 0
    @State private var musicControlsFocused = false
    @StateObject private var activityVisibility = HubActivityVisibility()
    @State private var workspaceReordering = false
    @State private var tabRevealTask: Task<Void, Never>?
    @State private var renameEntry: FileEntry?
    @State private var renameName = ""
    @State private var renameSessionID = UUID()
    @State private var extensionRename: (entry: FileEntry, name: String)?

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
                .transformAnchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { $0[.header] = $1 }
            Divider().opacity(0.55)
            browserBar
            Divider().opacity(0.45)
            if let message = model.directoryLoadMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("重试")) { model.retryDirectoryLoad() }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.isStagingRoot { stagingActions }
            content
                // Keep the surrounding viewport's existing window-layout
                // transition, without interpolating the file rows themselves.
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    activityIndicator
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted && fileDropFeedback == nil && !model.isRecentsRoot ? Color.accentColor : .clear, lineWidth: 2).padding(4))
                .onDrop(of: [hubFileDragType, .fileURL, .image, .url, .item], isTargeted: $dropTargeted) { receiveDrop($0, destination: model.currentURL) }
                .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { regions, anchor in regions[.content] = anchor }
            Divider().opacity(0.45)
            if embeddedMusicLayout.placement == .bottom {
                HubQQMusicBar(controller: music, isPresented: presentation.previewVisible)
                Divider().opacity(0.45)
            }
            footer
        }
        .font(.system(size: model.settings.fontSize))
        .environment(\.locale, model.settings.resolvedLanguage.locale)
        .environment(\.hubInterfaceMotion, interfaceMotion)
        .background(backgroundColor)
        .background(HubKeyMonitor(handler: handleKey))
        .overlayPreferenceValue(HubFileDropRegionKey.self) { anchors in
            GeometryReader { geometry in
                let regions = anchors.mapValues { geometry[$0] }
                let frames = Dictionary(uniqueKeysWithValues: regions.compactMap { key, frame -> (URL, CGRect)? in
                    if case .item(let url) = key { return (url, frame) }; return nil
                })
                nativeFileDrop(regions: regions, frames: frames, size: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                nativeWorkspaceReorderDrop(regions: regions, size: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let feedback = fileDropFeedback { feedback.overlay(in: geometry.size) }
            }
        }
        .overlayPreferenceValue(HubShortcutReorderRegionKey.self) { regions in
            GeometryReader { geometry in
                nativeShortcutReorderDrop(regions: regions, geometry: geometry)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .overlayPreferenceValue(HubHeaderDragRegionKey.self) { anchors in
            GeometryReader { geometry in
                HubWindowDragHandle(dragRects: HubHeaderDragGeometry.rectangles(
                    in: CGRect(origin: .zero, size: geometry.size), regions: anchors.mapValues { geometry[$0] }))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if showsAirDropHint || (airDropTargeted && fileDropFeedback == nil) {
                    Text(showsAirDropHint ? L("将文件拖到 AirDrop 图标，或先选中文件再点按") : L("松开以通过 AirDrop 发送"))
                        .font(.caption).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 12).padding(.bottom, 52)
                        .transition(.opacity)
                }
            }
            .animation(interfaceMotion.feedback, value: showsAirDropHint || airDropTargeted)
            .allowsHitTesting(false)
        }
        .task(id: showsAirDropHint) {
            guard showsAirDropHint else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            showsAirDropHint = false
        }
        .onReceive(NotificationCenter.default.publisher(for: hubFileDragDidEnd)) { _ in
            presentation.setFileDragActive(false)
            workspaceSpringLoader.cancel()
            fileDropTarget = nil
            fileDropFeedback = nil
            dropTargeted = false
            stagingDropTargeted = false
            airDropTargeted = false
            showsAirDropHint = false
        }
        .onReceive(NotificationCenter.default.publisher(for: hubWorkspaceDragDidEnd)) { _ in
            workspaceReordering = false
            workspaceSpringLoader.cancel()
            hoverTask?.cancel()
            hoveredWorkspace = nil
            workspaceRevealPointer = NSEvent.mouseLocation
        }
        .onReceive(NotificationCenter.default.publisher(for: hubWorkspaceDragDidBegin)) { _ in
            workspaceReordering = true
            tabRevealTask?.cancel()
        }
        .onChange(of: presentation.previewVisible) {
            activityVisibility.update(active: activityActive, presented: $0)
            prepareWorkspaceHover()
            if !$0 { clearFileDrop(); showsAirDropHint = false; tabRevealTask?.cancel(); renameEntry = nil }
        }
        .onChange(of: presentation.header) { _ in prepareWorkspaceHover() }
        .onChange(of: canReceiveAirDrop) { if !$0 { showsAirDropHint = false; if airDropTargeted { clearFileDrop() } } }
        .onDisappear {
            clearFileDrop(); showsAirDropHint = false; hoverTask?.cancel(); tabRevealTask?.cancel()
            renameEntry = nil
            activityVisibility.update(active: false, presented: false)
        }
        .onAppear {
            prepareWorkspaceHover()
            activityVisibility.update(active: activityActive, presented: presentation.previewVisible)
        }
        .onChange(of: activityActive) { activityVisibility.update(active: $0, presented: presentation.previewVisible) }
        .onChange(of: model.search) { _ in renameEntry = nil; model.selectedIDs = [] }
        .onChange(of: model.selectedIDs) { selection in
            if let entry = renameEntry, !selection.contains(entry.url) { renameEntry = nil }
        }
        .onReceive(model.$entries) { entries in
            if let entry = renameEntry, !entries.contains(where: { $0.url == entry.url }) { renameEntry = nil }
        }
        .onChange(of: model.selectedWorkspaceID) { _ in
            renameEntry = nil
            let current = model.selectedWorkspaceID
            if current == nil || hoverSelection.needsReveal(current) { hoverTask?.cancel(); hoveredWorkspace = nil }
            hoverSelection.observe(current: current)
        }
        .onChange(of: model.currentURL) { _ in renameEntry = nil }
        .onChange(of: model.viewMode) { _ in renameEntry = nil }
        .onChange(of: dropTargeted) { if $0 { presentation.setFileDragActive(true) } }
        .sheet(item: $editingWorkspace) { WorkspaceEditor(model: model, workspace: $0) }
        .sheet(item: $folderStyleEntry) { entry in
            HubFolderStyleEditor(entry: entry) { label, icon in model.performFinderAction(.folderStyle(label, icon), urls: [entry.url]) }
        }
        .alert(L("新建文件夹"), isPresented: $newFolder) {
            TextField(L("名称"), text: $folderName)
            Button(L("取消"), role: .cancel) { }
            Button(L("创建")) { model.createFolder(named: folderName) }
        }
        .alert(L("更改文件扩展名？"), isPresented: Binding(get: { extensionRename != nil }, set: { if !$0 { extensionRename = nil } })) {
            Button(L("取消"), role: .cancel) { extensionRename = nil }
            Button(L("保留原扩展名")) {
                if let request = extensionRename {
                    model.rename(request.entry, to: HubFileNameEditing.keepingExtension(from: request.entry.url.lastPathComponent, in: request.name))
                }
                extensionRename = nil
            }
            Button(L("使用新名称")) { if let request = extensionRename { model.rename(request.entry, to: request.name) }; extensionRename = nil }
                .keyboardShortcut(.defaultAction)
        } message: { Text(L("更改扩展名可能导致原来的应用无法识别文件，不会转换文件格式。")) }
        .alert(L("移到废纸篓？"), isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button(L("取消"), role: .cancel) { pendingTrash = [] }
            Button(L("移到废纸篓"), role: .destructive) { let urls = pendingTrash; pendingTrash = []; model.trash(urls) }
        } message: { Text(L("将 \(pendingTrash.count) 个项目移到系统废纸篓。可以在访达中恢复。")) }
        .alert(L("操作未完成"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("好")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var interfaceMotion: HubInterfaceMotion {
        HubInterfaceMotion(enabled: !reduceMotion && !presentation.defersFileRendering && !workspaceReordering,
                           speed: model.settings.resolvedAnimationSpeed)
    }

    private var activityActive: Bool { model.directoryLoading || model.fileOperationsInProgress > 0 }

    private var activityIndicator: some View {
        ZStack(alignment: .topTrailing) {
            if activityVisibility.visible {
                HStack(spacing: 7) {
                    ZStack {
                        ProgressView().controlSize(.small).opacity(activityActive ? 1 : 0)
                        Image(systemName: "checkmark").font(.caption).opacity(activityActive ? 0 : 1)
                    }.frame(width: 14, height: 14)
                    Text(!activityActive ? L("已完成") : model.fileOperationsInProgress > 0 ? L("正在处理文件…") : model.entries.isEmpty ? L("正在读取…") : L("已读取 \(model.entries.count) 项…"))
                        .font(.caption)
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule()).padding(10)
                    .transition(.opacity)
            }
        }
        .animation(interfaceMotion.feedback, value: activityVisibility.visible)
        .animation(interfaceMotion.feedback, value: activityActive)
        .allowsHitTesting(false)
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
            .anchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { [.music: $0] }
            .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { $0[.headerMusic] = $1 }
    }

    @ViewBuilder private var workspaceBar: some View {
        VStack(spacing: 0) {
            workspaceHeader
                .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { $0[.header] = $1 }
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
                    workspaceLeading(leftWorkspaces, selectionNamespace: leftTabSelection, availableWidth: sideWidth)
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
                            workspaceLeading(rightWorkspaces, selectionNamespace: rightTabSelection, availableWidth: layout.rightViewportWidth)
                                .frame(width: layout.rightViewportWidth, alignment: .leading).clipped()
                        }
                        HubWindowDragHandle().frame(width: layout.dragWidth, height: 30).help(L("拖动窗口"))
                        HStack(spacing: HubWorkspaceHeaderLayout.tabSpacing) { workspaceControls }
                            .animation(interfaceMotion.selection, value: model.selectedWorkspaceID)
                            .animation(nil, value: interfaceMotion.enabled)
                            .fixedSize()
                            .background(GeometryReader { controlsGeometry in
                                Color.clear.preference(key: HubWorkspaceControlsWidthKey.self,
                                                       value: controlsGeometry.size.width)
                            })
                            .frame(width: layout.controlsWidth, alignment: .trailing)
                            .contentShape(Rectangle()).clipped()
                            .transformAnchorPreference(key: HubShortcutReorderRegionKey.self, value: .bounds) { regions, anchor in
                                regions.viewports.append(anchor)
                            }
                            .transformAnchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { $0[.controls] = $1 }
                            .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { $0[.headerControls] = $1 }
                    }.frame(width: sideWidth).clipped()
                }.padding(.horizontal, 12).frame(height: geometry.size.height)
                    .onPreferenceChange(HubWorkspaceControlsWidthKey.self) { width in
                        if width.isFinite && width > 0 && abs(width - workspaceControlsWidth) > 0.5 {
                            workspaceControlsWidth = width
                        }
                    }
            }.frame(height: embeddedMusicLayout.headerHeight)
        } else {
            HStack(spacing: 8) {
                workspaceLeading(model.tabWorkspaces, selectionNamespace: floatingTabSelection)
                HubWindowDragHandle().frame(minWidth: 32, maxWidth: .infinity, minHeight: 30, maxHeight: 30).help(L("拖动窗口"))
                HStack(spacing: HubWorkspaceHeaderLayout.tabSpacing) { workspaceControls }.fixedSize()
                    .animation(interfaceMotion.selection, value: model.selectedWorkspaceID)
                    .animation(nil, value: interfaceMotion.enabled)
                    .transformAnchorPreference(key: HubShortcutReorderRegionKey.self, value: .bounds) { regions, anchor in
                        regions.viewports.append(anchor)
                    }
                    .transformAnchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { $0[.controls] = $1 }
                    .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { $0[.headerControls] = $1 }
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .padding(.top, presentation.header.embedded ? presentation.header.topInset : 0)
        }
    }

    private func workspaceLeading(_ workspaces: [Workspace], selectionNamespace: Namespace.ID, availableWidth: CGFloat? = nil) -> some View {
        let tabWidthLimit = availableWidth.map { max(48, $0) }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HubWorkspaceHeaderLayout.tabSpacing) {
                    ForEach(workspaces) { workspace in
                        workspaceTab(workspace, selectionNamespace: selectionNamespace, maximumWidth: tabWidthLimit).id(workspace.id)
                    }
                }.padding(.vertical, 3)
                    .animation(interfaceMotion.selection, value: model.selectedWorkspaceID)
                    .animation(nil, value: interfaceMotion.enabled)
            }
            .contentShape(Rectangle()).clipped()
            .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { regions, anchor in
                for workspace in workspaces { regions[.tabViewport(workspace.id)] = anchor }
            }
            .transformAnchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { regions, anchor in
                for workspace in workspaces { regions[.viewport(workspace.id)] = anchor }
            }
            .onHover { if !$0 { workspaceRevealPointer = nil } }
            .onAppear { revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: model.selectedWorkspaceID) { _ in
                if hoverSelection.needsReveal(model.selectedWorkspaceID) { revealSelectedWorkspace(in: workspaces, using: proxy) }
            }
            .onChange(of: workspaces.map(\.id)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: workspaces.map(\.name)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: workspaces.map(\.iconOnly)) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: model.settings.fontSize) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
            .onChange(of: availableWidth) { _ in revealSelectedWorkspace(in: workspaces, using: proxy) }
        }.frame(maxWidth: min(workspaceTabsWidth(workspaces), tabWidthLimit ?? workspaceTabsWidth(workspaces))).layoutPriority(1)
    }

    private func revealSelectedWorkspace(in workspaces: [Workspace], using proxy: ScrollViewProxy) {
        guard !HubWorkspaceDragState.isDragging, !HubFileDragState.isDragging,
              let id = model.selectedWorkspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        hoverTask?.cancel()
        hoveredWorkspace = nil
        // Position after SwiftUI has laid out new/renamed tabs. Use minimal
        // scrolling so a tab already under the pointer stays in place.
        tabRevealTask?.cancel()
        tabRevealTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, presentation.previewVisible, model.selectedWorkspaceID == id,
                  !HubWorkspaceDragState.isDragging, !HubFileDragState.isDragging else { return }
            workspaceRevealPointer = NSEvent.mouseLocation
            withAnimation(interfaceMotion.feedback) { proxy.scrollTo(id) }
        }
    }

    @State private var stagingHoverID = UUID()
    private func prepareWorkspaceHover() {
        hoverTask?.cancel(); hoveredWorkspace = nil
        hoverSelection.reset()
        workspaceRevealPointer = NSEvent.mouseLocation
    }

    private func commitWorkspaceHover(_ id: UUID, action: () -> Void) {
        tabRevealTask?.cancel()
        hoverTask = nil
        hoverSelection.record(id)
        action()
        // Opening staging for the first time can create its real workspace ID.
        if model.selectedWorkspaceID != id { hoverSelection.record(model.selectedWorkspaceID) }
    }

    private func selectWorkspaceFromClick(_ id: UUID) {
        prepareWorkspaceHover()
        model.selectWorkspace(id)
    }

    private func canHoverWorkspace(_ target: UUID) -> Bool {
        let ready = renameEntry == nil && presentation.previewVisible && !presentation.windowMoving && !presentation.layoutChanging &&
            !presentation.surfaceAnimating && !HubWorkspaceDragState.isDragging && !HubFileDragState.isDragging
        guard HubWorkspaceHoverActivation.permits(target: target, current: model.selectedWorkspaceID, ready: ready,
            pointer: NSEvent.mouseLocation, origin: workspaceRevealPointer) else { return false }
        workspaceRevealPointer = nil
        return true
    }

    private func shortcutHover(_ entered: Bool, key: UUID, action: @escaping () -> Void) {
        guard entered else {
            if hoveredWorkspace == key { hoverTask?.cancel(); hoveredWorkspace = nil }
            return
        }
        tabRevealTask?.cancel()
        hoverTask?.cancel()
        guard model.settings.switchDelay > 0, canHoverWorkspace(key) else { return }
        hoveredWorkspace = key
        let task = DispatchWorkItem {
            guard hoveredWorkspace == key, canHoverWorkspace(key) else { return }
            commitWorkspaceHover(key, action: action)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.switchDelay, execute: task)
    }

    @ViewBuilder private func fixedShortcut(_ item: HubShortcutItem) -> some View {
        switch item {
        case .favorite:
            if let favorite = model.fixedFavoriteWorkspace {
                Button { activateShortcut(.favorite) } label: {
                    HubWorkspaceShortcutLabel(symbol: model.selectedWorkspaceID == favorite.id ? "star.fill" : "star",
                                              selected: model.selectedWorkspaceID == favorite.id,
                                              targeted: workspaceSpringLoader.target == favorite.id,
                                              selectionNamespace: shortcutSelection)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L("收藏：\(model.displayName(for: favorite))"))
                    .help(L("\(model.displayName(for: favorite)) · 右键可隐藏快捷入口"))
                    .onHover { shortcutHover($0, key: favorite.id, action: { model.selectWorkspace(favorite.id) }) }
                    .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: workspaceFileDrop(favorite))
                    .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.workspace(favorite.id): $0] }
                    .contextMenu {
                        HubMenuButton(L("编辑收藏…"), systemImage: "pencil") { editingWorkspace = favorite }
                        HubMenuButton(L("隐藏收藏快捷入口"), systemImage: "eye.slash") { model.setFavoriteShortcutVisible(false) }
                    }
            }
        case .airDrop:
            if model.settings.resolvedAirDropEnabled {
                Button { activateShortcut(.airDrop) } label: { HubWorkspaceShortcutLabel(symbol: "airplayaudio", targeted: airDropTargeted) }
                    .buttonStyle(.plain)
                    .disabled(!canReceiveAirDrop)
                    .accessibilityLabel("AirDrop")
                    .help(L("AirDrop · 拖入文件，或先选择文件后点按"))
                    .onDrop(of: HubAirDropFileDropDelegate.contentTypes, delegate: HubAirDropFileDropDelegate(
                        canReceive: { presentation.previewVisible && canReceiveAirDrop && !HubWorkspaceDragState.isDragging },
                        targeted: { active in
                            if active {
                                if !airDropTargeted {
                                    clearFileDrop()
                                    airDropTargeted = true
                                    showsAirDropHint = false
                                    hoverTask?.cancel(); hoveredWorkspace = nil
                                    presentation.setFileDragActive(true)
                                }
                            } else {
                                airDropTargeted = false
                                if fileDropFeedback?.action == .airDrop { fileDropFeedback = nil }
                            }
                        }, receive: receiveAirDropFiles))
                    .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.airDrop: $0] }
            }
        case .recents:
            if let recent = model.fixedRecentWorkspace {
                Button { activateShortcut(.recents) } label: {
                    HubWorkspaceShortcutLabel(symbol: "clock",
                                              selected: model.selectedWorkspaceID == recent.id,
                                              targeted: workspaceSpringLoader.target == recent.id,
                                              selectionNamespace: shortcutSelection)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L("最近使用：\(model.displayName(for: recent))"))
                    .help(L("\(model.displayName(for: recent)) · 右键可隐藏快捷入口"))
                    .onHover { shortcutHover($0, key: recent.id, action: { model.selectWorkspace(recent.id) }) }
                    .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: workspaceFileDrop(recent))
                    .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.workspace(recent.id): $0] }
                    .contextMenu {
                        HubMenuButton(L("隐藏最近使用快捷入口"), systemImage: "eye.slash") { model.setRecentShortcutVisible(false) }
                    }
            }
        case .staging:
            if model.settings.resolvedStagingEnabled {
                Button { activateShortcut(.staging) } label: {
                    HubWorkspaceShortcutLabel(symbol: model.stagedURLs.isEmpty ? "tray" : "tray.full.fill",
                                              count: model.stagedURLs.count, selected: model.isStagingWorkspace,
                                              targeted: stagingDropTargeted, selectionNamespace: shortcutSelection)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L("暂存区，\(model.stagedURLs.count) 个项目"))
                    .help(L("暂存区 · 拖入文件暂存引用，点击查看，右键快速转移"))
                    .onHover { shortcutHover($0, key: model.settings.stagingWorkspaceID ?? stagingHoverID, action: { model.openStagingWorkspace() }) }
                    .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: HubWorkspaceFileDropDelegate(
                        id: model.settings.stagingWorkspaceID ?? stagingHoverID, loader: workspaceSpringLoader,
                        delay: model.settings.switchDelay,
                        canActivate: { presentation.previewVisible && model.settings.resolvedStagingEnabled && !HubWorkspaceDragState.isDragging },
                        activate: { if !model.isStagingWorkspace { model.openStagingWorkspace() } },
                        targeted: { stagingDropTargeted = $0; if $0 { presentation.setFileDragActive(true) } }, receive: receiveStagingDrop))
                    .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.staging: $0] }
                    .contextMenu {
                        HubMenuButton(L("打开暂存区"), systemImage: "tray") { model.openStagingWorkspace() }
                        if model.currentURL != nil {
                            HubMenuButton(L("复制全部到当前文件夹"), systemImage: "doc.on.doc") { model.transferStagingToCurrentFolder(copy: true) }
                                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                            HubMenuButton(L("移动全部到当前文件夹"), systemImage: "folder") { model.transferStagingToCurrentFolder(copy: false) }
                                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                        }
                        HubMenuButton(L("复制全部到…"), systemImage: "doc.on.doc") { model.chooseStagingTransfer(copy: true, urls: model.stagedURLs) }
                            .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                        HubMenuButton(L("移动全部到…"), systemImage: "folder") { model.chooseStagingTransfer(copy: false, urls: model.stagedURLs) }
                            .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                        Divider()
                        HubMenuButton(L("清空暂存引用"), systemImage: "minus.circle") { model.clearStagedFiles() }
                            .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                        HubMenuButton(L("关闭暂存区"), systemImage: "eye.slash") { model.setStagingEnabled(false) }
                    }
            }
        }
    }

    private func shortcutTitle(_ item: HubShortcutItem) -> String {
        switch item {
        case .favorite: return model.fixedFavoriteWorkspace.map { model.displayName(for: $0) } ?? L("收藏")
        case .airDrop: return "AirDrop"
        case .recents: return model.fixedRecentWorkspace.map { model.displayName(for: $0) } ?? L("最近使用")
        case .staging: return L("暂存区")
        }
    }

    private func shortcutSymbol(_ item: HubShortcutItem) -> String {
        switch item {
        case .favorite: return model.fixedFavoriteWorkspace?.id == model.selectedWorkspaceID ? "star.fill" : "star"
        case .airDrop: return "airplayaudio"
        case .recents: return "clock"
        case .staging: return model.stagedURLs.isEmpty ? "tray" : "tray.full.fill"
        }
    }

    private func activateShortcut(_ item: HubShortcutItem) {
        guard model.visibleShortcutItems.contains(item) else { return }
        prepareWorkspaceHover()
        switch item {
        case .favorite:
            if let favorite = model.fixedFavoriteWorkspace { model.selectWorkspace(favorite.id) }
        case .airDrop:
            guard canReceiveAirDrop else { return }
            let selection = model.selectedURLs
            let urls = selection.isEmpty && model.isStagingRoot ? model.stagedURLs : selection
            guard !urls.isEmpty else { showsAirDropHint = true; return }
            queueAirDropFiles(urls)
        case .recents:
            if let recent = model.fixedRecentWorkspace { model.selectWorkspace(recent.id) }
        case .staging: model.openStagingWorkspace()
        }
    }

    @ViewBuilder private var workspaceControls: some View {
        ForEach(model.visibleShortcutItems) { item in
            fixedShortcut(item)
                .overlay(HubWorkspaceDragBridge(
                    workspaceID: item.dragID, title: shortcutTitle(item),
                    domain: .shortcut, symbol: shortcutSymbol(item),
                    acceptsReorderDrops: false,
                    onSelect: { activateShortcut(item) },
                    onReorder: { source, target, after in
                        model.reorderShortcut(sourceID: source, targetID: target, after: after)
                    },
                    onDragStateChanged: { _ in
                        clearFileDrop()
                        hoverTask?.cancel(); hoveredWorkspace = nil
                        workspaceRevealPointer = NSEvent.mouseLocation
                    }))
                .anchorPreference(key: HubShortcutReorderRegionKey.self, value: .bounds) {
                    HubShortcutReorderRegions(frames: [item.dragID: $0])
                }
        }
        Menu {
            Toggle(L("固定收藏到右上角"), isOn: Binding(
                get: { model.fixedFavoriteWorkspace != nil },
                set: { model.setFavoriteShortcutVisible($0) }))
            Toggle(L("固定最近使用到右上角"), isOn: Binding(
                get: { model.settings.resolvedRecentShortcutEnabled },
                set: { model.setRecentShortcutVisible($0) }))
            Toggle(L("显示文件暂存区"), isOn: Binding(
                get: { model.settings.resolvedStagingEnabled },
                set: { model.setStagingEnabled($0) }))
            Toggle(L("启用 AirDrop"), isOn: Binding(
                get: { model.settings.resolvedAirDropEnabled },
                set: { model.settings.airDropEnabled = $0 }))
            Divider()
            HubMenuButton(L("文件夹工作区…"), systemImage: "folder.badge.plus") { model.chooseWorkspace(mode: .folder) }
            HubMenuButton(L("文件与文件夹合集…"), systemImage: "square.stack.3d.up") { model.chooseWorkspace(mode: .references) }
        } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: HubWorkspaceShortcutLabel.width, height: HubWorkspaceShortcutLabel.height) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: HubWorkspaceShortcutLabel.width, height: HubWorkspaceShortcutLabel.height).clipped()
            .accessibilityLabel(L("添加工作区")).help(L("添加工作区"))
        if presentation.windowMoving ? presentation.movingPinned : model.pinned {
            Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: HubWorkspaceShortcutLabel.width, height: HubWorkspaceShortcutLabel.height) }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("收起 (Esc)"))
        }
    }

    private var stagingActions: some View {
        HStack(spacing: 10) {
            if model.stagingTransferInProgress {
                ProgressView().controlSize(.small)
                Text(L("正在转移文件…")).foregroundStyle(.secondary)
            } else {
                Text(L("仅保存引用 · 清空暂存不会删除原文件")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(model.selectedURLs.isEmpty ? L("复制全部到…") : L("复制所选到…")) { model.chooseStagingTransfer(copy: true) }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
            Button(model.selectedURLs.isEmpty ? L("移动全部到…") : L("移动所选到…")) { model.chooseStagingTransfer(copy: false) }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
            Button { model.clearStagedFiles() } label: { Image(systemName: "minus.circle") }
                .disabled(model.stagedURLs.isEmpty || model.stagingTransferInProgress)
                .help(L("清空暂存引用，保留原文件")).accessibilityLabel(L("清空暂存引用"))
        }.padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func workspaceTabWidth(_ workspace: Workspace) -> CGFloat {
        let font = NSFont.systemFont(ofSize: model.settings.fontSize)
        if workspace.iconOnly == true || workspace.name.isEmpty { return HubWorkspaceShortcutLabel.width }
        return 40 + 6 + (model.displayName(for: workspace) as NSString).size(withAttributes: [.font: font]).width
    }

    private func workspaceTabsWidth(_ workspaces: [Workspace]) -> CGFloat {
        workspaces.reduce(CGFloat(0)) { $0 + workspaceTabWidth($1) }
            + CGFloat(max(0, workspaces.count - 1)) * HubWorkspaceHeaderLayout.tabSpacing
    }

    private var fileDragContext: HubFileDragContext {
        HubFileDragContext(workspaceID: model.selectedWorkspaceID, directory: model.currentURL)
    }

    private func workspaceTab(_ workspace: Workspace, selectionNamespace: Namespace.ID, maximumWidth: CGFloat? = nil) -> some View {
        let iconOnly = workspace.iconOnly == true || workspace.name.isEmpty
        return Button { selectWorkspaceFromClick(workspace.id) } label: {
            HStack(spacing: 6) {
                workspaceIcon(workspace).frame(width: 16, height: 16)
                if workspace.iconOnly != true && !workspace.name.isEmpty { Text(model.displayName(for: workspace)).lineLimit(1).truncationMode(.tail) }
            }
            .frame(maxWidth: iconOnly ? nil : maximumWidth.map { max(24, $0 - 24) }, alignment: .leading)
            .padding(.horizontal, iconOnly ? (HubWorkspaceShortcutLabel.width - 16) / 2 : 12).padding(.vertical, 8)
            .background(HubSelectionBackdrop(selected: model.selectedWorkspaceID == workspace.id, namespace: selectionNamespace, cornerRadius: iconOnly ? 6 : 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name.isEmpty ? workspace.mode.title : model.displayName(for: workspace))
        .help(model.displayName(for: workspace) + "\n" + (workspace.mode == .recents ? L("自动更新最近使用的文件") : workspace.rootPath ?? L("文件与文件夹合集")))
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
            tabRevealTask?.cancel()
            hoverTask?.cancel()
            guard canHoverWorkspace(workspace.id) else { hoveredWorkspace = nil; return }
            hoveredWorkspace = workspace.id
            if model.settings.switchDelay > 0 {
                let task = DispatchWorkItem {
                    if hoveredWorkspace == workspace.id && canHoverWorkspace(workspace.id) {
                        commitWorkspaceHover(workspace.id) { model.selectWorkspace(workspace.id) }
                    }
                }
                hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.switchDelay, execute: task)
            }
        }
        .contextMenu {
            HubMenuButton(L("编辑工作区…"), systemImage: "pencil") { editingWorkspace = workspace }
            Toggle(L("仅显示图标"), isOn: Binding(
                get: { model.workspaces.first(where: { $0.id == workspace.id })?.iconOnly == true },
                set: { model.setWorkspaceIconOnly(id: workspace.id, enabled: $0) }))
            if let index = model.tabWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
                HubMenuButton(L("向左移动"), systemImage: "arrow.left") {
                    let tabs = model.tabWorkspaces
                    if let current = tabs.firstIndex(where: { $0.id == workspace.id }), current > 0 {
                        model.reorderWorkspace(workspace.id, relativeTo: tabs[current - 1].id, after: false)
                    }
                }.disabled(index == 0)
                HubMenuButton(L("向右移动"), systemImage: "arrow.right") {
                    let tabs = model.tabWorkspaces
                    if let current = tabs.firstIndex(where: { $0.id == workspace.id }), current + 1 < tabs.count {
                        model.reorderWorkspace(workspace.id, relativeTo: tabs[current + 1].id, after: true)
                    }
                }.disabled(index == model.tabWorkspaces.count - 1)
            }
            Divider()
            HubMenuButton(L("移除工作区"), systemImage: "minus.circle") { model.removeWorkspace(workspace.id) }
        }
        .overlay(HubWorkspaceDragBridge(
            workspaceID: workspace.id,
            title: workspace.name.isEmpty ? L("工作区") : model.displayName(for: workspace),
            acceptsReorderDrops: false,
            onSelect: { selectWorkspaceFromClick(workspace.id) },
            onReorder: { source, target, after in model.reorderWorkspace(source, relativeTo: target, after: after) },
            onDragStateChanged: { _ in
                workspaceSpringLoader.cancel()
                hoverTask?.cancel()
                hoveredWorkspace = nil
                workspaceRevealPointer = NSEvent.mouseLocation
            }
        ))
        .onDrop(of: HubWorkspaceFileDropDelegate.contentTypes, delegate: workspaceFileDrop(workspace))
        .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.workspace(workspace.id): $0] }
        .anchorPreference(key: HubHeaderDragRegionKey.self, value: .bounds) { [.tab(workspace.id): $0] }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(workspaceSpringLoader.target == workspace.id ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
    }

    /// Each strip is clipped independently so the notch and hidden tabs never
    /// become reorder targets. Blank space at either end remains usable.
    private func reorderDropBounds(for viewport: CGRect, size: CGSize) -> CGRect {
        var safe = CGRect(origin: .zero, size: size)
        if presentation.header.embedded && presentation.header.split {
            let exclusion = presentation.header.exclusionWidth
            if viewport.midX < size.width / 2 {
                safe.size.width = max(0, (size.width - exclusion) / 2)
            } else {
                safe.origin.x = min(size.width, (size.width + exclusion) / 2)
                safe.size.width = max(0, size.width - safe.minX)
            }
        }
        return viewport.insetBy(dx: -32, dy: -6).intersection(safe)
    }

    private func nativeWorkspaceReorderDrop(regions: [HubFileDropRegion: CGRect], size: CGSize) -> some View {
        let tabs = model.tabWorkspaces
        var frames: [UUID: CGRect] = [:]
        var viewports: [CGRect] = []
        for tab in tabs {
            guard let frame = regions[.workspace(tab.id)], let viewport = regions[.tabViewport(tab.id)] else { continue }
            let visible = frame.intersection(viewport)
            if !visible.isNull && !visible.isEmpty { frames[tab.id] = visible }
            if !viewports.contains(viewport) { viewports.append(viewport) }
        }
        return HubShortcutReorderDropBridge(frames: frames, domain: .workspace,
            enabled: presentation.previewVisible,
            dropBounds: viewports.map { reorderDropBounds(for: $0, size: size) },
            orderedIDs: tabs.map(\.id),
            onHover: { HubWorkspaceDragBridge.autoscrollWorkspace(id: $0) },
            onReorder: { source, target, after in model.reorderWorkspace(source, relativeTo: target, after: after) })
    }

    private func nativeShortcutReorderDrop(regions: HubShortcutReorderRegions, geometry: GeometryProxy) -> some View {
        let viewports = regions.viewports.map { geometry[$0] }
        var frames: [UUID: CGRect] = [:]
        for (id, anchor) in regions.frames {
            let frame = geometry[anchor]
            for viewport in viewports {
                let visible = frame.intersection(viewport)
                if !visible.isNull && !visible.isEmpty { frames[id] = visible; break }
            }
        }
        return HubShortcutReorderDropBridge(frames: frames, domain: .shortcut,
            enabled: presentation.previewVisible,
            dropBounds: viewports.map { reorderDropBounds(for: $0, size: geometry.size) },
            orderedIDs: model.visibleShortcutItems.map(\.dragID),
            onReorder: { source, target, after in model.reorderShortcut(sourceID: source, targetID: target, after: after) })
    }

    /// A single native destination survives spring-loaded navigation. Header
    /// and file cells only publish geometry; neither owns the file session.
    private func nativeFileDrop(regions: [HubFileDropRegion: CGRect], frames: [URL: CGRect], size: CGSize) -> some View {
        // Geometry and ordering belong to the same layout snapshot. Do not
        // locale-sort the directory again for every draggingUpdated event.
        let order = model.fileOrderURLs
        let tabs = model.tabWorkspaces
        let tabFrames = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab -> (UUID, CGRect)? in
            guard let frame = regions[.workspace(tab.id)], let viewport = regions[.tabViewport(tab.id)] else { return nil }
            let visible = frame.intersection(viewport)
            return visible.isNull || visible.isEmpty ? nil : (tab.id, visible)
        })
        let exclusion = presentation.header.embedded && presentation.header.split
            ? CGRect(x: (size.width - presentation.header.exclusionWidth) / 2, y: 0,
                     width: presentation.header.exclusionWidth, height: regions[.header]?.height ?? 0) : nil
        func insertion(at point: CGPoint) -> HubWorkspaceTabInsertion? {
            guard let header = regions[.header], let controls = regions[.headerControls] else { return nil }
            return HubWorkspaceTabInsertion.resolve(at: point, header: header, controls: controls,
                music: regions[.headerMusic], exclusion: exclusion, frames: tabFrames, order: tabs.map(\.id))
        }
        func creationPlan(_ slot: HubWorkspaceTabInsertion, urls: [URL], payload: HubFileDragPayload?) -> HubFileDropPlan? {
            guard model.canOfferFolderWorkspaceDrop(urls, knownFolderURLs: payload?.folderURLs) else { return nil }
            return HubFileDropPlan(workspaceID: nil, directory: nil, item: nil, title: L("新标签"),
                action: .createWorkspace, workspaceInsertion: slot)
        }
        return HubNativeFileDropBridge(enabled: presentation.previewVisible,
            contains: { point in insertion(at: point) != nil || HubFileDropRegion.at(point, in: regions) != nil },
            operation: { point, urls, payload, copy in
                let slot = insertion(at: point).flatMap { model.isKnownNonFolderDrop(urls, knownFolderURLs: payload?.folderURLs) ? nil : $0 }
                let region = slot == nil ? HubFileDropRegion.at(point, in: regions) : nil
                guard slot != nil || region != nil else { clearFileDrop(); return [] }
                presentation.setFileDragActive(true)
                let plan: HubFileDropPlan?
                if let slot { plan = creationPlan(slot, urls: urls, payload: payload) }
                else { plan = region.flatMap {
                    fileDropPlan(region: $0, point: point, frames: frames, content: regions[.content] ?? .zero, order: order, payload: payload, copy: copy, urls: urls)
                } }
                if case .workspace(let id)? = region {
                    workspaceSpringLoader.enter(id, delay: model.settings.switchDelay,
                        canActivate: { presentation.previewVisible && model.workspaces.contains(where: { $0.id == id }) },
                        activate: { if model.selectedWorkspaceID != id { model.selectWorkspace(id) } })
                } else if region == .staging {
                    let id = model.settings.stagingWorkspaceID ?? stagingHoverID
                    workspaceSpringLoader.enter(id, delay: model.settings.switchDelay,
                        canActivate: { model.settings.resolvedStagingEnabled },
                        activate: { if !model.isStagingWorkspace { model.openStagingWorkspace() } })
                } else { workspaceSpringLoader.cancel() }
                if region == .airDrop { hoverTask?.cancel(); hoveredWorkspace = nil; showsAirDropHint = false }
                if stagingDropTargeted != (region == .staging) { stagingDropTargeted = region == .staging }
                let airDropActive = plan?.action == .airDrop
                if airDropTargeted != airDropActive { airDropTargeted = airDropActive }
                let item = region == .content ? plan?.item : nil
                if fileDropTarget != item { fileDropTarget = item }
                let targeted = region == .content && plan != nil
                if dropTargeted != targeted { dropTargeted = targeted }
                let feedback = plan.map { HubFileDropFeedback(rect: $0.workspaceInsertion?.marker ?? $0.slot?.rect ?? $0.item.flatMap { frames[$0] } ?? region?.visibleFrame(in: regions) ?? .zero,
                    title: $0.title, count: urls.count, action: $0.action, insertion: $0.slot != nil || $0.workspaceInsertion != nil) }
                if fileDropFeedback != feedback { fileDropFeedback = feedback }
                return plan?.action == .move || plan?.action == .reorder ? .move : plan == nil ? [] : .copy
            }, exited: clearFileDrop,
            receive: { urls, payload, point, copy in
                if let slot = insertion(at: point), !model.isKnownNonFolderDrop(urls, knownFolderURLs: payload?.folderURLs) { return model.addFolderWorkspaces(urls, before: slot.before) }
                guard let region = HubFileDropRegion.at(point, in: regions),
                      let plan = fileDropPlan(region: region, point: point, frames: frames, content: regions[.content] ?? .zero, order: order, payload: payload, copy: copy, urls: urls) else { return false }
                if plan.action == .airDrop { return queueAirDropFiles(urls) }
                if plan.action == .reorder { model.reorderEntries(urls, before: plan.slot?.before); return true }
                if region == .staging { return model.stageFiles(urls) }
                let accepted = model.acceptFileDrop(urls, workspaceID: plan.workspaceID, directory: plan.directory, copy: copy,
                    insertionOrder: plan.slot == nil ? nil : order, before: plan.slot?.before)
                if !accepted && model.errorMessage == nil { model.errorMessage = L("目标暂时不可用，文件尚未转移。请等待正在进行的操作完成后重试。") }
                return accepted
            })
    }

    private func clearFileDrop() {
        fileDropTarget = nil; fileDropFeedback = nil; dropTargeted = false; stagingDropTargeted = false; airDropTargeted = false
        workspaceSpringLoader.cancel()
    }

    private var canReceiveAirDrop: Bool {
        model.settings.resolvedAirDropEnabled && !model.sharingInProgress &&
            !model.stagingTransferInProgress && model.fileOperationsInProgress == 0 && !HubImportActivity.isBusy
    }

    private func receiveAirDropFiles(_ providers: [NSItemProvider]) -> Bool {
        clearFileDrop()
        return HubAirDropFileDropReceiver.receive(providers: providers,
            canReceive: { canReceiveAirDrop },
            completion: { _ = queueAirDropFiles($0) },
            onError: { model.errorMessage = $0 })
    }

    @discardableResult private func queueAirDropFiles(_ urls: [URL]) -> Bool {
        guard canReceiveAirDrop else { return false }
        let files: [URL]
        do { files = try HubAirDropPolicy.uniqueFiles(urls) }
        catch { model.errorMessage = error.localizedDescription; return false }
        clearFileDrop()
        showsAirDropHint = false
        // Let AppKit finish the native drag and provider batches release their
        // activity tickets before presenting the system sharing window.
        DispatchQueue.main.async {
            guard canReceiveAirDrop else {
                model.errorMessage = L("AirDrop 暂时不可用，请等待文件操作完成后重试。")
                return
            }
            NotificationCenter.default.post(name: Notification.Name("HubAirDropFiles"), object: nil, userInfo: ["urls": files])
        }
        return true
    }

    private func fileDropPlan(region: HubFileDropRegion, point: CGPoint, frames: [URL: CGRect], content: CGRect, order: [URL],
                              payload: HubFileDragPayload?, copy: Bool, urls: [URL]) -> HubFileDropPlan? {
        switch region {
        case .airDrop:
            return HubFileDropPlan.airDrop(urls: urls, allowed: presentation.previewVisible && canReceiveAirDrop)
        case .workspace(let id):
            guard let workspace = model.workspaces.first(where: { $0.id == id }), workspace.mode != .recents else { return nil }
            return HubFileDropPlan(workspaceID: id, directory: workspace.rootURL, item: nil,
                title: model.displayName(for: workspace), action: workspace.mode == .references ? .reference : copy ? .copy : .move)
        case .staging:
            guard model.settings.resolvedStagingEnabled, !model.stagingTransferInProgress else { return nil }
            return HubFileDropPlan(workspaceID: model.settings.stagingWorkspaceID, directory: nil, item: nil, title: L("暂存区"), action: .reference)
        case .content:
            guard let id = model.selectedWorkspaceID, !model.isRecentsRoot else { return nil }
            let hit = frames.first(where: { $0.value.contains(point) })?.key
            let reorder = payload.map { HubFileDragData.shouldReorder($0, in: fileDragContext) } ?? false
            let folder = hit.flatMap { target -> URL? in
                guard !reorder, !model.isReferenceRoot, !model.isStagingRoot, let entry = model.entries.first(where: { $0.url == target && $0.canNavigate }),
                      let frame = frames[target], frame.insetBy(dx: frame.width * 0.24, dy: frame.height * 0.18).contains(point) else { return nil }
                return entry.url
            }
            let reference = model.isReferenceRoot || model.isStagingRoot
            let slot = folder == nil ? HubFileInsertionSlot.resolve(at: point, frames: frames, order: order,
                content: content, horizontal: model.viewMode != .grid || model.settings.horizontalScroll,
                excluding: reorder ? Set(payload?.urls ?? []) : []) : nil
            return HubFileDropPlan(workspaceID: id, directory: reference ? nil : folder ?? model.currentURL,
                item: folder,
                title: folder?.lastPathComponent ?? model.currentURL?.lastPathComponent ?? model.selectedWorkspace.map { model.displayName(for: $0) } ?? L("当前工作区"),
                action: reorder ? .reorder : reference ? .reference : copy ? .copy : .move, slot: slot)
        case .item, .tabViewport, .header, .headerControls, .headerMusic: return nil
        }
    }

    private func workspaceFileDrop(_ workspace: Workspace) -> HubWorkspaceFileDropDelegate {
        HubWorkspaceFileDropDelegate(
            id: workspace.id, loader: workspaceSpringLoader, delay: model.settings.switchDelay,
            canActivate: { presentation.previewVisible && !HubWorkspaceDragState.isDragging && model.workspaces.contains(where: { $0.id == workspace.id }) },
            activate: { if model.selectedWorkspaceID != workspace.id { model.selectWorkspace(workspace.id) } },
            acceptsDrop: workspace.mode != .recents,
            movesFiles: workspace.mode == .folder,
            targeted: { if $0 { presentation.setFileDragActive(true) } },
            receive: { providers in
                guard workspace.mode != .recents else { return false }
                // Releasing on a tab targets its root, never a stale directory
                // retained by the workspace that was visible before the dwell.
                model.selectWorkspace(workspace.id)
                return receiveDrop(providers, destination: workspace.rootURL, reorderLocal: false)
            })
    }

    @ViewBuilder private func workspaceIcon(_ workspace: Workspace) -> some View {
        if let path = workspace.customIconPath {
            HubWorkspaceCustomIcon(path: path, fallbackSymbol: workspace.symbol,
                                   tint: model.selectedWorkspaceID == workspace.id ? .accentColor : .secondary,
                                   isVisible: presentation.previewVisible)
        }
        else { Image(systemName: workspace.symbol.isEmpty ? "folder" : workspace.symbol).foregroundStyle(model.selectedWorkspaceID == workspace.id ? Color.accentColor : Color.secondary) }
    }

    private var browserBar: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", L("后退"), disabled: !model.canGoBack) { model.goBack() }
            iconButton("chevron.right", L("前进"), disabled: !model.canGoForward) { model.goForward() }
            HubPathBar(model: model)
                .frame(minWidth: 40, maxWidth: .infinity)
                .layoutPriority(1)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.isRecentsRoot ? L("搜索最近使用") : L("搜索当前文件夹"), text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 8).padding(.vertical, 6).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).frame(minWidth: 100, maxWidth: 210).layoutPriority(2)
            HStack(spacing: 1) {
                viewButton(.grid, symbol: "square.grid.2x2", label: L("图标视图"))
                viewButton(.list, symbol: "list.bullet", label: L("列表视图"))
                viewButton(.columns, symbol: "rectangle.split.3x1", label: L("分栏视图"))
            }.padding(2).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .animation(interfaceMotion.selection, value: model.viewMode)
                .animation(nil, value: interfaceMotion.enabled)
            Menu {
                Picker(L("排序方式"), selection: $model.sortKey) {
                    Text(L("名称")).tag(SortKey.name); Text(L("种类")).tag(SortKey.kind); Text(L("大小")).tag(SortKey.size)
                    Text(L("修改日期")).tag(SortKey.modified); Text(L("创建日期")).tag(SortKey.created); Text(L("添加日期")).tag(SortKey.added)
                }
                Divider()
                Toggle(L("升序"), isOn: $model.ascending)
                Toggle(L("文件夹优先"), isOn: Binding(get: { model.settings.resolvedFoldersFirst },
                    set: { model.settings.foldersFirst = $0 })).disabled(model.isManualEntryOrder)
                Toggle(L("按手动顺序显示"), isOn: Binding(get: { model.isManualEntryOrder }, set: { model.setManualEntryOrder($0) }))
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(model.isRecentsRoot ? L("按最近使用时间排序") : L("排序"))
                .help(model.isRecentsRoot ? L("最近使用按最近打开时间排列，最新的在前") : L("排序"))
                .disabled(model.isRecentsRoot)
        }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if model.selectedWorkspace == nil {
            VStack(spacing: 15) {
                Image(systemName: "folder.badge.plus").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                Text(L("把常用文件放到触手可及的地方")).font(.system(size: 16, weight: .medium))
                Text(L("添加文件夹，或创建只保存文件引用的合集。")).foregroundStyle(.secondary)
                HStack { Button(L("添加文件夹…")) { model.chooseWorkspace(mode: .folder) }; Button(L("创建合集…")) { model.chooseWorkspace(mode: .references) } }
                Text(L("可通过触发位置、菜单栏或自定义快捷键呼出")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.search.isEmpty ? model.isRecentsRoot ? "clock" : "tray" : "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                Text(emptyTitle).font(.system(size: 14, weight: .medium))
                Text(emptyDetail).foregroundStyle(.secondary)
                if model.search.isEmpty && model.selectedWorkspace?.mode == .references && model.currentURL == nil { Button(L("添加项目…")) { model.addReferences() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.directoryLoading && !activityVisibility.visible ? 0 : 1)
                .animation(interfaceMotion.feedback, value: activityVisibility.visible)
                .contextMenu { backgroundMenu }
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
        if model.directoryLoading { return L("正在读取文件信息…") }
        if model.directoryLoadMessage != nil { return L("暂时无法读取内容") }
        if !model.search.isEmpty { return L("没有匹配的项目") }
        if model.isRecentsRoot { return model.recentFilesLoading ? L("正在读取最近使用…") : L("暂无最近使用的文件") }
        return L("这里还没有项目")
    }

    private var emptyDetail: String {
        if model.directoryLoading { return L("文件读取在后台进行，你可以随时切换工作区。") }
        if model.directoryLoadMessage != nil { return L("请稍后重试，或通过上方标签切换到其他工作区。") }
        if !model.search.isEmpty { return L("试试其他名称") }
        if model.isRecentsRoot { return model.recentFilesMessage ?? L("最近打开的文件会自动出现在这里。结果取决于系统索引。") }
        return model.isReferenceRoot ? L("拖入文件或文件夹以添加引用") : L("拖入文件以移动，按住 ⌥ 键以复制")
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
            HubFileIcon(entry: entry, size: model.settings.iconSize, allowsThumbnail: !model.isCloudPlaceholder(entry),
                        lightweight: presentation.defersFileRendering).opacity(entry.exists ? 1 : 0.4)
            fileName(entry, grid: true)
        }
        .padding(.horizontal, 5).padding(.vertical, 9)
        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .fileNameHoverArea(entry.url.lastPathComponent, enabled: renameEntry?.url != entry.url)
        .contextMenu { fileMenu(entry) }
        .overlay(fileInteraction(for: entry))
        .overlay(dropIndicator(for: entry, beforeOnTop: model.settings.horizontalScroll))
        .onDrop(of: [hubFileDragType, .fileURL, .image, .url], isTargeted: dropBinding(for: entry.url)) { receiveItemDrop($0, entry: entry) }
        .fileSelectionBounds(entry.url)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                listSortColumn(L("名称"), key: .name).frame(maxWidth: .infinity, alignment: .leading)
                listSortColumn(model.isRecentsRoot ? L("最近使用") : L("修改日期"), key: .modified).frame(width: 120)
                listSortColumn(L("种类"), key: .kind).frame(width: 80)
                listSortColumn(L("大小"), key: .size, alignment: .trailing).frame(width: 66)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 7).background(Color.primary.opacity(0.025))
            ScrollView(.vertical, showsIndicators: model.settings.showScrollbar) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 9) {
                            HubFileIcon(entry: entry, size: 22, allowsThumbnail: false, lightweight: presentation.defersFileRendering)
                            fileName(entry)
                            Text((model.isRecentsRoot ? model.lastUsedDate(for: entry.url) : entry.modified)?.formatted(.dateTime.locale(locale).year().month(.abbreviated).day().hour().minute()) ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            Text(model.isCloudPlaceholder(entry) ? L("仅在云端") : entry.kind).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(width: 80, alignment: .leading)
                            Text(entry.isDirectory || model.isCloudPlaceholder(entry) ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.025), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .fileNameHoverArea(entry.url.lastPathComponent, enabled: renameEntry?.url != entry.url)
                        .contextMenu { fileMenu(entry) }
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

    private func listSortColumn(_ title: String, key: SortKey, alignment: Alignment = .leading) -> some View {
        let active = !model.isRecentsRoot && !model.isManualEntryOrder && model.sortKey == key
        return Button { model.sortByColumn(key) } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 8).opacity(active ? 1 : 0)
            }.frame(maxWidth: .infinity, alignment: alignment).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isRecentsRoot)
            .accessibilityLabel(L("按\(title)排序"))
            .accessibilityValue(active ? model.ascending ? L("升序") : L("降序") : L("未排序"))
            .help(model.isRecentsRoot ? L("最近使用按最近打开时间排列") : L("按\(title)排序，再次点击切换升降序"))
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
                                    ForEach(parentDirectory.entries) { entry in
                                        let url = entry.url
                                        Button { model.navigate(to: url) } label: {
                                            HStack(spacing: 7) { HubFileIcon(entry: entry, size: 18, allowsThumbnail: false, lightweight: presentation.defersFileRendering); Text(entry.name).lineLimit(1).fileNameTooltip(entry.url.lastPathComponent, displayName: entry.name, fontSize: model.settings.fontSize); Spacer(); Image(systemName: "chevron.right").font(.system(size: 8)) }.padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
                                                .background(url == current ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain).fileNameHoverArea(entry.url.lastPathComponent)
                                    }
                                }.padding(5)
                            }
                            if let message = parentDirectory.message {
                                Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
                            }
                        }.frame(width: layout.parentWidth)
                            .task(id: parent.path) { parentDirectory.load(parent) }
                            .onDisappear { parentDirectory.clear() }
                        Divider().frame(width: layout.separatorWidth)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.currentURL?.lastPathComponent ?? model.selectedWorkspace.map { model.displayName(for: $0) } ?? L("项目")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(10)
                        Divider()
                        ScrollView(showsIndicators: model.settings.showScrollbar) {
                            LazyVStack(spacing: 1) {
                                ForEach(model.visibleEntries) { entry in
                                    HStack(spacing: 7) {
                                        HubFileIcon(entry: entry, size: 20, allowsThumbnail: false, lightweight: presentation.defersFileRendering)
                                        fileName(entry)
                                        Spacer()
                                        if entry.isDirectory && !entry.isPackage { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 9).padding(.vertical, 6)
                                        .background(model.selectedIDs.contains(entry.url) ? Color.accentColor.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                                        .fileNameHoverArea(entry.url.lastPathComponent, enabled: renameEntry?.url != entry.url)
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
                            Text(L("选择文件以预览"))
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
                        .fileNameTooltip(entry.url.lastPathComponent, displayName: entry.name, fontSize: 11)
                    Text(model.isCloudPlaceholder(entry) ? L("仅在云端") : entry.isDirectory ? entry.kind : "\(entry.kind) · \(entry.sizeText)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { preview([entry.url]) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help(L("在独立窗口快速查看")).accessibilityLabel(L("放大预览")).disabled(!entry.exists || model.isCloudPlaceholder(entry) || HubInlinePreviewPolicy.isExecutableBundle(entry.url))
                Button { model.openExternally(entry.url) } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help(L("在默认应用中打开")).accessibilityLabel(L("打开文件")).disabled(!model.canOpen(entry))
            }.padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            switch HubInlinePreviewPolicy.disposition(for: candidate) {
            case .file(let identity):
                HubInlinePreview(item: presentation.previewVisible ? identity : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .application:
                VStack(spacing: 12) {
                    HubFileIcon(entry: entry, size: 96, allowsThumbnail: false, lightweight: presentation.defersFileRendering)
                    Text(entry.name).font(.headline).lineLimit(2)
                        .fileNameTooltip(entry.url.lastPathComponent, displayName: entry.name, fontSize: 13, lines: 2)
                    Text(L("应用程序")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .directory:
                previewPlaceholder("folder", title: entry.name, detail: L("在左侧选择文件以预览内容"))
            case .unavailable:
                if model.isCloudPlaceholder(entry) {
                    previewPlaceholder("icloud.and.arrow.down", title: L("文件尚未下载"), detail: L("点击右上角打开文件，由系统下载后查看"))
                } else {
                    previewPlaceholder("doc.badge.ellipsis", title: L("文件暂时不可用"), detail: L("文件可能已移动，或当前无法访问"))
                }
            case .empty:
                previewPlaceholder("doc.text.magnifyingglass", title: L("选择文件以预览"), detail: "")
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
            iconButton("arrow.up", L("上一级"), disabled: !model.canGoUp) { model.goUp() }
            Text(model.currentLocationDescription)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.currentURL?.path ?? (model.isRecentsRoot ? L("最近使用不接收文件拖入，原文件保留在原位置") : ""))
            Spacer(minLength: 6)
            Text(model.selectedIDs.isEmpty ? L("\(model.visibleEntries.count) 个项目") : L("已选 \(model.selectedIDs.count) / \(model.visibleEntries.count)")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            iconButton("arrow.clockwise", L("刷新")) { model.refresh() }
            Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin").foregroundStyle(model.pinned ? Color.accentColor : Color.secondary).frame(width: 24, height: 23) }.buttonStyle(.plain).help(model.pinned ? L("取消固定") : L("固定窗口"))
            iconButton("gearshape", L("设置")) { onSettings() }
        }.padding(.horizontal, 13).padding(.vertical, 7)
    }

    @ViewBuilder private var backgroundMenu: some View {
        if model.canPasteFiles { HubMenuButton(L("粘贴"), systemImage: "doc.on.clipboard") { model.pasteFiles() } }
        if model.currentURL != nil { HubMenuButton(L("新建文件夹…"), systemImage: "folder.badge.plus") { folderName = L("新建文件夹"); newFolder = true }; HubMenuButton(L("在访达中打开"), systemImage: "folder") { if let url = model.currentURL { NSWorkspace.shared.open(url) } } }
        if let directory = model.currentURL { HubMenuButton(L("在终端中打开"), systemImage: "terminal") { model.openTerminal(at: directory) } }
        if model.selectedWorkspace?.mode == .references && model.currentURL == nil { HubMenuButton(L("添加项目…"), systemImage: "plus") { model.addReferences() } }
        HubMenuButton(L("刷新"), systemImage: "arrow.clockwise") { model.refresh() }
    }

    @ViewBuilder private func fileMenu(_ entry: FileEntry) -> some View {
        let urls = model.selectedIDs.contains(entry.url) && model.selectedIDs.count > 1 ? model.selectedURLs : [entry.url]
        let busy = model.stagingTransferInProgress || model.sharingInProgress || model.fileOperationsInProgress > 0
        HubMenuButton(L("打开"), systemImage: "arrow.up.forward.square") { if urls.count == 1 { model.open(entry) } else { urls.forEach { NSWorkspace.shared.open($0) } } }
        if !entry.isDirectory || entry.isPackage {
            Menu(L("打开方式")) {
                ForEach(NSWorkspace.shared.urlsForApplications(toOpen: entry.url), id: \.self) { application in
                    Button { NSWorkspace.shared.open([entry.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) } label: { Text(application.deletingPathExtension().lastPathComponent) }
                }
                Button(L("其他应用…")) { chooseApplication(for: entry.url) }
            }
        }
        HubMenuButton(L("快速查看"), systemImage: "eye") { preview(urls) }.disabled(HubInlinePreviewPolicy.quickLookURLs(urls).isEmpty)
        HubMenuButton(L("在访达中显示"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        HubMenuButton(L("显示简介"), systemImage: "info.circle") { model.performFinderAction(.information, urls: urls) }.disabled(busy || urls.count > 20)
        if urls.count == 1 { HubMenuButton(L("重新命名…"), systemImage: "pencil") { beginRename(entry) }.disabled(model.isStagingRoot && model.stagingTransferInProgress) }
        Divider()
        HubMenuButton(L("压缩"), systemImage: "archivebox") { model.performFinderAction(.compress, urls: urls) }.disabled(busy)
        HubMenuButton(HubFinderAction.duplicateMenuTitle, systemImage: "plus.square.on.square") { model.performFinderAction(.duplicate, urls: urls) }.disabled(busy)
        HubMenuButton(L("制作替身"), systemImage: "arrowshape.turn.up.right") { model.performFinderAction(.alias, urls: urls) }.disabled(busy)
        Divider()
        HubMenuButton(L("拷贝"), systemImage: "doc.on.doc") { model.copyFiles(urls) }
        HubMenuButton(L("复制路径"), systemImage: "link") { model.copyPath(urls) }
        if model.settings.resolvedStagingEnabled && !model.isStagingRoot {
            HubMenuButton(L("添加到暂存区"), systemImage: "tray.and.arrow.down") { model.stageFiles(urls) }
                .disabled(model.stagingTransferInProgress)
        }
        if model.isStagingRoot {
            HubMenuButton(L("复制到文件夹…"), systemImage: "doc.on.doc") { model.chooseStagingTransfer(copy: true, urls: urls) }
                .disabled(model.stagingTransferInProgress)
            HubMenuButton(L("移动到文件夹…"), systemImage: "folder") { model.chooseStagingTransfer(copy: false, urls: urls) }
                .disabled(model.stagingTransferInProgress)
        }
        HubMenuButton(L("共享…"), systemImage: "square.and.arrow.up") { NotificationCenter.default.post(name: Notification.Name("HubShare"), object: nil, userInfo: ["urls": urls]) }
            .disabled(model.sharingInProgress || model.stagingTransferInProgress || model.fileOperationsInProgress > 0)
        if model.settings.resolvedAirDropEnabled {
            HubMenuButton("AirDrop…", systemImage: "airplayaudio") { NotificationCenter.default.post(name: Notification.Name("HubAirDrop"), object: nil, userInfo: ["urls": urls]) }
            .disabled(model.sharingInProgress || model.stagingTransferInProgress || model.fileOperationsInProgress > 0)
        }
        Divider()
        Menu(L("颜色标签")) {
            ForEach(HubFinderLabel.colors) { label in
                Button { model.performFinderAction(.label(label.rawValue), urls: urls) } label: {
                    Label { Text(label.name) } icon: { Image(nsImage: label.menuIcon(selected: urls.count == 1 && entry.labelNumber == label.rawValue)) }
                }
            }
            Divider()
            Button(L("移除颜色标签")) { model.performFinderAction(.label(0), urls: urls) }
        }.disabled(busy)
        if urls.count == 1 && entry.canNavigate {
            HubMenuButton(L("自定义文件夹…"), systemImage: "paintpalette") { folderStyleEntry = entry }.disabled(busy)
        }
        if urls.count == 1 {
            HubMenuButton(L("在终端中打开"), systemImage: "terminal") { model.openTerminal(at: entry.canNavigate ? entry.url : entry.url.deletingLastPathComponent()) }
        }
        if model.selectedWorkspace?.mode == .references && model.currentURL == nil {
            Divider()
            if let paths = model.selectedWorkspace?.referencePaths, let index = paths.firstIndex(of: entry.url.path) {
                HubMenuButton(L("向前移动"), systemImage: "arrow.left") { if index > 0 { model.reorderReference(entry.url, before: URL(fileURLWithPath: paths[index - 1])) } }.disabled(index == 0)
                HubMenuButton(L("向后移动"), systemImage: "arrow.right") { if index + 1 < paths.count { model.reorderReference(URL(fileURLWithPath: paths[index + 1]), before: entry.url) } }.disabled(index + 1 >= paths.count)
            }
            HubMenuButton(model.isStagingRoot ? L("从暂存区移除引用") : L("从合集中移除引用"), systemImage: "minus.circle") { model.removeReferences(urls) }
                .disabled(model.isStagingRoot && model.stagingTransferInProgress)
        }
        if !model.isStagingRoot {
            Divider()
            HubMenuButton(L("移到废纸篓…"), systemImage: "trash", role: .destructive) { pendingTrash = urls }
        }
    }

    private func fileInteraction(for entry: FileEntry, navigateOnClick: Bool = false) -> some View {
        HubFileDragBridge(entryURL: entry.url, context: fileDragContext,
                          interactionEnabled: renameEntry?.url != entry.url,
                          selectedURLs: { model.selectedURLs }, folderURLsForDrag: { model.folderURLsForDrag($0, including: entry) },
                          selectEntry: { selectForDrag(entry) },
                          onClick: { flags in
                              select(entry, flags: flags)
                              if navigateOnClick && entry.isDirectory && !entry.isPackage { model.navigate(to: entry.url) }
                          }, onOpen: { model.open(entry) }, onTrash: { model.trashDraggedFiles($0) })
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
    private func chooseApplication(for url: URL) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = L("打开")
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
        if fileDropFeedback == nil && !model.isRecentsRoot && fileDropTarget == entry.url {
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
        if model.isStagingRoot { return receiveStagingDrop(providers) }
        if model.isReferenceRoot { return receiveDrop(providers, destination: nil, reorderLocal: false) }
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
        guard fileProviders.count <= 20000, let ticket = HubImportActivity.begin() else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        let workspaceID = model.selectedWorkspaceID
        let batch = HubDropBatch(count: fileProviders.count) { urls in
            HubImportActivity.end(ticket)
            guard !urls.isEmpty else { model.errorMessage = L("无法读取拖入的文件地址。"); return }
            if !model.acceptFileDrop(urls, workspaceID: workspaceID, directory: destination, copy: copy) {
                model.errorMessage = L("目标工作区已不可用，或已有多个文件传输正在进行。")
            }
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
                model.errorMessage = L("暂存区当前不可用。导入的文件已保留，请重新开启暂存区后添加。")
            } else if !failures.isEmpty {
                model.errorMessage = failures.joined(separator: "\n")
            }
        }
    }
    private func receiveImageDrop(_ providers: [NSItemProvider], destination: URL?) -> Bool {
        let workspaceID = model.selectedWorkspaceID
        // One bounded importer handles images, SVG, promises and web images.
        // As with native files, collection roots accept references to imported
        // content and a captured folder remains the target after navigation.
        return HubStagingDropReceiver.receive(providers) { urls, failures in
            if !urls.isEmpty, !model.acceptFileDrop(urls, workspaceID: workspaceID, directory: destination, copy: true) {
                model.errorMessage = L("目标工作区已不可用。导入内容已保留在本机暂存目录。")
            } else if !failures.isEmpty { model.errorMessage = failures.joined(separator: "\n") }
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
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 23, height: 23) }
            .buttonStyle(HubToolbarButtonStyle()).disabled(disabled).help(help)
    }
    private func viewButton(_ mode: HubViewMode, symbol: String, label: String) -> some View {
        Button { if model.viewMode != mode { model.viewMode = mode } } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22)
                .background(HubSelectionBackdrop(selected: model.viewMode == mode, namespace: viewModeSelection, cornerRadius: 4))
        }.buttonStyle(HubToolbarButtonStyle()).help(label)
    }
    private func beginRename(_ entry: FileEntry) {
        guard renameEntry == nil, extensionRename == nil, !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging,
              !(model.isStagingRoot && model.stagingTransferInProgress) else { return }
        model.selectedIDs = [entry.url]
        hoverTask?.cancel(); hoveredWorkspace = nil
        renameName = entry.url.lastPathComponent
        renameSessionID = UUID()
        renameEntry = entry
    }

    private func fileName(_ entry: FileEntry, grid: Bool = false) -> some View {
        let editing = renameEntry?.url == entry.url
        let context = fileDragContext, mode = model.viewMode, session = renameSessionID
        return Text(entry.name).font(.system(size: model.settings.fontSize))
            .lineLimit(grid ? 2 : 1).multilineTextAlignment(grid ? .center : .leading)
            .fileNameTooltip(entry.url.lastPathComponent, displayName: entry.name, fontSize: model.settings.fontSize, lines: grid ? 2 : 1, enabled: !editing)
            .frame(maxWidth: .infinity, minHeight: grid ? 29 : nil, alignment: grid ? .top : .leading)
            .opacity(editing ? 0 : 1).accessibilityHidden(editing)
            .overlay {
                if editing {
                    HubInlineFileNameEditor(name: renameName, isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                                            fontSize: model.settings.fontSize, centered: grid,
                                            onCommit: { name in
                                                guard renameSessionID == session else { return }
                                                guard fileDragContext == context, model.viewMode == mode else { renameEntry = nil; return }
                                                finishRename(name, entry: entry)
                                            }, onCancel: { if renameSessionID == session { renameEntry = nil } })
                        .id(session)
                }
            }
    }

    private func finishRename(_ name: String, entry: FileEntry) {
        guard renameEntry?.url == entry.url else { return }
        renameEntry = nil
        guard model.selectedIDs == [entry.url], !(model.isStagingRoot && model.stagingTransferInProgress) else { return }
        guard name != entry.url.lastPathComponent else { return }
        do { try HubFileOperations.validateName(name) }
        catch { model.errorMessage = error.localizedDescription; return }
        if HubFileNameEditing.changesExtension(from: entry.url.lastPathComponent, to: name, isDirectory: entry.isDirectory, isPackage: entry.isPackage) {
            extensionRename = (entry, name)
        } else { model.rename(entry, to: name) }
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
        if let action = HubClipboardShortcut.resolve(keyCode: event.keyCode, modifiers: flags) {
            switch action {
            case .copy: model.copySelectedFiles()
            case .copyPaths: model.copySelectedPaths()
            case .paste: model.pasteFiles()
            }
            return true
        }
        if let action = HubFinderAction.shortcut(keyCode: event.keyCode, modifiers: flags), !model.selectedURLs.isEmpty {
            model.performFinderAction(action, urls: model.selectedURLs); return true
        }
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
        if command && flags.contains(.shift) && event.charactersIgnoringModifiers == "n" { folderName = L("新建文件夹"); newFolder = true; return true }
        if flags.contains(.option) && !command && event.keyCode == 123 { model.goBack(); return true }
        if flags.contains(.option) && !command && event.keyCode == 124 { model.goForward(); return true }
        guard !command && !flags.contains(.control) && !flags.contains(.option) else { return false }
        if event.keyCode == 49 { if !model.selectedURLs.isEmpty { preview(model.selectedURLs) }; return true }
        if [36, 76].contains(event.keyCode), !flags.contains(.shift) {
            if model.selectedIDs.count == 1, let entry = model.selectedEntries.first { beginRename(entry) }
            return true
        }
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

struct HubKeyMonitor: NSViewRepresentable {
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
                    guard let self else { return event }
                    return self.route(event)
                }
            }
        }
        func route(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if HubInlinePreviewFocus.contains(window.firstResponder) { return event }
            if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
            return handler?(event) == true ? nil : event
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
            Text(L("编辑工作区")).font(.title3.bold())
            HStack(spacing: 12) {
                if let path = workspace.customIconPath { HubWorkspaceCustomIcon(path: path, fallbackSymbol: workspace.symbol, tint: .accentColor).frame(width: 36, height: 36) } else { Image(systemName: workspace.symbol).font(.system(size: 30)).foregroundStyle(Color.accentColor).frame(width: 42) }
                TextField(L("工作区名称"), text: $workspace.name).textFieldStyle(.roundedBorder)
            }
            Text(workspace.mode == .folder ? L("文件夹：\(workspace.rootPath ?? L("未选择"))") : workspace.mode == .recents ? L("最近使用 · 自动更新最近打开的文件") : L("文件与文件夹合集 · \(workspace.referencePaths.count) 个引用")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField(L("搜索图标名称，或直接输入 SF Symbol 名称"), text: $symbolSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 9) {
                    ForEach(symbols.filter { symbolSearch.isEmpty || $0.localizedCaseInsensitiveContains(symbolSearch) }, id: \.self) { symbol in
                        Button { workspace.symbol = symbol; workspace.customIconPath = nil } label: { Image(systemName: symbol).font(.system(size: 19)).frame(width: 36, height: 32).background(workspace.symbol == symbol && workspace.customIconPath == nil ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).help(symbol)
                    }
                }
            }.frame(height: 165)
            HStack {
                Button(L("自定义图片…")) { chooseImage() }
                if !symbolSearch.isEmpty, NSImage(systemSymbolName: symbolSearch, accessibilityDescription: nil) != nil { Button(L("使用此符号")) { workspace.symbol = symbolSearch; workspace.customIconPath = nil } }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { workspace.name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines); model.updateWorkspace(workspace); dismiss() }.keyboardShortcut(.defaultAction).disabled(workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workspace.symbol.isEmpty && workspace.customIconPath == nil)
            }
        }.padding(24).frame(width: 460)
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        if HubWindowPresentation.runModal(panel) == .OK, let url = panel.url { workspace.customIconPath = url.path }
    }
}
