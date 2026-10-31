import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// SwiftUI can retain a previous drop destination after the pointer exits it.
/// Never accept a content drop whose release point is outside that content.
struct HubContentFileDropDelegate: DropDelegate {
    let size: CGSize
    let types: [UTType]
    let targeted: (Bool) -> Void
    let receive: ([NSItemProvider]) -> Bool
    var accepts: () -> Bool = { true }

    func contains(_ point: CGPoint) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
            CGRect(origin: .zero, size: size).contains(point)
    }
    func validateDrop(info: DropInfo) -> Bool { accepts() && contains(info.location) }
    func dropEntered(info: DropInfo) { targeted(accepts() && contains(info.location)) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let inside = accepts() && contains(info.location)
        targeted(inside)
        guard inside else { return nil }
        let internalDrag = types.first.map { info.hasItemsConforming(to: [$0]) } ?? false
        return DropProposal(operation: internalDrag && !NSEvent.modifierFlags.contains(.option) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool { perform(at: info.location, providers: info.itemProviders(for: types)) }
    func perform(at point: CGPoint, providers: [NSItemProvider]) -> Bool {
        targeted(false)
        guard accepts(), contains(point) else { return false }
        return receive(providers)
    }
}

struct HubContentDropSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
