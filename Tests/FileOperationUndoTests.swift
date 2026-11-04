import Foundation
import Darwin

@main struct FileOperationUndoTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-OperationUndo-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let trashRoot = root.appendingPathComponent("recoverable-trash", isDirectory: true)
        try fm.createDirectory(at: trashRoot, withIntermediateDirectories: false)
        func trash(_ url: URL) throws -> URL {
            let target = trashRoot.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            return target
        }
        func file(_ name: String, _ contents: String = "original") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        func attribute(_ name: String, _ data: Data?, _ url: URL) throws {
            if let data {
                let code = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
                try require(code == 0, "Fixture xattr must be writable")
            } else { try require(removexattr(url.path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR, "Fixture xattr removal must succeed") }
        }
        func tags(_ values: [String], _ url: URL) throws {
            try attribute("com.apple.metadata:_kMDItemUserTags",
                PropertyListSerialization.data(fromPropertyList: values.map { $0 + "\n0" }, format: .binary, options: 0), url)
        }
        func data(_ name: String, _ url: URL) -> Data? {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var result = Data(count: size)
            let read = result.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read == size ? result : nil
        }

        // Large regular contents and large directory trees do not take part in
        // an ordinary move's history admission or undo verification.
        let original = try file("large-original"), moved = root.appendingPathComponent("large-moved")
        let largeHandle = try FileHandle(forWritingTo: original)
        try largeHandle.truncate(atOffset: 64 * 1024 * 1024 + 1); try largeHandle.close()
        try fm.moveItem(at: original, to: moved)
        let largeRecord = try HubFileOperationUndo.moved(from: original, to: moved)
        try require(largeRecord.estimatedBytes < 4096 && largeRecord.scopeURLs.contains(moved), "Move history stores identities/paths, not file bytes")
        let append = try FileHandle(forWritingTo: moved); try append.seekToEnd(); try append.write(contentsOf: Data("edited".utf8)); try append.close()
        let largeUndo = HubFileOperationUndo.apply([largeRecord], trash: trash)
        try require(largeUndo.failures.isEmpty && fm.fileExists(atPath: original.path), "A file larger than the strict label fingerprint limit still moves back")
        try require((try original.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 64 * 1024 * 1024 + 7, "Undo preserves edits made after a plain move")
        let largeRedo = HubFileOperationUndo.apply(largeUndo.inverse, trash: trash)
        try require(largeRedo.failures.isEmpty && fm.fileExists(atPath: moved.path), "Ordinary move exposes a reversible inverse")
        let tree = try directory("large-tree"), treeTarget = root.appendingPathComponent("tree-moved")
        for index in 0..<1100 { fm.createFile(atPath: tree.appendingPathComponent("entry-\(index)").path, contents: Data()) }
        try fm.moveItem(at: tree, to: treeTarget)
        let treeRecord = try HubFileOperationUndo.moved(from: tree, to: treeTarget)
        try require(HubFileOperationUndo.apply([treeRecord], trash: trash).failures.isEmpty, "A directory with more than 1024 descendants still undoes without a tree digest")

        // Capturing the resulting object, not the vanished source inode, also
        // works when a cross-volume transfer created a new destination inode.
        let crossSource = try file("cross-source"), crossTarget = root.appendingPathComponent("cross-result")
        try fm.copyItem(at: crossSource, to: crossTarget); try fm.removeItem(at: crossSource)
        let crossRecord = try HubFileOperationUndo.moved(from: crossSource, to: crossTarget)
        try require(HubFileOperationUndo.apply([crossRecord], trash: trash).failures.isEmpty && fm.fileExists(atPath: crossSource.path), "A recreated destination identity is acknowledged at capture")

        let aliasTarget = try file("symlink-target"), link = root.appendingPathComponent("link"), linkMoved = root.appendingPathComponent("link-moved")
        try fm.createSymbolicLink(at: link, withDestinationURL: aliasTarget)
        try fm.moveItem(at: link, to: linkMoved)
        let linkRecord = try HubFileOperationUndo.moved(from: link, to: linkMoved)
        try require(HubFileOperationUndo.apply([linkRecord], trash: trash).failures.isEmpty, "Moving a symlink reverses the link itself")
        try require(try Data(contentsOf: aliasTarget) == Data("original".utf8), "Symlink undo never edits or moves its referent")
        let hard = root.appendingPathComponent("hard"), hardMoved = root.appendingPathComponent("hard-moved")
        try fm.linkItem(at: aliasTarget, to: hard); try fm.moveItem(at: hard, to: hardMoved)
        try require(HubFileOperationUndo.apply([try HubFileOperationUndo.moved(from: hard, to: hardMoved)], trash: trash).failures.isEmpty, "Hardlinked files do not need a content fingerprint to move back")

        let created = try directory("created-folder"), inside = created.appendingPathComponent("later-edit.txt")
        let createdRecord = try HubFileOperationUndo.created(created)
        try Data("keep this edit".utf8).write(to: inside)
        let removed = HubFileOperationUndo.apply([createdRecord], trash: trash)
        try require(removed.failures.isEmpty && removed.trashed == [created] && !fm.fileExists(atPath: created.path), "Undoing creation uses recoverable Trash even if its contents changed")
        try require(removed.inverse.count == 1 && removed.inverse[0].scopeURLs.contains { $0.path.hasPrefix(trashRoot.path) }, "The actual returned Trash address is retained")
        let recreated = HubFileOperationUndo.apply(removed.inverse, trash: trash)
        try require(recreated.failures.isEmpty && (try Data(contentsOf: inside)) == Data("keep this edit".utf8), "Redo restores the trashed original with later contents intact")
        try require(HubFileOperationUndo.apply(recreated.inverse, trash: trash).failures.isEmpty, "Creation remains reversible after redo")

        let occupiedOriginal = try file("occupied-original"), occupiedCurrent = root.appendingPathComponent("occupied-current")
        try fm.moveItem(at: occupiedOriginal, to: occupiedCurrent)
        let occupiedRecord = try HubFileOperationUndo.moved(from: occupiedOriginal, to: occupiedCurrent)
        try fm.createSymbolicLink(at: occupiedOriginal, withDestinationURL: root.appendingPathComponent("missing-target"))
        let blocked = HubFileOperationUndo.apply([occupiedRecord], trash: trash)
        try require(!blocked.failures.isEmpty && blocked.remaining.count == 1 && blocked.inverse.isEmpty, "A broken symlink occupies the original path and prevents overwriting")
        try require(fm.fileExists(atPath: occupiedCurrent.path), "Rejected undo leaves the moved object untouched")

        let oldParent = try directory("old-parent"), oldPath = oldParent.appendingPathComponent("item"), newPath = try file("parent-test-current")
        let parentRecord = try HubFileOperationUndo.moved(from: oldPath, to: newPath)
        try fm.moveItem(at: oldParent, to: root.appendingPathComponent("retired-parent"))
        try fm.createDirectory(at: oldParent, withIntermediateDirectories: false)
        try require(!HubFileOperationUndo.apply([parentRecord], trash: trash).failures.isEmpty && fm.fileExists(atPath: newPath.path), "Undo cannot restore into a different directory replacing the original parent")
        try fm.removeItem(at: oldParent)
        try require(!HubFileOperationUndo.apply([parentRecord], trash: trash).failures.isEmpty, "A missing original parent is not silently recreated")
        let replaceOriginal = root.appendingPathComponent("replaced-original"), replaceCurrent = try file("replaced-current")
        let replaceRecord = try HubFileOperationUndo.moved(from: replaceOriginal, to: replaceCurrent)
        try fm.moveItem(at: replaceCurrent, to: root.appendingPathComponent("retired-current"))
        try Data("new unrelated file".utf8).write(to: replaceCurrent)
        let replacement = HubFileOperationUndo.apply([replaceRecord], trash: trash)
        try require(!replacement.failures.isEmpty && replacement.remaining.count == 1 && (try Data(contentsOf: replaceCurrent)) == Data("new unrelated file".utf8), "Identity replacement cannot undo an unrelated newer file or silently skip its history barrier")

        let stepA = try file("chain-a"), stepB = root.appendingPathComponent("chain-b"), stepC = root.appendingPathComponent("chain-c")
        try fm.moveItem(at: stepA, to: stepB); let first = try HubFileOperationUndo.moved(from: stepA, to: stepB)
        try fm.moveItem(at: stepB, to: stepC); let second = try HubFileOperationUndo.moved(from: stepB, to: stepC)
        let chain = HubFileOperationUndo.apply([first, second], trash: trash)
        try require(chain.failures.isEmpty && fm.fileExists(atPath: stepA.path), "Batch inverses apply in reverse dependency order")
        try require(HubFileOperationUndo.apply(chain.inverse, trash: trash).failures.isEmpty && fm.fileExists(atPath: stepC.path), "Inverse records preserve redo dependency order")
        let partial = HubFileOperationUndo.apply([occupiedRecord, try HubFileOperationUndo.created(try file("partial-created"))], trash: trash)
        try require(partial.remaining.count == 1 && partial.inverse.count == 1 && partial.trashed.count == 1, "Successful partial undo and blocked records remain separately reversible")
        let blockedBeforeCreated = try file("blocked-before-created")
        let blockedGroup = HubFileOperationUndo.apply([try HubFileOperationUndo.created(blockedBeforeCreated), occupiedRecord], trash: trash)
        try require(blockedGroup.remaining.count == 2 && blockedGroup.inverse.isEmpty && fm.fileExists(atPath: blockedBeforeCreated.path),
                    "A failure stops the group before older potentially dependent operations execute")

        let metadata = try directory("metadata"), icon = metadata.appendingPathComponent("Icon\r")
        var finderBefore = Data(repeating: 0, count: 32); finderBefore[9] = 4
        try attribute("com.apple.FinderInfo", finderBefore, metadata); try tags(["prior custom"], metadata)
        try attribute("com.apple.icon.folder#S", Data("before".utf8), metadata)
        try Data("old icon bytes".utf8).write(to: icon)
        try attribute("com.apple.ResourceFork", Data("old resource".utf8), icon)
        let before = try HubFileOperationUndo.captureMetadata(metadata)
        try require(try HubFileOperationUndo.changedMetadata(metadata, before: before) == nil, "An unchanged style does not create history")
        var finderAfter = finderBefore; finderAfter[9] = 14
        try attribute("com.apple.FinderInfo", finderAfter, metadata); try tags(["applied custom"], metadata)
        try attribute("com.apple.icon.folder#S", Data("after".utf8), metadata)
        try Data("new icon bytes".utf8).write(to: icon)
        try attribute("com.apple.ResourceFork", Data("new resource".utf8), icon)
        let metadataRecord = try HubFileOperationUndo.changedMetadata(metadata, before: before)!
        let styleUndo = HubFileOperationUndo.apply([metadataRecord], trash: trash)
        try require(styleUndo.failures.isEmpty && data("com.apple.FinderInfo", metadata) == finderBefore && data("com.apple.icon.folder#S", metadata) == Data("before".utf8), "Style undo restores exact native attributes")
        try require((try Data(contentsOf: icon)) == Data("old icon bytes".utf8) && data("com.apple.ResourceFork", icon) == Data("old resource".utf8), "The original Icon file bytes and resource fork are restored")
        let styleRedo = HubFileOperationUndo.apply(styleUndo.inverse, trash: trash)
        try require(styleRedo.failures.isEmpty && (try Data(contentsOf: icon)) == Data("new icon bytes".utf8), "Metadata inverse restores the applied style on redo")
        let applied = try HubFileOperationUndo.captureMetadata(metadata)
        try tags(["external later change"], metadata)
        let tagChanged = HubFileOperationUndo.apply(styleRedo.inverse, trash: trash)
        try require(!tagChanged.failures.isEmpty && (try metadata.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).contains("external later change"), "A later Finder metadata edit cannot be overwritten")
        // Restore only the test's known applied xattr so the existing strict
        // record is again eligible for a deliberately failing write sequence.
        try tags(["applied custom"], metadata)
        try require(try HubFileOperationUndo.captureMetadata(metadata) == applied, "The fixture must match the expected applied snapshot")
        enum Injected: Error { case blockedTrash }
        let rolledBack = HubFileOperationUndo.apply(styleRedo.inverse, trash: { _ in throw Injected.blockedTrash })
        try require(!rolledBack.failures.isEmpty && (try HubFileOperationUndo.captureMetadata(metadata)) == applied,
                    "If replacing the Icon fails after root attrs changed, those fields roll back to the complete applied state")
        try require(!(try fm.contentsOfDirectory(atPath: metadata.path)).contains { $0.hasPrefix(".FileDock-UndoIcon-") }, "Synthetic staging files are cleaned after rollback")

        let none = try directory("absent-icon"), noneBefore = try HubFileOperationUndo.captureMetadata(none)
        let noneIcon = none.appendingPathComponent("Icon\r"); try Data("applied".utf8).write(to: noneIcon)
        let absentRecord = try HubFileOperationUndo.changedMetadata(none, before: noneBefore)!
        let absentUndo = HubFileOperationUndo.apply([absentRecord], trash: trash)
        try require(absentUndo.failures.isEmpty && !fm.fileExists(atPath: noneIcon.path), "An originally absent Icon remains absent")
        try require(HubFileOperationUndo.apply(absentUndo.inverse, trash: trash).failures.isEmpty && fm.fileExists(atPath: noneIcon.path), "Redo can recreate a prior icon from bounded metadata")
        let styleLink = root.appendingPathComponent("metadata-link")
        try fm.createSymbolicLink(at: styleLink, withDestinationURL: metadata)
        try require((try? HubFileOperationUndo.captureMetadata(styleLink)) == nil, "Metadata never follows a symlink root")
        let oversized = try directory("oversized-icon"), oversizedIcon = oversized.appendingPathComponent("Icon\r")
        fm.createFile(atPath: oversizedIcon.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversizedIcon); try handle.truncate(atOffset: 16 * 1024 * 1024 + 1); try handle.close()
        try require((try? HubFileOperationUndo.captureMetadata(oversized)) == nil, "Metadata journal memory has a bounded capture size")
        print("PASS: identity-only large/tree/cross-volume-result moves, edited contents, symlinks/hardlinks, recoverable create/redo, original conflicts/parent replacement, partial/history order, exact native style/redo, external metadata rejection, rollback and bounded metadata capture")
        print("LIMIT: cross-volume-result coverage recreates a destination inode; it does not require or exercise a second mounted volume")
    }
}
