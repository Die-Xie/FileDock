import AppKit
import Combine
import Sparkle
import SwiftUI

/// A missing release feed, a cancelled installation and an up-to-date result
/// are different outcomes. Preserve nested diagnostics without changing trust.
struct FileDockUpdateOutcome {
    var status: String
    var details: String?

    init(error: Error) {
        let root = error as NSError
        if root.domain == SUSparkleErrorDomain && root.code == Int(SUError.noUpdateError.rawValue) {
            let reason = (root.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            switch reason {
            case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue), Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue):
                status = "当前已是最新可用版本"
            case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue), Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue), Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue):
                status = "当前系统或设备不符合最新版本要求"
            default: status = "暂未发现可用的新版本"
            }
            details = nil
            return
        }
        if (root.domain == SUSparkleErrorDomain && root.code == Int(SUError.installationCanceledError.rawValue)) ||
            (root.domain == NSURLErrorDomain && root.code == NSURLErrorCancelled) {
            status = "已取消更新"; details = nil; return
        }
        var chain: [NSError] = [], next: NSError? = root
        while let value = next, chain.count < 8 {
            chain.append(value)
            next = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if chain.contains(where: { $0.domain == SUSparkleErrorDomain && [Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue)].contains($0.code) }) {
            status = "更新校验失败，已停止安装。请稍后重试或查看发行版本。"
        } else if chain.contains(where: { $0.domain == NSURLErrorDomain || ($0.domain == SUSparkleErrorDomain && $0.code == Int(SUError.downloadError.rawValue)) }) {
            status = "无法获取更新，请检查网络或稍后重试。"
        } else {
            status = "检查或升级未完成，可重试或查看发行版本。"
        }
        details = chain.map { "\($0.domain.prefix(200)) (\($0.code))：\($0.localizedDescription.prefix(2048))" }.joined(separator: "\n")
    }
}

/// Sparkle owns download, signature verification, safe replacement and relaunch.
/// The Ed25519 public key/feed are sealed in Info.plist; the private key stays in
/// the login keychain. FileDock keeps its existing code-signing requirement.
@MainActor final class FileDockUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var status = "可手动检查新版本"
    @Published private(set) var errorDetails: String?
    @Published private(set) var lastChecked: Date?
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let relaunch = FileDockUpdateRelaunchGate()
    var filesBusy: () -> Bool = { false }
    var presentationBusy: () -> Bool = { false }

    override convenience init() { self.init(startingUpdater: true) }

    init(startingUpdater: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: nil)
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
        guard !presentationBusy() else {
            status = "请先完成或取消当前共享或对话框，再检查更新。"
            return
        }
        guard canCheck else { return }
        status = "正在检查更新…"
        errorDetails = nil
        // Publish before Sparkle opens its window so the browser yields its level.
        sessionInProgress = true
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        errorDetails = nil
        status = "发现新版本 \(item.displayVersionString)"
    }
    private func record(_ error: Error) {
        let outcome = FileDockUpdateOutcome(error: error)
        status = outcome.status; errorDetails = outcome.details
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { record(error) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { relaunch.cancel(); record(error) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        sessionInProgress = false
        relaunch.cancel()
        if let error { record(error) }
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
            if let details = updater.errorDetails {
                DisclosureGroup("错误详情") {
                    Text(details).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
