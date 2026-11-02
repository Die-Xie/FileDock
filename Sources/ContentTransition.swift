import SwiftUI
import Combine

/// A single reveal for the first usable snapshot of a new browsing context.
/// Further batches and metadata refreshes do not feed this state. Fast switches
/// share the in-flight reveal instead of repeatedly dimming the viewport.
struct HubContentRevealState {
    private(set) var deadline: TimeInterval?
    mutating func begin(now: TimeInterval, duration: TimeInterval) -> Bool {
        guard now.isFinite, duration.isFinite, duration > 0 else { settle(); return false }
        if let deadline, now < deadline { return false }
        let next = now + duration
        guard next.isFinite else { settle(); return false }
        deadline = next
        return true
    }
    mutating func settle() { deadline = nil }
}

@MainActor final class HubContentReveal: ObservableObject {
    @Published private(set) var opacity: Double = 1
    private var state = HubContentRevealState()
    private var pendingDuration: TimeInterval?
    private var observedRevision: UInt64?
    private var observedFilterRevision: UInt64?

    static func duration(speed: Double) -> TimeInterval {
        let speed = speed.isFinite ? min(2, max(0.5, speed)) : 1
        return min(0.30, max(0.16, 0.28 / speed))
    }

    func observe(revision: UInt64, enabled: Bool, speed: Double) {
        let previous = observedRevision
        observedRevision = revision
        guard let previous, previous != revision else { return }
        reveal(enabled: enabled, speed: speed)
    }

    func observeFilter(revision: UInt64, enabled: Bool, speed: Double) {
        let previous = observedFilterRevision
        observedFilterRevision = revision
        guard let previous, previous != revision else { return }
        reveal(enabled: enabled, speed: speed)
    }

    func reveal(enabled: Bool, speed: Double) {
        guard enabled else { settle(); return }
        guard pendingDuration == nil else { return }
        let duration = Self.duration(speed: speed)
        guard state.begin(now: ProcessInfo.processInfo.systemUptime, duration: duration) else { return }
        pendingDuration = duration
        withoutAnimation { opacity = 0.74 }
    }

    // Called by the modifier after SwiftUI observes the seeded opacity. A
    // queued Task.yield alone can merge both states into one render update.
    func animateSeededReveal() {
        guard let duration = pendingDuration, opacity < 1 else { return }
        pendingDuration = nil
        state.settle()
        _ = state.begin(now: ProcessInfo.processInfo.systemUptime, duration: duration)
        withAnimation(.timingCurve(0.25, 0.35, 0.30, 1, duration: duration)) { opacity = 1 }
    }

    func settle() {
        pendingDuration = nil
        state.settle()
        if opacity != 1 { withoutAnimation { opacity = 1 } }
    }

    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

/// Lives outside the file tree's animation barrier. It never changes identity,
/// layout, hit testing or native drop anchors, and never publishes per frame.
struct HubContentOpacity: AnimatableModifier {
    var opacity: Double
    let enabled: Bool
    var animatableData: Double {
        get { opacity }
        set { opacity = newValue }
    }
    var effectiveOpacity: Double { enabled ? opacity : 1 }
    func body(content: Content) -> some View { content.opacity(effectiveOpacity) }
}

private struct HubContentVisualPhase: Equatable {
    var opacity: Double = 1
    var enabled = false
    var duration: TimeInterval = 0.28
    var remaining: CGFloat { enabled ? CGFloat(max(0, min(1, (1 - opacity) / 0.26))) : 0 }
    var animation: Animation? {
        enabled && opacity == 1 ? .timingCurve(0.25, 0.35, 0.30, 1, duration: duration) : nil
    }
}
private struct HubContentVisualPhaseKey: EnvironmentKey {
    static let defaultValue = HubContentVisualPhase()
}
private extension EnvironmentValues {
    var hubContentVisualPhase: HubContentVisualPhase {
        get { self[HubContentVisualPhaseKey.self] }
        set { self[HubContentVisualPhaseKey.self] = newValue }
    }
}

/// Animate only the pixels inside a file cell's padding. Selection backgrounds,
/// native click/drag bridges and insertion anchors remain outside this effect.
struct HubFileLiftOffset: AnimatableModifier {
    var offset: CGFloat
    let enabled: Bool
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    var effectiveOffset: CGFloat { enabled ? offset : 0 }
    func body(content: Content) -> some View { content.offset(y: effectiveOffset) }
}

struct HubFileContentLift: ViewModifier {
    let distance: CGFloat
    @Environment(\.hubContentVisualPhase) private var phase
    func body(content: Content) -> some View {
        content.modifier(HubFileLiftOffset(offset: distance * phase.remaining, enabled: phase.enabled))
            .animation(phase.animation, value: phase.opacity)
            .animation(nil, value: phase.enabled)
            // The file tree forbids implicit geometry animation. Opt in only
            // this decorative child, and only for the shared reveal endpoint.
            .transaction { $0.disablesAnimations = false }
    }
}

@MainActor struct HubContentRevealModifier: ViewModifier {
    let revisions: AnyPublisher<UInt64, Never>
    let filterRevisions: AnyPublisher<UInt64, Never>
    let enabled: Bool
    let speed: Double
    @StateObject private var reveal: HubContentReveal

    init(revisions: AnyPublisher<UInt64, Never>,
         filterRevisions: AnyPublisher<UInt64, Never> = Empty<UInt64, Never>().eraseToAnyPublisher(),
         enabled: Bool, speed: Double,
         reveal: HubContentReveal? = nil) {
        self.revisions = revisions; self.filterRevisions = filterRevisions
        self.enabled = enabled; self.speed = speed
        _reveal = StateObject(wrappedValue: reveal ?? HubContentReveal())
    }

    func body(content: Content) -> some View {
        content
            .environment(\.hubContentVisualPhase, .init(opacity: reveal.opacity, enabled: enabled,
                duration: HubContentReveal.duration(speed: speed)))
            // A non-animatable gate also forces the presentation value to one
            // when an animation already targets one but is still in flight.
            .modifier(HubContentOpacity(opacity: reveal.opacity, enabled: enabled))
            .animation(nil, value: enabled)
            .onReceive(revisions) { reveal.observe(revision: $0, enabled: enabled, speed: speed) }
            .onReceive(filterRevisions) { reveal.observeFilter(revision: $0, enabled: enabled, speed: speed) }
            .onChange(of: reveal.opacity) { if $0 < 1 && enabled { reveal.animateSeededReveal() } }
            .onChange(of: enabled) { if !$0 { reveal.settle() } }
            .onDisappear { reveal.settle() }
    }
}
