import AppKit
import Carbon
import SwiftUI

@main struct ShortcutRecorderLayoutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let many = HubShortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        let samples: [(HubShortcut?, String)] = [
            (HubGlobalShortcuts.defaults.top, "⌥\u{2009}⌘\u{2009}↓"),
            (HubGlobalShortcuts.defaults.cursor, "⌥\u{2009}⌘\u{2009}→"),
            (many, "⌃\u{2009}⌥\u{2009}⇧\u{2009}⌘\u{2009}F20")
        ]
        for language in [HubLanguage.simplifiedChinese, .english] {
            HubLocalization.select(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (index, sample) in samples.enumerated() {
                    let recorder = HubShortcutRecorder(name: "Action", shortcut: sample.0, onChange: { _ in })
                    let host = NSHostingView(rootView: recorder.frame(width: 178, height: 30).padding(8))
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 194, height: 46),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
                    let button = descendants(host).compactMap { $0 as? HubShortcutRecorder.RecordingButton }.first!
                    precondition(button.title == sample.1, "Modifier and key glyphs must be visually separated")
                    precondition(button.accessibilityValue() as? String == sample.0?.displayString,
                                 "Visual spacing must not alter the semantic shortcut or accessibility value")
                    precondition((button.title as NSString).size(withAttributes: [.font: button.font!]).width < button.bounds.width - 12,
                                 "Even a four-modifier function key must fit the existing recorder")
                    if let capture = ProcessInfo.processInfo.environment["FILEDOCK_SHORTCUT_CAPTURE_DIR"] {
                        let folder = URL(fileURLWithPath: capture)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])!.write(
                            to: folder.appendingPathComponent("\(language.rawValue)-\(appearance.rawValue)-\(index).png"))
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
        print("PASS: native shortcut labels are spaced, fit long combinations in light/dark and Chinese/English, and preserve semantic accessibility values")
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
