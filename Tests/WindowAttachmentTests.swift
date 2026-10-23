import Foundation
import CoreGraphics

@main struct WindowAttachmentTests {
    static func main() {
        var automatic = HubWindowAttachmentPolicy()
        precondition(!automatic.automaticallyPinned)
        precondition(automatic.didDetach(currentlyPinned: false) && automatic.automaticallyPinned)
        automatic.didChangePin(true)
        // Subsequent move notifications observe a pin already set by detaching.
        precondition(automatic.didDetach(currentlyPinned: true) && automatic.automaticallyPinned)
        precondition(!automatic.didAttach(currentlyPinned: true) && !automatic.automaticallyPinned)
        precondition(!automatic.didAttach(currentlyPinned: false), "Repeated attachment must not invent a pin")

        var manual = HubWindowAttachmentPolicy()
        precondition(manual.didDetach(currentlyPinned: true) && !manual.automaticallyPinned)
        precondition(manual.didAttach(currentlyPinned: true), "A manual pin must survive a top attachment")

        var overridden = HubWindowAttachmentPolicy()
        _ = overridden.didDetach(currentlyPinned: false)
        overridden.didChangePin(false)
        precondition(!overridden.automaticallyPinned)
        overridden.didChangePin(true)
        precondition(overridden.didAttach(currentlyPinned: true), "Cancel then re-pin belongs to the user")
        _ = overridden.didDetach(currentlyPinned: false)
        overridden.didChangePin(false)
        precondition(!overridden.didAttach(currentlyPinned: false), "Manual unpin stays unpinned")

        // Hiding/reopening beside the cursor is not a top attachment: callers
        // leave this policy untouched, retaining automatic pin ownership.
        var cursorPresentation = HubWindowAttachmentPolicy()
        _ = cursorPresentation.didDetach(currentlyPinned: false)
        precondition(cursorPresentation.automaticallyPinned)
        cursorPresentation.didChangePin(true)
        precondition(cursorPresentation.automaticallyPinned && !cursorPresentation.didAttach(currentlyPinned: true))

        let screen = NSRect(x: 0, y: 24, width: 1440, height: 838)
        func frame(centerOffset: CGFloat = 0, topOffset: CGFloat = 0) -> NSRect {
            NSRect(x: screen.midX - 450 + centerOffset, y: screen.maxY - 480 + topOffset, width: 900, height: 480)
        }
        func attaches(_ value: NSRect, sourceWidth: CGFloat = 200) -> Bool {
            HubWindowAttachmentPolicy.shouldReattach(frame: value, screenVisibleFrame: screen, sourceWidth: sourceWidth)
        }
        precondition(attaches(frame()))
        for offset: CGFloat in [-24, 24] { precondition(attaches(frame(topOffset: offset))) }
        for offset: CGFloat in [-24.01, 24.01] { precondition(!attaches(frame(topOffset: offset))) }
        for offset: CGFloat in [-100, 100] { precondition(attaches(frame(centerOffset: offset))) }
        for offset: CGFloat in [-100.01, 100.01] { precondition(!attaches(frame(centerOffset: offset))) }
        precondition(attaches(frame(centerOffset: 48), sourceWidth: 20))
        precondition(!attaches(frame(centerOffset: 48.01), sourceWidth: 20))
        // Missing, non-finite, or wider-than-screen source geometry falls back
        // to 186 points; it must not make the entire top edge an attachment zone.
        for width: CGFloat in [0, -1, .nan, .infinity, -.infinity, 1441, .greatestFiniteMagnitude] {
            precondition(attaches(frame(centerOffset: 93), sourceWidth: width))
            precondition(!attaches(frame(centerOffset: 93.01), sourceWidth: width))
        }
        let negativeScreen = screen.offsetBy(dx: -2000, dy: -1000)
        precondition(HubWindowAttachmentPolicy.shouldReattach(frame: frame().offsetBy(dx: -2000, dy: -1000),
                     screenVisibleFrame: negativeScreen, sourceWidth: 200), "Secondary displays may have negative coordinates")
        precondition(!HubWindowAttachmentPolicy.shouldReattach(frame: frame(), screenVisibleFrame: negativeScreen,
                     sourceWidth: 200), "A frame on another display must not snap to this screen")

        let invalidFrames: [NSRect] = [
            .zero, NSRect(x: 0, y: 0, width: -10, height: 10), NSRect(x: 0, y: 0, width: 10, height: -10),
            NSRect(x: CGFloat.nan, y: 0, width: 10, height: 10), NSRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
            NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
            NSRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 10)
        ]
        for invalid in invalidFrames {
            precondition(!attaches(invalid))
            precondition(!HubWindowAttachmentPolicy.shouldReattach(frame: frame(), screenVisibleFrame: invalid, sourceWidth: 200))
        }
        print("PASS: drag-detach pin ownership, manual override, top attachment and finite snap geometry")
    }
}
