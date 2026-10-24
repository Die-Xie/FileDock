import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns download, signature verification, safe replacement and relaunch.
/// The Ed25519 public key/feed are sealed in Info.plist; the private key stays in
/// the login keychain. FileDock keeps its existing code-signing requirement.
@MainActor final class FileDockUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var status = "可手动检查新版本"
    @Published private(set) var lastChecked: Date?
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let relaunch = FileDockUpdateRelaunchGate()
    var filesBusy: () -> Bool = { false }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.sessionInProgress = updater.sessionInProgress }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.lastChecked = updater.lastUpdateCheckDate }
            }
        ]
    }

    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }

    func checkForUpdates() {
        guard canCheck else { return }
        status = "正在检查更新…"
        // Publish before Sparkle opens its window so the browser yields its level.
        sessionInProgress = true
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { status = "当前已是最新可用版本" }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { relaunch.cancel(); status = "检查或升级失败：\(error.localizedDescription)" }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        sessionInProgress = false
        relaunch.cancel()
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let postponed = relaunch.postpone(whileBusy: filesBusy, resume: installHandler)
        if postponed { status = "更新已就绪，等待文件操作完成后重启…" }
        return postponed
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

@MainActor struct FileDockUpdateSettings: View {
    @ObservedObject var updater: FileDockUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("软件更新", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            Text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
            Text(updater.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("检查更新…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                if updater.sessionInProgress { ProgressView().controlSize(.small) }
            }
            Toggle("每天自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticChecks($0) }))
            Text("发现新版后由你决定下载与安装。升级保留工作区、偏好设置和现有授权；文件操作完成后才会重启。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = updater.lastChecked {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Link("查看发行版本", destination: URL(string: "https://github.com/Die-Xie/FileDock/releases")!)
            Spacer()
        }.padding(12)
    }
}
