import AppKit
import SwiftUI

@MainActor private final class FooterAlignmentProbe { var more: CGRect? }
private struct FooterMoreFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

@main struct FooterAlignmentTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FooterAlignment-\(UUID())")
        let folder = root.appendingPathComponent("Files", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<22 {
            let ext = index < 8 ? "pdf" : index < 14 ? "md" : index < 18 ? "zip" : "svg"
            var file = folder.appendingPathComponent("Fixture-\(index).\(ext)")
            try Data("fixture".utf8).write(to: file)
            var values = URLResourceValues(); values.labelNumber = index < 5 ? 6 : 4
            try file.setResourceValues(values)
        }
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        model.workspaces = [Workspace(name: "Alignment", symbol: "folder", rootPath: folder.path)]
        model.selectWorkspace(model.workspaces[0].id)
        model.settings.qqMusicEnabled = false; model.settings.colorLabelFilterEnabled = true
        model.settings.fileTypeShortcuts = HubFileType.defaultShortcuts
        for _ in 0..<500 where model.directoryLoading { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(model.entries.count == 22)
        for language in [HubLanguage.simplifiedChinese, .english] {
            model.settings.language = language.rawValue; HubLocalization.select(language)
            for width in [CGFloat(568), 778, 1000] {
                model.setColorLabelFilter(nil); model.setFileTypeFilter(nil); model.search = ""; model.selectedIDs = []
                let state = HubPresentationState(); state.previewVisible = true
                if width != 1000 { state.setSurfaceAnimating(true) }
                let probe = FooterAlignmentProbe()
                let host = NSHostingView(rootView: HubView(model: model, presentation: state,
                    music: HubQQMusicController(), onSettings: {}, onClose: {})
                    .overlayPreferenceValue(HubFileTypePlateKey.self) { anchors in
                        GeometryReader { geometry in
                            Color.clear.preference(key: FooterMoreFrameKey.self,
                                                   value: anchors[.more].map { geometry[$0] })
                        }.allowsHitTesting(false)
                    }.onPreferenceChange(FooterMoreFrameKey.self) { probe.more = $0 })
                let panel = NSPanel(contentRect: CGRect(x: -2000, y: -2000, width: width, height: 440),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true; panel.contentView = host
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
                try await settle(host)
                let initial = try moreFrame(probe, host: host)
                var cases = 0
                func check(_ step: String) throws {
                    let current = try moreFrame(probe, host: host)
                    precondition(abs(current.minX - initial.minX) <= 0.5 && abs(current.minY - initial.minY) <= 0.5,
                                 "More anchor moved for \(language.rawValue)/\(width)/\(step): \(initial) -> \(current)")
                    precondition(model.entries.count == 22, "Filtering must not change the unfiltered count-slot reservation")
                    cases += 1
                }
                for type in [Optional("ext:pdf"), "ext:md", "ext:svg", nil] {
                    model.setFileTypeFilter(type)
                    if width == 1000 {
                        try await Task.sleep(nanoseconds: 5_000_000); host.layoutSubtreeIfNeeded(); try check("animated 5ms")
                        try await Task.sleep(nanoseconds: 20_000_000); host.layoutSubtreeIfNeeded(); try check("animated 25ms")
                    }
                    try await settle(host); try check("type \(type ?? "all")")
                    model.selectedIDs = Set(model.visibleEntries.prefix(1).map(\.url))
                    try await settle(host); try check("one selected")
                    model.selectedIDs = Set(model.visibleEntries.map(\.url))
                    try await settle(host); try check("N selected")
                    model.selectedIDs = []; try await settle(host); try check("selection cleared")
                }
                model.setFileTypeFilter("ext:md"); model.setColorLabelFilter(.red)
                try await settle(host); precondition(model.visibleEntries.isEmpty); try check("empty color/type intersection")
                model.setColorLabelFilter(.blue); try await settle(host); try check("color blue")
                model.setColorLabelFilter(nil); model.setFileTypeFilter(nil); model.search = "no-matching-name"
                try await settle(host); precondition(model.visibleEntries.isEmpty); try check("zero search results")
                model.search = ""; model.selectedIDs = Set(model.visibleEntries.map(\.url))
                try await settle(host); try check("all 22 selected")
                print("PASS: \(language.rawValue) \(Int(width))pt, \(cases) filter/selection states keep actual More bounds fixed despite count changes")
            }
        }
        print("LIMIT: This verifies the real HubView Menu bounds via its existing anchor; macOS may independently position an open menu near screen edges")
    }

    @MainActor private static func moreFrame(_ probe: FooterAlignmentProbe, host: NSView) throws -> CGRect {
        guard let frame = probe.more, abs(frame.width - 23) < 0.5, abs(frame.height - 24) < 0.5,
              host.bounds.contains(frame) else {
            throw NSError(domain: "FooterAlignmentTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or out-of-bounds actual More anchor: \(String(describing: probe.more))"])
        }
        return frame
    }
    @MainActor private static func settle(_ view: NSView) async throws {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
    }
}
