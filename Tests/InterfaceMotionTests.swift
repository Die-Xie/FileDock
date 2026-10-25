import AppKit
import SwiftUI
import Combine

@main struct InterfaceMotionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        policy()
        hoverAdmission()
        deadlines()
        try await lifecycle()
        try await stableHosting()
        print("PASS: bounded/scaled interface motion, quiet short jobs, minimum indicator dwell, progress coalescing, hidden/cancelled tasks, selection-only animation and stable native file/tab destinations under rapid switching")
        print("LIMIT: Hidden hosting and callback tests do not measure WindowServer frame rate or subjective motion quality")
    }

    private static func hoverAdmission() {
        let current = UUID(), other = UUID()
        let point = CGPoint(x: 100, y: 30)
        precondition(!HubWorkspaceHoverActivation.permits(target: other, current: current, ready: true, pointer: point, origin: point),
            "Opening or relayout beneath a stationary cursor must not switch workspaces")
        precondition(!HubWorkspaceHoverActivation.permits(target: other, current: current, ready: true, pointer: CGPoint(x: 101.9, y: 31.9), origin: point))
        precondition(HubWorkspaceHoverActivation.permits(target: other, current: current, ready: true, pointer: CGPoint(x: 102, y: 30), origin: point))
        precondition(!HubWorkspaceHoverActivation.permits(target: current, current: current, ready: true, pointer: point, origin: nil),
            "Hovering the selected tab must never refresh or clear its selection")
        precondition(!HubWorkspaceHoverActivation.permits(target: other, current: current, ready: false, pointer: CGPoint(x: 110, y: 30), origin: point),
            "Surface transitions, hidden windows, moving windows and drag sessions must reject ordinary hover switching")
        precondition(HubWorkspaceHoverActivation.permits(target: other, current: current, ready: true, pointer: point, origin: nil))
        precondition(!HubWorkspaceHoverActivation.permits(target: other, current: current, ready: true, pointer: CGPoint(x: CGFloat.nan, y: 30), origin: nil))
    }

    private static func policy() {
        let standard = HubInterfaceMotion(enabled: true)
        precondition(standard.selection != nil && standard.feedback != nil)
        precondition(standard.selectionDuration == 0.22 && standard.feedbackDuration == 0.12)
        for speed in [Double.nan, .infinity, -.infinity, -1, 0, 0.5, 1, 2, 100] {
            let motion = HubInterfaceMotion(enabled: true, speed: speed)
            precondition((0.12...0.30).contains(motion.selectionDuration))
            precondition((0.06...0.18).contains(motion.feedbackDuration))
        }
        precondition(HubInterfaceMotion(enabled: true, speed: 2).selectionDuration < standard.selectionDuration)
        let disabled = HubInterfaceMotion(enabled: false)
        precondition(disabled.selection == nil && disabled.feedback == nil)
    }

    private static func deadlines() {
        var state = HubActivityVisibilityState()
        state.update(active: true, presented: true, now: 1)
        precondition(!state.visible && state.deadline == 1.15)
        state.update(active: false, presented: true, now: 1.1)
        state.advance(now: 2)
        precondition(!state.visible && state.deadline == nil, "Short requests never flash a spinner")

        state.update(active: true, presented: true, now: 3)
        for i in 0..<100 { state.update(active: true, presented: true, now: 3 + Double(i) / 1000) }
        precondition(state.deadline == 3.15, "Progress cannot postpone the display deadline")
        state.advance(now: 3.15)
        precondition(state.visible && state.deadline == nil)
        state.update(active: false, presented: true, now: 3.16)
        state.advance(now: 3.3)
        precondition(state.visible, "A visible indicator must not disappear after a single frame")
        state.update(active: true, presented: true, now: 3.31)
        state.advance(now: 4)
        precondition(state.visible && state.deadline == nil, "A following batch cancels pending disappearance")
        state.update(active: false, presented: true, now: 4.1)
        precondition(!state.visible && state.deadline == nil, "A long-running job needs no extra delay on completion")

        state.update(active: true, presented: true, now: 5)
        state.update(active: true, presented: false, now: 5.1)
        state.advance(now: 6)
        precondition(!state.visible && state.deadline == nil, "An old timer cannot reveal a hidden panel")
        state.update(active: true, presented: true, now: 7)
        precondition(!state.visible && state.deadline == 7.15)
        state.advance(now: 7.2)
        state.update(active: true, presented: false, now: 7.21)
        precondition(!state.visible && state.deadline == nil, "Closing immediately clears even the minimum dwell")
    }

    @MainActor private static func lifecycle() async throws {
        let activity = HubActivityVisibility()
        var publications = 0
        let observer = activity.objectWillChange.sink { publications += 1 }
        activity.update(active: true, presented: true)
        for _ in 0..<1000 { activity.update(active: true, presented: true) }
        try await Task.sleep(nanoseconds: 210_000_000)
        precondition(activity.visible && publications == 1)
        activity.update(active: false, presented: true)
        activity.update(active: true, presented: true)
        activity.update(active: true, presented: false)
        precondition(!activity.visible && publications == 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(!activity.visible && publications == 2)
        observer.cancel()
        weak var released: HubActivityVisibility?
        autoreleasepool {
            let temporary = HubActivityVisibility()
            released = temporary
            temporary.update(active: true, presented: true)
        }
        precondition(released == nil, "A pending delay cannot retain its owner")
    }

    @MainActor private static func stableHosting() async throws {
        let state = MotionFixtureState()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MotionFixture(state: state))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func flatten(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(flatten) }
        func sources() -> [HubWorkspaceDragBridge.WorkspaceDragView] {
            flatten(host).compactMap { $0 as? HubWorkspaceDragBridge.WorkspaceDragView }
        }
        for _ in 0..<20 where sources().count != 3 {
            try await Task.sleep(nanoseconds: 5_000_000); host.layoutSubtreeIfNeeded()
        }
        let original = sources()
        precondition(original.count == 3)
        let file = flatten(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first!
        let frames = Dictionary(uniqueKeysWithValues: original.map { ($0.workspaceID, $0.convert($0.bounds, to: host)) })
        let objects = Dictionary(uniqueKeysWithValues: original.map { ($0.workspaceID, ObjectIdentifier($0)) })
        func checkSources() {
            let current = sources()
            precondition(current.count == original.count)
            for view in current {
                precondition(objects[view.workspaceID] == ObjectIdentifier(view), "Selection must not replace native drag sources")
                precondition(frames[view.workspaceID] == view.convert(view.bounds, to: host), "Only the backdrop may move, never the hit geometry")
                precondition(view.registeredDraggedTypes.isEmpty)
            }
        }
        for i in 0..<90 {
            state.selected = i % 3
            state.motionEnabled = i < 45 || i % 5 != 0
            host.layoutSubtreeIfNeeded()
            checkSources()
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        precondition(flatten(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }.first === file)
        checkSources()
        precondition(!window.isVisible && !HubWorkspaceDragState.isDragging)
    }
}

@MainActor private final class MotionFixtureState: ObservableObject {
    @Published var selected = 0
    @Published var motionEnabled = true
    let ids = (0..<3).map { _ in UUID() }
}

@MainActor private struct MotionFixture: View {
    @ObservedObject var state: MotionFixtureState
    @Namespace private var selection
    private var motion: HubInterfaceMotion { .init(enabled: state.motionEnabled) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Text("Tab \(index)").frame(width: 80, height: 32)
                        .background(HubSelectionBackdrop(selected: state.selected == index, namespace: selection))
                        .overlay(HubWorkspaceDragBridge(workspaceID: state.ids[index], title: "Tab", acceptsReorderDrops: false,
                            onSelect: {}, onReorder: { _, _, _ in }, onDragStateChanged: { _ in }))
                }
            }
            .animation(motion.selection, value: state.selected)
            .animation(nil, value: motion.enabled)
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 320, height: 180)
            .overlay(HubNativeFileDropBridge(contains: { _ in true }, operation: { _, _, _, _ in .copy }, receive: { _, _, _, _ in true }))
            .environment(\.hubInterfaceMotion, motion)
    }
}
