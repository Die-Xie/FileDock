import SwiftUI
import UniformTypeIdentifiers

/// One spring-loaded target for the whole header. Repeated draggingUpdated
/// events must not restart the dwell timer; a stale exit cannot cancel a new tab.
@MainActor
final class HubWorkspaceSpringLoader: ObservableObject {
    @Published private(set) var target: UUID?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    static func dwell(_ switchDelay: TimeInterval) -> TimeInterval {
        // Turning off ordinary pointer switching still permits drag navigation.
        switchDelay.isFinite && switchDelay > 0 ? min(2, max(0.15, switchDelay)) : 0.35
    }

    func enter(_ id: UUID, delay: TimeInterval, canActivate: @escaping () -> Bool,
               activate: @escaping () -> Void) {
        guard target != id else { return }
        cancel()
        target = id
        let token = generation
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.dwell(delay) * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == token, self.target == id, canActivate() else { return }
            self.task = nil
            activate()
        }
    }

    func exit(_ id: UUID) { if target == id { cancel() } }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        target = nil
    }
}

/// Drop lifecycle events are delivered during a native file drag, unlike the
/// ordinary pointer onHover callbacks. Providers are read only on actual drop.
@MainActor
struct HubWorkspaceFileDropDelegate: DropDelegate {
    static let contentTypes: [UTType] = [hubFileDragType, .fileURL, .image, .url, .item]

    let id: UUID
    let loader: HubWorkspaceSpringLoader
    let delay: TimeInterval
    let canActivate: () -> Bool
    let activate: () -> Void
    var acceptsDrop = true
    var movesFiles = false
    var targeted: (Bool) -> Void = { _ in }
    let receive: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        canActivate() && info.hasItemsConforming(to: Self.contentTypes)
    }

    func dropEntered(info: DropInfo) { entered() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard canActivate() else { loader.exit(id); targeted(false); return DropProposal(operation: .cancel) }
        entered()
        let operation: DropOperation = !acceptsDrop ? .forbidden
            : movesFiles && info.hasItemsConforming(to: [.fileURL]) && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
        return DropProposal(operation: operation)
    }

    func dropExited(info: DropInfo) { loader.exit(id); targeted(false) }

    func performDrop(info: DropInfo) -> Bool {
        loader.exit(id)
        targeted(false)
        guard acceptsDrop, validateDrop(info: info) else { return false }
        return receive(info.itemProviders(for: Self.contentTypes))
    }

    private func entered() {
        guard canActivate() else { return }
        targeted(true)
        loader.enter(id, delay: delay, canActivate: canActivate, activate: activate)
    }
}
