import AppKit
import SwiftUI

@main
struct WorkspaceSpringLoadingTests {
    @MainActor static func main() async throws {
        let loader = HubWorkspaceSpringLoader()
        let first = UUID(), second = UUID()
        var selected: [UUID] = []
        var allowed = true
        let canActivate = { allowed }
        func enter(_ id: UUID) {
            loader.enter(id, delay: 0.15, canActivate: canActivate) { selected.append(id) }
        }
        func pause(_ duration: Double) async throws { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }

        enter(first)
        try await pause(0.08)
        enter(first)
        try await pause(0.10)
        precondition(selected == [first], "Repeated drag updates must not postpone switching")
        enter(first)
        try await pause(0.18)
        precondition(selected == [first], "A stationary drag selects its target only once")

        loader.exit(first)
        enter(second)
        loader.exit(second)
        try await pause(0.18)
        precondition(selected == [first] && loader.target == nil, "Leaving before the dwell cancels navigation")

        enter(first)
        enter(second)
        loader.exit(first)
        try await pause(0.18)
        precondition(selected == [first, second], "Late exits from the previous tab cannot cancel the current target")

        loader.cancel()
        enter(first)
        allowed = false
        try await pause(0.18)
        precondition(selected == [first, second], "Hiding the panel, removing a workspace or reordering tabs must prevent stale activation")
        allowed = true
        loader.cancel()
        enter(first)
        loader.cancel()
        try await pause(0.18)
        precondition(selected == [first, second], "Drop/end/cancel cannot leave a pending navigation")

        enter(first)
        try await pause(0.18)
        precondition(selected == [first, second, first], "A fresh drag can revisit the same target")
        precondition(HubWorkspaceSpringLoader.dwell(0) == 0.35, "Drag navigation remains available when ordinary hover is disabled")
        precondition(HubWorkspaceSpringLoader.dwell(.nan) == 0.35)
        precondition(HubWorkspaceSpringLoader.dwell(9) == 2)
        precondition(HubWorkspaceSpringLoader.dwell(0.01) == 0.15)
        loader.cancel()
        print("PASS: drag dwell survives periodic updates, selects once, cancels on exit/end and rejects stale target/disabled callbacks")
        print("LIMIT: Native file-drag routing between SwiftUI destinations requires pointer verification; no user input or files are changed")
    }
}
