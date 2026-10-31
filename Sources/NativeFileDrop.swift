import AppKit
import SwiftUI
import os

/// Posted when an external color drop has been accepted. Observers must defer
/// focus changes until the native drop callback returns.
let hubExternalColorDropAccepted = Notification.Name("HubExternalColorDropAccepted")

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

    static func takesHitTest(type: NSEvent.EventType?, mousePressed: Bool, fileDrag: Bool, workspaceDrag: Bool, localPressDispatch: Bool = false) -> Bool {
        guard !workspaceDrag, mousePressed || fileDrag else { return false }
        // The current NSEvent may be retained from an unrelated interaction
        // when Finder owns the drag. Only reject an event while this app is
        // actually dispatching it; neither its age nor app activation is proof.
        if localPressDispatch {
            switch type {
            case .leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel: return false
            default: break
            }
        }
        return true
    }

    static func externalRelease(type: NSEvent.EventType?, active: Bool) -> Bool { active && type == .leftMouseUp }
}

/// A local monitor marks pointer events actually being dispatched by this app.
/// Clear on the next main queue turn so a retained NSApp.currentEvent cannot
/// mask a later Finder drag, including a quick re-entry from another app.
@MainActor enum HubLocalFilePressDispatch {
    private struct Identity: Equatable {
        var type: NSEvent.EventType
        var windowNumber: Int
        var timestamp: TimeInterval
        init(_ event: NSEvent) {
            // eventNumber is invalid for wheel and keyboard events and raises
            // an Objective-C exception. These fields are valid for every event.
            type = event.type; windowNumber = event.windowNumber; timestamp = event.timestamp
        }
    }
    private static var monitor: Any?
    private static var identity: Identity?
    private static var generation: UInt64 = 0

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]) { event in
            MainActor.assumeIsolated { begin(event) }
            return event
        }
    }

    static func begin(_ event: NSEvent) {
        guard [.leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel].contains(event.type) else { return }
        generation &+= 1
        let token = generation
        identity = Identity(event)
        DispatchQueue.main.async { if generation == token { identity = nil } }
    }

    static func contains(_ event: NSEvent?) -> Bool {
        guard let event, let identity else { return false }
        return identity == Identity(event)
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
        view.enabled = enabled
        view.identifier = NSUserInterfaceItemIdentifier("FileDockUnifiedFileDropRouter")
        view.contains = contains; view.operation = operation; view.exited = exited; view.receive = receive
    }
    static func dismantleNSView(_ view: DestinationView, coordinator: ()) {
        // The owning HubView clears feedback and spring loading on disappear.
        // A callback here would mutate its State while SwiftUI destroys the
        // graph, causing an exclusive-access conflict during window teardown.
        view.resetTracking(); view.operation = nil; view.exited = nil; view.receive = nil
    }

    final class DestinationView: NSView {
        var enabled = true
        var contains: (CGPoint) -> Bool = { _ in true }
        var operation: ((CGPoint, [URL], HubFileDragPayload?, Bool) -> NSDragOperation)?
        var currentEventType: () -> NSEvent.EventType? = { NSApp?.currentEvent?.type }
        var currentEventIsLocalPress: () -> Bool = { HubLocalFilePressDispatch.contains(NSApp?.currentEvent) }
        var primaryMousePressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
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
        private var externalDragActive = false
        #if FILEDOCK_DRAG_DIAGNOSTICS
        var diagnosticRole: String { "unified-file" }
        #endif
        override init(frame: NSRect) {
            super.init(frame: frame)
            HubLocalFilePressDispatch.install()
            registerForDraggedTypes([.fileURL, HubNativeFileDropData.legacyFiles])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        func resetTracking() { externalDragActive = false; cachedKey = nil; cachedInput = nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { resetTracking() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let eventType = currentEventType()
            let pressed = primaryMousePressed()
            // A locally dispatched press cannot belong to the previous drag session. This
            // also recovers if AppKit never delivered its exit/end callback.
            if currentEventIsLocalPress() && (eventType == .leftMouseDown || eventType == .rightMouseDown || eventType == .otherMouseDown) { resetTracking() }
            let externalRelease = HubNativeFileDropData.externalRelease(type: eventType, active: externalDragActive)
            if !pressed && !externalRelease { externalDragActive = false }
            let local = convert(point, from: superview)
            let inside = bounds.intersection(visibleRect).contains(local)
            let eligible = enabled && !isHiddenOrHasHiddenAncestor &&
                HubNativeFileDropData.takesHitTest(type: eventType, mousePressed: pressed,
                    fileDrag: HubFileDragState.isDragging || externalRelease, workspaceDrag: HubWorkspaceDragState.isDragging,
                    localPressDispatch: currentEventIsLocalPress())
            let accepted = eligible && inside && contains(local)
            #if FILEDOCK_DRAG_DIAGNOSTICS
            if HubFileDragState.isDragging {
                HubDragDiagnostics.log("destination-hit", "kind=\(diagnosticRole) eligible=\(eligible) inside=\(inside) accepted=\(accepted) event=\(eventType?.rawValue ?? 0) pressed=\(pressed)")
            }
            #endif
            guard accepted else { return nil }
            return self
        }
        private func input(_ sender: NSDraggingInfo) -> ([URL], HubFileDragPayload?)? {
            guard enabled, !HubWorkspaceDragState.isDragging, NSApp.modalWindow == nil,
                  window?.attachedSheet == nil else { return nil }
            let source = sender.draggingSource as AnyObject?
            let key = InputKey(sequence: sender.draggingSequenceNumber, board: sender.draggingPasteboard.name,
                change: sender.draggingPasteboard.changeCount, source: source.map(ObjectIdentifier.init), session: HubFileDragState.current?.id)
            if cachedKey == key { return cachedInput }
            // AppKit can enter a destination before beginDraggingSession
            // returns and binds our pasteboard. Authentication may therefore
            // become valid without the drag sequence or pasteboard changing.
            // Only cache successful reads; retry a transient failure on update.
            cachedKey = nil; cachedInput = nil
            let urls = HubNativeFileDropData.urls(from: sender.draggingPasteboard)
            guard !urls.isEmpty else {
                #if FILEDOCK_DRAG_DIAGNOSTICS
                HubDragDiagnostics.log("destination-input", "status=no-urls")
                #endif
                return nil
            }
            let payload = HubFileDragState.localPayload(source: sender.draggingSource as AnyObject?, pasteboard: sender.draggingPasteboard)
            // Our source must authenticate. An unrelated Finder drag must not
            // be rejected merely because a previous source missed its callback.
            if sender.draggingSource is HubFileDragBridge.FileDragView, payload == nil {
                #if FILEDOCK_DRAG_DIAGNOSTICS
                HubDragDiagnostics.log("destination-input", "status=local-auth-failed count=\(urls.count)")
                #endif
                return nil
            }
            #if FILEDOCK_DRAG_DIAGNOSTICS
            HubDragDiagnostics.log("destination-input", "status=accepted local=\(payload != nil) count=\(urls.count)")
            #endif
            cachedKey = key
            cachedInput = (urls, payload)
            return cachedInput
        }
        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let (urls, payload) = input(sender) else {
                #if FILEDOCK_DRAG_DIAGNOSTICS
                HubDragDiagnostics.log("destination-update", "status=invalid-input kind=\(diagnosticRole)")
                #endif
                exited?(); return []
            }
            let point = convert(sender.draggingLocation, from: nil)
            guard contains(point) else {
                #if FILEDOCK_DRAG_DIAGNOSTICS
                HubDragDiagnostics.log("destination-update", "status=outside kind=\(diagnosticRole)")
                #endif
                exited?(); return []
            }
            let copy = NSEvent.modifierFlags.contains(.option) || !sender.draggingSourceOperationMask.contains(.move)
            let proposed = operation?(point, urls, payload, copy) ?? []
            let allowed = proposed.intersection(sender.draggingSourceOperationMask)
            #if FILEDOCK_DRAG_DIAGNOSTICS
            HubDragDiagnostics.log("destination-update", "status=planned kind=\(diagnosticRole) local=\(payload != nil) proposed=\(proposed.rawValue) allowed=\(allowed.rawValue)")
            #endif
            // Finder may only allow copying (for example from a read-only disk).
            return allowed.isEmpty && proposed == .move && sender.draggingSourceOperationMask.contains(.copy) ? .copy : allowed
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            #if FILEDOCK_DRAG_DIAGNOSTICS
            HubDragDiagnostics.log("destination-enter", "kind=\(diagnosticRole)")
            #endif
            let result = update(sender); externalDragActive = !result.isEmpty
            return result
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let result = update(sender); externalDragActive = !result.isEmpty; return result
        }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
        override func draggingExited(_ sender: NSDraggingInfo?) { externalDragActive = false; exited?() }
        override func draggingEnded(_ sender: NSDraggingInfo) { externalDragActive = false; exited?() }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { externalDragActive = false; exited?() }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !update(sender).isEmpty }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let (urls, payload) = input(sender), !update(sender).isEmpty else { externalDragActive = false; exited?(); return false }
            let point = convert(sender.draggingLocation, from: nil)
            let copy = NSEvent.modifierFlags.contains(.option) || !sender.draggingSourceOperationMask.contains(.move)
            // End hover before navigation can dismantle this destination.
            let completion = receive
            exited?()
            let accepted = completion?(urls, payload, point, copy) ?? false
            externalDragActive = false
            Self.logger.debug("File drop: items=\(urls.count) local=\(payload != nil) copy=\(copy) accepted=\(accepted)")
            return accepted
        }
    }
}
