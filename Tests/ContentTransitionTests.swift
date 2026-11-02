import AppKit
import SwiftUI
import Combine

@main struct ContentTransitionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var state = HubContentRevealState()
        precondition(state.begin(now: 1, duration: 0.2))
        precondition(!state.begin(now: 1.05, duration: 0.2))
        precondition(!state.begin(now: 1.19, duration: 0.2), "Fast targets must share the current curve, without repeated dimming")
        precondition(state.deadline == 1.2)
        precondition(state.begin(now: 1.21, duration: 0.2))
        state.settle()
        precondition(state.deadline == nil)
        for invalid in [Double.nan, .infinity, -.infinity] {
            precondition(!state.begin(now: invalid, duration: 0.2))
            precondition(!state.begin(now: 1, duration: invalid))
        }
        for speed in [Double.nan, .infinity, -100, 0.5, 1, 2, 100] {
            precondition((0.16...0.30).contains(HubContentReveal.duration(speed: speed)))
        }
        precondition(HubContentReveal.duration(speed: 2) < HubContentReveal.duration(speed: 1))
        precondition(HubContentOpacity(opacity: 0.89, enabled: false).effectiveOpacity == 1,
                     "An already interpolating opacity must be fully visible as soon as motion is disabled")
        precondition(HubFileLiftOffset(offset: 3, enabled: false).effectiveOffset == 0,
                     "A live lift must return to its fixed hit region immediately when interaction starts")

        let reveal = HubContentReveal()
        var changes = 0
        let observer = reveal.objectWillChange.sink { changes += 1 }
        reveal.observe(revision: 12, enabled: true, speed: 1)
        reveal.observe(revision: 12, enabled: true, speed: 1)
        precondition(changes == 0, "Attaching or resubscribing to an already displayed snapshot must not replay it")
        reveal.reveal(enabled: false, speed: 1)
        precondition(reveal.opacity == 1 && changes == 0)
        reveal.reveal(enabled: true, speed: 1)
        precondition(reveal.opacity == 0.74)
        for _ in 0..<100 { reveal.reveal(enabled: true, speed: 1) }
        precondition(changes == 1, "Rapid switches cannot cause per-event or per-frame view invalidations")
        reveal.animateSeededReveal()
        precondition(reveal.opacity == 1 && changes == 2)
        try await Task.sleep(nanoseconds: 330_000_000)
        precondition(changes == 2, "The rendering engine interpolates; no main-actor frame timer is needed")
        reveal.reveal(enabled: true, speed: 1)
        precondition(reveal.opacity == 0.74)
        reveal.settle()
        let cancelledChanges = changes
        reveal.animateSeededReveal()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(reveal.opacity == 1 && changes == cancelledChanges, "Hide, resize, drag and reduced motion must cancel a queued reveal")
        observer.cancel()

        weak var released: HubContentReveal?
        autoreleasepool {
            let temporary = HubContentReveal()
            released = temporary
            temporary.reveal(enabled: true, speed: 1)
        }
        precondition(released == nil, "Pending presentation must not retain a closed browser")
        try await hostedLifecycle()
        print("PASS: one bounded content reveal, rapid-switch continuity, no frame publications, immediate cancellation, speed bounds and lifetime")
    }

    @MainActor private static func hostedLifecycle() async throws {
        let revisions = CurrentValueSubject<UInt64, Never>(4)
        let filters = CurrentValueSubject<UInt64, Never>(0)
        let reveal = HubContentReveal()
        var observed: [Double] = []
        let observation = reveal.$opacity.sink { observed.append($0) }
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 300, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let visual = NSView(); visual.wantsLayer = true
        let host = NSHostingView(rootView: ContentVisualProbe(view: visual).frame(width: 100, height: 50)
            .modifier(HubFileContentLift(distance: 6)).padding(20)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .modifier(HubContentRevealModifier(
            revisions: revisions.eraseToAnyPublisher(), filterRevisions: filters.eraseToAnyPublisher(),
            enabled: true, speed: 1, reveal: reveal)))
        window.contentView = host
        window.orderFront(nil)
        defer { observation.cancel(); window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        let baseline = visual.convert(visual.bounds, to: host).minY
        precondition(observed == [1], "The initial CurrentValue delivery cannot animate an already ready context")
        revisions.send(5)
        precondition(reveal.opacity == 0.74, "Seed must precede the first new file render")
        // Unlike a controller-only test, reaching one here requires SwiftUI's
        // real modifier onChange to have received and committed the seed.
        for _ in 0..<100 where reveal.opacity != 1 {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(observed == [1, 0.74, 1], "The real hosted modifier must start the seeded transition exactly once")
        for revision in 6...100 { revisions.send(UInt64(revision)) }
        precondition(observed == [1, 0.74, 1], "An in-flight fast-switch sequence must not flash again")
        var offsets: [CGFloat] = []
        for _ in 0..<35 {
            host.layoutSubtreeIfNeeded()
            offsets.append(visual.convert(visual.bounds, to: host).minY - baseline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(offsets.contains { abs($0) > 0.25 && abs($0) < 5.75 },
                     "The actual visual subtree must move through intermediate positions beneath the file-tree transaction barrier")
        precondition(abs(offsets.last!) < 0.01, "Visual contents settle back into their unchanged cell layout")
        filters.send(100) // Equal numeric counters in separate channels are distinct changes.
        precondition(reveal.opacity == 0.74, "A bottom filter change must reveal its files even when its counter matches a tab revision")
        reveal.settle()
    }
}

private struct ContentVisualProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) { }
}
