import Foundation

@main struct DropRedoTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FileDock-StrictRedo-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let quarantine = root.appendingPathComponent("recoverable", isDirectory: true)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: false)
        func trash(_ url: URL) throws -> URL {
            let target = quarantine.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            return target
        }
        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("original".utf8).write(to: url)
            return url
        }
        func label(_ value: Int, _ url: URL) throws {
            try require(try HubFinderFileActions.setLabel(value, urls: [url]).failures.isEmpty, "Fixture color write succeeds")
        }
        func number(_ url: URL) throws -> Int {
            var fresh = URL(fileURLWithPath: url.path); fresh.removeAllCachedResourceValues()
            return try fresh.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0
        }

        let tagged = try file("tagged"), originalTags = try HubDropUndo.captureTags(tagged)
        try label(7, tagged)
        let metadataOnly = try HubDropUndo.capture(source: nil, destination: tagged, transfer: .metadataOnly,
            originalLabel: 0, appliedLabel: 7, originalTagSnapshot: originalTags)
        let metadataUndo = HubDropUndo.undo([metadataOnly])
        try require(metadataUndo.failures.isEmpty && metadataUndo.inverse.count == 1 && metadataUndo.inverseUnavailable == 0 && (try number(tagged)) == 0,
                    "Strict metadata undo produces a small exact redo record")
        let metadataRedo = HubFileOperationUndo.apply(metadataUndo.inverse, trash: trash)
        if !metadataRedo.failures.isEmpty { print("metadata redo failures: \(metadataRedo.failures)") }
        try require(metadataRedo.failures.isEmpty && (try number(tagged)) == 7, "Metadata redo restores the applied color")
        try require(HubFileOperationUndo.apply(metadataRedo.inverse, trash: trash).failures.isEmpty && (try number(tagged)) == 0,
                    "A strict metadata action remains undoable after redo")

        let source = try file("source"), destination = root.appendingPathComponent("moved")
        let sourceTags = try HubDropUndo.captureTags(source)
        try fm.moveItem(at: source, to: destination); try label(4, destination)
        let strictMove = try HubDropUndo.capture(source: source, destination: destination, transfer: .move,
            originalLabel: 0, appliedLabel: 4, originalTagSnapshot: sourceTags)
        let moveUndo = HubDropUndo.undo([strictMove])
        try require(moveUndo.failures.isEmpty && moveUndo.inverse.count == 2 && moveUndo.inverseUnavailable == 0 && (try number(source)) == 0,
                    "Move-plus-color produces both physical and metadata redo inverses")
        let moveRedo = HubFileOperationUndo.apply(moveUndo.inverse, trash: trash)
        try require(moveRedo.failures.isEmpty && !fm.fileExists(atPath: source.path) && (try number(destination)) == 4,
                    "Redo reapplies color before moving the restored source to its former destination")
        let undoAgain = HubFileOperationUndo.apply(moveRedo.inverse, trash: trash)
        try require(undoAgain.failures.isEmpty && fm.fileExists(atPath: source.path) && (try number(source)) == 0,
                    "Redo's generated inverse restores both location and original metadata")

        // A later metadata edit rejects the dependent redo move as well. Keep
        // the failed metadata record as a barrier on repeated attempts.
        let expected = try HubFileOperationUndo.captureMetadata(source)
        try label(6, source)
        let blocked = HubFileOperationUndo.apply(moveUndo.inverse, trash: trash)
        try require(!blocked.failures.isEmpty && blocked.remaining.count == 2 && blocked.inverse.isEmpty &&
                    fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: destination.path) && (try number(source)) == 6,
                    "A rejected metadata prerequisite must not let the physical redo move execute")
        let stillBlocked = HubFileOperationUndo.apply(blocked.remaining, trash: trash)
        try require(!stillBlocked.failures.isEmpty && fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: destination.path),
                    "Retry cannot silently discard the failed prerequisite")
        if let restore = try HubFileOperationUndo.restoringMetadata(snapshot: expected, to: source) {
            try require(HubFileOperationUndo.apply([restore], trash: trash).failures.isEmpty, "Restore the known fixture metadata")
        }
        try require(HubFileOperationUndo.apply(blocked.remaining, trash: trash).failures.isEmpty && (try number(destination)) == 4,
                    "The complete dependent redo group can retry once the external conflict is repaired")

        let copySource = try file("copy-source"), copyDestination = root.appendingPathComponent("copied")
        let copyTags = try HubDropUndo.captureTags(copySource)
        let copySnapshot = try HubDropUndo.captureCopySource(copySource)
        try fm.copyItem(at: copySource, to: copyDestination); try label(7, copyDestination)
        let strictCopy = try HubDropUndo.capture(source: nil, destination: copyDestination, transfer: .copy,
            originalLabel: 0, appliedLabel: 7, copySource: copySnapshot, originalTagSnapshot: copyTags)
        let copyUndo = HubDropUndo.undo([strictCopy], recoverableTrash: trash)
        try require(copyUndo.failures.isEmpty && copyUndo.inverse.count == 1 && copyUndo.inverseUnavailable == 0,
                    "A strict verified copy retains its actual recoverable Trash URL for redo")
        let copyRedo = HubFileOperationUndo.apply(copyUndo.inverse, trash: trash)
        try require(copyRedo.failures.isEmpty && (try number(copyDestination)) == 7 && fm.fileExists(atPath: copySource.path),
                    "Copy redo restores the same trashed copy with its applied label, leaving the source untouched")
        let edited = try file("edited-strict-copy")
        let editedRecord = try HubDropUndo.capture(source: nil, destination: edited, transfer: .copy, originalLabel: nil, appliedLabel: nil,
                                                  copySource: HubDropUndo.captureCopySource(edited))
        try Data("external edit".utf8).write(to: edited)
        let rejected = HubDropUndo.undo([editedRecord], recoverableTrash: trash)
        try require(!rejected.failures.isEmpty && rejected.inverse.isEmpty && fm.fileExists(atPath: edited.path),
                    "Adding redo never weakens the original strict edited-copy rejection")

        // Redo style retargeting uses the actual destination identity after a
        // completed transfer, including the new inode a cross-volume move gets.
        let replacement = try file("retargeted-style")
        if let retarget = try HubFileOperationUndo.restoringMetadata(snapshot: try HubFileOperationUndo.captureMetadata(copyDestination), to: replacement) {
            try require(HubFileOperationUndo.apply([retarget], trash: trash).failures.isEmpty && (try number(replacement)) == 7,
                        "Retargeted desired metadata is validated against the actual current object, not the vanished path's inode")
        } else { fatalError("Different fixture colors require a metadata inverse") }
        let plainOriginal = root.appendingPathComponent("plain-original"), plainMoved = try file("plain-moved")
        let plain = try HubDropUndo.capture(source: plainOriginal, destination: plainMoved, transfer: .move, originalLabel: nil, appliedLabel: nil)
        let plainUndo = HubDropUndo.undo([plain])
        try require(plainUndo.failures.isEmpty && plainUndo.inverse.count == 1 && HubFileOperationUndo.apply(plainUndo.inverse, trash: trash).failures.isEmpty,
                    "Legacy strict moves without labels also expose their physical redo")
        print("PASS: strict label/move/copy undo supplies recoverable redo without weakening fingerprint/tag rejection; dependent metadata failure blocks all subsequent moves and remains blocked on retry")
    }
}
