// Render the production HubView with isolated, generic demonstration files.
// No user configuration, clipboard, real player, permission or input automation.
import AppKit
import SwiftUI
import Quartz
import ScreenCaptureKit

@MainActor private final class ShowcaseLoader: HubDirectoryLoading {
    let root: URL
    init(root: URL) { self.root = root }
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        let urls: [URL]
        if let directory = request.directory, directory.path.hasPrefix(root.path + "/") {
            urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        } else { urls = request.references.map { URL(fileURLWithPath: $0) }.filter { $0.path.hasPrefix(root.path + "/") } }
        completion(.success(.init(entries: urls.map { FileEntry(url: $0) }, canonicalDirectoryPath: request.directory?.path)))
    }
    func cancel(id: UUID) {}
}

private final class ShowcaseMusic: HubQQMusicBackend, @unchecked Sendable {
    func probe() -> HubQQMusicProbe { .init(installed: true, pid: 4242, trusted: true) }
    func requestAccess() -> Bool { preconditionFailure("Showcase cannot request access") }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        .success(.init(pid: pid, title: "Morning Light", artist: "Demo Playlist", isPlaying: false))
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        preconditionFailure("Showcase cannot control playback")
    }
}

@MainActor private final class ShowcaseDesktop: NSView {
    let wallpaper: NSImage
    override var isFlipped: Bool { true }
    init(size: CGSize, wallpaper: NSImage) {
        self.wallpaper = wallpaper
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        wallpaper.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.13).setFill(); bounds.fill()
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 34).fill()
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: 0, y: 33, width: bounds.width, height: 0.5).fill()
        // Decorative desktop framing; the product view below is unmodified.
        let ink = NSColor.white.withAlphaComponent(0.86)
        ("FileDock" as NSString).draw(at: CGPoint(x: 29, y: 9), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ink])
        for (symbol, x) in [("wifi", bounds.width - 120), ("battery.100", bounds.width - 88)] {
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let tinted = NSImage(size: CGSize(width: 19, height: 15), flipped: false) { rect in
                    icon.draw(in: rect); ink.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: CGRect(x: x, y: 10, width: 19, height: 15), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        ("10:24" as NSString).draw(at: CGPoint(x: bounds.width - 53, y: 9), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: ink])
    }
}

@MainActor private final class ShowcaseNotch: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13)
        path.appendRect(NSRect(x: 0, y: 0, width: bounds.width, height: 16)); path.fill()
        NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 4, y: 11, width: 8, height: 8)).fill()
        NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1, y: 12, width: 2, height: 2)).fill()
    }
}

