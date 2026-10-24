import SwiftUI
import AppKit

@MainActor
struct HubQQMusicSetupView: View {
    @ObservedObject var controller: HubQQMusicController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("QQ 音乐连接", systemImage: "music.note") .font(.headline)
                Spacer()
                Text(statusTitle).font(.caption.weight(.medium))
                    .foregroundStyle(controller.status == .ready ? Color.green : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                step("已安装 QQ 音乐", complete: controller.connectionProbe.map(\.installed))
                step("QQ 音乐已运行", complete: controller.connectionProbe.map { $0.pid != nil })
                step("FileDock 辅助功能已授权", complete: controller.connectionProbe.map(\.trusted))
            }
            Text(controller.status == .ready ? "已连接，歌曲信息和播放控制可用。" : controller.message ?? "正在检测连接状态…")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(controller.setupActionTitle) { controller.performSetupAction() }
                    .buttonStyle(.borderedProminent).disabled(controller.setupAction == nil)
                if controller.status == .needsPermission || controller.status == .unavailable {
                    Button("重新检测") { controller.reconnect() }
                }
            }
            if controller.status == .needsPermission {
                Text("在打开的系统设置中开启 FileDock，返回后会自动重连。系统授权需要你本人确认。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("列表里没有 FileDock，或开关已开仍无法连接？") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("点系统列表下方的「＋」添加当前应用；若已有旧条目，可重新添加当前应用后重试。")
                        Button("在访达中显示当前 FileDock") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }.font(.caption).padding(.top, 6)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func step(_ title: String, complete: Bool?) -> some View {
        Label(title, systemImage: complete == true ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(complete == true ? Color.green : Color.secondary)
            .font(.callout)
            .accessibilityLabel("\(title)，\(complete == true ? "已完成" : complete == nil ? "检测中" : "未完成")")
    }

    private var statusTitle: String {
        switch controller.status {
        case .notInstalled: return "未安装"
        case .notRunning: return "等待打开"
        case .needsPermission: return "需要授权"
        case .connecting: return "正在连接"
        case .ready: return "已连接"
        case .unavailable: return "连接异常"
        }
    }
}
