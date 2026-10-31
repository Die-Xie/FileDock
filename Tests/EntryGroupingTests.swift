import AppKit
import SwiftUI

@main struct EntryGroupingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-Groups-\(UUID())")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let outside = root.appendingPathComponent("external.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let files = ["b.txt", "a.pdf", "c.txt", "目录"].map { folder.appendingPathComponent($0) }
        for file in files.dropLast() { try Data("fixture".utf8).write(to: file) }
        try fm.createDirectory(at: files.last!, withIntermediateDirectories: false)
        try Data("external".utf8).write(to: outside)
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let workspace = model.addWorkspace(name: "fixture", mode: .folder, urls: [folder])!
        for _ in 0..<500 where model.directoryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.directoryLoading && model.entries.count == 4)
        model.setManualEntryOrder(true)
        model.reorderEntries([files[2]], before: files[1])
        let manual = model.fileOrderURLs
        let paths = model.selectedWorkspace!.directoryOrders!
        model.settings.groupsEnabled = true
        precondition(model.groupingActive && model.selectedWorkspace!.directoryOrders == paths)
        model.sortKey = .kind
        model.ascending = true
        precondition(model.selectedWorkspace!.directoryOrders == paths, "Changing the grouping key cannot discard manual order")
        let groups = model.visibleGroups
        precondition(groups.count >= 2 && groups.flatMap(\.entries).map(\.url) == model.visibleEntries.map(\.url))
        precondition(Set(model.visibleEntries.map(\.url)) == Set(manual))
        for group in groups {
            let urls = group.entries.map(\.url)
            precondition(manual.filter { urls.contains($0) } == urls, "Within each group, manual order stays unchanged")
        }
        precondition(zip(groups, groups.dropFirst()).allSatisfy { $0.title.localizedStandardCompare($1.title) != .orderedDescending })
        model.sortByColumn(.kind)
        precondition(!model.ascending && model.visibleGroups.map(\.id) == groups.reversed().map(\.id),
                     "Column clicks reverse group order even when a saved manual order exists")
        precondition(model.selectedWorkspace!.directoryOrders == paths)
        let count = model.entryGroupingCalculationCount
        for _ in 0..<100 { _ = model.visibleEntries; _ = model.visibleGroups }
        precondition(model.entryGroupingCalculationCount == count, "View reads reuse the grouped snapshot")
        model.reorderEntries([files[0]], before: files[1])
        precondition(model.selectedWorkspace!.directoryOrders == paths, "Grouped local reorder must be a no-op")
        model.search = "txt"
        precondition(model.visibleEntries.count == 2 && model.visibleGroups.flatMap(\.entries).count == 2)
        model.search = ""
        let state = HubPresentationState(); state.previewVisible = true
        let host = NSHostingView(rootView: HubView(model: model, presentation: state, music: HubQQMusicController(), onSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        for (iteration, mode) in [HubViewMode.grid, .list, .columns].enumerated() {
            model.viewMode = mode; settle(host)
            let views = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
            let bridge = views.first { $0.bounds.width > 500 && $0.contains(CGPoint(x: 500, y: 200)) }!
            let source = iteration.isMultiple(of: 2) ? files[2] : files[0]
            let target = iteration.isMultiple(of: 2) ? files[0] : files[2]
            let local = HubFileDragPayload(id: UUID(), context: .init(workspaceID: workspace.id, directory: folder), urls: [source])
            let itemViews = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }
            guard let targetView = itemViews.first(where: { $0.entryURL == target }),
                  let otherGroupView = itemViews.first(where: { $0.entryURL == files[1] }) else {
                preconditionFailure("Grouped files must retain native drag cells in \(mode): \(itemViews.map { $0.entryURL.lastPathComponent })")
            }
            func beforePoint(_ view: NSView) -> CGPoint {
                let rect = view.convert(view.bounds, to: bridge)
                return CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2)
            }
            let targetPoint = beforePoint(targetView)
            let otherPoint = beforePoint(otherGroupView)
            precondition(bridge.operation?(targetPoint, [source], local, false) == .move,
                         "A same-group native drag must offer reordering in \(mode)")
            precondition(bridge.receive?([source], local, targetPoint, false) == true)
            for _ in 0..<500 where model.directoryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
            settle(host)
            guard let group = model.visibleGroup(containing: source) else { preconditionFailure("Reordered item lost its group") }
            let groupURLs = group.entries.map(\.url)
            precondition(groupURLs.firstIndex(of: source)! < groupURLs.firstIndex(of: target)!, "Grouped insertion must be reflected by the displayed order")
            let afterReorder = model.selectedWorkspace!.directoryOrders!
            precondition((bridge.operation?(otherPoint, [source], local, false) ?? .copy).isEmpty,
                         "A cross-group native drag must not offer a move")
            precondition(bridge.receive?([source], local, otherPoint, false) == false)
            precondition(bridge.operation?(CGPoint(x: 500, y: 200), [outside], nil, false) == .move,
                         "External drag remains accepted in each grouped view")
            precondition(model.selectedWorkspace!.directoryOrders == afterReorder, "Cross-group rejection must preserve order")
        }
        guard let textGroup = model.visibleGroup(containing: files[0]) else { preconditionFailure("Expected text group") }
        let beforeTailTest = model.fileOrderURLs
        let visibleTextOrder = textGroup.entries.map(\.url)
        precondition(visibleTextOrder == [files[2], files[0]])
        precondition(model.reorderGroupedEntries([files[2]], before: nil, groupID: textGroup.id),
                     "A group-tail insertion must remain inside its group")
        precondition(model.visibleGroup(containing: files[0])?.entries.map(\.url) == [files[0], files[2]])
        precondition(!model.reorderGroupedEntries([files[0], files[1]], before: nil, groupID: textGroup.id),
                     "A multi-selection spanning groups cannot be reordered")
        precondition(model.reorderGroupedEntries([files[2]], before: files[0], groupID: textGroup.id))
        precondition(model.fileOrderURLs == beforeTailTest, "Reversing group-tail insertion must restore the exact global order")
        precondition(HubFileDropFeedback(rect: .zero, title: "", count: 1,
                                        action: .groupedReorderBlocked, insertion: false).prompt == L("只能在同一群组内调整顺序"))
        model.viewMode = .grid; model.settings.horizontalScroll = true; settle(host)
        let horizontal = descendants(host).compactMap { $0 as? HubFileDragBridge.FileDragView }
        precondition(!horizontal.isEmpty && horizontal.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 },
                     "Horizontal grouped grids must lay out actual interactive file cells")
        model.settings.horizontalScroll = false; settle(host)
        model.setColorLabelFilter(.orange); settle(host)
        let bridges = descendants(host).compactMap { $0 as? HubNativeFileDropBridge.DestinationView }
        let colorBridge = bridges.first { $0.bounds.width > 500 && $0.contains(CGPoint(x: 500, y: 200)) }!
        let local = HubFileDragPayload(id: UUID(), context: .init(workspaceID: workspace.id, directory: folder), urls: [files[0]])
        let reorderedPaths = model.selectedWorkspace!.directoryOrders!
        precondition(colorBridge.operation?(CGPoint(x: 500, y: 200), [files[0]], local, false) == .copy)
        precondition(colorBridge.receive?([files[0]], local, CGPoint(x: 500, y: 200), false) == true)
        for _ in 0..<500 where model.fileOperationsInProgress > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(FileEntry(url: files[0]).labelNumber == 7 && model.selectedWorkspace!.directoryOrders == reorderedPaths,
                     "Grouped local drag into a selected color adds the label without changing order")
        model.setColorLabelFilter(nil)
        let delegate = HubContentFileDropDelegate(size: CGSize(width: 300, height: 200), types: [], targeted: { _ in }, receive: { _ in true }, accepts: { false })
        precondition(!delegate.perform(at: CGPoint(x: 50, y: 50), providers: []), "Fallback must also refuse local grouped reorders")
        model.settings.groupsEnabled = false
        let reordered = model.fileOrderURLs
        precondition(model.visibleEntries.map(\.url) == reordered && model.isManualEntryOrder && reordered != manual,
                     "Turning grouping off retains the user's grouped reorder in the manual sequence")
        let restored = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        precondition(!restored.settings.resolvedGroupsEnabled && restored.selectedWorkspace!.directoryOrders == reorderedPaths)
        let missing = FileEntry(url: folder.appendingPathComponent("missing"))
        let unknown = HubEntryGrouping.groups([missing], by: .modified, locale: Locale(identifier: "en"))
        precondition(unknown.count == 1 && unknown[0].id == "date:unknown")
        let multilingual = HubEntryGrouping.groups([FileEntry(url: files[0]), FileEntry(url: files.last!)], by: .name,
                                                    locale: Locale(identifier: "zh-Hans"))
        precondition(multilingual.map(\.title).contains("B") && multilingual.map(\.title).contains("M"),
                     "Chinese initials use transliteration instead of collapsing into Other")
        let virtual = makeTestModel(storageURL: root.appendingPathComponent("virtual.json"))
        let reference = virtual.addWorkspace(name: "References", mode: .references, urls: files)!
        virtual.settings.groupsEnabled = true
        for _ in 0..<500 where virtual.directoryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        let referencePaths = virtual.selectedWorkspace!.referencePaths
        virtual.reorderEntries([files[0]], before: files[1])
        virtual.sortKey = .name
        precondition(virtual.selectedWorkspace!.referencePaths == referencePaths && virtual.referenceManualOrder)
        precondition(virtual.stageFiles(files)); virtual.openStagingWorkspace()
        let stagingPaths = virtual.selectedWorkspace!.referencePaths
        virtual.reorderEntries([files[0]], before: files[1])
        precondition(virtual.isStagingRoot && virtual.groupingActive && virtual.selectedWorkspace!.referencePaths == stagingPaths)
        _ = virtual.addRecentWorkspace()
        precondition(virtual.isRecentsRoot && !virtual.groupingActive, "Recents keeps its chronological system order")
        virtual.selectWorkspace(reference.id)
        precondition(virtual.groupingActive && virtual.selectedWorkspace!.referencePaths == referencePaths)

        // Search may hide same-group items while unrelated groups are
        // interleaved in the persisted manual order. Reordering the visible
        // subset must never discard or rearrange any nonmoving references.
        let interleavedDirectory = root.appendingPathComponent("interleaved", isDirectory: true)
        try fm.createDirectory(at: interleavedDirectory, withIntermediateDirectories: true)
        let interleavedNames = ["visible-one.txt", "other-one.pdf", "hidden.txt",
                                "visible-two.txt", "other-two.pdf", "visible-three.txt"]
        let interleaved = interleavedNames.map { interleavedDirectory.appendingPathComponent($0) }
        for url in interleaved { try Data(url.lastPathComponent.utf8).write(to: url) }
        let filtered = makeTestModel(storageURL: root.appendingPathComponent("filtered-groups.json"))
        let filteredWorkspace = filtered.addWorkspace(name: "Filtered", mode: .references, urls: interleaved)!
        for _ in 0..<500 where filtered.directoryLoading || filtered.entries.count != interleaved.count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(filtered.entries.count == interleaved.count && filtered.referenceManualOrder)
        filtered.settings.groupsEnabled = true
        filtered.sortKey = .kind
        filtered.search = "visible-"
        guard let filteredGroup = filtered.visibleGroup(containing: interleaved[0]) else { preconditionFailure("Expected visible text group") }
        precondition(filteredGroup.entries.map(\.url) == [interleaved[0], interleaved[3], interleaved[5]])
        precondition(filtered.reorderGroupedEntries([interleaved[3], interleaved[0]], before: nil, groupID: filteredGroup.id),
                     "A reversed multi-selection may move to the end of its visible group")
        let expectedAfterTail = [interleaved[1], interleaved[2], interleaved[4], interleaved[5], interleaved[0], interleaved[3]]
        precondition(filtered.selectedWorkspace?.referencePaths == expectedAfterTail.map(\.path),
                     "Hidden references and other groups must remain present and retain relative order")
        for _ in 0..<500 where filtered.directoryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(filtered.visibleGroup(containing: interleaved[0])?.entries.map(\.url) == [interleaved[5], interleaved[0], interleaved[3]],
                     "The multi-selection keeps its original relative order")
        precondition(filtered.reorderGroupedEntries([interleaved[3]], before: interleaved[0], groupID: filteredGroup.id))
        let expectedAfterInsertion = [interleaved[1], interleaved[2], interleaved[4], interleaved[5], interleaved[3], interleaved[0]]
        precondition(filtered.selectedWorkspace?.referencePaths == expectedAfterInsertion.map(\.path),
                     "Inserting within the filtered group must leave every other reference in place")
        filtered.search = ""
        filtered.settings.groupsEnabled = false
        for _ in 0..<500 where filtered.directoryLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(filtered.selectedWorkspace?.id == filteredWorkspace.id && filtered.visibleEntries.map(\.url) == expectedAfterInsertion,
                     "Disabling grouping must retain the complete adjusted manual sequence")
        for url in interleaved {
            let contents = try Data(contentsOf: url)
            precondition(contents == Data(url.lastPathComponent.utf8))
        }
        window.contentView = nil
        model.settings.groupsEnabled = true
        model.sortKey = .modified
        let largeFolder = root.appendingPathComponent("large", isDirectory: true)
        try fm.createDirectory(at: largeFolder, withIntermediateDirectories: false)
        let initial = largeFolder.appendingPathComponent("seed.txt")
        try Data("x".utf8).write(to: initial)
        var largeEntries = [FileEntry(url: initial)]
        for index in 1..<12000 {
            let url = largeFolder.appendingPathComponent("\(index).txt")
            try fm.linkItem(at: initial, to: url)
            largeEntries.append(FileEntry(url: url))
        }
        precondition(Set(largeEntries.map(\.url)).count == 12000 && largeEntries.allSatisfy { $0.modified != nil })
        model.entries = largeEntries
        let start = ProcessInfo.processInfo.systemUptime
        _ = model.visibleGroups
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let before = model.entryGroupingCalculationCount
        for _ in 0..<100 { _ = model.visibleGroups; _ = model.visibleEntries }
        precondition(model.entryGroupingCalculationCount == before && elapsed < 1.0,
                     "Large grouped directories must be cached without blocking on filesystem reads")
        print("PASS: grouped views, same-group reorder, cross-group rejection, external drops, search, missing dates, restart and 12,000-entry cache (\(elapsed)s)")
        print("LIMIT: grouped layout and physical drag interactions still require WindowServer/UI verification")
    }
    @MainActor static func settle(_ view: NSView) {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
