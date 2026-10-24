import Foundation

/// Shared admission control for provider/import batches. Tickets cover the
/// complete callback lifetime, so an update cannot restart during a file write.
@MainActor enum HubImportActivity {
    private static var tickets = Set<UUID>()
    static var isBusy: Bool { !tickets.isEmpty }
    static var count: Int { tickets.count }
    static func begin() -> UUID? {
        guard tickets.count < 2 else { return nil }
        let id = UUID(); tickets.insert(id); return id
    }
    static func end(_ id: UUID) { tickets.remove(id) }
}

/// A provider may never finish or may invoke its callback after timeout. Closing
/// the gate prevents late writes; a write already in progress retains its ticket
/// until the actual filesystem operation returns.
final class HubImportLease: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private var closed = false
    private var writes = 0
    init(id: UUID) { self.id = id }
    func beginWrite() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        writes += 1; return true
    }
    func endWrite() {
        lock.lock(); writes -= 1
        let release = closed && writes == 0
        lock.unlock()
        if release { Task { @MainActor in HubImportActivity.end(id) } }
    }
    @MainActor func close() {
        lock.lock(); closed = true
        let release = writes == 0
        lock.unlock()
        if release { HubImportActivity.end(id) }
    }
}
