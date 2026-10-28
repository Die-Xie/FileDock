import AppKit
import SwiftUI

@MainActor private final class SettingsFixtureLoader: HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        completion(.success(.init(entries: [], canonicalDirectoryPath: request.directory?.path)))
    }
    func cancel(id: UUID) {}
}

@main struct SettingsLayoutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/AppIcon.icns")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-Settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HubModel(storageURL: root.appendingPathComponent("config.json"), directoryLoader: SettingsFixtureLoader())
        model.settings.allowedApplicationBundleIDs = ["com.apple.finder"]
        let music = HubQQMusicController() // Never visible: no player queries or authorization.
        let updater = FileDockUpdater(startingUpdater: false) // No scheduled or network checks.
        for language in [HubLanguage.simplifiedChinese, .english] {
            model.settings.language = language.rawValue
            for style in [NSAppearance.Name.aqua, .darkAqua] {
                model.settings.backgroundTheme = style == .aqua ? "solid" : "liquidGlass"
                for page in HubSettingsPage.allCases {
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: style)
                    let settings = model.settings, workspaces = model.workspaces, writes = model.configurationWriteCount
                    let host = NSHostingView(rootView: HubSettingsView(model: model, music: music, updater: updater, page: page))
                    window.contentView = host
                    settle(host)
                    precondition(host.fittingSize == CGSize(width: 780, height: 600) && !window.isVisible)
                    precondition(model.settings == settings && model.workspaces == workspaces && model.configurationWriteCount == writes,
                                 "Opening settings pages must not normalize, reset or save user configuration")
                    let rendered = snapshot(host)
                    precondition(rendered.count > 4000, "The native settings window must render content")
                    if let capture = ProcessInfo.processInfo.environment["FILEDOCK_SETTINGS_CAPTURE_DIR"] {
                        try FileManager.default.createDirectory(atPath: capture, withIntermediateDirectories: true)
                        let destination = URL(fileURLWithPath: capture)
                        try rendered.write(to: destination.appendingPathComponent("\(language.rawValue)-\(page.rawValue)-\(style.rawValue).png"))
                        for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                            guard let document = scroll.documentView, document.bounds.height > scroll.bounds.height + 50 else { continue }
                            document.scrollToVisible(CGRect(x: 0, y: document.isFlipped ? document.bounds.maxY - 20 : 0, width: 1, height: 20))
                        }
                        settle(host)
                        try snapshot(host).write(to: destination.appendingPathComponent("\(language.rawValue)-\(page.rawValue)-\(style.rawValue)-bottom.png"))
                    }
                    if page == .activation {
                        for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                            guard let document = scroll.documentView else { continue }
                            document.scrollToVisible(CGRect(x: 0, y: document.isFlipped ? document.bounds.maxY - 20 : 0, width: 1, height: 20))
                        }
                        settle(host)
                        let populatedRendering = snapshot(host)
                        model.settings.allowedApplicationBundleIDs = []
                        settle(host)
                        precondition(snapshot(host) != populatedRendering, "Whitelist application changes must update the mounted settings page")
                        model.settings.allowedApplicationBundleIDs = ["com.apple.finder"]
                        settle(host)
                    }
                    if page == .general {
                        model.settings.language = language == .english ? "zh-Hans" : "en"
                        settle(host)
                        precondition(snapshot(host) != rendered, "Language must update the mounted settings view without reopening it")
                        model.settings.language = language.rawValue
                        settle(host)
                        NotificationCenter.default.post(name: Notification.Name("HubSelectMusicSettings"), object: nil)
                        settle(host)
                        precondition(snapshot(host) != rendered, "Music deep-link must replace the general page")
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
        print("PASS: Chinese/English, all seven settings pages in light/dark hidden native windows, rendered content, read-only page visits and music deep-link")
    }

    @MainActor private static func snapshot(_ host: NSView) -> Data {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
}
