import Foundation

/// Delays only the requested relaunch. Canceling/replacing an update invalidates
/// its handler, including while a file/provider operation is still finishing.
@MainActor final class FileDockUpdateRelaunchGate {
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    @discardableResult
    func postpone(whileBusy busy: @escaping () -> Bool, resume: @escaping () -> Void) -> Bool {
        cancel()
        guard busy() else { return false }
        task = Task {
            while busy() {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            resume()
        }
        return true
    }
    deinit { task?.cancel() }
}
