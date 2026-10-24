import SwiftUI
import AppKit

/// Screen-derived layout is transient; it must not leak into saved preferences.
@MainActor
final class HubPresentationState: ObservableObject {
    struct Header: Equatable {
        var embedded = false
        var exclusionWidth: CGFloat = 0
        var topInset: CGFloat = 0
        var split = false
    }
    @Published var header = Header()
    @Published var previewVisible = false { didSet { if oldValue != previewVisible { updateRenderingPolicy() } } }
    @Published private(set) var fileDragActive = false
    @Published private(set) var windowMoving = false
    private(set) var movingPinned = false
    @Published private(set) var layoutChanging = false
    private var layoutTask: Task<Void, Never>?
    @Published private(set) var surfaceAnimating = false
    var defersFileRendering: Bool { !previewVisible || fileDragActive || windowMoving || surfaceAnimating || layoutChanging }
    init() { updateRenderingPolicy() }
    func setSurfaceAnimating(_ active: Bool) {
        guard surfaceAnimating != active else { return }
        surfaceAnimating = active
        updateRenderingPolicy()
    }
    func beginWindowMove(pinned: Bool) {
        guard !windowMoving else { return }
        movingPinned = pinned
        windowMoving = true
        updateRenderingPolicy()
    }
    func endWindowMove(reduceMotion: Bool) {
        guard windowMoving else { return }
        layoutTask?.cancel()
        layoutChanging = !reduceMotion
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            header = .init()
            windowMoving = false
        }
        updateRenderingPolicy()
        if layoutChanging {
            layoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
                guard let self else { return }
                self.layoutChanging = false; self.updateRenderingPolicy()
            }
        }
    }
    private func updateRenderingPolicy() {
        HubFileIconCache.prefersLightweight = defersFileRendering
        HubFileIconUpdates.setPaused(defersFileRendering)
    }
    func setFileDragActive(_ active: Bool) {
        guard fileDragActive != active else { return }
        fileDragActive = active
        updateRenderingPolicy()
    }
}
