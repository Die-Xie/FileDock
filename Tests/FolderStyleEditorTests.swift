import AppKit
import SwiftUI

@main struct FolderStyleEditorTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-StyleEditor-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let entry = FileEntry(url: root)
        for language in [HubLanguage.simplifiedChinese, .english] {
            HubLocalization.select(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for mode in HubFolderStyleEditor.IconMode.allCases {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
                    let view = HubFolderStyleEditor(entry: entry, initialMode: mode) { _, _ in preconditionFailure("Visiting an editor must never apply changes") }
                    let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                    window.contentView = host
                    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
                    precondition(host.fittingSize.width <= 501 && host.fittingSize.height <= 600, "All localized controls must fit the editor")
                    let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: image)
                    if let folder = ProcessInfo.processInfo.environment["FILEDOCK_STYLE_CAPTURE_DIR"] {
                        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder)
                            .appendingPathComponent("\(language.rawValue)-\(appearance.rawValue)-\(mode.rawValue).png"))
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
        HubLocalization.select(.simplifiedChinese)
        precondition(!FileEntry(url: root).folderAppearance.customIcon && FileEntry(url: root).labelNumber == entry.labelNumber)
        try await keyboardChecks(root.resolvingSymlinksInPath())
        print("PASS: native folder style editor, five modes in Chinese/English and light/dark, bounded layout, non-mutating visits, image/symbol previews and actual Cmd-D/Cmd-L file actions in all three browser layouts")
    }
    @MainActor private static func keyboardChecks(_ root: URL) async throws {
        let directory = root.appendingPathComponent("keyboard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.svg"), data = Data("<svg/>".utf8)
        try data.write(to: source)
        let model = makeTestModel(storageURL: root.appendingPathComponent("keyboard-config.json"))
        let workspace = model.addWorkspace(name: "Keyboard", mode: .folder, urls: [directory])!
        model.selectWorkspace(workspace.id)
        for mode in HubViewMode.allCases {
            model.viewMode = mode
            let presentation = HubPresentationState(); presentation.previewVisible = true
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: HubQQMusicController(), onSettings: {}, onClose: {}))
            window.contentView = host
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
            let keyboard = descendants(host).compactMap { $0 as? HubKeyMonitor.KeyboardView }.first!
            for (code, text) in [(UInt16(2), "d"), (UInt16(37), "l")] {
                model.selectedIDs = [source]; window.makeFirstResponder(host)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                precondition(keyboard.route(event) == nil)
                let deadline = Date().addingTimeInterval(15)
                while model.fileOperationsInProgress > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(model.fileOperationsInProgress == 0 && model.errorMessage == nil)
                let created = model.selectedURLs.first!
                precondition(created != source)
                if code == 2 {
                    let copy = try Data(contentsOf: created); precondition(copy == data)
                } else { let values = try created.resourceValues(forKeys: [.isAliasFileKey]); precondition(values.isAliasFile == true) }
            }
            window.contentView = nil; window.close()
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
