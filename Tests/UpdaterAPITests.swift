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
        print("PASS: actual optional Sparkle delegate selectors, fixed app identity/HTTPS feed/Ed25519 key, required feed+archive authentication, manual opt-in checks and no silent install/profile")
    }
}
