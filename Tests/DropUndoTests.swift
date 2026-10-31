import Foundation
import Darwin

@main struct DropUndoTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
        guard try value() else { fatalError(message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileDock-DropUndo-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let quarantine = root.appendingPathComponent("trash", isDirectory: true)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        func trash(_ url: URL) throws { try fm.moveItem(at: url, to: quarantine.appendingPathComponent(url.lastPathComponent)) }
        func label(_ number: Int, _ url: URL) throws {
            try require(try HubFinderFileActions.setLabel(number, urls: [url]).failures.isEmpty)
        }
        func number(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0 }
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try Data("original".utf8).write(to: url); return url
        }
        func setTags(_ tags: [String], on url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: tags.map { $0 + "\n0" }, format: .binary, options: 0)
            let status = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            try require(status == 0)
        }
        let metadata = try file("metadata")
        try setTags(["keep custom tag"], on: metadata)
        let tags = try metadata.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        let originalSnapshot = try HubDropUndo.captureTags(metadata)
        try label(7, metadata)
        let tagRecord = try HubDropUndo.capture(source: nil, destination: metadata, transfer: .metadataOnly,
                                                originalLabel: 0, appliedLabel: 7, originalTags: tags, originalTagSnapshot: originalSnapshot)
        let tagUndo = HubDropUndo.undo([tagRecord], trash: trash)
        try require(tagUndo.failures.isEmpty && (try number(metadata)) == 0)
        try require((try metadata.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).contains("keep custom tag"))
        try require(try HubDropUndo.captureTags(metadata) == originalSnapshot, "Undo restores original tag xattr bytes")

        try label(7, metadata)
        let changedTags = try HubDropUndo.capture(source: nil, destination: metadata, transfer: .metadataOnly,
                                                  originalLabel: 0, appliedLabel: 7, originalTags: tags, originalTagSnapshot: originalSnapshot)
        try setTags(["keep custom tag", "new user tag"], on: metadata)
        let userChangedSnapshot = try HubDropUndo.captureTags(metadata)
        try require(!HubDropUndo.undo([changedTags], trash: trash).failures.isEmpty)
        try require(try HubDropUndo.captureTags(metadata) == userChangedSnapshot,
                    "Rejected undo must preserve the user's changed tag metadata")
        let noTagsFile = try file("no-tags")
        let absentTags = try HubDropUndo.captureTags(noTagsFile)
        try label(4, noTagsFile)
        let noTagsRecord = try HubDropUndo.capture(source: nil, destination: noTagsFile, transfer: .metadataOnly,
                                                    originalLabel: 0, appliedLabel: 4, originalTagSnapshot: absentTags)
        try require(HubDropUndo.undo([noTagsRecord], trash: trash).failures.isEmpty)
        try require(try HubDropUndo.captureTags(noTagsFile) == absentTags, "An absent tag xattr stays absent")

        let copied = try file("copy")
        let copyRecord = try HubDropUndo.capture(source: nil, destination: copied, transfer: .copy, originalLabel: nil, appliedLabel: nil,
                                                 copySource: HubDropUndo.captureCopySource(copied))
        let copyUndo = HubDropUndo.undo([copyRecord], trash: trash)
        try require(copyUndo.failures.isEmpty && !fm.fileExists(atPath: copied.path))
        try require(fm.fileExists(atPath: quarantine.appendingPathComponent("copy").path), "Copies go to recoverable trash")

        let copySource = try file("copy-source"), copyTarget = root.appendingPathComponent("copy-target")
        try setTags(["custom tag"], on: copySource)
        try label(2, copySource)
        let priorTags = try copySource.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        let priorTagSnapshot = try HubDropUndo.captureTags(copySource)
        let sourceSnapshot = try HubDropUndo.captureCopySource(copySource)
        try fm.copyItem(at: copySource, to: copyTarget)
        try label(7, copyTarget)
        let verifiedCopy = try HubDropUndo.capture(source: nil, destination: copyTarget, transfer: .copy,
                                                   originalLabel: 2, appliedLabel: 7, originalTags: priorTags, copySource: sourceSnapshot, originalTagSnapshot: priorTagSnapshot)
        // Finder synthesizes tagNames from FinderInfo when there are no
        // custom tags; changing only the color must not reject a valid copy.
        let colorOnly = try file("color-only"), colorOnlyTarget = root.appendingPathComponent("color-only-target")
        try label(6, colorOnly)
        let noUserTags = try HubDropUndo.captureTags(colorOnly)
        let colorOnlySnapshot = try HubDropUndo.captureCopySource(colorOnly)
        try fm.copyItem(at: colorOnly, to: colorOnlyTarget)
        try label(4, colorOnlyTarget)
        _ = try HubDropUndo.capture(source: nil, destination: colorOnlyTarget, transfer: .copy,
                                    originalLabel: 6, appliedLabel: 4, copySource: colorOnlySnapshot, originalTagSnapshot: noUserTags)
        let changedTagsCopy = root.appendingPathComponent("color-only-changed-tags")
        try fm.copyItem(at: colorOnly, to: changedTagsCopy)
        try setTags(["user-added"], on: changedTagsCopy)
        try require((try? HubDropUndo.capture(source: nil, destination: changedTagsCopy, transfer: .copy,
                                              originalLabel: nil, appliedLabel: nil, copySource: colorOnlySnapshot)) == nil,
                    "A changed real user-tag xattr must reject copy undo")
        try require(HubDropUndo.undo([verifiedCopy], trash: trash).failures.isEmpty)
        try require(fm.fileExists(atPath: copySource.path))
        let editedTarget = root.appendingPathComponent("edited-before-capture")
        try fm.copyItem(at: copySource, to: editedTarget)
        try Data("modified after transfer".utf8).write(to: editedTarget)
        try require((try? HubDropUndo.capture(source: nil, destination: editedTarget, transfer: .copy,
                                               originalLabel: nil, appliedLabel: nil, copySource: sourceSnapshot)) == nil)
        try require(fm.fileExists(atPath: editedTarget.path))

        let modified = try file("changed")
        let changed = try HubDropUndo.capture(source: nil, destination: modified, transfer: .copy, originalLabel: nil, appliedLabel: nil,
                                              copySource: HubDropUndo.captureCopySource(modified))
        try Data("user change".utf8).write(to: modified)
        try require(!HubDropUndo.undo([changed], trash: trash).failures.isEmpty && fm.fileExists(atPath: modified.path))
        let metadataModified = try file("extended-attributes")
        let metadataCopy = try HubDropUndo.capture(source: nil, destination: metadataModified, transfer: .copy, originalLabel: nil, appliedLabel: nil,
                                                   copySource: HubDropUndo.captureCopySource(metadataModified))
        let attribute = Data("user data".utf8)
        let written = attribute.withUnsafeBytes { setxattr(metadataModified.path, "user.filedock-test", $0.baseAddress, $0.count, 0, 0) }
        try require(written == 0)
        try require(!HubDropUndo.undo([metadataCopy], trash: trash).failures.isEmpty && fm.fileExists(atPath: metadataModified.path))

        let source = root.appendingPathComponent("original-location"), moved = try file("moved")
        let move = try HubDropUndo.capture(source: source, destination: moved, transfer: .move, originalLabel: nil, appliedLabel: nil)
        try Data("existing".utf8).write(to: source)
        try require(!HubDropUndo.undo([move], trash: trash).failures.isEmpty)
        try require(try Data(contentsOf: source) == Data("existing".utf8) && fm.fileExists(atPath: moved.path))
        try fm.removeItem(at: source)
        let movedBack = HubDropUndo.undo([move], trash: trash)
        try require(movedBack.failures.isEmpty && movedBack.relocations.count == 1 && fm.fileExists(atPath: source.path))

        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("nested"); try Data("original".utf8).write(to: nested)
        let folderSnapshot = try HubDropUndo.captureCopySource(folder)
        let folderCopy = root.appendingPathComponent("folder-copy")
        try fm.copyItem(at: folder, to: folderCopy)
        let copiedFolder = try HubDropUndo.capture(source: nil, destination: folderCopy, transfer: .copy,
                                                   originalLabel: nil, appliedLabel: nil, copySource: folderSnapshot)
        try require(HubDropUndo.undo([copiedFolder], trash: trash).failures.isEmpty)
        let folderRecord = try HubDropUndo.capture(source: nil, destination: folder, transfer: .copy, originalLabel: nil, appliedLabel: nil,
                                                   copySource: HubDropUndo.captureCopySource(folder))
        try Data("changed".utf8).write(to: nested)
        try require(!HubDropUndo.undo([folderRecord], trash: trash).failures.isEmpty && fm.fileExists(atPath: folder.path))

        let linked = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: linked, withDestinationURL: source)
        try require((try? HubDropUndo.captureCopySource(linked)) == nil)
        let hard = root.appendingPathComponent("hard")
        try fm.linkItem(at: source, to: hard)
        try require((try? HubDropUndo.captureCopySource(hard)) == nil)
        let large = try file("large")
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try largeHandle.close()
        try require((try? HubDropUndo.captureCopySource(large)) == nil)
        print("PASS: color undo, user label changes, recoverable copy, edited copies, occupied original, move and nested edits, symlinks and hardlinks")
    }
}
