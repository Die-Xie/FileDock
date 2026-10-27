import AppKit
import Carbon
import Foundation

@main struct FinderFileActionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-FinderActions-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder \"; $() 中文", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let svg = folder.appendingPathComponent("--sample.svg")
        let bytes = Data("<svg><title>unchanged</title></svg>".utf8)
        try bytes.write(to: svg)
        var tagged = folder, values = URLResourceValues(); values.tagNames = ["Keep This Tag"]
        try tagged.setResourceValues(values)
        let initialTags = try tagged.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        let picture = HubFolderArtwork.render(label: .green, symbol: "star.fill")!
        precondition(picture.count < 4 * 1024 * 1024 && HubFolderArtwork.decode(picture)?.width == 512)
        let styled = try await Task.detached { try HubFinderFileActions.folderStyle(folder, label: 2, icon: .artwork(picture)) }.value
        precondition(styled.changed == [folder])
        let entry = FileEntry(url: folder)
        precondition(entry.labelNumber == 2 && entry.folderAppearance.customIcon)
        precondition(initialTags.allSatisfy { entry.tagNames.contains($0) }, "Color edits preserve unrelated Finder tags")
        let afterLabel = try await Task.detached { try HubFinderFileActions.setLabel(6, urls: [folder, svg]) }.value
        precondition(afterLabel.changed.count == 2 && afterLabel.failures.isEmpty)
        precondition(FileEntry(url: folder).folderAppearance.customIcon && FileEntry(url: svg).labelNumber == 6)
        let originalIcon = NSWorkspace.shared.icon(forFile: folder.path).tiffRepresentation
        _ = try await Task.detached { try HubFinderFileActions.folderStyle(folder, label: 4, icon: .unchanged) }.value
        precondition(NSWorkspace.shared.icon(forFile: folder.path).tiffRepresentation == originalIcon, "Label-only changes must retain the custom bitmap")
        _ = try await Task.detached { try HubFinderFileActions.folderStyle(folder, label: 0, icon: .system) }.value
        precondition(!FileEntry(url: folder).folderAppearance.customIcon && FileEntry(url: folder).labelNumber == 0)
        try check(Data(contentsOf: svg) == bytes)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
        let package = root.appendingPathComponent("Bundle.app")
        try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        for bad in [link, package, svg] {
            do { _ = try await Task.detached { try HubFinderFileActions.folderStyle(bad, label: 6, icon: .system) }.value; preconditionFailure("Invalid folder style target") }
            catch {}
        }
        let rejectedLink = try await Task.detached { try HubFinderFileActions.setLabel(6, urls: [link]) }.value
        precondition(rejectedLink.changed.isEmpty && rejectedLink.failures.count == 1 && FileEntry(url: folder).labelNumber == 0)
        precondition(HubFolderArtwork.decode(Data("not an image".utf8)) == nil)
        let imageURL = root.appendingPathComponent("icon.png"); try picture.write(to: imageURL)
        let decoded = try await Task.detached { try HubFolderArtwork.readImage(imageURL) }.value
        precondition(HubFolderArtwork.decode(decoded)?.width == 512)
        precondition(HubFolderArtwork.render(label: .blue, emoji: "👨‍👩‍👧‍👦") != nil)

        let occupied = root.appendingPathComponent(folder.lastPathComponent + " alias")
        let sentinel = Data("keep existing".utf8); try sentinel.write(to: occupied)
        let aliases = try await Task.detached { try HubFinderFileActions.aliases([folder, svg], suffix: "alias") }.value
        precondition(aliases.created.count == 2 && aliases.failures.isEmpty)
        try check(Data(contentsOf: occupied) == sentinel)
        for (alias, source) in zip(aliases.created, [folder, svg]) {
            try check(alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
            let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
            precondition(resolved.resolvingSymlinksInPath() == source.resolvingSymlinksInPath(), "Make Alias creates real Finder bookmarks, not symlinks")
        }
        let single = try await Task.detached { try HubFinderFileActions.archive([folder], destination: root, defaultName: "Archive") }.value
        let second = try await Task.detached { try HubFinderFileActions.archive([folder], destination: root, defaultName: "Archive") }.value
        precondition(single.created.count == 1 && single.created != second.created)
        let extracted = root.appendingPathComponent("extracted")
        try run("/usr/bin/ditto", ["-x", "-k", single.created[0].path, extracted.path])
        try check(Data(contentsOf: extracted.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(svg.lastPathComponent)) == bytes)
        let another = root.appendingPathComponent("Other"); try fm.createDirectory(at: another, withIntermediateDirectories: true)
        let otherFile = another.appendingPathComponent("second.txt"); try Data("second".utf8).write(to: otherFile)
        let batch = try await Task.detached { try HubFinderFileActions.archive([svg, otherFile], destination: root, defaultName: "Archive") }.value
        let extractedBatch = root.appendingPathComponent("extracted-batch")
        try run("/usr/bin/ditto", ["-x", "-k", batch.created[0].path, extractedBatch.path])
        try check(Data(contentsOf: extractedBatch.appendingPathComponent(svg.lastPathComponent)) == bytes)
        try check(String(contentsOf: extractedBatch.appendingPathComponent("second.txt"), encoding: .utf8) == "second")
        let collision = another.appendingPathComponent(svg.lastPathComponent); try bytes.write(to: collision)
        do { _ = try await Task.detached { try HubFinderFileActions.archive([svg, collision], destination: root, defaultName: "Archive") }.value; preconditionFailure("Duplicate archive member names") }
        catch HubFinderActionError.duplicateArchiveNames {}
        do { _ = try HubFinderFileActions.showInformation(Array(repeating: svg, count: 21)); preconditionFailure("Too many Finder information windows") }
        catch HubFinderActionError.tooManyInfo {}
        do { _ = try await Task.detached { try HubFinderFileActions.archive([folder], destination: folder, defaultName: "Archive") }.value; preconditionFailure("Recursive output must be rejected") }
        catch {}
        do { _ = try await Task.detached { try HubFinderFileActions.archive([root.appendingPathComponent("missing")], destination: root, defaultName: "Archive") }.value; preconditionFailure("Missing input cannot publish partial ZIPs") }
        catch {}
        try check(fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".FileDock-") }, "Temporary write artifacts must be cleaned")
        let duplicated = try await Task.detached { try HubFinderFileActions.duplicate([svg]) }.value
        precondition(duplicated.created.count == 1 && duplicated.failures.isEmpty)
        try check(Data(contentsOf: duplicated.created[0]) == bytes)

        let event = try HubFinderFileActions.informationEvent([folder, svg])
        var scriptError: NSDictionary?
        precondition(NSAppleScript(source: HubFinderFileActions.informationScript)!.compileAndReturnError(&scriptError), "Finder information script must compile against the public scripting dictionary")
        precondition(scriptError == nil)
        let paths = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!.atIndex(1)!
        precondition(paths.atIndex(1)?.stringValue == folder.path && paths.atIndex(2)?.stringValue == svg.path,
                     "Quotes, shell syntax and Unicode paths are descriptor arguments, never script source")
        for key: UInt16 in [2, 34, 37] {
            precondition(HubFinderAction.shortcut(keyCode: key, modifiers: .command) != nil)
            for flags: NSEvent.ModifierFlags in [[], .control, [.command, .shift], [.command, .option], [.command, .control]] {
                precondition(HubFinderAction.shortcut(keyCode: key, modifiers: flags) == nil)
            }
        }
        HubLocalization.select(.english)
        precondition(HubFinderAction.duplicateMenuTitle == "Duplicate" && L("拷贝") == "Copy")
        HubLocalization.select(.simplifiedChinese)
        precondition(HubFinderAction.duplicateMenuTitle == "复制" && L("拷贝") == "拷贝")
        do { _ = try HubFinderFileActions.files([URL(string: "https://example.invalid/a")!]); preconditionFailure("Remote input") } catch {}
        try await modelChecks(root: root, folder: folder, picture: picture)
        print("PASS: real Finder labels/tag preservation, custom icon write/reset, bounded image decoding, symlink/package exclusions, native aliases/duplicates, safe ZIP collisions/multi-parent contents, unchanged sources, script descriptor isolation and captured model completion")
    }
    @MainActor private static func modelChecks(root: URL, folder: URL, picture: Data) async throws {
        let model = makeTestModel(storageURL: root.appendingPathComponent("config.json"))
        let left = model.addWorkspace(name: "Left", mode: .folder, urls: [root])!
        let right = model.addWorkspace(name: "Right", mode: .folder, urls: [folder])!
        model.selectWorkspace(left.id)
        let writes = model.configurationWriteCount
        model.performFinderAction(.folderStyle(2, .artwork(picture)), urls: [folder])
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(model.errorMessage == nil && model.configurationWriteCount == writes, "Metadata edits do not rewrite preferences or bookmarks")
        model.selectedIDs = [folder]
        model.performFinderAction(.compress, urls: [folder])
        model.selectWorkspace(right.id); model.search = "keep navigation"
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(model.selectedWorkspaceID == right.id && model.search == "keep navigation")
        precondition(model.errorMessage == nil)
        model.performFinderAction(.label(99), urls: [folder])
        try await wait { model.fileOperationsInProgress == 0 }
        precondition(model.errorMessage != nil && FileEntry(url: folder).labelNumber == 2)
    }
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(15)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition())
    }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String = "") throws {
        let result = try value(); precondition(result, message)
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
    }
}
