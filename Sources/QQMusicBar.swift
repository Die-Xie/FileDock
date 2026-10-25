import SwiftUI

@MainActor
struct HubQQMusicBar: View {
    @ObservedObject var controller: HubQQMusicController
    var compact = false
    var compactWidth: CGFloat = HubEmbeddedMusicLayout.controlWidth
    var isPresented = true
    var onControlFocusChange: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.hubInterfaceMotion) private var motion
    @State private var hoveringCompact = false
    @FocusState private var focusedCompactControl: Int?

    @ViewBuilder var body: some View {
        if compact { compactBar } else { fullBar }
    }

    private var fullBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.77, blue: 0.59))
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.title.isEmpty ? controller.playerName : controller.title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                progressSlot.padding(.top, 3)
            }.help(progressDescription).frame(maxWidth: .infinity, alignment: .leading)
            if controller.status != .ready {
                Button(controller.setupActionTitle) { controller.performSetupAction() }.controlSize(.small)
                    .disabled(controller.setupAction == nil)
            }
            HStack(spacing: 3) {
                control("backward.end.fill", label: "\(controller.playerName)上一首") { controller.previousTrack() }
                control(playSymbol, label: playLabel, prominent: true) { controller.togglePlayback() }
                control("forward.end.fill", label: "\(controller.playerName)下一首") { controller.nextTrack() }
            }.disabled(controller.status != .ready)
            Button(action: showConnectionSettings) {
                Image(systemName: "gearshape").frame(width: 24, height: 30)
            }.buttonStyle(.plain).help("音乐连接设置").accessibilityLabel("音乐连接设置")
            Button { controller.openPlayer() } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 13)).frame(width: 24, height: 30)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("打开\(controller.playerName)窗口")
                .accessibilityLabel("打开\(controller.playerName)窗口").disabled(controller.status == .notInstalled)
        }.padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var compactBar: some View {
        VStack(spacing: 3) {
            Group {
                if controller.status == .ready {
                    ZStack {
                        HubMusicMarquee(title: controller.title.isEmpty ? controller.playerName : controller.title,
                                        artist: controller.artist,
                                        active: isPresented && !showCompactControls)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(showCompactControls ? 0 : 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(showCompactControls)
                        HStack(spacing: 4) {
                            compactControl("backward.end.fill", label: "\(controller.playerName)上一首", focus: 0) { controller.previousTrack() }
                            compactControl(playSymbol, label: playLabel, prominent: true, focus: 1) { controller.togglePlayback() }
                            compactControl("forward.end.fill", label: "\(controller.playerName)下一首", focus: 2) { controller.nextTrack() }
                        }.opacity(showCompactControls ? 1 : 0)
                            .allowsHitTesting(showCompactControls)
                            .accessibilityHidden(!showCompactControls)
                    }
                } else {
                    Button(action: connect) {
                        HStack(spacing: 5) {
                            Image(systemName: "music.note")
                            Text(connectionLabel).lineLimit(1)
                        }.font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.buttonStyle(.plain)
                        .disabled(controller.status == .connecting)
                        .accessibilityLabel(connectionLabel)
                        .focused($focusedCompactControl, equals: 3)
                }
            }.frame(height: HubEmbeddedMusicLayout.controlHeight)
            // Reserve a stable height across polling/player changes. A player
            // without real timing data has no track or placeholder.
            progressSlot.padding(.horizontal, 6)
        }
        .frame(width: compactWidth, height: HubEmbeddedMusicLayout.barHeight)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            hoveringCompact = hovering
            if !hovering { focusedCompactControl = nil }
        }
        .animation(reduceMotion ? nil : motion.feedback, value: showCompactControls)
        .animation(nil, value: motion.enabled)
        .onChange(of: focusedCompactControl) { onControlFocusChange($0 != nil) }
        .onChange(of: controller.status) { if $0 != .ready { focusedCompactControl = nil } }
        .onDisappear { onControlFocusChange(false) }
        .help("\(controller.title.isEmpty ? controller.playerName : controller.title)\n\(subtitle)" + (visibleProgress.map { "\n\($0.description)" } ?? ""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(controller.title.isEmpty ? controller.playerName : controller.title)，\(subtitle)")
        .contextMenu {
            Text(controller.title.isEmpty ? controller.playerName : controller.title)
            Text(subtitle)
            Divider()
            Button("音乐连接设置…", action: showConnectionSettings)
            Button("打开\(controller.playerName)") { controller.openPlayer() }.disabled(controller.status == .notInstalled)
            if controller.status == .needsPermission {
                Button("连接\(controller.playerName)") { controller.requestAccess() }
            } else if controller.status == .unavailable {
                Button("重新连接") { controller.reconnect() }
            }
        }
    }

    private var visibleProgress: HubMusicProgress? { controller.status == .ready ? controller.progress : nil }
    private var progressSlot: some View {
        Color.clear.frame(height: 2).overlay {
            if let progress = visibleProgress {
                HubMusicProgressTrack(progress: progress, active: isPresented)
            }
        }.allowsHitTesting(false)
    }
    private var progressDescription: String {
        visibleProgress?.description ?? ""
    }

    private var showCompactControls: Bool {
        hoveringCompact || focusedCompactControl != nil || voiceOverEnabled
    }

    private var connectionLabel: String {
        switch controller.status {
        case .needsPermission: return "授权\(controller.playerName)控制"
        case .notRunning: return "连接\(controller.playerName)"
        case .unavailable: return "修复\(controller.playerName)连接"
        case .notInstalled: return "未安装\(controller.playerName)"
        case .connecting: return "正在连接…"
        case .ready: return controller.playerName
        }
    }

    private func connect() {
        showConnectionSettings()
    }

    private func showConnectionSettings() {
        NotificationCenter.default.post(name: Notification.Name("HubMusicSettings"), object: nil)
    }

    private func compactControl(_ symbol: String, label: String, prominent: Bool = false, focus: Int,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 12 : 10, weight: .semibold))
                .frame(width: prominent ? 30 : 28, height: HubEmbeddedMusicLayout.controlHeight)
                .background(prominent ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
            .focused($focusedCompactControl, equals: focus)
    }

    private var playSymbol: String {
        guard let playing = controller.isPlaying else { return "playpause.fill" }
        return playing ? "pause.fill" : "play.fill"
    }

    private var playLabel: String {
        guard let playing = controller.isPlaying else { return "播放或暂停\(controller.playerName)" }
        return playing ? "暂停\(controller.playerName)" : "播放\(controller.playerName)"
    }

    private var subtitle: String {
        if let message = controller.message, !message.isEmpty { return message }
        switch controller.status {
        case .notInstalled: return "尚未安装\(controller.playerName)"
        case .notRunning: return "打开\(controller.playerName)，继续你的播放列表"
        case .needsPermission: return controller.usesAutomationPermission ? "首次连接需要自动化权限" : "首次连接需要辅助功能权限"
        case .connecting: return "正在连接\(controller.playerName)…"
        case .unavailable: return "暂时无法读取播放状态"
        case .ready:
            let state = controller.isPlaying.map { $0 ? "正在播放" : "已暂停" } ?? controller.playerName
            return controller.artist.isEmpty ? state : "\(controller.artist) · \(state)"
        }
    }

    private func control(_ symbol: String, label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .frame(width: prominent ? 34 : 30, height: 32)
                .background(prominent ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
