import AppKit
import Foundation

@main struct ColorLabelFilterTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-ColorFilter-\(UUID())")
        let folder = root.appendingPathComponent("files")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var files: [HubFinderLabel: URL] = [:]
        for label in HubFinderLabel.allCases {
            var url = folder.appendingPathComponent("sample-\(label.rawValue).txt")
            try Data("fixture".utf8).write(to: url)
            var values = URLResourceValues(); values.labelNumber = label.rawValue
            try url.setResourceValues(values)
            files[label] = url
        }
        let child = folder.appendingPathComponent("child", isDirectory: true).standardizedFileURL
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("config.json")
        let model = makeTestModel(storageURL: storage)
        let workspace = model.addWorkspace(name: "Colors", mode: .folder, urls: [folder])!
        model.selectWorkspace(workspace.id)
        model.sortByColumn(.name)
        precondition(model.settings.resolvedColorLabelFilterEnabled && model.visibleEntries.count == 9)
        let calculations = model.entryOrderCalculationCount, writes = model.configurationWriteCount
        for mode in HubViewMode.allCases {
            model.viewMode = mode
            for label in HubFinderLabel.colors {
                model.selectedIDs = [child]
                model.setColorLabelFilter(label)
                precondition(model.selectedIDs.isEmpty)
                precondition(model.visibleEntries.map(\.url) == [files[label]!])
                for _ in 0..<20 { precondition(model.visibleEntries.count == 1) }
                model.search = "missing"
                precondition(model.visibleEntries.isEmpty)
                model.search = "sample"
                precondition(model.visibleEntries.map(\.url) == [files[label]!])
                model.search = ""
            }
        }
        precondition(model.entryOrderCalculationCount == calculations, "Color/search filtering must reuse the existing sort and cached metadata")
        // Only the explicit three view preferences above are persisted.
        precondition(model.configurationWriteCount == writes + HubViewMode.allCases.count)
        model.setColorLabelFilter(HubFinderLabel.none)
        precondition(Set(model.visibleEntries.map(\.url)) == [files[.none]!, child])
        model.setColorLabelFilter(.red)
        model.selectedIDs = [files[.red]!]
        var red = files[.red]!
        var blue = URLResourceValues(); blue.labelNumber = HubFinderLabel.blue.rawValue
        try red.setResourceValues(blue)
        model.refresh()
        precondition(model.colorLabelFilter == .red && model.visibleEntries.isEmpty && model.selectedIDs.isEmpty,
                     "Finder label changes must update the active filter and clear newly hidden selections")
        model.setColorLabelFilter(.blue)
        precondition(model.visibleEntries.count == 2)
        model.reorderEntries([red], before: nil)
        model.setColorLabelFilter(nil)
        precondition(model.visibleEntries.count == 9 && Set(model.fileOrderURLs).count == 9,
                     "Reordering a filtered view must preserve hidden files")
        model.setColorLabelFilter(.blue)
        model.navigate(to: child)
        precondition(model.colorLabelFilter == nil, "Navigation must clear a location's filter")
        model.goBack()
        model.setColorLabelFilter(.blue)
        let references = model.addWorkspace(name: "References", mode: .references, urls: Array(files.values))!
        model.selectWorkspace(references.id)
        precondition(model.colorLabelFilter == nil)
        model.setColorLabelFilter(.blue)
        precondition(model.visibleEntries.count == 2, "Virtual collections use the same loaded-label filter")
        let restarted = makeTestModel(storageURL: storage)
        precondition(restarted.colorLabelFilter == nil && restarted.settings.resolvedColorLabelFilterEnabled,
                     "The transient filter must never survive a restart")
        model.settings.colorLabelFilterEnabled = false
        precondition(model.colorLabelFilter == nil && model.visibleEntries.count == 8)
        model.setColorLabelFilter(.red)
        precondition(model.colorLabelFilter == nil, "A hidden filter cannot stay active")
        let disabled = makeTestModel(storageURL: storage)
        precondition(!disabled.settings.resolvedColorLabelFilterEnabled)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HubSettings())) as! [String: Any]
        object.removeValue(forKey: "colorLabelFilterEnabled")
        let legacy = try JSONDecoder().decode(HubSettings.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(legacy.resolvedColorLabelFilterEnabled, "Older settings must decode without requiring a new field")
        var input = HubColorLabelFilterInput()
        input.hovered(.red)
        precondition(input.click(.red, current: .red) == .red, "A first click after hover confirms instead of unexpectedly clearing the filter")
        precondition(!input.permitsHover(.red))
        precondition(input.click(.red, current: .red) == nil)
        precondition(!input.permitsHover(.red), "Hover cannot immediately undo a deliberate clear")
        input.exit(.red)
        precondition(input.permitsHover(.red))
        precondition(input.click(.blue, current: .red) == .blue)
        precondition(input.click(nil, current: .blue) == nil)
        print("PASS: native Finder colors, all three views, combined search, cached ordering, selection pruning, filtered reorder, navigation/workspace reset, references, transient state and persisted/legacy feature toggle")
    }
}
