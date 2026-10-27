import AppKit
import SwiftUI

enum HubFileNameEditing {
    static func selection(in name: String, isDirectory: Bool, isPackage: Bool) -> NSRange {
        let full = name as NSString
        let suffix = full.pathExtension
        guard !isDirectory || isPackage, !suffix.isEmpty else { return NSRange(location: 0, length: full.length) }
        return NSRange(location: 0, length: (full.deletingPathExtension as NSString).length)
    }
    static func changesExtension(from old: String, to new: String, isDirectory: Bool, isPackage: Bool) -> Bool {
        guard !isDirectory || isPackage else { return false }
        let previous = (old as NSString).pathExtension
        return !previous.isEmpty && previous.caseInsensitiveCompare((new as NSString).pathExtension) != .orderedSame
    }
    static func keepingExtension(from old: String, in new: String) -> String {
        let suffix = (old as NSString).pathExtension
        guard !suffix.isEmpty else { return new }
        let stem = (new as NSString).pathExtension.isEmpty ? new : (new as NSString).deletingPathExtension
        return stem + "." + suffix
    }
}

/// Native field editing owns Return/Escape/text commands. Only the active name
/// creates a field; no per-row observer, timer or filesystem read is added.
@MainActor struct HubInlineFileNameEditor: NSViewRepresentable {
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let fontSize: CGFloat
    var centered = false
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    private static weak var activeField: NameField?
    static func isEditing(in window: NSWindow) -> Bool { activeField?.window === window && activeField?.finished == false }

    func makeNSView(context: Context) -> NameField {
        let field = NameField()
        field.stringValue = name
        field.initialSelection = HubFileNameEditing.selection(in: name, isDirectory: isDirectory, isPackage: isPackage)
        updateNSView(field, context: context)
        return field
    }
    func updateNSView(_ field: NameField, context: Context) {
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        let alignment: NSTextAlignment = centered ? .center : .left
        if field.alignment != alignment { field.alignment = alignment }
        field.onCommit = onCommit; field.onCancel = onCancel
        // Never replace the user's draft during thumbnail/metadata refreshes.
        field.scheduleFocus()
    }
    static func dismantleNSView(_ field: NameField, coordinator: ()) { field.dispose() }

    final class NameField: NSTextField, NSTextFieldDelegate {
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        var initialSelection = NSRange(location: 0, length: 0)
        private(set) var finished = false
        private var began = false, focusScheduled = false
        override var mouseDownCanMoveWindow: Bool { false }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            delegate = self
            isEditable = true; isSelectable = true; isBezeled = false
            drawsBackground = true; backgroundColor = .textBackgroundColor
            textColor = .textColor; focusRingType = .exterior
            usesSingleLineMode = true
            cell?.isScrollable = true
            setAccessibilityLabel(L("文件名"))
            setAccessibilityIdentifier("filedock.inline-rename")
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !finished { HubInlineFileNameEditor.activeField = self }
            scheduleFocus()
        }
        override func layout() { super.layout(); scheduleFocus() }
        func scheduleFocus() {
            guard !finished, !began, !focusScheduled, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard !self.finished, !self.began, let window = self.window, window.makeFirstResponder(self) else { return }
                if self.currentEditor() == nil { self.selectText(nil) }
                guard let editor = self.currentEditor() as? NSTextView else { return }
                self.began = true
                HubInlineFileNameEditor.activeField = self
                editor.setSelectedRange(self.initialSelection)
                editor.scrollRangeToVisible(self.initialSelection)
            }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(selector) {
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:": finish(commit: true); return true
            case "cancelOperation:": finish(commit: false); return true
            default: return false
            }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            began = true
            HubInlineFileNameEditor.activeField = self
        }
        func controlTextDidEndEditing(_ notification: Notification) { if began { finish(commit: true, resign: false) } }
        private func finish(commit: Bool, resign: Bool = true) {
            guard !finished else { return }
            let name = currentEditor()?.string ?? stringValue
            finished = true
            if HubInlineFileNameEditor.activeField === self { HubInlineFileNameEditor.activeField = nil }
            let commitAction = onCommit, cancelAction = onCancel
            onCommit = nil; onCancel = nil
            if resign { stopEditing() }
            if commit { commitAction?(name) } else { cancelAction?() }
        }
        private func stopEditing() {
            let editor = currentEditor()
            _ = abortEditing()
            if let window, window.firstResponder === self || (editor != nil && window.firstResponder === editor) {
                window.makeFirstResponder(nil)
            }
        }
        func dispose() {
            let wasFinished = finished
            let cancel = onCancel
            finished = true; onCommit = nil; onCancel = nil
            if HubInlineFileNameEditor.activeField === self { HubInlineFileNameEditor.activeField = nil }
            if !wasFinished {
                stopEditing()
                // Dismantling can occur inside a SwiftUI update. The session
                // guard in the owner rejects this deferred callback if a new
                // edit has already started.
                DispatchQueue.main.async { cancel?() }
            }
        }
    }
}
