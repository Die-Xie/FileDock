import AppKit
import Foundation

@MainActor private final class FileTypeBatchLoader: HubDirectoryLoading {
    var progress: ((HubDirectorySnapshot) -> Void)?
    var completion: ((Result<HubDirectorySnapshot, Error>) -> Void)?
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        load(id: id, request: request, progress: { _ in }, completion: completion)
    }
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        self.progress = progress; self.completion = completion
    }
    func cancel(id: UUID) { progress = nil; completion = nil }
}

@main struct FileTypeFilterTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        normalization()
        shortcutPresentation()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-TypeFilter-\(UUID())")
        let folder = root.appendingPathComponent("files")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var files: [String: URL] = [:]
        for name in ["a.MD", "b.md", "c.PDF", "archive.tar.gz", "README", "actual.folder", "actual.__none__", "actual.none", "unusual.a&b", "long." + String(repeating: "x", count: 40), ".hidden", ".hidden.md"] {
            let url = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            files[name] = url
        }
        for (name, label) in [("a.MD", HubFinderLabel.red), ("b.md", .blue), ("c.PDF", .red)] {
            var url = files[name]!, values = URLResourceValues()
            values.labelNumber = label.rawValue
            try url.setResourceValues(values)
        }
        let child = folder.appendingPathComponent("child", isDirectory: true)
        let namedFolder = folder.appendingPathComponent("notes.md", isDirectory: true)
        let application = folder.appendingPathComponent("Example.app", isDirectory: true)
        for directory in [child, namedFolder, application] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let directoryLink = folder.appendingPathComponent("folder-link.pdf")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: child)
        let linked = FileEntry(url: directoryLink)
        precondition(HubFileType.key(for: linked) == (linked.canNavigate ? HubFileType.folder : "ext:pdf"),
                     "Directory links retain the existing cached navigation semantics rather than being separately resolved")
        precondition(HubFileType.key(for: FileEntry(url: namedFolder)) == HubFileType.folder)
        let app = FileEntry(url: application)
        precondition(app.isPackage && HubFileType.key(for: app) == "ext:app", "Application packages must never be classified as folders")
        precondition(HubFileType.key(for: FileEntry(url: files[".hidden"]!)) == HubFileType.noExtension)
        precondition(HubFileType.key(for: FileEntry(url: files[".hidden.md"]!)) == "ext:md")

        let storage = root.appendingPathComponent("config.json")
        let model = makeTestModel(storageURL: storage)
        let workspace = model.addWorkspace(name: "Types", mode: .folder, urls: [folder])!
        model.selectWorkspace(workspace.id)
        model.sortByColumn(.name)
        precondition(model.settings.resolvedFileTypeShortcuts == HubFileType.defaultShortcuts && model.fileTypeFilter == nil)
        let types = model.availableFileTypes
        let counts = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0.count) })
        precondition(counts["ext:md"] == 2 && counts["ext:app"] == 1 && counts["ext:gz"] == 1 &&
                     counts["ext:folder"] == 1 && counts["ext:__none__"] == 1 && counts[HubFileType.noExtension] == 1,
                     "Unexpected type counts: \(counts)")
        precondition(counts["ext:a&b"] == 1 && counts["ext:" + String(repeating: "x", count: 40)] == 1,
                     "The current-panel menu must include literal unusual and long suffixes even when they are not shortcut input tokens")
        _ = model.visibleEntries
        let calculations = model.entryOrderCalculationCount
        let typeCalculations = model.fileTypeCalculationCount
        for mode in HubViewMode.allCases {
            model.viewMode = mode
            model.selectedIDs = [files["c.PDF"]!]
            model.setFileTypeFilter(".MD")
            precondition(model.selectedIDs.isEmpty && Set(model.visibleEntries.map(\.url)) == [files["a.MD"]!, files["b.md"]!])
            model.search = "a.MD"
            precondition(model.visibleEntries.map(\.url) == [files["a.MD"]!])
            model.setColorLabelFilter(.red)
            precondition(model.visibleEntries.map(\.url) == [files["a.MD"]!])
            model.search = "missing"
            precondition(model.visibleEntries.isEmpty && model.availableFileTypes == types,
                         "Search, color and type filtering must intersect without removing any menu options")
            model.search = ""; model.setColorLabelFilter(nil); model.setFileTypeFilter(nil)
        }
        let writes = model.configurationWriteCount
        model.setFileTypeFilter("ext:folder")
        precondition(model.visibleEntries.map(\.url) == [files["actual.folder"]!])
        model.setFileTypeFilter(HubFileType.noExtension)
        precondition(model.visibleEntries.map(\.url) == [files["README"]!])
        model.setFileTypeFilter("ext:a&b")
        precondition(model.visibleEntries.map(\.url) == [files["unusual.a&b"]!])
        for _ in 0..<100 { _ = model.availableFileTypes; _ = model.visibleEntries }
        precondition(model.entryOrderCalculationCount == calculations && model.fileTypeCalculationCount == typeCalculations &&
                     model.configurationWriteCount == writes,
                     "Filter changes and repeated footer reads must reuse sorting/type counts and never write transient browsing state")
        model.settings.fileTypeShortcuts = [".PDF", "folder", "PDF", ".folder"]
        precondition(model.settings.resolvedFileTypeShortcuts == ["ext:pdf", "folder", "ext:folder"] && model.fileTypeFilter == "ext:a&b",
                     "Customizing shortcuts must retain an active non-shortcut filter")
        let restarted = makeTestModel(storageURL: storage)
        precondition(restarted.fileTypeFilter == nil && restarted.settings.resolvedFileTypeShortcuts == ["ext:pdf", "folder", "ext:folder"],
                     "Only user shortcuts persist; the active filter starts clear after restart")
        model.setFileTypeFilter("folder")
        model.selectedIDs = [child]
        try fm.removeItem(at: child)
        try Data().write(to: child)
        model.refresh()
        precondition(model.fileTypeFilter == "folder" && model.selectedIDs.isEmpty && !model.visibleEntries.contains { $0.url == child },
                     "A refresh must prune selected entries whose cached type no longer matches")
        model.setFileTypeFilter("md")
        model.navigate(to: namedFolder)
        precondition(model.fileTypeFilter == nil, "Committed directory navigation clears its old type filter")
        model.goBack()
        model.setFileTypeFilter("md")
        let references = model.addWorkspace(name: "References", mode: .references, urls: [files["a.MD"]!, files["c.PDF"]!])!
        model.selectWorkspace(references.id)
        precondition(model.fileTypeFilter == nil)
        model.setFileTypeFilter("pdf")
        precondition(model.visibleEntries.map(\.url) == [files["c.PDF"]!], "Reference roots use the same metadata-only filter")
        try batches(storage: storage, workspace: workspace, entries: [FileEntry(url: files["a.MD"]!), FileEntry(url: files["c.PDF"]!)])
        let originalOrder = [files["a.MD"]!, files["c.PDF"]!, files["actual.folder"]!, files["b.md"]!, files["README"]!]
        let ordered = model.addWorkspace(name: "Ordered types", mode: .references, urls: originalOrder)!
        model.selectWorkspace(ordered.id)
        let beforeOrder = model.fileOrderURLs
        model.setFileTypeFilter("md")
        model.reorderEntries([files["b.md"]!], before: files["a.MD"]!)
        precondition(model.visibleEntries.map(\.url) == [files["b.md"]!, files["a.MD"]!])
        model.setFileTypeFilter(nil)
        let afterOrder = model.fileOrderURLs
        let moved = Set([files["a.MD"]!, files["b.md"]!])
        precondition(Set(afterOrder) == Set(originalOrder) && afterOrder.filter { !moved.contains($0) } == beforeOrder.filter { !moved.contains($0) },
                     "Reordering a type-filtered collection must retain every hidden file and their relative order")
        model.settings.groupsEnabled = true
        model.setFileTypeFilter("md")
        precondition(Set(model.visibleGroups.flatMap(\.entries).map(\.url)) == moved)
        model.setFileTypeFilter("pdf")
        precondition(model.visibleGroups.flatMap(\.entries).map(\.url) == model.visibleEntries.map(\.url) &&
                     model.visibleEntries.map(\.url) == [files["c.PDF"]!] && model.visibleGroup(containing: files["a.MD"]!) == nil,
                     "Changing type must rebuild visible groups and discard hidden entries' old group indices")
        model.entries = Array(repeating: FileEntry(url: files["a.MD"]!), count: 20_000)
        let scans = model.fileTypeCalculationCount
        let started = ProcessInfo.processInfo.systemUptime
        precondition(model.availableFileTypes == [HubFileTypeOption(id: "ext:md", count: 20_000)])
        let calculated = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = model.availableFileTypes }
        let finished = ProcessInfo.processInfo.systemUptime
        precondition(model.fileTypeCalculationCount == scans + 1)
        print("METRIC: 20000 cached entries type scan \((calculated - started) * 1000) ms; 1000 cache hits \((finished - calculated) * 1000) ms; exactly one scan")
        print("PASS: type normalization/collision isolation, packages and folder metadata, all view modes, intersected filters, cached current-panel types, transient selection, persisted shortcuts, navigation and progressive snapshot invalidation")
    }

    static func normalization() {
        precondition(HubFileType.normalizedShortcuts(["MD", ".pdf", "ZIP", "folder", "md"]) == HubFileType.defaultShortcuts)
        precondition(HubFileType.normalizedIdentifier(".folder") == "ext:folder" &&
                     HubFileType.normalizedIdentifier(".__none__") == "ext:__none__" &&
                     HubFileType.normalizedIdentifier("none") == HubFileType.noExtension &&
                     HubFileType.normalizedIdentifier(".none") == "ext:none")
        precondition(HubFileType.normalizedIdentifier("../pdf") == nil && HubFileType.normalizedIdentifier("tar.gz") == nil &&
                     HubFileType.normalizedIdentifier("*pdf") == nil && HubFileType.normalizedIdentifier(String(repeating: "a", count: 33)) == nil)
        precondition(HubFileType.parseShortcuts("MD， .PDF; folder\nzip\t.md") == ["ext:md", "ext:pdf", "folder", "ext:zip"])
        precondition(HubFileType.parseShortcuts(String(repeating: " ", count: 300) + "pdf") == ["ext:pdf"],
                     "Empty separator tokens must not exhaust the bounded candidate budget")
        let escaped = ["ext:folder", "ext:__none__", HubFileType.noExtension, "ext:pdf", "folder", "ext:none"]
        precondition(HubFileType.parseShortcuts(HubFileType.editingText(for: escaped)) == escaped)
        precondition(HubFileType.normalizedShortcuts((0..<30).map { "type\($0)" }).count == HubFileType.maximumShortcuts)
        precondition(HubFileType.normalizedShortcuts(Array(repeating: "*invalid", count: 1000) + ["pdf"]).isEmpty &&
                     HubFileType.parseShortcuts(String(repeating: "*", count: 100_000) + " pdf").isEmpty,
                     "Untrusted configuration lists and editor pastes have bounded normalization work")
        var settings = HubSettings()
        settings.fileTypeShortcuts = []
        settings.normalize()
        precondition(settings.resolvedFileTypeShortcuts.isEmpty)
        let data = try! JSONEncoder().encode(HubSettings())
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "fileTypeShortcuts")
        let legacy = try! JSONDecoder().decode(HubSettings.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(legacy.resolvedFileTypeShortcuts == HubFileType.defaultShortcuts)
    }

    static func shortcutPresentation() {
        func options(_ identifiers: [String]) -> [HubFileTypeOption] {
            identifiers.map { HubFileTypeOption(id: $0, count: 1) }
        }
        let defaults = HubFileType.defaultShortcuts
        precondition(HubFileType.displayedShortcuts(preferred: defaults,
            available: options(["folder", "ext:pdf", "ext:txt", "ext:zip", "ext:md"])) == defaults,
            "Available favorites must keep the configured order rather than the menu's order")
        precondition(HubFileType.displayedShortcuts(preferred: defaults,
            available: options(["folder", "ext:txt", "ext:pdf", HubFileType.noExtension])) ==
                ["ext:pdf", "folder", "ext:txt", HubFileType.noExtension],
            "Missing defaults must disappear and remaining slots must use actual panel types")
        precondition(HubFileType.displayedShortcuts(preferred: ["png", "folder", "pdf"],
            available: options(["ext:txt", "ext:pdf", "ext:png", "folder"])) == ["ext:png", "folder", "ext:pdf"])
        precondition(HubFileType.displayedShortcuts(preferred: [], available: options(defaults)).isEmpty &&
                     HubFileType.displayedShortcuts(preferred: defaults, available: []).isEmpty,
                     "An explicit empty customization or an empty snapshot must show no shortcut chips")
        precondition(HubFileType.displayedShortcuts(preferred: defaults, available: [
            HubFileTypeOption(id: "folder", count: 0), HubFileTypeOption(id: "ext:md", count: -1),
            HubFileTypeOption(id: "ext:txt", count: 1), HubFileTypeOption(id: "ext:txt", count: 3),
            HubFileTypeOption(id: "ext:folder", count: 1), HubFileTypeOption(id: "ext:none", count: 1)]) ==
                ["ext:txt", "ext:folder", "ext:none"],
            "Only positive actual categories fill slots, without duplicates or reserved-name collisions")
        let early = options(["ext:pdf"])
        let later = options(["ext:txt", "ext:pdf", "ext:md", "ext:csv", "ext:png"])
        precondition(HubFileType.displayedShortcuts(preferred: defaults, available: early) == ["ext:pdf"] &&
                     HubFileType.displayedShortcuts(preferred: defaults, available: later) == ["ext:md", "ext:pdf", "ext:txt", "ext:csv"],
                     "Progressive snapshots must resolve available types anew without reserving empty default slots")
        let many = options((0..<20_000).map { "ext:type\($0)" }) + options(["ext:pdf"])
        precondition(HubFileType.displayedShortcuts(preferred: defaults, available: many) ==
                     ["ext:pdf", "ext:type0", "ext:type1", "ext:type2"],
                     "A favorite at the end of a large type list must displace a fallback without expanding the slot count")
        let custom = (0..<30).map { "preferred\($0)" }
        precondition(HubFileType.displayedShortcuts(preferred: custom, available: many).count == HubFileType.maximumShortcuts,
                     "Large configurations cannot increase the number of rendered shortcuts past the existing limit")
    }

    @MainActor static func batches(storage: URL, workspace: Workspace, entries: [FileEntry]) throws {
        let seed = makeTestModel(storageURL: storage)
        seed.selectWorkspace(workspace.id)
        let loader = FileTypeBatchLoader()
        let model = HubModel(storageURL: storage, directoryLoader: loader)
        precondition(model.directoryLoading && model.entries.isEmpty)
        let canonical = workspace.rootPath
        loader.progress?(HubDirectorySnapshot(entries: [entries[0]], canonicalDirectoryPath: canonical))
        precondition(model.availableFileTypes == [HubFileTypeOption(id: "ext:md", count: 1)])
        precondition(HubFileType.displayedShortcuts(preferred: model.settings.resolvedFileTypeShortcuts,
            available: model.availableFileTypes) == ["ext:md"], "A partial snapshot must not show absent default categories")
        model.setFileTypeFilter("pdf")
        precondition(model.visibleEntries.isEmpty && model.fileTypeFilter == "ext:pdf")
        loader.progress?(HubDirectorySnapshot(entries: entries, canonicalDirectoryPath: canonical))
        precondition(model.availableFileTypes.count == 2 && model.visibleEntries.map(\.url) == [entries[1].url],
                     "A filter absent from an early batch must remain active until later matching entries arrive")
        let expandedShortcuts = HubFileType.displayedShortcuts(preferred: model.settings.resolvedFileTypeShortcuts,
            available: model.availableFileTypes)
        precondition(expandedShortcuts.contains("ext:md") && expandedShortcuts.contains("ext:pdf"),
                     "The selected type must not hide other loaded types from automatic shortcut filling")
        model.setFileTypeFilter("md")
        model.selectedIDs = [entries[0].url]
        loader.completion?(.success(HubDirectorySnapshot(entries: [entries[1]], canonicalDirectoryPath: canonical)))
        precondition(model.availableFileTypes == [HubFileTypeOption(id: "ext:pdf", count: 1)] && model.visibleEntries.isEmpty && model.selectedIDs.isEmpty,
                     "Each progressive batch invalidates type counts and completion prunes selection against the active type")
    }
}
