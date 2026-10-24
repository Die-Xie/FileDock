import Foundation

/// Cancelled Quick Look requests retain their real slot until their callback
/// returns. Rapid tab switching cannot flood the system with decoding requests.
@MainActor final class HubThumbnailWorkQueue {
    static let shared = HubThumbnailWorkQueue()
    private struct Job { var start: (@escaping @MainActor () -> Void) -> Void; var cancel: () -> Void }
    private var pending: [UUID] = []
    private var jobs: [UUID: Job] = [:]
    private var active = Set<UUID>()
    private let limit: Int
    private let queueLimit: Int
    private var pumpScheduled = false
    private var pumping = false
    var activeCount: Int { active.count }
    var pendingCount: Int { pending.count }
    init(limit: Int = 4, queueLimit: Int = 128) { self.limit = max(1, limit); self.queueLimit = max(1, queueLimit) }
    func submit(start: @escaping (@escaping @MainActor () -> Void) -> Void, cancel: @escaping () -> Void) -> UUID? {
        guard pending.count < queueLimit else { return nil }
        let id = UUID(); jobs[id] = Job(start: start, cancel: cancel); pending.append(id)
        schedulePump()
        return id
    }
    func cancel(_ id: UUID) {
        if active.contains(id) { jobs[id]?.cancel() }
        else { jobs.removeValue(forKey: id); pending.removeAll { $0 == id } }
    }
    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in self?.pumpScheduled = false; self?.pump() }
    }
    private func pump() {
        guard !pumping else { return }
        pumping = true; defer { pumping = false }
        while active.count < limit, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let job = jobs[id] else { continue }
            active.insert(id)
            job.start { [weak self] in
                guard let self, self.active.remove(id) != nil else { return }
                self.jobs.removeValue(forKey: id)
                self.schedulePump()
            }
        }
    }
}
