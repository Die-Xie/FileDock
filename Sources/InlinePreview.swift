import AppKit
import Quartz
import SwiftUI

/// Native preview children own document scrolling, selection and copy shortcuts.
enum HubInlinePreviewFocus {
    @MainActor static func contains(_ responder: NSResponder?) -> Bool {
        var cursor = responder
        var seen = Set<ObjectIdentifier>()
        while let current = cursor, seen.insert(ObjectIdentifier(current)).inserted {
            if let view = current as? NSView {
                var ancestor: NSView? = view
                while let candidate = ancestor {
                    if candidate is HubInlinePreviewHostView { return true }
                    ancestor = candidate.superview
                }
            }
            cursor = current.nextResponder
        }
        return false
    }
}

@MainActor
struct HubInlinePreview: NSViewRepresentable {
    let item: HubInlinePreviewIdentity?

    func makeNSView(context: Context) -> HubInlinePreviewHostView { HubInlinePreviewHostView() }
    func updateNSView(_ view: HubInlinePreviewHostView, context: Context) { view.update(item) }
    static func dismantleNSView(_ view: HubInlinePreviewHostView, coordinator: ()) { view.close() }
}

/// One reusable native preview. Repeated model polls must not reset its page or zoom.
@MainActor
final class HubInlinePreviewHostView: NSView {
    private let preview: QLPreviewView
    private var identity: HubInlinePreviewIdentity?
    private var savedIdentity: HubInlinePreviewIdentity?
    private var savedDisplayState: Any?
    private var closed = false

    override init(frame frameRect: NSRect) {
        preview = QLPreviewView(frame: .zero, style: .normal)
        super.init(frame: frameRect)
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityLabel("文件内容预览")
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ requested: HubInlinePreviewIdentity?) {
        guard !closed else { return }
        let next = requested.flatMap { HubInlinePreviewPolicy.isExecutableBundle($0.url) ? nil : $0 }
        switch HubInlinePreviewUpdate.action(previous: identity, next: next) {
        case .unchanged: return
        case .clear:
            savedIdentity = identity
            savedDisplayState = preview.displayState
            preview.previewItem = nil
        case .replace:
            preview.previewItem = next?.url as NSURL?
            if next == savedIdentity, let savedDisplayState { preview.displayState = savedDisplayState }
            self.savedDisplayState = nil
            savedIdentity = nil
        case .refresh:
            preview.refreshPreviewItem()
        }
        identity = next
    }

    func close() {
        guard !closed else { return }
        closed = true
        identity = nil
        savedIdentity = nil
        savedDisplayState = nil
        preview.previewItem = nil
        preview.close()
    }
}
