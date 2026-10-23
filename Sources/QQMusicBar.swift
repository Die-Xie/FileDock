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
                Text(controller.title.isEmpty ? "QQ 音乐" : controller.title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if controller.status == .needsPermission {
                Button("连接 QQ 音乐") { controller.requestAccess() }.controlSize(.small)
                    .help("授权辅助功能，以读取曲目并操作 QQ 音乐的播放控件")
            } else if controller.status == .notRunning {
                Button("打开 QQ 音乐") { controller.openQQMusic() }.controlSize(.small)
            } else if controller.status == .unavailable {
                Button("重新连接") { controller.reconnect() }.controlSize(.small)
            }
            HStack(spacing: 3) {
                control("backward.end.fill", label: "QQ 音乐上一首") { controller.previousTrack() }
                control(playSymbol, label: playLabel, prominent: true) { controller.togglePlayback() }
                control("forward.end.fill", label: "QQ 音乐下一首") { controller.nextTrack() }
            }.disabled(controller.status != .ready)
            Button { controller.openQQMusic() } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 13)).frame(width: 24, height: 30)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("打开 QQ 音乐窗口")
                .accessibilityLabel("打开 QQ 音乐窗口").disabled(controller.status == .notInstalled)
        }.padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var compactBar: some View {
        Group {
            if controller.status == .ready {
                ZStack {
                    HubMusicMarquee(title: controller.title.isEmpty ? "QQ 音乐" : controller.title,
                                    artist: controller.artist,
                                    active: isPresented && !showCompactControls)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(showCompactControls ? 0 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(showCompactControls)
                    HStack(spacing: 4) {
                        compactControl("backward.end.fill", label: "QQ 音乐上一首", focus: 0) { controller.previousTrack() }
                        compactControl(playSymbol, label: playLabel, prominent: true, focus: 1) { controller.togglePlayback() }
                        compactControl("forward.end.fill", label: "QQ 音乐下一首", focus: 2) { controller.nextTrack() }
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
                    .disabled(controller.status == .notInstalled || controller.status == .connecting)
                    .accessibilityLabel(connectionLabel)
                    .focused($focusedCompactControl, equals: 3)
            }
        }
        .frame(width: compactWidth, height: HubEmbeddedMusicLayout.controlHeight)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            hoveringCompact = hovering
            if !hovering { focusedCompactControl = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showCompactControls)
        .onChange(of: focusedCompactControl) { onControlFocusChange($0 != nil) }
        .onChange(of: controller.status) { if $0 != .ready { focusedCompactControl = nil } }
        .onDisappear { onControlFocusChange(false) }
        .help("\(controller.title.isEmpty ? "QQ 音乐" : controller.title)\n\(subtitle)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(controller.title.isEmpty ? "QQ 音乐" : controller.title)，\(subtitle)")
        .contextMenu {
            Text(controller.title.isEmpty ? "QQ 音乐" : controller.title)
            Text(subtitle)
            Divider()
            Button("打开 QQ 音乐") { controller.openQQMusic() }.disabled(controller.status == .notInstalled)
            if controller.status == .needsPermission {
                Button("连接 QQ 音乐") { controller.requestAccess() }
            } else if controller.status == .unavailable {
                Button("重新连接") { controller.reconnect() }
            }
        }
    }

    private var showCompactControls: Bool {
        hoveringCompact || focusedCompactControl != nil || voiceOverEnabled
    }

    private var connectionLabel: String {
        switch controller.status {
        case .needsPermission: return "连接 QQ 音乐"
        case .notRunning: return "打开 QQ 音乐"
        case .unavailable: return "重新连接"
        case .notInstalled: return "未安装 QQ 音乐"
        case .connecting: return "正在连接…"
        case .ready: return "QQ 音乐"
        }
    }

    private func connect() {
        switch controller.status {
        case .needsPermission: controller.requestAccess()
        case .notRunning: controller.openQQMusic()
        case .unavailable: controller.reconnect()
        default: break
        }
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
        guard let playing = controller.isPlaying else { return "播放或暂停 QQ 音乐" }
        return playing ? "暂停 QQ 音乐" : "播放 QQ 音乐"
    }

    private var subtitle: String {
        if let message = controller.message, !message.isEmpty { return message }
        switch controller.status {
        case .notInstalled: return "尚未安装 QQ 音乐"
        case .notRunning: return "打开 QQ 音乐，继续你的播放列表"
        case .needsPermission: return "首次连接需要辅助功能权限"
        case .connecting: return "正在连接 QQ 音乐…"
        case .unavailable: return "暂时无法读取播放状态"
        case .ready:
            let state = controller.isPlaying.map { $0 ? "正在播放" : "已暂停" } ?? "QQ 音乐"
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
