import AppKit
import SwiftUI
import os

/// File URLs come from the actual AppKit drag, independently of SwiftUI's
/// provider coercion. A private token can authorize reordering only with the
/// bound source, pasteboard and complete URL list of the live native session.
@MainActor enum HubNativeFileDropData {
    static let legacyFiles = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let items = pasteboard.pasteboardItems, items.contains(where: { $0.types.contains(.fileURL) }) {
            guard items.count <= 20000 else { return [] }
            for item in items {
                guard let text = item.string(forType: .fileURL), text.utf8.count <= 65536,
                      let url = URL(string: text), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" else { return [] }
                urls.append(url.standardizedFileURL)
            }
        } else if let paths = pasteboard.propertyList(forType: legacyFiles) as? [String], paths.count <= 20000 {
            guard paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 65536 }) else { return [] }
            urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    static func takesHitTest(type: NSEvent.EventType?, mousePressed: Bool, fileDrag: Bool, workspaceDrag: Bool) -> Bool {
        guard !workspaceDrag, mousePressed || fileDrag else { return false }
        switch type {
        case .leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel: return false
        default: return true
        }
    }
}

@MainActor struct HubNativeFileDropBridge: NSViewRepresentable {
    var enabled = true
    var contains: (CGPoint) -> Bool = { _ in true }
    var operation: (CGPoint, [URL], HubFileDragPayload?, Bool) -> NSDragOperation
    var exited: () -> Void = {}
    var receive: ([URL], HubFileDragPayload?, CGPoint, Bool) -> Bool

    func makeNSView(context: Context) -> DestinationView {
        let view = DestinationView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: DestinationView, context: Context) {
        view.enabled = enabled; view.contains = contains; view.operation = operation; view.exited = exited; view.receive = receive
    }
    static func dismantleNSView(_ view: DestinationView, coordinator: ()) {
        // The owning HubView clears feedback and spring loading on disappear.
        // A callback here would mutate its State while SwiftUI destroys the
        // graph, causing an exclusive-access conflict during window teardown.
        view.operation = nil; view.exited = nil; view.receive = nil
    }

    final class DestinationView: NSView {
        var enabled = true
        var contains: (CGPoint) -> Bool = { _ in true }
        var operation: ((CGPoint, [URL], HubFileDragPayload?, Bool) -> NSDragOperation)?
        private static let logger = Logger(subsystem: "local.diexie.filedock", category: "FileDrop")
        var exited: (() -> Void)?
        var receive: (([URL], HubFileDragPayload?, CGPoint, Bool) -> Bool)?
        private struct InputKey: Equatable {
            var sequence: Int
            var board: NSPasteboard.Name
            var change: Int
            var source: ObjectIdentifier?
            var session: UUID?
        }
        private var cachedKey: InputKey?
        private var cachedInput: ([URL], HubFileDragPayload?)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, HubNativeFileDropData.legacyFiles])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, !isHiddenOrHasHiddenAncestor,
                  HubNativeFileDropData.takesHitTest(type: NSApp?.currentEvent?.type,
                    mousePressed: NSEvent.pressedMouseButtons & 1 != 0,
                    fileDrag: HubFileDragState.isDragging, workspaceDrag: HubWorkspaceDragState.isDragging),
                  bounds.intersection(visibleRect).contains(convert(point, from: superview)),
                  contains(convert(point, from: superview)) else { return nil }
            return self
        }
        private func input(_ sender: NSDraggingInfo) -> ([URL], HubFileDragPayload?)? {
            guard enabled, !HubWorkspaceDragState.isDragging, NSApp.modalWindow == nil,
                  window?.attachedSheet == nil else { return nil }
            let source = sender.draggingSource as AnyObject?
            let key = InputKey(sequence: sender.draggingSequenceNumber, board: sender.draggingPasteboard.name,
                change: sender.draggingPasteboard.changeCount, source: source.map(ObjectIdentifier.init), session: HubFileDragState.current?.id)
            if cachedKey == key { return cachedInput }
            cachedKey = key; cachedInput = nil
            let urls = HubNativeFileDropData.urls(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return nil }
            let payload = HubFileDragState.localPayload(source: sender.draggingSource as AnyObject?, pasteboard: sender.draggingPasteboard)
            // Our source must authenticate. An unrelated Finder drag must not
            // be rejected merely because a previous source missed its callback.
            if sender.draggingSource is HubFileDragBridge.FileDragView, payload == nil { return nil }
            cachedInput = (urls, payload)
            return cachedInput
        }
        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let (urls, payload) = input(sender) else { exited?(); return [] }
            let point = convert(sender.draggingLocation, from: nil)
            guard contains(point) else { exited?(); return [] }
            let copy = NSEvent.modifierFlags.contains(.option) || !sender.draggingSourceOperationMask.contains(.move)
            let proposed = operation?(point, urls, payload, copy) ?? []
            let allowed = proposed.intersection(sender.draggingSourceOperationMask)
            // Finder may only allow copying (for example from a read-only disk).
            return allowed.isEmpty && proposed == .move && sender.draggingSourceOperationMask.contains(.copy) ? .copy : allowed
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
        override func draggingExited(_ sender: NSDraggingInfo?) { exited?() }
        override func draggingEnded(_ sender: NSDraggingInfo) { exited?() }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { exited?() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !update(sender).isEmpty }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let (urls, payload) = input(sender), !update(sender).isEmpty else { exited?(); return false }
            let point = convert(sender.draggingLocation, from: nil)
            let copy = NSEvent.modifierFlags.contains(.option) || !sender.draggingSourceOperationMask.contains(.move)
            // End hover before navigation can dismantle this destination.
            let completion = receive
            exited?()
            let accepted = completion?(urls, payload, point, copy) ?? false
            Self.logger.debug("File drop: items=\(urls.count) local=\(payload != nil) copy=\(copy) accepted=\(accepted)")
            return accepted
        }
    }
}
