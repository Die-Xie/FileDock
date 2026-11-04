import AppKit
import SwiftUI
import Combine

@MainActor private final class TypeAvailabilityFixtureState: ObservableObject {
    @Published var available = ["ext:md", "ext:pdf", "ext:zip", "folder"].map { HubFileTypeOption(id: $0, count: 1) }
    @Published var enabled = true
    @Published var reduced = false
    @Published var width: CGFloat = 400
    @Published var selection: String?
    var anchors: [HubFileTypePlateTarget: CGRect] = [:]
}
private struct TypeAvailabilityFramesKey: PreferenceKey {
    static var defaultValue: [HubFileTypePlateTarget: CGRect] = [:]
    static func reduce(value: inout [HubFileTypePlateTarget: CGRect], nextValue: () -> [HubFileTypePlateTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct TypeAvailabilityFixture: View {
    @ObservedObject var state: TypeAvailabilityFixtureState
    var body: some View {
        HubFileTypeFilterBar(shortcuts: HubFileType.defaultShortcuts, selection: state.selection,
            available: state.available, totalCount: state.available.reduce(0) { $0 + $1.count },
            onSelect: { state.selection = $0 }, onUpdateShortcuts: { _ in })
            .frame(width: state.width, alignment: .trailing)
            .environment(\.hubInterfaceMotion, HubInterfaceMotion(enabled: state.enabled && !state.reduced))
            .environment(\.colorScheme, .dark)
            .overlayPreferenceValue(HubFileTypePlateKey.self) { anchors in
                GeometryReader { geometry in
                    Color.clear.preference(key: TypeAvailabilityFramesKey.self, value: anchors.mapValues { geometry[$0] })
                }.allowsHitTesting(false)
            }.onPreferenceChange(TypeAvailabilityFramesKey.self) { state.anchors = $0 }
    }
}

@main struct FooterTypeAvailabilityMotionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        try await controllerAndText()
        try await hostedBar()
        print("PASS: actual type-bar surface width interpolates and retargets, text has visible intermediate lift, More/control anchors stay fixed, empty batches coalesce, compact/full have one noninteractive surface, and interaction/reduced-motion gates settle immediately")
    }

    @MainActor private static func controllerAndText() async throws {
        let reveal = HubFileTypeAvailabilityReveal()
        var phases: [Double] = []
        let observation = reveal.$phase.sink { phases.append($0) }
        defer { observation.cancel() }
        reveal.observe(types: ["ext:md"], enabled: true, speed: 1)
        reveal.observe(types: ["ext:md"], enabled: true, speed: 1)
        precondition(phases == [1], "Count-only refreshes and initial subscriptions cannot replay availability motion")
        reveal.observe(types: ["ext:pdf"], enabled: true, speed: 1)
        precondition(phases == [1, 0])
        for index in 0..<100 { reveal.observe(types: ["ext:batch\(index)"], enabled: true, speed: 1) }
        precondition(phases == [1, 0], "Pending seeds cannot repeatedly dim the labels")
        reveal.animateSeededReveal()
        for index in 0..<100 { reveal.observe(types: ["ext:next\(index)"], enabled: true, speed: 1) }
        precondition(phases == [1, 0, 1], "Rapid targets share one bounded text reveal")
        reveal.settle()
        for speed in [Double.nan, .infinity, -100, 0.5, 1, 2, 100] {
            precondition((0.26...0.42).contains(HubFileTypeAvailabilityReveal.duration(speed: speed)))
        }
        precondition(HubFileTypeAvailabilityReveal.duration(speed: 1) == 0.36)
        precondition(HubFileTypeAvailabilityReveal.duration(speed: 2) >= 0.26, "Fast user settings must still leave this availability change perceptible")
        precondition(HubFileTypeLabelEffect(phase: 0.5, enabled: false).effectiveOffset == 0)
        precondition(HubFileTypeLabelEffect(phase: 0.5, enabled: false).effectiveOpacity == 1)

        let state = TypeAvailabilityFixtureState()
        let visual = NSView(); visual.wantsLayer = true
        let controller = HubFileTypeAvailabilityReveal()
        var hostedPhases: [Double] = []
        let hostedObservation = controller.$phase.sink { hostedPhases.append($0) }
        defer { hostedObservation.cancel() }
        let host = NSHostingView(rootView: TypeAvailabilityTextFixture(state: state, visual: visual, reveal: controller))
        let panel = makePanel(host)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        try await settle(host)
        let baseline = visual.convert(visual.bounds, to: host).minY
        state.available = [.init(id: "ext:pdf", count: 1)]
        try await wait(host) { hostedPhases.count == 3 }
        precondition(hostedPhases == [1, 0, 1], "The hosted modifier must observe its seed before starting the text reveal")
        var offsets: [CGFloat] = []
        for _ in 0..<45 {
            host.layoutSubtreeIfNeeded()
            offsets.append(visual.convert(visual.bounds, to: host).minY - baseline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(offsets.contains { abs($0) > 0.2 && abs($0) < 3.8 }, "The production text modifier must render a visible intermediate offset")
        precondition(abs(offsets.last!) < 0.01)
    }

    @MainActor private static func hostedBar() async throws {
        let state = TypeAvailabilityFixtureState()
        let host = NSHostingView(rootView: TypeAvailabilityFixture(state: state))
        let panel = makePanel(host)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        try await settle(host)
        let surface = onlySurface(host)
        precondition(surface.registeredDraggedTypes.isEmpty && surface.hitTest(.zero) == nil)
        let initial = surface.bounds.width
        let more = state.anchors[.more]!
        let plate = descendants(host).compactMap { $0 as? HubSelectionPlate.PlateView }.first!
        let plateStart = plate.convert(plate.presentationFrame!, to: host).midX
        state.available = [.init(id: "ext:md", count: 2)]
        try await wait(host) { surface.bounds.width < initial - 20 }
        let target = surface.bounds.width
        var widths: [CGFloat] = []
        var platePositions: [CGFloat] = []
        let plateEnd = plate.convert(plate.targetFrame!, to: host).midX
        precondition(plateEnd > plateStart + 20, "All must actually change its global position when the type strip contracts")
        for _ in 0..<45 {
            host.layoutSubtreeIfNeeded()
            widths.append(surface.presentationWidth)
            platePositions.append(plate.convert(plate.presentationFrame!, to: host).midX)
            precondition(state.anchors[.more] == more, "More must not move while actual type availability changes")
            precondition(abs(surface.convert(surface.presentationFrame, to: host).maxX - more.maxX - 2) < 0.5,
                         "The interpolated surface must stay anchored to the fixed More right edge")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(widths.contains { $0 > target + 0.5 && $0 < initial - 0.5 }, "The decorative surface must visibly pass through intermediate widths")
        precondition(abs(widths.last! - target) < 0.01)
        precondition(platePositions.contains { $0 > plateStart + 2 && $0 < plateEnd - 2 },
                     "The visible All plate must move through global intermediate positions even though its local target stays x=2")
        precondition(abs(platePositions.last! - plateEnd) < 0.1)
        precondition(state.anchors[.type("ext:pdf")] == nil && state.anchors[.type("ext:zip")] == nil,
                     "Unavailable old controls cannot retain hit regions during the decorative transition")
        let fixed = state.anchors
        try await Task.sleep(nanoseconds: 20_000_000); host.layoutSubtreeIfNeeded()
        precondition(state.anchors == fixed, "Text and base animation cannot interpolate the actual button anchors")

        state.available = [.init(id: "ext:md", count: 1), .init(id: "ext:pdf", count: 1), .init(id: "folder", count: 1)]
        try await wait(host) { surface.bounds.width > target + 20 }
        try await Task.sleep(nanoseconds: 30_000_000)
        let retargetStart = surface.presentationWidth
        state.available = [.init(id: "ext:svg", count: 1), .init(id: "ext:zip", count: 1)]
        try await wait(host) { state.anchors[.type("ext:svg")] != nil }
        precondition(abs(surface.presentationWidth - retargetStart) < 35,
                     "A/B/C must retarget from the live presentation width, without jumping back to an earlier endpoint")
        try await settle(host, turns: 90)

        let beforeEmpty = surface.presentationWidth
        state.available = []
        try await wait(host) { state.anchors[.type("ext:svg")] == nil }
        precondition(abs(surface.presentationWidth - beforeEmpty) < 1, "An empty first batch holds only the old backdrop briefly")
        precondition(abs(surface.convert(surface.presentationFrame, to: host).maxX - more.maxX - 2) < 0.5,
                     "The empty hold cannot shift the old decorative surface past the controls")
        state.available = [.init(id: "ext:svg", count: 5), .init(id: "ext:zip", count: 1)]
        try await wait(host) { state.anchors[.type("ext:svg")] != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(abs(surface.presentationWidth - beforeEmpty) < 1, "A following nonempty batch cancels the empty contraction")
        state.available = []
        try await settle(host, turns: 95)
        precondition(abs(surface.presentationWidth - surface.bounds.width) < 0.01,
                     "A confirmed empty panel cannot retain the old decorative width indefinitely")

        state.available = [.init(id: "ext:md", count: 1), .init(id: "ext:pdf", count: 1), .init(id: "ext:zip", count: 1)]
        try await wait(host) { surface.bounds.width > 100 }
        state.enabled = false
        try await wait(host) { surface.surfaceLayer.animation(forKey: "availability") == nil }
        precondition(surface.presentationWidth == surface.bounds.width)
        state.enabled = true; state.reduced = true
        state.available = [.init(id: "ext:md", count: 1)]
        try await settle(host)
        precondition(surface.surfaceLayer.animation(forKey: "availability") == nil)
        precondition(surface.presentationWidth == surface.bounds.width)

        state.width = 76; state.selection = "ext:md"
        try await settle(host)
        precondition(onlySurface(host) === surface, "ViewThatFits candidates must share one persistent surface")
        precondition(state.anchors[.more] != nil && state.anchors[.clear] != nil && state.anchors[.type("ext:md")] == nil,
                     "Only the visible compact candidate advertises controls")
        precondition(descendants(host).compactMap { $0 as? HubSelectionPlate.PlateView }.count == 1)
        state.width = 400
        try await settle(host)
        precondition(onlySurface(host) === surface)
        precondition(state.anchors[.type("ext:md")] != nil && state.anchors[.clear] == nil)
    }

    @MainActor private static func onlySurface(_ view: NSView) -> HubFileTypeAvailabilitySurface.SurfaceView {
        let surfaces = descendants(view).compactMap { $0 as? HubFileTypeAvailabilitySurface.SurfaceView }
        precondition(surfaces.count == 1, "There must be exactly one attached background across full/compact candidates")
        return surfaces[0]
    }
    @MainActor private static func makePanel(_ host: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: -2000, y: -2000, width: 420, height: 70),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true; panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }
    @MainActor private static func wait(_ view: NSView, until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 2_000_000) }
        precondition(condition(), "Expected the hosted type bar to observe its updated state")
    }
    @MainActor private static func settle(_ view: NSView, turns: Int = 10) async throws {
        for _ in 0..<turns { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct TypeAvailabilityTextVisual: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) { }
}
@MainActor private struct TypeAvailabilityTextFixture: View {
    @ObservedObject var state: TypeAvailabilityFixtureState
    let visual: NSView
    let reveal: HubFileTypeAvailabilityReveal
    var body: some View {
        TypeAvailabilityTextVisual(view: visual).frame(width: 40, height: 10)
            .modifier(HubFileTypeAvailabilityLabel()).padding(12)
            .modifier(HubFileTypeAvailabilityRevealModifier(types: state.available.map(\.id),
                enabled: state.enabled, speed: 1, reveal: reveal))
    }
}
