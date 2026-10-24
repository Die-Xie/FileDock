import AppKit
import Sparkle

/// Read-only live-feed smoke test. A disposable identity never accepts an
/// installation, loads production preferences, or opens update windows.
@MainActor final class LiveUpdateCheck: NSObject, NSApplicationDelegate, SPUUserDriver {
    private var updater: SPUUpdater?
    private var completed = false
    private var expectsUpdate: Bool { Bundle.main.object(forInfoDictionaryKey: "FDLiveExpectUpdate") as? Bool == true }
    private func finish(_ success: Bool, _ message: String) {
        guard !completed else { return }; completed = true
        print("\(success ? "PASS" : "FAIL"): \(message)")
        fflush(stdout)
        exit(success ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do { try updater!.start() } catch { finish(false, String(describing: error)); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updater?.checkForUpdates() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { self.finish(false, "Live feed timed out") }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
        finish(expectsUpdate, "Sparkle authenticated the live feed and found \(item.displayVersionString); no download or installation requested")
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { finish(false, String(describing: error)) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let error = error as NSError
        finish(!expectsUpdate && error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue),
               "Sparkle authenticated the live feed: \(error.localizedDescription)")
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); finish(false, String(describing: error)) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancellation(); finish(false, "Unexpected download request") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { finish(false, "Unexpected extraction request") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.skip); finish(false, "Unexpected installation request") }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { finish(false, "Unexpected installation") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement(); finish(false, "Unexpected relaunch") }
    func dismissUpdateInstallation() {}
}
@main struct LiveUpdateCheckMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = LiveUpdateCheck()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
