import SwiftUI
import AppKit

/// Motion is local to small feedback surfaces. Never attach these animations
/// to the browser's data, file geometry, or native drag destinations.
struct HubInterfaceMotion: Equatable {
    var enabled: Bool
    var speed: Double = 1
    private var normalizedSpeed: Double { speed.isFinite ? min(2, max(0.5, speed)) : 1 }
    var selectionDuration: TimeInterval { min(0.30, max(0.12, 0.22 / normalizedSpeed)) }
    var feedbackDuration: TimeInterval { min(0.18, max(0.06, 0.12 / normalizedSpeed)) }
    var selection: Animation? {
        enabled ? .timingCurve(0.22, 1, 0.36, 1, duration: selectionDuration) : nil
    }
    var feedback: Animation? { enabled ? .easeOut(duration: feedbackDuration) : nil }
}

enum HubWorkspaceHoverActivation {
    /// Re-tracking beneath a stationary pointer is layout, not user intent.
    static func permits(target: UUID, current: UUID?, ready: Bool, pointer: CGPoint, origin: CGPoint?) -> Bool {
        guard ready, target != current, pointer.x.isFinite, pointer.y.isFinite else { return false }
        guard let origin else { return true }
        return origin.x.isFinite && origin.y.isFinite &&
            (abs(pointer.x - origin.x) >= 2 || abs(pointer.y - origin.y) >= 2)
    }
}

/// Hover targets are already visible. Selection callbacks must not scroll the
/// strip or cancel the next hover while processing the previous selection.
struct HubWorkspaceHoverSelection: Equatable {
    private var selectedByHover: UUID?
    mutating func record(_ id: UUID?) { selectedByHover = id }
    mutating func observe(current: UUID?) {
        if current != selectedByHover { selectedByHover = nil }
    }
    mutating func reset() { selectedByHover = nil }
    func needsReveal(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return id != selectedByHover
    }
}

private struct HubInterfaceMotionKey: EnvironmentKey {
    static let defaultValue = HubInterfaceMotion(enabled: false)
}
extension EnvironmentValues {
    var hubInterfaceMotion: HubInterfaceMotion {
        get { self[HubInterfaceMotionKey.self] }
        set { self[HubInterfaceMotionKey.self] = newValue }
    }
}

/// Only the decorative shape travels. Labels, click targets and drop anchors
/// retain their actual layout throughout the transition.
struct HubSelectionBackdrop: View {
    let selected: Bool
    let namespace: Namespace.ID
    var cornerRadius: CGFloat = 8
    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.12))
                .matchedGeometryEffect(id: "selection", in: namespace)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct HubToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration) }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.hubInterfaceMotion) private var motion
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.4)
                .background(Color.primary.opacity(enabled ? configuration.isPressed ? 0.12 : hovering ? 0.065 : 0 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .scaleEffect(motion.enabled && configuration.isPressed ? 0.96 : 1)
                .animation(motion.feedback, value: hovering)
                .animation(motion.feedback, value: configuration.isPressed)
                .animation(nil, value: motion.enabled)
                .onHover { hovering = $0 }
        }
    }
}

/// Deadline state avoids a one-frame spinner and preserves a visible indicator
/// across consecutive batches. Repeated progress must never postpone showing it.
struct HubActivityVisibilityState {
    let delay: TimeInterval
    let minimumVisible: TimeInterval
    private(set) var visible = false
    private(set) var deadline: TimeInterval?
    private var active = false
    private var presented = false
    private var shownAt: TimeInterval?

    init(delay: TimeInterval = 0.15, minimumVisible: TimeInterval = 0.22) {
        self.delay = delay; self.minimumVisible = minimumVisible
    }
    mutating func update(active: Bool, presented: Bool, now: TimeInterval) {
        let changed = self.active != active || self.presented != presented
        self.active = active; self.presented = presented
        guard presented else {
            visible = false; shownAt = nil; deadline = nil
            return
        }
        if active {
            if visible { deadline = nil }
            else if changed || deadline == nil { deadline = now + delay }
        } else if visible {
            deadline = max(now, (shownAt ?? now) + minimumVisible)
        } else { deadline = nil }
        advance(now: now)
    }
    mutating func advance(now: TimeInterval) {
        guard presented, let deadline, now >= deadline else { return }
        self.deadline = nil
        visible = active
        shownAt = active ? now : nil
    }
}

@MainActor final class HubActivityVisibility: ObservableObject {
    @Published private(set) var visible = false
    private var state = HubActivityVisibilityState()
    private var task: Task<Void, Never>?
    private var input: (active: Bool, presented: Bool)?
    deinit { task?.cancel() }

    func update(active: Bool, presented: Bool) {
        guard input?.active != active || input?.presented != presented else { return }
        input = (active, presented)
        state.update(active: active, presented: presented, now: ProcessInfo.processInfo.systemUptime)
        publishAndSchedule()
    }
    private func publishAndSchedule() {
        task?.cancel(); task = nil
        if visible != state.visible { visible = state.visible }
        guard let deadline = state.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.state.advance(now: ProcessInfo.processInfo.systemUptime)
            self.publishAndSchedule()
        }
    }
}
