import AppKit
import Foundation

@main struct LocalizationTests {
    @MainActor static func main() throws {
        defer { HubLocalization.select(.simplifiedChinese) }
        precondition(HubLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]) == .english)
        precondition(HubLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW", "en"]) == .simplifiedChinese)
        precondition(HubLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]) == .english)
        precondition(HubLanguage.system.resolved(preferredLanguages: []) == .english)
        precondition(HubLocalizationCatalog.english.count > 500)
        let regex = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func slots(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, english) in HubLocalizationCatalog.english {
            precondition(!english.isEmpty && slots(key) == slots(english), "Translation argument mismatch: \(key)")
        }
        HubLocalization.select(.english)
        precondition(L("全屏与应用限制") == "Full Screen & App Restrictions")
        precondition(L("点击触发区域打开") == "Click Trigger Area to Open")
        let filename = "我的 {1} %@ \\" + "{0}.svg"
        precondition(L("无法打开 \(filename)。") == "Cannot open \(filename).")
        precondition(HubLocalization.render(template: "{1} → {0}", arguments: ["{1}", "%@"]) == "%@ → {1}")
        let message: HubLocalizedMessage = "版本 \(123)"
        precondition(HubLocalization.render(message) == "Version 123")
        HubLocalization.select(.simplifiedChinese)
        precondition(HubLocalization.render(message) == "版本 123")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-Language-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let configuration = root.appendingPathComponent("config.json")
        let model = HubModel(storageURL: configuration)
        let custom = model.addWorkspace(name: "中文 {1} 收藏", mode: .references, urls: [])!
        let beforeWorkspaces = model.workspaces
        let beforeSettings = model.settings
        let writes = model.configurationWriteCount
        for language in ["en", "zh-Hans", "system", "en"] {
            model.settings.language = language
            precondition(model.workspaces == beforeWorkspaces)
            precondition(model.displayName(for: custom) == custom.name)
        }
        precondition(model.configurationWriteCount == writes + 4)
        var expected = beforeSettings; expected.language = "en"
        precondition(model.settings == expected, "Changing language must preserve every other preference")
        precondition(model.displayName(for: model.favoriteWorkspace!) == "Favorites")
        let reopened = HubModel(storageURL: configuration)
        precondition(reopened.settings.resolvedLanguage == .english && reopened.workspaces == beforeWorkspaces)
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as! [String: Any]
        var settings = saved["settings"] as! [String: Any]
        settings.removeValue(forKey: "language"); saved["settings"] = settings
        try JSONSerialization.data(withJSONObject: saved).write(to: configuration)
        let legacy = HubModel(storageURL: configuration)
        precondition(legacy.settings.language == nil && legacy.settings.resolvedLanguage == .simplifiedChinese)
        precondition(HubLocalization.language == .simplifiedChinese && legacy.workspaces == beforeWorkspaces)
        settings["language"] = "unsupported"; saved["settings"] = settings
        try JSONSerialization.data(withJSONObject: saved).write(to: configuration)
        precondition(HubModel(storageURL: configuration).settings.resolvedLanguage == .system)
        // The lock protects simultaneous background error rendering and UI changes.
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            HubLocalization.select(index.isMultiple(of: 2) ? .english : .simplifiedChinese)
            let rendered = L("无法打开 \(filename)。")
            precondition(rendered == "Cannot open \(filename)." || rendered == "无法打开 \(filename)。")
        }
        HubLocalization.select(.english)
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<20000 { _ = L("版本 \(i)") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 2, "Localization must not block interaction: \(elapsed)s")
        print("PASS: language resolution, catalog arguments, literal user data, live switching, restart/legacy/invalid configuration, preserved workspaces/preferences, concurrent rendering; 20,000 renders in \(elapsed)s")
    }
}
