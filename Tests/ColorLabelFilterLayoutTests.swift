import AppKit
import SwiftUI

@main struct ColorLabelFilterLayoutTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        for language in [HubLanguage.simplifiedChinese, .english] {
            HubLocalization.select(language)
            for width in [CGFloat(92), 230] {
                let bar = HubColorLabelFilterBar(selection: .orange, onSelect: { _ in })
                let host = NSHostingView(rootView: bar.padding(8).frame(width: width + 16)
                    .environment(\.colorScheme, .dark))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width + 16, height: 38),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
                precondition(abs(host.fittingSize.width - width - 16) < 0.5 && host.fittingSize.height <= 40,
                             "Both the full strip and compact menu must fit a single footer row")
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                precondition(data.count > 400)
                if let capture = ProcessInfo.processInfo.environment["FILEDOCK_COLOR_FILTER_CAPTURE_DIR"] {
                    let folder = URL(fileURLWithPath: capture)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: folder.appendingPathComponent("\(language.rawValue)-\(Int(width)).png"))
                }
                window.contentView = nil; window.close()
            }
        }
        print("PASS: Chinese/English native color-filter strip and compact fallback fit one footer row")
    }
}
