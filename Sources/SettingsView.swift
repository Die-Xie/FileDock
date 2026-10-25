import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
struct HubSettingsView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var music: HubQQMusicController
    @ObservedObject var updater: FileDockUpdater
    @State private var selectedTab = 0
    @State private var blockedApplicationError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TabView(selection: $selectedTab) {
            general.tabItem { Label("通用", systemImage: "gearshape") }.tag(0)
            appearance.tabItem { Label("外观", systemImage: "paintpalette") }.tag(1)
            shortcuts.tabItem { Label("快捷键", systemImage: "keyboard") }.tag(2)
            musicSettings.tabItem { Label("音乐", systemImage: "music.note") }.tag(3)
            about.tabItem { Label("关于", systemImage: "info.circle") }.tag(4)
        }
        .padding(20).frame(width: 550, height: 495)
        .environment(\.hubInterfaceMotion, HubInterfaceMotion(enabled: !reduceMotion, speed: model.settings.resolvedAnimationSpeed))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HubSelectMusicSettings"))) { _ in selectedTab = 3 }
    }

    private var musicSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("显示音乐控制", isOn: Binding(get: { model.settings.resolvedQQMusicEnabled }, set: { model.settings.qqMusicEnabled = $0 }))
                if model.settings.resolvedQQMusicEnabled {
                    HubQQMusicSetupView(controller: music, onSelectionChange: { model.settings.musicPlayer = $0.rawValue })
                }
                Text("嵌入模式显示歌曲信息，悬停后控制播放；其他模式使用底部播放栏。授权完成后自动连接，无需每次配置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("呼出窗口") {
                    settingsRow("触发方式") {
                        Picker("触发方式", selection: $model.settings.triggerMode) {
                            Text("鼠标与快捷键").tag("both"); Text("仅鼠标").tag("hover"); Text("仅快捷键").tag("keyboard")
                        }.labelsHidden().frame(width: 190)
                    }
                    settingsRow("鼠标触发位置") {
                        Picker("鼠标触发位置", selection: $model.settings.hotCorner) {
                            Text("刘海 / 屏幕顶部中央").tag("notch"); Text("左上角").tag("topLeft"); Text("右上角").tag("topRight"); Text("左下角").tag("bottomLeft"); Text("右下角").tag("bottomRight")
                        }.labelsHidden().frame(width: 190)
                    }
                    if model.settings.hotCorner == "notch" {
                        Toggle("点按刘海呼出（关闭时悬停呼出）", isOn: Binding(get: { model.settings.notchClickToWake ?? false }, set: { model.settings.notchClickToWake = $0 }))
                            .disabled(model.settings.triggerMode == "keyboard")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        settingsRow("顶部展开样式") {
                            Picker("顶部展开样式", selection: Binding(get: { model.settings.resolvedNotchIntegrationStyle }, set: { model.settings.notchIntegrationStyle = $0 })) {
                                Text("曲线衔接").tag("connected")
                                Text("刘海嵌入").tag("embedded")
                            }.labelsHidden().frame(width: 190)
                        }
                        Text("刘海嵌入时，面板延伸至屏幕顶部，顶栏两侧避开中央刘海；空间不足时顶栏移至刘海下方。光标旁呼出保持悬浮样式。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        settingsRow("悬停多久后展开") {
                            HStack(spacing: 7) {
                                Slider(value: hoverMilliseconds, in: 0...1500, step: 10)
                                    .frame(width: 112).accessibilityLabel("悬停触发延迟，毫秒")
                                TextField("毫秒", value: hoverMilliseconds, format: .number.precision(.fractionLength(0)))
                                    .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing)
                                    .frame(width: 54).accessibilityLabel("触发延迟毫秒数")
                                Text("ms").font(.caption).foregroundStyle(.secondary)
                                Stepper("触发延迟", value: hoverMilliseconds, in: 0...1500, step: 10)
                                    .labelsHidden().fixedSize().accessibilityLabel("每次调整 10 毫秒")
                            }
                        }
                        HStack(spacing: 7) {
                            Text("快速设置").font(.caption).foregroundStyle(.secondary)
                            hoverPreset("即时", milliseconds: 0)
                            hoverPreset("灵敏", milliseconds: 120)
                            hoverPreset("稳妥", milliseconds: 300)
                            Spacer(minLength: 0)
                        }
                        Text(model.settings.hoverDelay == 0 ? "鼠标进入触发区域即展开。" : "当前 \(Int((model.settings.hoverDelay * 1000).rounded())) 毫秒；数值越小，呼出越快。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.settings.hotCorner == "notch" {
                            Text("有刘海的屏幕上，鼠标大部分进入刘海后才开始计时；移出会重新计时。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        settingsRow("鼠标移开多久后收起") {
                            HStack(spacing: 7) {
                                Slider(value: autoHideMilliseconds, in: 0...3000, step: 50)
                                    .frame(width: 112).accessibilityLabel("鼠标移开后收起延迟，毫秒")
                                TextField("毫秒", value: autoHideMilliseconds, format: .number.precision(.fractionLength(0)))
                                    .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing)
                                    .frame(width: 54).accessibilityLabel("收起延迟毫秒数")
                                Text("ms").font(.caption).foregroundStyle(.secondary)
                                Stepper("收起延迟", value: autoHideMilliseconds, in: 0...3000, step: 50)
                                    .labelsHidden().fixedSize().accessibilityLabel("每次调整收起延迟 50 毫秒")
                            }
                        }
                        HStack(spacing: 7) {
                            Text("快速设置").font(.caption).foregroundStyle(.secondary)
                            autoHidePreset("即时", milliseconds: 0)
                            autoHidePreset("标准", milliseconds: 550)
                            autoHidePreset("宽松", milliseconds: 1000)
                            Spacer(minLength: 0)
                        }
                        Text(model.settings.resolvedAutoHideDelay == 0 ? "鼠标移出面板区域即收起；返回面板会取消收起。" : "当前 \(Int((model.settings.resolvedAutoHideDelay * 1000).rounded())) 毫秒；返回面板会取消收起倒计时。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsRow("悬停切换工作区") { HStack { Slider(value: $model.settings.switchDelay, in: 0...1.5, step: 0.1).frame(width: 140); Text(model.settings.switchDelay == 0 ? "关闭" : String(format: "%.1f 秒", model.settings.switchDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 59) } }
                    Toggle("在副显示器上启用触发区域", isOn: $model.settings.secondaryScreens)
                }
                section("自动呼出例外") {
                    Toggle("全屏时暂停鼠标呼出", isOn: Binding(get: { model.settings.resolvedSuppressHoverInFullScreen }, set: { model.settings.suppressHoverInFullScreen = $0 }))
                    Text("全屏播放视频或使用全屏应用时暂停自动呼出。快捷键和菜单栏仍可主动打开面板。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("应用黑名单").font(.system(size: 12, weight: .medium))
                    Text("以下应用在前台时暂停鼠标呼出，适合游戏或无法自动识别全屏的播放器。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(model.settings.resolvedBlockedApplicationBundleIDs, id: \.self) { bundleID in
                        blockedApplicationRow(bundleID)
                    }
                    HStack {
                        Button("添加应用…") { chooseBlockedApplications() }
                        Menu("正在运行的应用") {
                            ForEach(runningApplications, id: \.processIdentifier) { app in
                                if let bundleID = app.bundleIdentifier {
                                    Button(app.localizedName ?? bundleID) { addBlockedApplications([bundleID]) }
                                        .disabled(model.settings.resolvedBlockedApplicationBundleIDs.contains(bundleID))
                                }
                            }
                            if runningApplications.isEmpty { Text("没有可添加的应用") }
                        }.fixedSize()
                    }
                    if let blockedApplicationError {
                        Text(blockedApplicationError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("启动与常驻") {
                    Toggle("在菜单栏显示图标", isOn: $model.settings.showMenuBarIcon)
                    Toggle("登录时启动", isOn: Binding(get: { model.settings.launchAtLogin }, set: { enabled in NotificationCenter.default.post(name: Notification.Name("HubLaunchAtLogin"), object: nil, userInfo: ["enabled": enabled]) }))
                    Text("如果系统要求确认，请在「系统设置 → 通用 → 登录项」中允许。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("文件") {
                    Toggle("启用 AirDrop", isOn: Binding(get: { model.settings.resolvedAirDropEnabled }, set: { model.settings.airDropEnabled = $0 }))
                    Toggle("在收藏旁显示文件暂存区", isOn: Binding(get: { model.settings.resolvedStagingEnabled }, set: { model.setStagingEnabled($0) }))
                    Text("拖入文件以临时收集，随后拖出或转移到目标文件夹。关闭入口会保留暂存项目。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("显示隐藏文件", isOn: $model.showHiddenFiles)
                    Toggle("排序时文件夹优先", isOn: Binding(get: { model.settings.resolvedFoldersFirst }, set: { model.settings.foldersFirst = $0 }))
                    Text("关闭后，文件和文件夹一起按所选列排序。手动顺序和最近使用不受影响。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("文件夹工作区中的拖入会移动文件；按住 ⌥ 拖入则复制。合集仅添加引用。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Button("导出工作区配置…") { model.exportConfiguration() }; Button("导入工作区配置…") { model.importConfiguration() } }
                }
            }.padding(8)
        }
    }

    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("主题") {
                    settingsRow("背景主题") {
                        Picker("背景主题", selection: Binding(get: { model.settings.resolvedBackgroundTheme }, set: { model.settings.backgroundTheme = $0 })) {
                            Text("纯色").tag("solid")
                            Text("液态玻璃").tag("liquidGlass")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    if model.settings.resolvedBackgroundTheme == "liquidGlass" {
                        Text("深色半透明玻璃，柔和模糊与边缘高光，不随系统明暗切换。macOS 26 使用原生玻璃，较早系统使用毛玻璃。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.settings.resolvedBackgroundTheme == "solid" {
                        settingsRow("外观") {
                            Picker("外观", selection: $model.settings.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                        }
                        settingsRow("浅色背景") { ColorPicker("浅色背景", selection: hexBinding(\.lightBackgroundHex), supportsOpacity: false).labelsHidden() }
                        settingsRow("深色背景") { ColorPicker("深色背景", selection: hexBinding(\.darkBackgroundHex), supportsOpacity: false).labelsHidden() }
                    }
                    Toggle("趣味动画", isOn: $model.settings.funAnimation)
                    Text("呼出窗口时显示轻量爪印动画。") .font(.caption).foregroundStyle(.secondary)
                }
                section("内容") {
                    settingsRow("文字大小") { HStack { Slider(value: $model.settings.fontSize, in: 10...17, step: 1).frame(width: 155); Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 45) } }
                    settingsRow("图标大小") { HStack { Slider(value: $model.settings.iconSize, in: 32...88, step: 4).frame(width: 155); Text("\(Int(model.settings.iconSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 45) } }
                    Toggle("显示滚动条", isOn: $model.settings.showScrollbar)
                    Toggle("图标视图横向滚动", isOn: $model.settings.horizontalScroll)
                }
                section("动画") {
                    settingsRow("界面动画速度") {
                        HStack(spacing: 10) {
                            Slider(value: animationSpeed, in: 0.5...2, step: 0.1)
                                .frame(width: 170).accessibilityLabel("界面动画速度")
                            Text(String(format: "%.1f×", model.settings.resolvedAnimationSpeed))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 42)
                        }
                    }
                    HStack(spacing: 8) {
                        animationPreset("舒缓", speed: 0.7)
                        animationPreset("标准", speed: 1)
                        animationPreset("轻快", speed: 1.5)
                        animationPreset("迅捷", speed: 2)
                    }
                    Text("倍率越大越快，面板开合、标签切换与状态反馈同步调整。系统开启“减少动态效果”时减少位移动画。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("窗口") {
                    settingsRow("宽度") { Stepper("\(Int(model.settings.width)) pt", value: $model.settings.width, in: 600...1400, step: 40).frame(width: 160) }
                    settingsRow("高度") { Stepper("\(Int(model.settings.height)) pt", value: $model.settings.height, in: 280...900, step: 20).frame(width: 160) }
                    Text("也可以直接拖动窗口边缘调整大小。") .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }

    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("全局快捷键") {
                    globalShortcutRow("在触发位置呼出 / 收起", target: "top", shortcut: model.settings.resolvedGlobalShortcuts.top)
                    globalShortcutRow("光标旁呼出 / 收起", target: "cursor", shortcut: model.settings.resolvedGlobalShortcuts.cursor)
                    Text("点击快捷键框后按下新的组合键。至少包含 ⌘、⌃ 或 ⌥；Esc 取消，Delete 清除。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("仅快捷键模式下，若两组都未设置或注册失败，会保留菜单栏入口。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("恢复默认快捷键") {
                            model.settings.globalShortcuts = nil
                        }
                        Spacer()
                        if model.settings.triggerMode == "hover" { Text("仅鼠标模式下不启用全局快捷键").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                section("浏览文件") {
                    shortcutRow("选择项目", keys: "↑ ↓ ← →")
                    shortcutRow("打开所选项目", keys: "↩ / ⌘ ↓")
                    shortcutRow("快速查看", keys: "空格")
                    shortcutRow("上一级文件夹", keys: "⌘ ↑")
                    shortcutRow("后退 / 前进", keys: "⌥ ← / ⌥ →")
                    shortcutRow("复制文件 / 复制路径", keys: "⌘ C / ⌘ ⌥ C")
                    shortcutRow("粘贴文件（复制）", keys: "⌘ V")
                    shortcutRow("全选", keys: "⌘ A")
                    shortcutRow("移到废纸篓（确认后）", keys: "⌘ ⌫")
                    shortcutRow("新建文件夹", keys: "⌘ ⇧ N")
                    shortcutRow("刷新", keys: "⌘ R")
                    shortcutRow("上一个 / 下一个工作区", keys: "⌘ ⇧ [ / ]")
                    shortcutRow("收起窗口", keys: "Esc")
                    shortcutRow("打开设置", keys: "⌘ ,")
                }
                Text("使用 ⌘ 点击选择多个文件，⇧ 点击连续选择。拖动工作区标签可调整顺序。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FileDock").font(.title2.bold())
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("原生 macOS 文件工作区 · 作者：Diexie").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                FileDockUpdateSettings(updater: updater)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("工作区、文件操作和设置均保存在本机。")
                        Text("Copyright © 2026 Diexie.").foregroundStyle(.tertiary)
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Button("使用说明") { NotificationCenter.default.post(name: Notification.Name("HubHelp"), object: nil) }
                }
            }.padding(10)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary); content() }
    }
    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
                $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func blockedApplicationRow(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
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
                model.settings.blockedApplicationBundleIDs = model.settings.resolvedBlockedApplicationBundleIDs.filter { $0 != bundleID }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("从黑名单移除 \(name)").accessibilityLabel("从黑名单移除 \(name)")
        }.padding(.vertical, 2)
    }

    private func chooseBlockedApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择不自动呼出面板的应用"
        panel.prompt = "加入黑名单"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard HubWindowPresentation.runModal(panel) == .OK else { return }
        let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !identifiers.isEmpty else {
            blockedApplicationError = "所选应用没有可用的标识，请选择其他应用。"
            return
        }
        addBlockedApplications(identifiers)
    }

    private func addBlockedApplications(_ identifiers: [String]) {
        let allowed = identifiers.filter { $0 != Bundle.main.bundleIdentifier }
        guard !allowed.isEmpty else {
            blockedApplicationError = "请添加需要暂停自动呼出的其他应用。"
            return
        }
        blockedApplicationError = nil
        model.settings.blockedApplicationBundleIDs = HubTriggerSuppressionPolicy.normalizedBundleIDs(
            model.settings.resolvedBlockedApplicationBundleIDs + allowed)
    }
    private var hoverMilliseconds: Binding<Double> {
        Binding(get: { (model.settings.hoverDelay * 1000).rounded() }, set: { value in
            guard value.isFinite else { return }
            model.settings.hoverDelay = min(1500, max(0, value.rounded())) / 1000
        })
    }
    private var animationSpeed: Binding<Double> {
        Binding(get: { model.settings.resolvedAnimationSpeed }, set: { value in
            guard value.isFinite else { return }
            model.settings.animationSpeed = min(2, max(0.5, value))
        })
    }
    private var autoHideMilliseconds: Binding<Double> {
        Binding(get: { (model.settings.resolvedAutoHideDelay * 1000).rounded() }, set: { value in
            guard value.isFinite else { return }
            model.settings.autoHideDelay = min(3000, max(0, value.rounded())) / 1000
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
    private func hoverPreset(_ title: String, milliseconds: Double) -> some View {
        Button { hoverMilliseconds.wrappedValue = milliseconds } label: {
            Text("\(title) \(Int(milliseconds)) ms")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(abs(model.settings.hoverDelay * 1000 - milliseconds) < 0.5 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func autoHidePreset(_ title: String, milliseconds: Double) -> some View {
        Button { autoHideMilliseconds.wrappedValue = milliseconds } label: {
            Text("\(title) \(Int(milliseconds)) ms")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(abs(model.settings.resolvedAutoHideDelay * 1000 - milliseconds) < 0.5 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) { Text(title); Spacer(); content() }.frame(minHeight: 24)
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
                Button("清除") { setShortcut(nil, target: target) }
                    .font(.caption).disabled(shortcut == nil).help("禁用此全局快捷键")
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
