import AppKit
import Sparkle

/// Isolated app used only by test-updater.sh. It never loads FileDock settings,
/// requests permissions, shows a window, or uses the production update signing key.
@MainActor final class UpdateFixture: NSObject, NSApplicationDelegate, SPUUserDriver {
    private var updater: SPUUpdater?
    private var result: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FDTestResultPath") as! String) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: result.appendingPathExtension("pid"))
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            try! Data("PASS: signed update installed and relaunched\n".utf8).write(to: result)
            NSApp.terminate(nil)
            return
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do { try updater!.start() }
        catch { fail(error) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updater?.checkForUpdates() }
    }
    private func fail(_ error: Error) {
        try? Data("FAIL: \(error)\n".utf8).write(to: result)
        NSApp.terminate(nil)
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reply(.install) } }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { fail(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); fail(error) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); fail(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reply(.install) } }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}
@main struct UpdateFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = UpdateFixture()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
