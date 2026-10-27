import Foundation

@main struct WorkspaceTabInsertionTests {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let header = CGRect(x: 0, y: 0, width: 680, height: 58)
        let controls = CGRect(x: 550, y: 10, width: 118, height: 32)
        let frames = [a: CGRect(x: 12, y: 13, width: 100, height: 32),
                      b: CGRect(x: 117, y: 13, width: 100, height: 32)]
        func slot(_ x: CGFloat, _ y: CGFloat = 28) -> HubWorkspaceTabInsertion? {
            HubWorkspaceTabInsertion.resolve(at: CGPoint(x: x, y: y), header: header, controls: controls,
                frames: frames, order: [a, b, c])
        }
        precondition(slot(10)?.before == a && slot(18)?.before == a)
        precondition(slot(62) == nil && slot(167) == nil, "Tab centers keep normal spring navigation and file transfers")
        precondition(slot(108)?.before == b && slot(115)?.before == b && slot(121)?.before == b)
        precondition(slot(215)?.before == c && slot(350)?.before == c,
                     "A clipped strip's tail inserts before the next offscreen tab, not the global end")
        precondition(slot(560) == nil && slot(4) == nil && slot(30, 56) == nil)
        precondition(slot(.nan) == nil)
        for point in stride(from: CGFloat(10), through: 549, by: 0.5) {
            if let value = slot(point) {
                precondition(header.contains(value.marker) && !value.marker.intersects(controls))
                precondition(value.marker.width == 2 && value.marker.height > 0)
            }
        }
        let music = CGRect(x: 280, y: 5, width: 180, height: 42)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 350, y: 28), header: header, controls: controls,
            music: music, frames: frames, order: [a, b]) == nil)
        let exclusion = CGRect(x: 240, y: 0, width: 200, height: 58)
        var split = frames; split[c] = CGRect(x: 490, y: 13, width: 50, height: 32)
        func splitSlot(_ x: CGFloat) -> HubWorkspaceTabInsertion? {
            HubWorkspaceTabInsertion.resolve(at: CGPoint(x: x, y: 28), header: header, controls: controls,
                exclusion: exclusion, frames: split, order: [a, b, c, d])
        }
        precondition(splitSlot(300) == nil)
        precondition(splitSlot(230)?.before == c && splitSlot(445)?.before == c)
        precondition(splitSlot(538)?.before == d)
        precondition(splitSlot(510) == nil)
        let empty = HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 28), header: header,
            controls: controls, frames: [:], order: [])!
        precondition(empty.before == nil && empty.marker.width == 2)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 28), header: header,
            controls: controls, frames: [:], order: [a]) == nil, "Incomplete anchors cannot promise an insertion slot")
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 480, y: 28), header: header,
            controls: controls, exclusion: exclusion, frames: frames, order: [a, b]) == nil,
            "An empty right strip must not draw an insertion marker for a tab that would flow left")
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 480, y: 28), header: header,
            controls: controls, exclusion: exclusion, frames: [:], order: []) == nil)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 28), header: header,
            controls: controls, exclusion: exclusion, frames: [:], order: []) != nil)
        let shiftedHeader = CGRect(x: 0, y: 0, width: 680, height: 100)
        let shiftedControls = CGRect(x: 550, y: 46, width: 118, height: 32)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 12), header: shiftedHeader,
            controls: shiftedControls, frames: [:], order: []) == nil, "Inset space above the actual row is not a drop zone")
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 60), header: shiftedHeader,
            controls: shiftedControls, frames: [:], order: []) != nil)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 28), header: .zero,
            controls: controls, frames: frames, order: [a, b]) == nil)
        precondition(HubWorkspaceTabInsertion.resolve(at: CGPoint(x: 120, y: 28), header: header,
            controls: .zero, frames: frames, order: [a, b]) == nil, "Incomplete control anchors cannot expose buttons as insertion targets")
        print("PASS: tab edge/gap/end insertion, ordinary centers preserved, offscreen order, empty strip, split notch, music/controls/inset exclusions, stable bounded 2pt markers and invalid geometry")
    }
}
