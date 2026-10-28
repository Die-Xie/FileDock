import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum HubSettingsPage: String, CaseIterable, Identifiable {
    case general, activation, files, appearance, shortcuts, music, about
    var id: Self { self }
    var sidebarTitle: String { self == .files ? L("文件") : title }
    var title: String {
        switch self {
        case .general: return L("通用")
        case .activation: return L("呼出与交互")
        case .files: return L("文件与工作区")
        case .appearance: return L("外观")
        case .shortcuts: return L("快捷键")
        case .music: return L("音乐")
        case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .activation: return "cursorarrow.motionlines"
        case .files: return "folder"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .music: return "music.note"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("启动、菜单栏与配置备份")
        case .activation: return L("决定面板何时出现、切换与收起")
        case .files: return L("右上角入口与文件浏览偏好")
        case .appearance: return L("主题、内容尺寸与界面动效")
        case .shortcuts: return L("全局呼出快捷键与文件操作速查")
        case .music: return L("播放器选择、连接与授权")
        case .about: return L("版本、软件更新与使用说明")
        }
    }
}

@MainActor
struct HubSettingsView: View {
    @ObservedObject var model: HubModel
    // The music page observes its controller locally. Progress polls must not
    // invalidate unrelated settings pages or the sidebar.
    let music: HubQQMusicController
    @ObservedObject var updater: FileDockUpdater
    @State private var selectedPage: HubSettingsPage?
    private enum ApplicationList { case blocked, allowed }
    @State private var blockedApplicationError: String?
    @State private var allowedApplicationError: String?
    @State private var switchDelayDraft: Double?
    @State private var hoverDelayDraft: Double?
    @State private var autoHideDelayDraft: Double?
    @State private var notchEntryThresholdDraft: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: HubModel, music: HubQQMusicController, updater: FileDockUpdater, page: HubSettingsPage = .general) {
        self.model = model; self.music = music; self.updater = updater
        _selectedPage = State(initialValue: page)
    }
    private var page: HubSettingsPage { selectedPage ?? .general }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("FileDock").font(.headline).padding(.horizontal, 18).padding(.top, 20)
                List(HubSettingsPage.allCases, selection: $selectedPage) { item in
                    Label(item.sidebarTitle, systemImage: item.symbol)
                        .padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar).accessibilityLabel(L("设置分类"))
                Divider()
                Button {
                    commitInteractionEdits()
                    NSApp.terminate(nil)
                } label: {
                    Label(L("退出 FileDock"), systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                }.buttonStyle(.plain).padding(.horizontal, 18).padding(.bottom, 14)
                    .accessibilityIdentifier("filedock.settings.quit")
                    .help(L("退出应用；进行中的文件传输完成后退出"))
            }.frame(width: 166)
                .background(Color.primary.opacity(0.025))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.title2.bold())
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageContent
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.id(page)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 780, height: 600)
            .environment(\.locale, model.settings.resolvedLanguage.locale)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.hubInterfaceMotion, HubInterfaceMotion(enabled: !reduceMotion, speed: model.settings.resolvedAnimationSpeed))
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HubSelectMusicSettings"))) { _ in selectedPage = .music }
            .onChange(of: selectedPage) { _ in commitInteractionEdits() }
            .onDisappear { commitInteractionEdits() }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: general
        case .activation: activation
        case .files: files
        case .appearance: appearance
        case .shortcuts: shortcuts
        case .music: musicSettings
        case .about: about
        }
    }
    private var general: some View {
        Group {
            section(L("语言")) {
                settingsRow(L("界面语言")) {
                    Picker(L("界面语言"), selection: Binding(get: { model.settings.resolvedLanguage }, set: { model.settings.language = $0.rawValue })) {
                        ForEach(HubLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.labelsHidden().frame(width: 200)
                        .accessibilityIdentifier("filedock.settings.language")
                }
                note(L("中文与 English 可随时切换，立即生效。文件名和自定义工作区名称保持原样。"))
            }
            section(L("启动与常驻")) {
                Toggle(L("登录时启动"), isOn: Binding(get: { model.settings.launchAtLogin }, set: { enabled in
                    NotificationCenter.default.post(name: Notification.Name("HubLaunchAtLogin"), object: nil, userInfo: ["enabled": enabled])
                }))
                Toggle(L("在菜单栏显示图标"), isOn: $model.settings.showMenuBarIcon)
                note(L("登录启动需要系统许可时，可前往「系统设置 → 通用 → 登录项」确认。"))
            }
            section(L("配置备份")) {
                note(L("备份工作区与偏好设置，导入后替换当前配置。文件内容不会包含在备份中。"))
                HStack(spacing: 10) {
                    Button(L("导出配置…")) { model.exportConfiguration() }
                    Button(L("导入配置…")) { model.importConfiguration() }
                }
            }
        }
    }
    private var activation: some View {
        Group {
            section(L("呼出方式")) {
                settingsRow(L("触发方式")) {
                    Picker(L("触发方式"), selection: $model.settings.triggerMode) {
                        Text(L("鼠标与快捷键")).tag("both"); Text(L("仅鼠标")).tag("hover"); Text(L("仅快捷键")).tag("keyboard")
                    }.labelsHidden().frame(width: 200)
                }
                settingsRow(L("鼠标触发位置")) {
                    Picker(L("鼠标触发位置"), selection: $model.settings.hotCorner) {
                        Text(L("刘海 / 屏幕顶部中央")).tag("notch"); Text(L("左上角")).tag("topLeft"); Text(L("右上角")).tag("topRight"); Text(L("左下角")).tag("bottomLeft"); Text(L("右下角")).tag("bottomRight")
                    }.labelsHidden().frame(width: 200)
                }.disabled(model.settings.triggerMode == "keyboard")
                if model.settings.hotCorner == "notch" {
                    Toggle(L("点按刘海呼出"), isOn: Binding(get: { model.settings.notchClickToWake ?? false }, set: { model.settings.notchClickToWake = $0 }))
                        .disabled(model.settings.triggerMode == "keyboard")
                    note(L("关闭后使用悬停呼出。"))
                    VStack(alignment: .leading, spacing: 7) {
                        settingsRow(L("鼠标进入比例")) {
                            Text(notchEntryThreshold.wrappedValue, format: .percent.precision(.fractionLength(0...1)))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Button(L("恢复 75%")) { notchEntryThreshold.wrappedValue = 0.75 }
                                .font(.caption)
                        }
                        Slider(value: notchEntryThreshold, in: 0.01...2, onEditingChanged: { editing in
                            if editing { notchEntryThresholdDraft = model.settings.resolvedNotchEntryThreshold }
                            else { commitInteractionEdits() }
                        }).accessibilityLabel(L("鼠标进入比例"))
                            .accessibilityValue(Text(notchEntryThreshold.wrappedValue, format: .percent.precision(.fractionLength(0...1))))
                            .accessibilityIdentifier("filedock.settings.notch-entry-threshold")
                        note(L("1%–100% 按鼠标可见面积判定；超过 100% 须完全进入后继续向上深入，200% 需到屏幕顶边。达到后才开始计时或响应点击，仅对真实刘海生效。"))
                    }.disabled(model.settings.triggerMode == "keyboard")
                    Divider()
                    Toggle(L("拖到刘海时阻止进入调度中心"), isOn: Binding(
                        get: { model.settings.resolvedBlockMissionControlAtNotch },
                        set: { model.settings.blockMissionControlAtNotch = $0 }))
                        .disabled(model.settings.triggerMode == "keyboard")
                        .accessibilityIdentifier("filedock.settings.notch-drag-guard")
                    note(L("仅过滤真实刘海顶边的拖动；其他位置、快捷键和触控板手势保持原样。需要辅助功能权限，全屏与应用限制期间暂停。"))
                    if model.settings.resolvedBlockMissionControlAtNotch && model.settings.triggerMode != "keyboard" {
                        HubNotchDragGuardStatusView()
                    }
                }
                Toggle(L("在副显示器上启用触发区域"), isOn: $model.settings.secondaryScreens)
                    .disabled(model.settings.triggerMode == "keyboard")
                note(L("全局快捷键可在左侧「快捷键」中配置。"))
            }
            section(L("延迟与切换")) {
                delayEditor(L("悬停后展开"), value: hoverMilliseconds, range: 0...1500,
                            detail: L("0 ms 表示立即展开；点按呼出时不使用此延迟。"), onEditingChanged: { editing in
                                if editing { hoverDelayDraft = model.settings.hoverDelay }
                                else { commitInteractionEdits() }
                            })
                    .disabled(model.settings.triggerMode == "keyboard" || model.settings.usesNotchClickToWake)
                Divider()
                delayEditor(L("鼠标移开后收起"), value: autoHideMilliseconds, range: 0...3000,
                            detail: L("返回面板会取消收起；已固定的面板保持显示。"), onEditingChanged: { editing in
                                if editing { autoHideDelayDraft = model.settings.resolvedAutoHideDelay }
                                else { commitInteractionEdits() }
                            })
                Divider()
                delayEditor(L("悬停切换工作区"), value: Binding(get: { switchDelay.wrappedValue * 1000 }, set: { switchDelay.wrappedValue = $0 / 1000 }), range: 0...1500,
                            detail: L("0 ms 关闭普通悬停切换；拖着文件时仍可悬停跳转。"), onEditingChanged: { editing in
                                if editing { switchDelayDraft = model.settings.switchDelay }
                                else { commitInteractionEdits() }
                            })
            }
            section(L("全屏与应用限制")) {
                Toggle(L("全屏时限制自动展开"), isOn: Binding(get: { model.settings.resolvedSuppressHoverInFullScreen }, set: { model.settings.suppressHoverInFullScreen = $0 }))
                HStack {
                    Text(L("限制期间的打开方式"))
                    Spacer()
                    Picker(L("限制期间的打开方式"), selection: Binding(get: { model.settings.resolvedClickWakeWhenSuppressed }, set: { model.settings.clickWakeWhenSuppressed = $0 })) {
                        Text(L("仅用快捷键或菜单栏")).tag(false)
                        Text(L("点击触发区域打开")).tag(true)
                    }.labelsHidden().frame(width: 245)
                }
                note(L("全屏或应用规则限制生效时，暂停悬停展开。可选择点击当前刘海或边角打开，退出限制后自动恢复。全局快捷键和菜单栏仍可使用；「仅快捷键」模式保持不变。"))
                Divider()
                DisclosureGroup(L("限制自动展开的应用（\(model.settings.resolvedBlockedApplicationBundleIDs.count)）")) {
                    VStack(alignment: .leading, spacing: 12) {
                        note(L("这些应用在前台时，也使用上方选择的打开方式。"))
                        ForEach(model.settings.resolvedBlockedApplicationBundleIDs, id: \.self) { applicationRow($0, list: .blocked) }
                        HStack {
                            Button(L("添加应用…")) { chooseApplications(.blocked) }
                            Menu(L("正在运行的应用")) {
                                ForEach(runningApplications, id: \.processIdentifier) { app in
                                    if let bundleID = app.bundleIdentifier {
                                        Button(app.localizedName ?? bundleID) { addApplications([bundleID], list: .blocked) }
                                            .disabled(model.settings.resolvedBlockedApplicationBundleIDs.contains(bundleID))
                                    }
                                }
                                if runningApplications.isEmpty { Text(L("没有可添加的应用")) }
                            }.fixedSize()
                        }
                        if let blockedApplicationError { Text(blockedApplicationError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.top, 10)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("白名单（\(model.settings.resolvedAllowedApplicationBundleIDs.count)）")).font(.subheadline.weight(.medium))
                    note(L("白名单中的应用即使全屏也允许正常鼠标触发；未加入的应用继续遵守现有规则。"))
                    ForEach(model.settings.resolvedAllowedApplicationBundleIDs, id: \.self) { applicationRow($0, list: .allowed) }
                    HStack {
                        Button(L("添加应用…")) { chooseApplications(.allowed) }
                        Menu(L("正在运行的应用")) {
                            ForEach(runningApplications, id: \.processIdentifier) { app in
                                if let bundleID = app.bundleIdentifier {
                                    Button(app.localizedName ?? bundleID) { addApplications([bundleID], list: .allowed) }
                                        .disabled(model.settings.resolvedAllowedApplicationBundleIDs.contains(bundleID))
                                }
                            }
                            if runningApplications.isEmpty { Text(L("没有可添加的应用")) }
                        }.fixedSize()
                    }
                    note(L("同一应用同时出现在黑名单与白名单时，以黑名单为准。白名单不改变触发位置或悬停／点按方式。"))
                    if let allowedApplicationError { Text(allowedApplicationError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
    private var files: some View {
        Group {
            section(L("右上角快捷入口")) {
                Toggle(L("收藏"), isOn: Binding(get: { model.settings.resolvedFavoriteShortcutEnabled }, set: { model.setFavoriteShortcutVisible($0) }))
                Toggle(L("最近使用"), isOn: Binding(get: { model.settings.resolvedRecentShortcutEnabled }, set: { model.setRecentShortcutVisible($0) }))
                Toggle(L("文件暂存区"), isOn: Binding(get: { model.settings.resolvedStagingEnabled }, set: { model.setStagingEnabled($0) }))
                Toggle("AirDrop", isOn: Binding(get: { model.settings.resolvedAirDropEnabled }, set: { model.settings.airDropEnabled = $0 }))
                note(L("与面板「＋」菜单同步。关闭入口保留收藏和暂存内容；拖动已显示的图标可调整顺序。"))
            }
            section(L("浏览与排序")) {
                Toggle(L("显示隐藏文件"), isOn: $model.showHiddenFiles)
                Toggle(L("排序时文件夹优先"), isOn: Binding(get: { model.settings.resolvedFoldersFirst }, set: { model.settings.foldersFirst = $0 }))
                note(L("关闭文件夹优先后，文件与文件夹按同一列混排。手动顺序和最近使用不受影响。"))
            }
            section(L("拖放文件")) {
                Toggle(L("拖出文件时自动收起面板"), isOn: Binding(get: { model.settings.resolvedHideOnFileDragExit }, set: { model.settings.hideOnFileDragExit = $0 }))
                note(L("拖出文件后按收起延迟隐藏面板，固定状态保留。计时期间返回面板会取消收起；收起后拖回刘海或当前设置的边角，会按展开延迟重新展开，点按唤醒模式也适用。延迟在「呼出与交互」中设置。"))
                Divider()
                Label(L("拖入文件夹：移动；按住 ⌥：复制"), systemImage: "folder")
                Label(L("拖入收藏或暂存：添加引用"), systemImage: "link")
                Label(L("文件夹拖到标签间隙：新建标签"), systemImage: "folder.badge.plus")
                Label(L("拖到 AirDrop：选择接收设备并发送"), systemImage: "airplayaudio")
                Label(L("拖到系统废纸篓：移除原文件"), systemImage: "trash")
                note(L("从顶栏空白处拖出面板会自动固定；文件区用于选择与拖放文件。"))
            }
        }
    }
    private var musicSettings: some View {
        Group {
            section(L("音乐控制")) {
                Toggle(L("显示音乐控制"), isOn: Binding(get: { model.settings.resolvedQQMusicEnabled }, set: { model.settings.qqMusicEnabled = $0 }))
                note(L("嵌入模式显示歌曲信息，悬停后控制播放；其他模式显示底部播放栏。"))
            }
            if model.settings.resolvedQQMusicEnabled {
                HubQQMusicSetupView(controller: music, onSelectionChange: { model.settings.musicPlayer = $0.rawValue })
            }
        }
    }
    private var appearance: some View {
        Group {
            section(L("主题")) {
                settingsRow(L("背景主题")) {
                    Picker(L("背景主题"), selection: Binding(get: { model.settings.resolvedBackgroundTheme }, set: { model.settings.backgroundTheme = $0 })) {
                        Text(L("纯色")).tag("solid")
                        Text(L("液态玻璃")).tag("liquidGlass")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                if model.settings.resolvedBackgroundTheme == "liquidGlass" {
                    Text(L("深色半透明玻璃，柔和模糊与边缘高光，不随系统明暗切换。macOS 26 使用原生玻璃，较早系统使用毛玻璃。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.settings.resolvedBackgroundTheme == "solid" {
                    settingsRow(L("外观")) {
                        Picker(L("外观"), selection: $model.settings.appearance) { Text(L("跟随系统")).tag("system"); Text(L("浅色")).tag("light"); Text(L("深色")).tag("dark") }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    settingsRow(L("浅色背景")) { ColorPicker(L("浅色背景"), selection: hexBinding(\.lightBackgroundHex), supportsOpacity: false).labelsHidden() }
                    settingsRow(L("深色背景")) { ColorPicker(L("深色背景"), selection: hexBinding(\.darkBackgroundHex), supportsOpacity: false).labelsHidden() }
                }
            }
            section(L("内容")) {
                settingsRow(L("文字大小")) { HStack { Slider(value: $model.settings.fontSize, in: 10...17, step: 1).frame(width: 155); Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 45) } }
                settingsRow(L("图标大小")) { HStack { Slider(value: $model.settings.iconSize, in: 32...88, step: 4).frame(width: 155); Text("\(Int(model.settings.iconSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 45) } }
                Toggle(L("显示滚动条"), isOn: $model.settings.showScrollbar)
                Toggle(L("图标视图横向滚动"), isOn: $model.settings.horizontalScroll)
            }
            section(L("动画")) {
                settingsRow(L("界面动画速度")) {
                    HStack(spacing: 10) {
                        Slider(value: animationSpeed, in: 0.5...2, step: 0.1)
                            .frame(width: 170).accessibilityLabel(L("界面动画速度"))
                        Text(String(format: "%.1f×", model.settings.resolvedAnimationSpeed))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 42)
                    }
                }
                HStack(spacing: 8) {
                    animationPreset(L("舒缓"), speed: 0.7)
                    animationPreset(L("标准"), speed: 1)
                    animationPreset(L("轻快"), speed: 1.5)
                    animationPreset(L("迅捷"), speed: 2)
                }
                Text(L("倍率越大越快，面板开合、标签切换与状态反馈同步调整。系统开启“减少动态效果”时减少位移动画。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section(L("面板布局")) {
                settingsRow(L("顶部展开样式")) {
                    Picker(L("顶部展开样式"), selection: Binding(get: { model.settings.resolvedNotchIntegrationStyle }, set: { model.settings.notchIntegrationStyle = $0 })) {
                        Text(L("曲线衔接")).tag("connected"); Text(L("刘海嵌入")).tag("embedded")
                    }.labelsHidden().frame(width: 200)
                }
                note(L("刘海嵌入会避开中央刘海；空间不足时顶栏移至下方。光标旁呼出保持悬浮样式。"))
                Divider()
                settingsRow(L("宽度")) { Stepper("\(Int(model.settings.width)) pt", value: $model.settings.width, in: 600...1400, step: 40).frame(width: 160) }
                settingsRow(L("高度")) { Stepper("\(Int(model.settings.height)) pt", value: $model.settings.height, in: 280...900, step: 20).frame(width: 160) }
                Text(L("也可以直接拖动窗口边缘调整大小。")) .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var shortcuts: some View {
        Group {
            section(L("全局快捷键")) {
                globalShortcutRow(L("在触发位置呼出 / 收起"), target: "top", shortcut: model.settings.resolvedGlobalShortcuts.top)
                globalShortcutRow(L("光标旁呼出 / 收起"), target: "cursor", shortcut: model.settings.resolvedGlobalShortcuts.cursor)
                Text(L("点击快捷键框后按下新的组合键。至少包含 ⌘、⌃ 或 ⌥；Esc 取消，Delete 清除。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("仅快捷键模式下，若两组都未设置或注册失败，会保留菜单栏入口。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("恢复默认快捷键")) {
                        model.settings.globalShortcuts = nil
                    }
                    Spacer()
                    if model.settings.triggerMode == "hover" { Text(L("仅鼠标模式下不启用全局快捷键")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            section(L("浏览文件")) {
                shortcutRow(L("选择项目"), keys: "↑ ↓ ← →")
                shortcutRow(L("重新命名单个所选项目"), keys: "↩ / Enter")
                shortcutRow(L("打开所选项目"), keys: L("⌘ ↓ / 双击"))
                shortcutRow(L("快速查看"), keys: L("空格"))
                shortcutRow(L("上一级文件夹"), keys: "⌘ ↑")
                shortcutRow(L("后退 / 前进"), keys: "⌥ ← / ⌥ →")
                shortcutRow(L("复制文件 / 复制路径"), keys: "⌘ C / ⌘ ⌥ C")
                shortcutRow(L("粘贴文件或图片"), keys: "⌘ V / ⌃ V")
                note(L("文件区也支持 Ctrl+C 复制。粘贴到文件夹时复制文件，粘贴到收藏、暂存区时添加引用；剪贴板图片保存为本地文件。文本输入框保留系统编辑行为。"))
                shortcutRow(L("全选"), keys: "⌘ A")
                shortcutRow(L("移到废纸篓（确认后）"), keys: "⌘ ⌫")
                shortcutRow(L("新建文件夹"), keys: "⌘ ⇧ N")
                shortcutRow(L("刷新"), keys: "⌘ R")
                shortcutRow(L("上一个 / 下一个工作区"), keys: "⌘ ⇧ [ / ]")
                shortcutRow(L("收起窗口"), keys: "Esc")
                shortcutRow(L("打开设置"), keys: "⌘ ,")
            }
            Text(L("使用 ⌘ 点击选择多个文件，⇧ 点击连续选择。拖动工作区标签可调整顺序。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var about: some View {
        Group {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("FileDock").font(.title2.bold())
                    Text(L("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("原生 macOS 文件工作区 · 作者：Diexie")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            FileDockUpdateSettings(updater: updater)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("工作区、文件操作和设置均保存在本机。"))
                    Text("Copyright © 2026 Diexie.").foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button(L("使用说明")) { NotificationCenter.default.post(name: Notification.Name("HubHelp"), object: nil) }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)).allowsHitTesting(false))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func delayEditor(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, detail: String,
                             onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            settingsRow(title) {
                HStack(spacing: 6) {
                    TextField(L("毫秒"), value: value, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing)
                        .frame(width: 64).accessibilityLabel(L("\(title)，毫秒"))
                    Text("ms").foregroundStyle(.secondary)
                }
            }
            Slider(value: value, in: range, onEditingChanged: onEditingChanged).accessibilityLabel(title)
            note(detail)
        }
    }
    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
                $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func applications(in list: ApplicationList) -> [String] {
        list == .blocked ? model.settings.resolvedBlockedApplicationBundleIDs : model.settings.resolvedAllowedApplicationBundleIDs
    }
    private func setApplications(_ identifiers: [String], list: ApplicationList) {
        if list == .blocked { model.settings.blockedApplicationBundleIDs = identifiers }
        else { model.settings.allowedApplicationBundleIDs = identifiers }
    }
    private func setApplicationError(_ message: String?, list: ApplicationList) {
        if list == .blocked { blockedApplicationError = message }
        else { allowedApplicationError = message }
    }
    private func applicationRow(_ bundleID: String, list: ApplicationList) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        let removeLabel = list == .blocked ? L("移除应用限制：\(name)") : L("从白名单移除：\(name)")
        return HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
            } else { Image(systemName: "app").frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if name != bundleID { Text(bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Button {
                setApplications(applications(in: list).filter { $0 != bundleID }, list: list)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help(removeLabel).accessibilityLabel(removeLabel)
        }.padding(.vertical, 2)
    }

    private func chooseApplications(_ list: ApplicationList) {
        let panel = NSOpenPanel()
        panel.title = list == .blocked ? L("选择不自动呼出面板的应用") : L("选择允许自动呼出的应用")
        panel.prompt = list == .blocked ? L("添加应用限制") : L("添加到白名单")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard HubWindowPresentation.runModal(panel) == .OK else { return }
        let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !identifiers.isEmpty else {
            setApplicationError(L("所选应用没有可用的标识，请选择其他应用。"), list: list)
            return
        }
        addApplications(identifiers, list: list)
    }

    private func addApplications(_ identifiers: [String], list: ApplicationList) {
        let allowed = identifiers.filter { $0 != Bundle.main.bundleIdentifier }
        guard !allowed.isEmpty else {
            setApplicationError(L("请选择 FileDock 以外的应用。"), list: list)
            return
        }
        setApplicationError(nil, list: list)
        setApplications(HubTriggerSuppressionPolicy.normalizedBundleIDs(applications(in: list) + allowed), list: list)
    }
    private var hoverMilliseconds: Binding<Double> {
        Binding(get: { ((hoverDelayDraft ?? model.settings.hoverDelay) * 1000).rounded() }, set: { value in
            guard value.isFinite else { return }
            let delay = min(1500, max(0, value.rounded())) / 1000
            if hoverDelayDraft != nil { hoverDelayDraft = delay }
            else if model.settings.hoverDelay != delay { model.settings.hoverDelay = delay }
        })
    }
    private var switchDelay: Binding<Double> {
        Binding(get: { switchDelayDraft ?? model.settings.switchDelay }, set: { value in
            guard value.isFinite else { return }
            let delay = min(1.5, max(0, value))
            if switchDelayDraft != nil { switchDelayDraft = delay }
            else if model.settings.switchDelay != delay { model.settings.switchDelay = delay }
        })
    }
    private var notchEntryThreshold: Binding<Double> {
        Binding(get: { notchEntryThresholdDraft ?? model.settings.resolvedNotchEntryThreshold }, set: { value in
            guard value.isFinite else { return }
            let overlap = min(2, max(0.01, value))
            if notchEntryThresholdDraft != nil { notchEntryThresholdDraft = overlap }
            else if model.settings.resolvedNotchEntryThreshold != overlap { model.settings.notchEntryThreshold = overlap }
        })
    }
    private func commitInteractionEdits() {
        var settings = model.settings
        if let draft = hoverDelayDraft { settings.hoverDelay = draft }
        if let draft = autoHideDelayDraft { settings.autoHideDelay = draft }
        if let draft = switchDelayDraft { settings.switchDelay = draft }
        if let draft = notchEntryThresholdDraft { settings.notchEntryThreshold = draft }
        hoverDelayDraft = nil; autoHideDelayDraft = nil; switchDelayDraft = nil
        notchEntryThresholdDraft = nil
        if settings != model.settings { model.settings = settings }
    }
    private var animationSpeed: Binding<Double> {
        Binding(get: { model.settings.resolvedAnimationSpeed }, set: { value in
            guard value.isFinite else { return }
            model.settings.animationSpeed = min(2, max(0.5, value))
        })
    }
    private var autoHideMilliseconds: Binding<Double> {
        Binding(get: { ((autoHideDelayDraft ?? model.settings.resolvedAutoHideDelay) * 1000).rounded() }, set: { value in
            guard value.isFinite else { return }
            let delay = min(3000, max(0, value.rounded())) / 1000
            if autoHideDelayDraft != nil { autoHideDelayDraft = delay }
            else if model.settings.autoHideDelay != delay { model.settings.autoHideDelay = delay }
        })
    }
    private func animationPreset(_ title: String, speed: Double) -> some View {
        Button { animationSpeed.wrappedValue = speed } label: {
            Text("\(title) \(String(format: "%.1f", speed))×")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(abs(model.settings.resolvedAnimationSpeed - speed) < 0.01 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 18) { Text(title); Spacer(minLength: 12); content() }.frame(minHeight: 28)
    }
    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }.frame(minHeight: 20)
    }
    private func globalShortcutRow(_ title: String, target: String, shortcut: HubShortcut?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(title)
                Spacer(minLength: 6)
                HubShortcutRecorder(name: title, shortcut: shortcut) { setShortcut($0, target: target) }
                    .frame(width: 178, height: 30)
                Button(L("清除")) { setShortcut(nil, target: target) }
                    .font(.caption).disabled(shortcut == nil).help(L("禁用此全局快捷键"))
            }
            if let error = model.settings.resolvedGlobalShortcuts.validationErrors[target] ?? model.shortcutRegistrationErrors[target] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(title)：\(error)")
            }
        }
    }
    private func setShortcut(_ shortcut: HubShortcut?, target: String) {
        var shortcuts = model.settings.resolvedGlobalShortcuts
        if target == "top" { shortcuts.top = shortcut } else { shortcuts.cursor = shortcut }
        model.settings.globalShortcuts = shortcuts
    }
    private func hexBinding(_ keyPath: WritableKeyPath<HubSettings, String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: Self.parseHex(model.settings[keyPath: keyPath])) }, set: { color in
            guard let value = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            model.settings[keyPath: keyPath] = String(format: "#%02X%02X%02X", Int(value.redComponent * 255), Int(value.greenComponent * 255), Int(value.blueComponent * 255))
        })
    }
    private static func parseHex(_ value: String) -> NSColor {
        let string = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let number = UInt32(string, radix: 16), string.count == 6 else { return .windowBackgroundColor }
        return NSColor(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}

@MainActor
private struct HubNotchDragGuardStatusView: View {
    @ObservedObject private var controller = HubNotchDragGuard.shared
    var body: some View {
        HStack {
            switch controller.status {
            case .active: Text(L("拖动过滤器已就绪")).foregroundStyle(.secondary)
            case .permissionRequired:
                Text(L("尚未授予辅助功能权限")).foregroundStyle(.secondary)
                Spacer()
                Button(L("前往授权…")) { controller.openPermissionSettings() }
            case .unavailable:
                Text(L("拖动过滤器暂不可用")).foregroundStyle(.secondary)
                Spacer()
                Button(L("重试")) { controller.retry() }
            case .inactive: Text(L("当前显示器或触发方式未启用拖动过滤")).foregroundStyle(.secondary)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
