import AppKit
import SwiftUI

@MainActor private final class FooterMotionState: ObservableObject {
    @Published var color: HubFinderLabel? = .red
    @Published var type: String? = "ext:md"
    @Published var enabled = true
    @Published var reduceMotion = false
    @Published var dropHint: HubFinderLabel?
    var colorRegions: [HubFileDropRegion: CGRect] = [:]
}
private struct FooterMotionRegionsKey: PreferenceKey {
    static var defaultValue: [HubFileDropRegion: CGRect] = [:]
    static func reduce(value: inout [HubFileDropRegion: CGRect], nextValue: () -> [HubFileDropRegion: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
@MainActor private struct FooterMotionFixture: View {
    @ObservedObject var state: FooterMotionState
    let colors: Bool
    let width: CGFloat
    var shortcuts = HubFileType.defaultShortcuts
    var body: some View {
        Group {
            if colors {
                HubColorLabelFilterBar(selection: state.color, onSelect: { state.color = $0 },
                    nativeDropHint: { state.dropHint == $0 ? "drop" : nil })
            } else {
                HubFileTypeFilterBar(shortcuts: shortcuts, selection: state.type,
                    available: [HubFileTypeOption(id: "ext:md", count: 1), .init(id: "ext:pdf", count: 1),
                                .init(id: "ext:zip", count: 1), .init(id: "folder", count: 1), .init(id: "ext:svg", count: 1)],
                    totalCount: 5, onSelect: { state.type = $0 }, onUpdateShortcuts: { _ in })
            }
        }.frame(width: width, height: 28).padding(8)
            .environment(\.hubInterfaceMotion, HubInterfaceMotion(enabled: state.enabled && !state.reduceMotion))
            .environment(\.colorScheme, .dark)
            .overlayPreferenceValue(HubFileDropRegionKey.self) { anchors in
                GeometryReader { geometry in
                    Color.clear.preference(key: FooterMotionRegionsKey.self, value: anchors.mapValues { geometry[$0] })
                }
            }.onPreferenceChange(FooterMotionRegionsKey.self) { state.colorRegions = $0 }
    }
}

@main struct FooterFilterMotionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        for colors in [true, false] {
            let state = FooterMotionState()
            let width: CGFloat = colors ? 270 : 250
            let host = NSHostingView(rootView: FooterMotionFixture(state: state, colors: colors, width: width))
            let window = panel(host: host, width: width)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await settle(host)
            let plates = descendants(host).compactMap { $0 as? HubSelectionPlate.PlateView }
            precondition(plates.count == 1, "Each visible filter strip owns one persistent decorative plate")
            let plate = plates[0], originalFrame = plate.frame
            let start = plate.targetFrame!
            let regions = state.colorRegions
            if colors { state.color = .blue } else { state.type = "ext:zip" }
            try await wait(host) { plate.targetFrame != start }
            let target = plate.targetFrame!
            precondition(target.midX > start.midX + 20 && plate.frame == originalFrame)
            try await Task.sleep(nanoseconds: 35_000_000)
            let position = plate.presentationFrame!.midX
            precondition(position > start.midX && position < target.midX,
                         "Filter selection must visibly pass through an intermediate position")
            if colors {
                precondition(state.colorRegions == regions && regions.count == 8,
                             "Color animation cannot change the full padded native drop anchors")
                let expected = regions[.colorLabel(HubFinderLabel.blue.rawValue)]!
                precondition(host.convert(target, from: plate) == expected)
                state.dropHint = .orange
                try await settle(host)
                precondition(state.colorRegions == regions && descendants(host).compactMap { $0 as? HubSelectionPlate.PlateView }.first === plate,
                             "Native drag guidance cannot replace the selection plate or move its drop targets")
            } else {
                state.type = "ext:svg"
                try await wait(host) { plate.targetFrame?.width == 23 }
                precondition(plate.targetFrame!.maxX <= plate.bounds.maxX + 0.5,
                             "A type chosen from the menu marks the existing more segment")
            }
            state.enabled = false
            try await wait(host) { plate.selectionLayer.animation(forKey: "selection") == nil }
            precondition(plate.hitTest(.zero) == nil && plate.registeredDraggedTypes.isEmpty)
            state.reduceMotion = true; state.enabled = true
            if colors { state.color = .green } else { state.type = nil }
            try await settle(host)
            precondition(plate.selectionLayer.animation(forKey: "selection") == nil,
                         "Reduced motion disables the footer plate without changing selection")
        }
        for colors in [true, false] {
            let state = FooterMotionState()
            let host = NSHostingView(rootView: FooterMotionFixture(state: state, colors: colors, width: 100))
            let window = panel(host: host, width: 100)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await settle(host)
            let plates = descendants(host).compactMap { $0 as? HubSelectionPlate.PlateView }
            precondition(state.colorRegions.isEmpty, "Compact controls cannot advertise hidden color drop anchors")
            precondition(plates.count == (colors ? 0 : 1), "ViewThatFits cannot leave an inactive full-strip plate attached")
            if !colors {
                precondition(plates[0].targetFrame != nil)
                state.type = nil
                try await settle(host)
                precondition(plates[0].targetFrame != nil && plates[0].targetFrame!.width >= 28,
                             "The compact clear/all segment keeps its selection state visible")
            }
        }
        print("PASS: color/type footer plates render intermediate positions, preserve drop anchors and hints, honor reduced motion/disabled state, and keep compact/menu selection without hidden hit receivers")
    }
    @MainActor private static func panel(host: NSView, width: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: -2000, y: -2000, width: width + 16, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true; panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }
    @MainActor private static func wait(_ view: NSView, until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition())
    }
    @MainActor private static func settle(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
