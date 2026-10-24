import Foundation

@main struct UpdateRelaunchTests {
    @MainActor static func main() async throws {
        let gate = FileDockUpdateRelaunchGate()
        var busy = false, count = 0
        precondition(!gate.postpone(whileBusy: { busy }, resume: { count += 1 }))
        precondition(count == 0, "Idle installation stays with the updater")
        busy = true
        precondition(gate.postpone(whileBusy: { busy }, resume: { count += 1 }))
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(count == 0)
        busy = false
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(count == 1)
        busy = true
        gate.postpone(whileBusy: { busy }, resume: { count += 100 })
        gate.cancel(); busy = false
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(count == 1, "An aborted update must never invoke a stale installation handler")
        busy = true
        gate.postpone(whileBusy: { busy }, resume: { count += 100 })
        gate.postpone(whileBusy: { busy }, resume: { count += 1 })
        busy = false
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(count == 2, "Only the latest pending relaunch may resume")
        print("PASS: update relaunch waits for real file work, resumes once, and cancels obsolete/aborted handlers without blocking main")
    }
}
