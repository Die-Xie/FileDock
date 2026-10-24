import AppKit
import SwiftUI

@MainActor private final class DropLayoutFixture: ObservableObject {
    @Published var empty = false
    let id = UUID()
    let file = URL(fileURLWithPath: "/source.txt")
    var measuredRegions = Set<HubFileDropRegion>()
}
@MainActor private struct DropLayoutView: View {
    @ObservedObject var fixture: DropLayoutFixture
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Target tab").frame(width: 120, height: 50)
                    .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.workspace(fixture.id): $0] }
                Spacer()
            }.transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { regions, anchor in
                regions[.tabViewport(fixture.id)] = anchor
            }
            Group {
                if fixture.empty { Text("Empty target folder") }
                else {
                    ScrollView {
                        Text("Source file").frame(height: 100)
                            .anchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { [.item(fixture.file): $0] }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .transformAnchorPreference(key: HubFileDropRegionKey.self, value: .bounds) { regions, anchor in regions[.content] = anchor }
        }
        .overlayPreferenceValue(HubFileDropRegionKey.self) { anchors in
            GeometryReader { geometry in
                let regions = anchors.mapValues { geometry[$0] }
                HubNativeFileDropBridge(contains: { point in
                    fixture.measuredRegions = Set(regions.keys)
                    return HubFileDropRegion.at(point, in: regions) != nil
                },
                    operation: { _, _, _, _ in .copy }, receive: { _, _, _, _ in true })
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}
@main struct NativeDropHostingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let fixture = DropLayoutFixture()
        let host = NSHostingView(rootView: DropLayoutView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        settle(host)
        guard let first = destination(in: host) else { preconditionFailure("Native destination must exist before spring navigation") }
        precondition(first.frame.size == CGSize(width: 600, height: 350), "The unified destination must cover the actual panel, rather than an intrinsic 10pt region")
        let payload = HubFileDragPayload(id: UUID(), context: .init(workspaceID: fixture.id, directory: nil), urls: [URL(fileURLWithPath: "/test.txt")])
        HubFileDragState.begin(payload)
        defer { HubFileDragState.end(payload.id) }
        precondition(host.hitTest(CGPoint(x: 300, y: 150)) === first, "The file destination must win over underlying content during a live drag")
        precondition(fixture.measuredRegions.contains(.workspace(fixture.id)), "A parent viewport must append to, never overwrite, child tab anchors")
        precondition(fixture.measuredRegions.contains(.item(fixture.file)), "The content region must append to, never overwrite, item anchors needed for reorder guidance")
        fixture.empty = true
        settle(host)
        precondition(destination(in: host) === first, "Spring-loaded navigation must preserve the same AppKit destination")
        precondition(host.hitTest(CGPoint(x: 300, y: 150)) === first, "Empty destinations must still receive the eventual release")
        print("PASS: actual SwiftUI/AppKit layout fills the panel, wins file hit testing and preserves native destination identity across spring-loaded empty-folder navigation")
    }
    @MainActor private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func destination(in view: NSView) -> HubNativeFileDropBridge.DestinationView? {
        if let view = view as? HubNativeFileDropBridge.DestinationView { return view }
        return view.subviews.compactMap { destination(in: $0) }.first
    }
}
