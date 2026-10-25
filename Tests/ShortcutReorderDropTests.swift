import AppKit
import SwiftUI

@main struct ShortcutReorderDropTests {
    private static let ids = (0..<4).map { _ in UUID() }
    private static let bounds = CGRect(x: 0, y: 0, width: 400, height: 100)
    private static var frames: [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: 100 + CGFloat($0.offset) * 34, y: 20, width: 30, height: 32)) })
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        geometry()
        callbacks()
        sourceOnlyClicks()
        print("PASS: unified reorder gaps, leading/trailing 32pt, vertical 6pt, clipped strips, no-op/source removal, offscreen sources, domain registration, native callbacks, stale/auth rejection and click pass-through")
        print("LIMIT: Actual pointer drag/edge autoscroll and rendering in FileDock need native UI verification; no visible windows, files or sharing are used")
    }

    private static func geometry() {
        func plan(_ x: CGFloat, _ y: CGFloat = 35, source: UUID = ids[1]) -> HubShortcutReorderPlan? {
            HubShortcutReorderGeometry.plan(frames: frames, bounds: bounds, point: CGPoint(x: x, y: y), sourceID: source)
        }
        precondition(plan(67.99) == nil && plan(68) != nil)
        precondition(plan(263.99) != nil && plan(264) == nil)
        precondition(plan(130, 13.99) == nil && plan(130, 14) != nil)
        precondition(plan(130, 57.99) != nil && plan(130, 58) == nil)
        precondition(plan(.nan) == nil && plan(.infinity) == nil)
        let leading = plan(75)!
        precondition(leading.targetID == ids[0] && !leading.after && leading.insertionIndex == 0 && !leading.isNoOp)
        let trailing = plan(260)!
        precondition(trailing.targetID == ids[3] && trailing.after && trailing.insertionIndex == 3 && !trailing.isNoOp)
        let gap = plan(132, source: ids[3])!
        precondition(gap.targetID == ids[1] && !gap.after && gap.marker.midX == 132)
        precondition(plan(132)!.isNoOp && plan(166)!.isNoOp, "Both sides of the source occupy its original insertion slot")
        let secondHalf = plan(155, source: ids[0])!
        precondition(secondHalf.targetID == ids[2] && !secondHalf.after && secondHalf.insertionIndex == 1)
        for source in ids {
            for x in stride(from: CGFloat(68), through: 263, by: 1) {
                let p = plan(x, source: source)!
                if p.isNoOp { precondition(p.insertionIndex == ids.firstIndex(of: source)!) }
                else {
                    precondition(p.targetID != source)
                    var result = ids.filter { $0 != source }
                    let targetIndex = result.firstIndex(of: p.targetID)!
                    result.insert(source, at: targetIndex + (p.after ? 1 : 0))
                    precondition(result.firstIndex(of: source) == p.insertionIndex && result != ids)
                }
            }
        }
        var missing = frames
        missing.removeValue(forKey: ids[1])
        precondition(HubShortcutReorderGeometry.plan(frames: missing, bounds: bounds, point: CGPoint(x: 132, y: 35), sourceID: ids[1]) == nil)
        let offscreen = HubShortcutReorderGeometry.plan(frames: missing, bounds: bounds, point: CGPoint(x: 260, y: 35), sourceID: ids[1], orderedIDs: ids)!
        precondition(offscreen.targetID == ids[3] && offscreen.after && offscreen.insertionIndex == 3)
        var invalid = frames
        invalid[ids[1]] = CGRect(x: 900, y: 20, width: 30, height: 32)
        precondition(HubShortcutReorderGeometry.plan(frames: invalid, bounds: bounds, point: CGPoint(x: 132, y: 35), sourceID: ids[1]) == nil)
        invalid[ids[1]] = CGRect(x: 134, y: 20, width: 0, height: 32)
        precondition(HubShortcutReorderGeometry.plan(frames: invalid, bounds: bounds, point: CGPoint(x: 132, y: 35), sourceID: ids[1]) == nil)

        let splitFrames = [ids[0]: CGRect(x: 20, y: 20, width: 30, height: 32),
                           ids[1]: CGRect(x: 54, y: 20, width: 30, height: 32),
                           ids[2]: CGRect(x: 280, y: 20, width: 30, height: 32),
                           ids[3]: CGRect(x: 314, y: 20, width: 30, height: 32)]
        let strips = [CGRect(x: 0, y: 10, width: 100, height: 50), CGRect(x: 260, y: 10, width: 120, height: 50)]
        func splitPlan(_ x: CGFloat) -> HubShortcutReorderPlan? {
            HubShortcutReorderGeometry.plan(frames: splitFrames, bounds: bounds, point: CGPoint(x: x, y: 35), sourceID: ids[0], dropBounds: strips, orderedIDs: ids)
        }
        precondition(splitPlan(100) == nil && splitPlan(150) == nil && splitPlan(259) == nil, "The notch between strip viewports is never a drop target")
        precondition(splitPlan(98)!.targetID == ids[1] && splitPlan(98)!.after)
        precondition(splitPlan(265)!.targetID == ids[2] && !splitPlan(265)!.after)
        precondition(splitPlan(370)!.targetID == ids[3] && splitPlan(370)!.after)
        var edgeFrames = splitFrames
        edgeFrames[ids[2]] = CGRect(x: 250, y: 20, width: 30, height: 32)
        let edgePlan = HubShortcutReorderGeometry.plan(frames: edgeFrames, bounds: bounds, point: CGPoint(x: 260, y: 35), sourceID: ids[0], dropBounds: strips, orderedIDs: ids)!
        precondition(strips[1].contains(edgePlan.marker), "A marker at a clipped edge must stay within its own safe strip, not extend into the notch")
        let cropped = CGRect(x: 0, y: 0, width: 150, height: 100)
        precondition(HubShortcutReorderGeometry.plan(frames: frames, bounds: cropped, point: CGPoint(x: 151, y: 35), sourceID: ids[0]) == nil)
        let cropPlan = HubShortcutReorderGeometry.plan(frames: frames, bounds: cropped, point: CGPoint(x: 149, y: 35), sourceID: ids[0])!
        precondition(cropPlan.targetID == ids[1] && cropped.contains(cropPlan.marker), "Root clipping excludes hidden targets and keeps the line visible")
        let single = HubShortcutReorderGeometry.plan(frames: [ids[0]: frames[ids[0]]!], bounds: bounds, point: CGPoint(x: 75, y: 35), sourceID: ids[0])!
        precondition(single.isNoOp)
    }

    @MainActor private static func callbacks() {
        for domain in [HubWorkspaceDragDomain.shortcut, .workspace] {
            let source = HubWorkspaceDragBridge.WorkspaceDragView(frame: frames[ids[1]]!)
            source.workspaceID = ids[1]; source.domain = domain; source.acceptsReorderDrops = false
            let target = HubShortcutReorderDropBridge.DestinationView(frame: bounds)
            target.frames = frames; target.domain = domain
            let otherDomain = HubShortcutReorderDropBridge.DestinationView(frame: bounds)
            otherDomain.domain = domain == .shortcut ? .workspace : .shortcut; otherDomain.frames = frames
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let payload = HubWorkspaceDragPayload(id: UUID(), workspaceID: ids[1], domain: domain)
            precondition(target.registeredDraggedTypes.isEmpty && otherDomain.registeredDraggedTypes.isEmpty)
            HubWorkspaceDragState.begin(payload, source: source)
            precondition(target.registeredDraggedTypes == [hubWorkspaceDragType] && otherDomain.registeredDraggedTypes.isEmpty)
            let midSession = HubShortcutReorderDropBridge.DestinationView(frame: bounds)
            midSession.domain = domain
            precondition(midSession.registeredDraggedTypes == [hubWorkspaceDragType], "A receiver created mid-session arms the current domain")
            precondition(board.writeObjects([HubWorkspaceDragData.pasteboardItem(for: payload)]))
            HubWorkspaceDragState.bind(pasteboard: board, source: source, for: payload.id)
            let info = ShortcutDropInfo(board: board, source: source)
            func move(_ point: CGPoint) { info.draggingLocation = target.convert(point, to: nil) }
            move(CGPoint(x: 260, y: 35))
            var reorder: [(UUID, UUID, Bool)] = []
            var selections = 0
            source.onSelect = { selections += 1 }
            target.onReorder = { reorder.append(($0, $1, $2)) }
            precondition(source.registeredDraggedTypes.isEmpty && source.hitTest(NSPoint(x: 140, y: 30)) == nil)
            precondition(target.hitTest(target.convert(CGPoint(x: 260, y: 35), to: target.superview)) === target)
            precondition(otherDomain.hitTest(otherDomain.convert(CGPoint(x: 260, y: 35), to: otherDomain.superview)) == nil)
            precondition(otherDomain.draggingEntered(info).isEmpty)
            precondition(target.draggingEntered(info) == .move && target.insertion?.after == true)
            precondition(target.prepareForDragOperation(info))
            precondition(target.performDragOperation(info))
            precondition(reorder.count == 1 && reorder[0].0 == ids[1] && reorder[0].1 == ids[3] && reorder[0].2 && selections == 0)
            precondition(target.insertion == nil)
            move(CGPoint(x: 75, y: 35))
            precondition(target.draggingUpdated(info) == .move && target.insertion?.after == false)
            precondition(target.performDragOperation(info) && reorder.count == 2 && reorder[1].1 == ids[0] && !reorder[1].2)
            move(CGPoint(x: 132, y: 35))
            precondition(target.draggingEntered(info) == .move && target.insertion?.isNoOp == true)
            precondition(target.performDragOperation(info) && reorder.count == 2, "A source's adjacent slot is an accepted no-op")
            move(CGPoint(x: 260, y: 14))
            precondition(target.draggingEntered(info) == .move)
            target.draggingExited(info); precondition(target.insertion == nil)
            precondition(target.draggingEntered(info) == .move)
            target.draggingEnded(info); precondition(target.insertion == nil)
            precondition(target.draggingEntered(info) == .move)
            target.concludeDragOperation(info); precondition(target.insertion == nil)
            move(CGPoint(x: 260, y: 13.9))
            precondition(target.draggingUpdated(info).isEmpty && !target.performDragOperation(info))
            move(CGPoint(x: 260, y: 35))
            precondition(target.draggingEntered(info) == .move)
            target.enabled = false
            precondition(target.insertion == nil && target.registeredDraggedTypes.isEmpty && !target.performDragOperation(info))
            target.enabled = true
            precondition(target.registeredDraggedTypes == [hubWorkspaceDragType])
            target.isHidden = true
            precondition(target.draggingEntered(info).isEmpty && !target.performDragOperation(info))
            target.isHidden = false; source.isHidden = true
            precondition(target.draggingEntered(info).isEmpty)
            source.isHidden = false
            target.frames.removeValue(forKey: ids[1])
            precondition(target.draggingEntered(info).isEmpty)
            target.orderedIDs = ids
            precondition(target.draggingEntered(info) == .move, "An explicitly listed offscreen workspace source remains valid")
            target.frames = frames; target.orderedIDs = []
            info.draggingSourceOperationMask = .copy
            precondition(target.draggingEntered(info).isEmpty)
            info.draggingSourceOperationMask = .move
            info.draggingSource = NSObject()
            precondition(target.draggingEntered(info).isEmpty)
            info.draggingSource = source
            board.clearContents()
            precondition(board.writeObjects([HubWorkspaceDragData.pasteboardItem(for: payload)]))
            precondition(target.draggingEntered(info).isEmpty, "Replacing the pasteboard invalidates the binding even with the same token")
            HubWorkspaceDragState.bind(pasteboard: board, source: source, for: payload.id)
            precondition(target.draggingEntered(info) == .move)
            HubWorkspaceDragState.end(payload.id, source: source)
            precondition(target.insertion == nil && target.registeredDraggedTypes.isEmpty && midSession.registeredDraggedTypes.isEmpty)
            precondition(target.hitTest(target.convert(CGPoint(x: 260, y: 35), to: target.superview)) == nil && !target.performDragOperation(info))
            precondition(reorder.count == 2 && selections == 0)
        }
    }

    @MainActor private static func sourceOnlyClicks() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        window.contentView = root
        let source = HubWorkspaceDragBridge.WorkspaceDragView(frame: CGRect(x: 10, y: 10, width: 30, height: 32))
        source.acceptsReorderDrops = false; source.domain = .shortcut
        root.addSubview(source)
        var clicks = 0
        source.onSelect = { clicks += 1 }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: source.convert(CGPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        source.mouseDown(with: event(.leftMouseDown)); source.mouseUp(with: event(.leftMouseUp))
        precondition(clicks == 1 && !window.isVisible && !HubWorkspaceDragState.isDragging)
        source.acceptsReorderDrops = true
        precondition(source.registeredDraggedTypes == [hubWorkspaceDragType])
    }
}

@MainActor private final class ShortcutDropInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?) { draggingPasteboard = board; draggingSource = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
