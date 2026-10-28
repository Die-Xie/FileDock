import AppKit
import SwiftUI

@main struct InlineRenameTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-InlineRename-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        precondition(HubFileNameEditing.selection(in: "报告🚀.pdf", isDirectory: false, isPackage: false) == NSRange(location: 0, length: ("报告🚀" as NSString).length))
        precondition(HubFileNameEditing.selection(in: ".gitignore", isDirectory: false, isPackage: false).length == 10)
        precondition(HubFileNameEditing.selection(in: "archive.tar.gz", isDirectory: false, isPackage: false).length == 11)
        precondition(HubFileNameEditing.selection(in: "folder.v1", isDirectory: true, isPackage: false).length == 9)
        precondition(HubFileNameEditing.selection(in: "Pages.pages", isDirectory: true, isPackage: true).length == 5)
        precondition(!HubFileNameEditing.changesExtension(from: "old.txt", to: "new.TXT", isDirectory: false, isPackage: false))
        precondition(HubFileNameEditing.changesExtension(from: "old.txt", to: "new.md", isDirectory: false, isPackage: false))
        precondition(HubFileNameEditing.changesExtension(from: "old.txt", to: "new", isDirectory: false, isPackage: false))
        precondition(!HubFileNameEditing.changesExtension(from: "folder.v1", to: "folder.v2", isDirectory: true, isPackage: false))
        precondition(HubFileNameEditing.keepingExtension(from: "old.txt", in: "new.md") == "new.txt")
        precondition(HubFileNameEditing.keepingExtension(from: "old.txt", in: "new") == "new.txt")

        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let workspace = model.addWorkspace(name: "Rename", mode: .folder, urls: [root])!
        model.selectWorkspace(workspace.id)
        let music = HubQQMusicController() // Never visible: no player/TCC access.
        for (index, mode) in HubViewMode.allCases.enumerated() {
            let source = root.appendingPathComponent("报告🚀-\(mode.rawValue)-a-very-long-original-file-name-to-check-hover-without-truncation.txt")
            let other = root.appendingPathComponent("other-\(mode.rawValue).txt")
            try Data("fixture".utf8).write(to: source); try Data("other".utf8).write(to: other)
            model.refresh(); model.viewMode = mode; model.selectedIDs = []
            let presentation = HubPresentationState(); presentation.previewVisible = true
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: HubView(model: model, presentation: presentation, music: music, onSettings: {}, onClose: {}))
            panel.contentView = host
            try await settle(host)
            func fileView(_ url: URL) -> HubFileDragBridge.FileDragView {
                descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }.first { $0.entryURL.path == url.path }!
            }
            precondition(fileView(source).toolTip == nil,
                         "Native drag overlays must not register unconditional filename tooltips")
            func filenameTracking(_ url: URL) -> HubFileNameTooltip.TrackingView {
                descendants(host).compactMap { $0 as? HubFileNameTooltip.TrackingView }.first { $0.name == url.lastPathComponent }!
            }
            precondition(filenameTracking(source).displayName == source.lastPathComponent)
            let keyboard = descendants(host).compactMap { $0 as? HubKeyMonitor.KeyboardView }.first!
            func key(_ code: UInt16 = 36) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
            }
            func fields() -> [HubInlineFileNameEditor.NameField] { descendants(host).compactMap { $0 as? HubInlineFileNameEditor.NameField } }
            precondition(keyboard.route(key()) == nil); try await settle(host)
            precondition(fields().isEmpty, "Return without selection must not open or rename anything")
            model.selectedIDs = [source, other]; try await settle(host)
            precondition(keyboard.route(key()) == nil); try await settle(host)
            precondition(fields().isEmpty, "Multi-selection must not rename an arbitrary first item")
            model.selectedIDs = [source]; try await settle(host)
            precondition(keyboard.route(key(index == 1 ? 76 : 36)) == nil); try await settle(host)
            precondition(fields().count == 1 && !panel.isVisible, "All three layouts must create one inline editor without a dialog")
            let field = fields()[0]
            guard let editor = field.currentEditor() as? NSTextView else { preconditionFailure("Native filename editor must take keyboard focus") }
            precondition(editor.selectedRange() == HubFileNameEditing.selection(in: source.lastPathComponent, isDirectory: false, isPackage: false))
            precondition(HubInlineFileNameEditor.isEditing(in: panel))
            if let capture = ProcessInfo.processInfo.environment["FILEDOCK_RENAME_CAPTURE_DIR"] {
                try manager.createDirectory(atPath: capture, withIntermediateDirectories: true)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: capture).appendingPathComponent("rename-\(mode.rawValue).png"))
            }
            let escape = key(53)
            precondition(keyboard.route(escape) === escape, "Editable field commands must bypass the file keyboard handler")
            editor.setMarkedText("输入中", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(!field.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")) && !field.finished,
                         "Return during IME composition must confirm text instead of renaming the file")
            editor.unmarkText()
            let drag = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }.first { $0.entryURL.path == source.path }!
            precondition(!drag.interactionEnabled && drag.hitTest(.zero) == nil, "Editing text must receive clicks before the file drag overlay")
            precondition(descendants(host).compactMap { $0 as? HubFileNameTooltip.TrackingView }.contains { $0.name == source.lastPathComponent && !$0.enabled }, "The edited filename must disable its tracking region; a separate preview title may retain its own region")
            precondition(drag.toolTip == nil, "The native file tooltip must not cover the active filename editor")
            editor.string = "unsaved-\(mode.rawValue).txt"
            model.refresh(); try await settle(host)
            precondition(fields()[0] === field && editor.string == "unsaved-\(mode.rawValue).txt",
                         "Metadata refresh must preserve the native editor, draft and focus")
            precondition(field.control(field, textView: editor, doCommandBy: NSSelectorFromString("cancelOperation:")))
            try await settle(host)
            precondition(fields().isEmpty && !HubInlineFileNameEditor.isEditing(in: panel) && model.fileOperationsInProgress == 0)
            precondition(manager.fileExists(atPath: source.path))

            precondition(keyboard.route(key()) == nil); try await settle(host)
            let committed = fields()[0], target = root.appendingPathComponent("renamed-\(mode.rawValue).txt")
            let committedEditor = committed.currentEditor() as! NSTextView
            precondition(committed.stringValue == source.lastPathComponent, "Escape must discard the previous draft")
            committedEditor.string = target.lastPathComponent
            precondition(committed.control(committed, textView: committedEditor, doCommandBy: NSSelectorFromString("insertNewline:")))
            try await wait { model.fileOperationsInProgress == 0 && manager.fileExists(atPath: target.path) }
            try await settle(host)
            precondition(!manager.fileExists(atPath: source.path) && model.selectedIDs == [target])
            precondition(filenameTracking(target).enabled && filenameTracking(target).name == target.lastPathComponent)
            precondition(fileView(target).toolTip == nil, "Renaming must not introduce unconditional native tooltips")
            precondition(fields().isEmpty && !HubInlineFileNameEditor.isEditing(in: panel))
            precondition(keyboard.route(key()) == nil); try await settle(host)
            let abandoned = fields()[0]
            guard let abandonedEditor = abandoned.currentEditor() as? NSTextView else {
                print("Rename focus diagnostic:", mode.rawValue, abandoned.finished, abandoned.frame, String(describing: panel.firstResponder), HubInlineFileNameEditor.isEditing(in: panel))
                fflush(stdout)
                preconditionFailure("Repeated rename must regain focus after asynchronous row relocation")
            }
            abandonedEditor.string = "must-not-write.txt"
            model.viewMode = mode == .grid ? .list : .grid
            try await settle(host)
            precondition(fields().isEmpty && model.fileOperationsInProgress == 0 && !manager.fileExists(atPath: root.appendingPathComponent("must-not-write.txt").path),
                         "View replacement must cancel editing without writing a stale draft")
            panel.contentView = nil; panel.close()
            try await Task.sleep(nanoseconds: 25_000_000) // Drain actual hosting-view teardown.
        }

        // Native blur commits once; removal/disposal never commits a draft.
        let field = HubInlineFileNameEditor.NameField(frame: CGRect(x: 0, y: 0, width: 200, height: 22))
        let panel = NSPanel(contentRect: field.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = field
        field.stringValue = "original.txt"; var deliveries: [String] = []
        field.onCommit = { deliveries.append($0) }
        try await settle(field)
        (field.currentEditor() as! NSTextView).string = "blur.txt"
        panel.makeFirstResponder(nil); try await settle(field)
        precondition(deliveries == ["blur.txt"])
        field.dispose(); field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        precondition(deliveries.count == 1 && !HubInlineFileNameEditor.isEditing(in: panel))
        panel.contentView = nil; panel.close()
        print("PASS: actual grid/list/column Return and keypad Enter routing, inline focus/stem selection, editable-command bypass, draft retention across refresh, drag exclusion, Escape cancellation, async rename/selection, view-change cancellation, native blur single delivery and extension policy")
    }
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition())
    }
    @MainActor private static func settle(_ view: NSView) async throws {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 25_000_000) }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