@main struct ReadmeShowcase {
    @MainActor static func main() async throws {
        guard #available(macOS 14.4, *) else { fatalError("Native showcase capture requires macOS 14.4 or later") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        precondition(arguments.count == 3, "ReadmeShowcase wallpaper output-directory")
        let wallpaperURL = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard let wallpaper = NSImage(contentsOf: wallpaperURL) else { fatalError("Missing wallpaper") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-Readme-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let canvasSize = CGSize(width: 1440, height: 960)
        for language in ["zh-Hans", "en"] {
            let chinese = language == "zh-Hans"
            let directory = root.appendingPathComponent(language, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let names = chinese ? ["设计素材", "参考资料", "本周计划"] : ["Design assets", "References", "Weekly plan"]
            var files: [URL] = []
            for name in names {
                let url = directory.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: url, withIntermediateDirectories: true); files.append(url)
            }
            let brief = directory.appendingPathComponent(chinese ? "产品方案.pdf" : "Product brief.pdf")
            try makePDF(at: brief, chinese: chinese); files.append(brief)
            let notes = directory.appendingPathComponent(chinese ? "项目笔记.md" : "Project notes.md")
            try "# Project notes\n\nA small place for everyday files.\n\n- Gather references\n- Review the draft\n- Keep the next step close\n".write(to: notes, atomically: true, encoding: .utf8)
            files.append(notes)
            let image = directory.appendingPathComponent(chinese ? "界面灵感.png" : "Inspiration.png")
            try Data(contentsOf: wallpaperURL).write(to: image); files.append(image)
            let checklist = directory.appendingPathComponent(chinese ? "待办清单.txt" : "Checklist.txt")
            try "Review the brief\nCollect the references\nPrepare the next draft\n".write(to: checklist, atomically: true, encoding: .utf8)
            files.append(checklist)
            let design = directory.appendingPathComponent(chinese ? "设计规范.pdf" : "Design guide.pdf")
            try makePDF(at: design, chinese: chinese); files.append(design)
            let extras = chinese ? ["会议记录.md", "灵感摘录.txt", "交付清单.txt", "阅读笔记.md", "调研摘要.pdf", "归档说明.md"] : ["Meeting notes.md", "Ideas.txt", "Deliverables.txt", "Reading notes.md", "Research.pdf", "Archive notes.md"]
            for name in extras {
                let url = directory.appendingPathComponent(name)
                if url.pathExtension == "pdf" { try makePDF(at: url, chinese: chinese) }
                else { try "# \(name)\n\nCollect the references.\nReview the details.\nPrepare the next step.\n".write(to: url, atomically: true, encoding: .utf8) }
                files.append(url)
            }
            let model = HubModel(storageURL: directory.appendingPathComponent("config.json"), directoryLoader: ShowcaseLoader(root: root))
            let project = Workspace(name: chinese ? "项目资料" : "Projects", symbol: "folder", mode: .references, referencePaths: files.map(\.path))
            let ideas = Workspace(name: chinese ? "灵感收集" : "Inspiration", symbol: "sparkles", mode: .references, referencePaths: [image.path])
            let daily = Workspace(name: chinese ? "日常" : "Everyday", symbol: "folder", mode: .references, referencePaths: [notes.path, checklist.path])
            let favorites = Workspace(name: "收藏", symbol: "star", mode: .references, referencePaths: [brief.path])
            let staged = Workspace(name: "暂存区", symbol: "tray", mode: .references, referencePaths: [brief.path, image.path, notes.path, checklist.path, design.path])
            model.workspaces = [project, ideas, daily, favorites, staged]
            model.settings.language = language
            model.settings.appearance = "dark"
            model.settings.backgroundTheme = "liquidGlass"
            model.settings.fontSize = 15
            model.settings.iconSize = 88
            model.settings.favoriteWorkspaceID = favorites.id
            model.settings.stagingWorkspaceID = staged.id
            model.settings.recentShortcutEnabled = false
            model.settings.launchAtLogin = false
            model.settings.qqMusicEnabled = true
            let music = HubQQMusicController(backend: ShowcaseMusic())
            music.setEnabled(true); music.setVisible(true)
            for mode in ["workspace", "staging", "preview"] {
                model.selectWorkspace(mode == "staging" ? staged.id : project.id)
                model.viewMode = mode == "preview" ? .columns : .grid
                model.pinned = mode == "preview"
                if mode == "preview" { model.selectedIDs = [brief] }
                else if mode == "workspace" { model.selectedIDs = [files[0]] }
                let presentation = HubPresentationState()
                presentation.previewVisible = true
                presentation.header = mode == "preview" ? .init() : .init(embedded: true, exclusionWidth: 210, topInset: 34, split: true)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: canvasSize), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                let desktop = ShowcaseDesktop(size: canvasSize, wallpaper: wallpaper)
                window.contentView = desktop
                let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: music, onSettings: {}, onClose: {}))
                let surface = HubNotchSurface(contentView: host)
                let width: CGFloat = mode == "preview" ? 1200 : 1120
                let height: CGFloat = mode == "preview" ? 680 : 540
                surface.frame = CGRect(x: (canvasSize.width - width) / 2, y: mode == "preview" ? 100 : 0, width: width, height: height)
                desktop.addSubview(surface)
                surface.configure(attached: mode != "preview", sourceWidth: 190, bodyColor: .windowBackgroundColor,
                                  reduceMotion: true, embedded: mode != "preview", liquidGlass: true)
                surface.setPresented(true, animated: false) {}
                let notch = ShowcaseNotch(frame: CGRect(x: canvasSize.width / 2 - 95, y: 0, width: 190, height: 34))
                desktop.addSubview(notch)
                window.center()
                window.orderFrontRegardless()
                for _ in 0..<16 {
                    desktop.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 70_000_000)
                }
                // Glass is composited by WindowServer, so cacheDisplay cannot
                // capture it. Public currentProcess content exposes only our
                // own demo windows without screen-recording consent or access
                // to the user's other apps. Never enumerate global content.
                let content = try await SCShareableContent.currentProcess
                guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    fatalError("Own demo window is not shareable")
                }
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(canvasSize.width * 2)
                configuration.height = Int(canvasSize.height * 2)
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let pixels = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: pixels)
                let destination = output.appendingPathComponent("\(mode)-\(language).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
                print("Rendered production HubView: \(destination.lastPathComponent)")
                window.contentView = nil; window.close()
            }
            music.setVisible(false); music.setEnabled(false)
        }
    }

    @MainActor private static func makePDF(at url: URL, chinese: Bool) throws {
        var box = CGRect(x: 0, y: 0, width: 840, height: 595)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("No PDF context") }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill(); box.fill()
        let title = chinese ? "让文件，回到顺手的位置。" : "Keep your next step close."
        let subtitle = chinese ? "项目方案 · 演示文档" : "Project brief · Demo document"
        (title as NSString).draw(at: CGPoint(x: 48, y: 498), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.black])
        (subtitle as NSString).draw(at: CGPoint(x: 48, y: 463), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray])
        let sections = chinese ? ["01  收集所需", "把资料放在同一个工作区，减少来回寻找。", "02  整理思路", "预览文件，保留接下来需要的内容。", "03  继续工作", "将整理好的文件移到目标位置。"] : ["01  Gather what you need", "Keep the references for your next task together.", "02  Review the details", "Preview a document before deciding where it belongs.", "03  Keep moving", "Organize the files, then return to your work."]
        for (i, text) in sections.enumerated() {
            (text as NSString).draw(at: CGPoint(x: 48, y: 388 - i * 42), withAttributes: [.font: NSFont.systemFont(ofSize: i % 2 == 0 ? 18 : 12, weight: i % 2 == 0 ? .semibold : .regular), .foregroundColor: i % 2 == 0 ? NSColor.black : NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
    }
}
