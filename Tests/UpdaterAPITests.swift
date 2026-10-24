import AppKit
import Foundation
import Sparkle

@main struct UpdaterAPITests {
    @MainActor static func main() throws {
        for name in ["updater:didFindValidUpdate:", "updaterDidNotFindUpdate:error:",
                     "updater:didAbortWithError:", "updater:didFinishUpdateCycleForUpdateCheck:error:",
                     "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                     "allowedSystemProfileKeysForUpdater:"] {
            precondition(FileDockUpdater.instancesRespond(to: NSSelectorFromString(name)), "Incorrect optional Sparkle delegate selector: \(name)")
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil) as! [String: Any]
        precondition(info["CFBundleIdentifier"] as? String == "local.diexie.filedock")
        precondition(info["SUFeedURL"] as? String == "https://github.com/Die-Xie/FileDock/releases/latest/download/appcast.xml")
        let key = Data(base64Encoded: info["SUPublicEDKey"] as! String)!
        precondition(key.count == 32)
        for flag in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] { precondition(info[flag] as? Bool == true) }
        for flag in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"] { precondition(info[flag] as? Bool == false) }
        precondition(info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                               userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        precondition(FileDockUpdateOutcome(error: noUpdate).status == "当前已是最新可用版本" && FileDockUpdateOutcome(error: noUpdate).details == nil,
                     "Sparkle also aborts with no-update: this must not become a failure")
        let unsupported = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                  userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue)])
        precondition(FileDockUpdateOutcome(error: unsupported).status.contains("不符合"))
        let missing = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "Feed not found (404)"])
        let wrapped = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue), userInfo: [NSUnderlyingErrorKey: missing])
        precondition(FileDockUpdateOutcome(error: wrapped).status.contains("无法获取") && FileDockUpdateOutcome(error: wrapped).details!.contains("404"))
        let invalidSignature = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))
        let validation = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue), userInfo: [NSUnderlyingErrorKey: invalidSignature])
        precondition(FileDockUpdateOutcome(error: validation).status.contains("校验失败"))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        precondition(FileDockUpdateOutcome(error: offline).status.contains("网络"))
        let cancelled = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
        precondition(FileDockUpdateOutcome(error: cancelled).status == "已取消更新" && FileDockUpdateOutcome(error: cancelled).details == nil)
        print("PASS: actual optional Sparkle delegate selectors, fixed app identity/HTTPS feed/Ed25519 key, required feed+archive authentication, manual opt-in checks, no silent install/profile and distinct latest/unsupported/cancelled/network/signature outcomes")
    }
}
