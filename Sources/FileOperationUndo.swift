import Foundation
import Darwin

/// Ordinary Finder-style inverses never inspect file contents. A moved item
/// may have been edited since the move: restore that same object, including
/// the edits. Created items are sent to recoverable Trash, never deleted.
/// Synchronous APIs belong on a file worker, not the main actor.
enum HubFileOperationUndo {
    fileprivate struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let kind: mode_t
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }
    fileprivate struct IconFile: Equatable, Sendable {
        let identity: Identity
        let bytes: Data
        let attributes: [String: Data]
        let permissions: Int
        var estimatedBytes: Int { bytes.count + attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } + 256 }
    }
    struct MetadataSnapshot: Equatable, Sendable {
        fileprivate let url: URL
        fileprivate let identity: Identity
        fileprivate let attributes: [String: Data]
        fileprivate let icon: IconFile?
        var estimatedBytes: Int { url.path.utf8.count + attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } + (icon?.estimatedBytes ?? 0) + 512 }
    }
    struct Record: Sendable {
        fileprivate enum Kind: Sendable {
            case move(original: URL, current: URL, identity: Identity, parent: Identity)
            case created(URL, Identity)
            case metadata(expected: MetadataSnapshot, desired: MetadataSnapshot)
        }
        fileprivate let kind: Kind
        var scopeURLs: [URL] {
            switch kind {
            case .move(let original, let current, _, _): return [original, original.deletingLastPathComponent(), current, current.deletingLastPathComponent()]
            case .created(let url, _): return [url, url.deletingLastPathComponent()]
            case .metadata(let expected, _): return [expected.url]
            }
        }
        var estimatedBytes: Int {
            switch kind {
            case .move(let original, let current, _, _): return original.path.utf8.count + current.path.utf8.count + 512
            case .created(let url, _): return url.path.utf8.count + 256
            case .metadata(let expected, let desired): return expected.estimatedBytes + desired.estimatedBytes
            }
        }
        fileprivate var currentURL: URL {
            switch kind {
            case .move(_, let current, _, _), .created(let current, _): return current
            case .metadata(let expected, _): return expected.url
            }
        }
    }
    struct Outcome: Sendable {
        var inverse: [Record] = []
        var remaining: [Record] = []
        var failures: [String] = []
        var restored: [URL] = []
        var relocations: [(URL, URL)] = []
        var trashed: [URL] = []
    }
    enum Failure: LocalizedError {
        case unsafe, changed, occupied, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsafe: return L("无法安全验证此项目。")
            case .changed: return L("此项目在拖放后已发生变化。")
            case .occupied: return L("原位置已有同名项目。")
            case .tooLarge: return L("此项目过大，无法安全验证并撤销。")
            }
        }
    }
    private static let metadataLimit = 16 * 1024 * 1024
    private static let rootAttributes = ["com.apple.FinderInfo", "com.apple.metadata:_kMDItemUserTags", "com.apple.icon.folder#S", "com.apple.ResourceFork"]

    static func moved(from original: URL, to current: URL) throws -> Record {
        let original = try fileURL(original), current = try fileURL(current)
        guard original.path != current.path else { throw Failure.unsafe }
        return Record(kind: .move(original: original, current: current,
                                  identity: try identity(current), parent: try parentIdentity(original)))
    }
    static func created(_ url: URL) throws -> Record {
        let url = try fileURL(url)
        return Record(kind: .created(url, try identity(url)))
    }
    static func changedMetadata(_ url: URL, before: MetadataSnapshot) throws -> Record? {
        let after = try captureMetadata(url)
        guard before.url.path == after.url.path, before.identity == after.identity else { throw Failure.changed }
        return before == after ? nil : Record(kind: .metadata(expected: after, desired: before))
    }

    /// A completed move may have crossed volumes and acquired a new root
    /// identity. Retarget a previously captured desired style only after that
    /// real move; its expected state is still captured from the current object.
    static func restoringMetadata(snapshot: MetadataSnapshot, to url: URL) throws -> Record? {
        let actual = try captureMetadata(url)
        guard actual.identity.kind == snapshot.identity.kind else { throw Failure.unsafe }
        let desired = MetadataSnapshot(url: actual.url, identity: actual.identity,
                                       attributes: snapshot.attributes, icon: snapshot.icon)
        return desired == actual ? nil : Record(kind: .metadata(expected: actual, desired: desired))
    }

    static func apply(_ records: [Record], trash: (URL) throws -> URL = systemTrash) -> Outcome {
        var result = Outcome()
        for index in records.indices.reversed() {
            let record = records[index]
            do {
                switch record.kind {
                case .move(let original, let current, let expected, let parent):
                    guard try identity(current) == expected, try parentIdentity(original) == parent else { throw Failure.changed }
                    guard try !exists(original) else { throw Failure.occupied }
                    // FileManager refuses occupied paths, including a broken
                    // symlink or an item appearing after the lstat check.
                    try FileManager.default.moveItem(at: current, to: original)
                    result.restored.append(original); result.relocations.append((current, original))
                    result.inverse.append(try moved(from: current, to: original))
                case .created(let current, let expected):
                    guard try identity(current) == expected else { throw Failure.changed }
                    let location = try trash(current)
                    result.trashed.append(current)
                    result.inverse.append(try moved(from: current, to: location))
                case .metadata(let expected, let desired):
                    let actual = try captureMetadata(expected.url)
                    guard actual == expected else { throw Failure.changed }
                    try restoreMetadata(desired, current: actual, trash: trash)
                    do {
                        let applied = try captureMetadata(expected.url)
                        result.inverse.append(Record(kind: .metadata(expected: applied, desired: actual)))
                        result.restored.append(expected.url)
                    } catch {
                        // Capture failure must not leave an unjournaled style
                        // change behind when the previous state can be restored.
                        if let partial = try? captureMetadata(expected.url) { try? restoreMetadata(actual, current: partial, trash: trash) }
                        throw error
                    }
                }
            } catch {
                result.failures.append("\(record.currentURL.lastPathComponent)：\(error.localizedDescription)")
                // Earlier records may depend on this operation (for example,
                // restore a label before moving its file). Keep the failed
                // record as a barrier even if its current identity changed;
                // retrying must never skip it and execute only the later move.
                result.remaining = Array(records.prefix(index + 1))
                break
            }
        }
        return result
    }

    static func captureMetadata(_ rawURL: URL) throws -> MetadataSnapshot {
        let url = try fileURL(rawURL)
        let before = try status(url)
        let rootIdentity = try identity(before)
        guard rootIdentity.kind == S_IFREG || rootIdentity.kind == S_IFDIR else { throw Failure.unsafe }
        var budget = metadataLimit
        var attributes: [String: Data] = [:]
        for key in rootAttributes {
            if let data = try attribute(key, at: url, budget: &budget) { attributes[key] = data }
        }
        var icon: IconFile?
        if rootIdentity.kind == S_IFDIR {
            let child = url.appendingPathComponent("Icon\r")
            if try exists(child) {
                let info = try status(child)
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                      info.st_size >= 0, info.st_size <= budget else { throw Failure.unsafe }
                let childIdentity = try identity(info)
                let descriptor = open(child.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw Failure.unsafe }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, try identity(opened) == childIdentity else { throw Failure.changed }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(512 * 1024, budget + 1)), !chunk.isEmpty {
                    guard chunk.count <= budget else { throw Failure.tooLarge }
                    budget -= chunk.count; data.append(chunk)
                }
                var childAttributes: [String: Data] = [:]
                for key in try attributeNames(child) {
                    if let value = try attribute(key, at: child, budget: &budget) { childAttributes[key] = value }
                }
                let after = try status(child)
                guard stable(info, after), try identity(after) == childIdentity else { throw Failure.changed }
                icon = IconFile(identity: childIdentity, bytes: data, attributes: childAttributes, permissions: Int(info.st_mode & 0o7777))
            }
        }
        guard stable(before, try status(url)) else { throw Failure.changed }
        return MetadataSnapshot(url: url, identity: rootIdentity, attributes: attributes, icon: icon)
    }

    private static func restoreMetadata(_ desired: MetadataSnapshot, current: MetadataSnapshot,
                                        trash: (URL) throws -> URL) throws {
        let url = current.url
        guard desired.identity == current.identity, try identity(url) == current.identity else { throw Failure.changed }
        let iconURL = url.appendingPathComponent("Icon\r")
        var stage: URL?
        var stageIdentity: Identity?
        var oldIconTrash: URL?
        var changedAttributes: [String] = []
        // Stage complete icon bytes/xattrs before changing any live metadata.
        if let icon = desired.icon, icon != current.icon {
            let prepared = url.appendingPathComponent(".FileDock-UndoIcon-\(UUID().uuidString)")
            let descriptor = open(prepared.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.unsafe }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            stage = prepared; stageIdentity = try? identity(prepared)
            do {
                try handle.write(contentsOf: icon.bytes); try handle.close()
                for (key, value) in icon.attributes { try writeAttribute(key, value: value, at: prepared) }
                guard chmod(prepared.path, mode_t(icon.permissions)) == 0 else { throw Failure.unsafe }
            } catch { try? handle.close(); removePrivateStage(prepared, identity: stageIdentity); throw error }
        }
        defer { if let stage { removePrivateStage(stage, identity: stageIdentity) } }
        do {
            // Revalidate immediately before the first mutation. This detects
            // later Finder changes rather than overwriting their new tags/icon.
            guard try captureMetadata(url) == current else { throw Failure.changed }
            for key in rootAttributes where desired.attributes[key] != current.attributes[key] {
                try writeAttribute(key, value: desired.attributes[key], at: url)
                changedAttributes.append(key)
            }
            if desired.icon != current.icon {
                if current.icon != nil { oldIconTrash = try trash(iconURL) }
                if let stage {
                    guard try !exists(iconURL) else { throw Failure.occupied }
                    try FileManager.default.moveItem(at: stage, to: iconURL)
                }
            }
        } catch {
            // Roll back only the fields already written; never follow a
            // replacement root or overwrite a concurrent Icon file.
            if (try? identity(url)) == current.identity {
                if let oldIconTrash, (try? exists(iconURL)) == false { try? FileManager.default.moveItem(at: oldIconTrash, to: iconURL) }
                for key in changedAttributes.reversed() { try? writeAttribute(key, value: current.attributes[key], at: url) }
            }
            throw error
        }
    }

    private static func removePrivateStage(_ url: URL, identity expected: Identity?) {
        guard let expected, (try? identity(url)) == expected else { return }
        // This file contains only a newly staged copy of bounded icon metadata.
        // Original user files and icon files always use recoverable Trash.
        try? FileManager.default.removeItem(at: url)
    }
    private static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw Failure.unsafe }
        return result as URL
    }
    private static func fileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0"), url.query == nil, url.fragment == nil else { throw Failure.unsafe }
        return url.standardizedFileURL
    }
    private static func status(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure.unsafe }
        return info
    }
    private static func identity(_ url: URL) throws -> Identity { try identity(status(url)) }
    private static func identity(_ info: stat) throws -> Identity {
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { throw Failure.unsafe }
        return Identity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), kind: kind,
                        birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    private static func parentIdentity(_ url: URL) throws -> Identity {
        var info = stat()
        guard stat(url.deletingLastPathComponent().path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafe }
        return try identity(info)
    }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.unsafe }
        return false
    }
    private static func stable(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
    private static func attribute(_ key: String, at url: URL, budget: inout Int) throws -> Data? {
        let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if length < 0 { if errno == ENOATTR { return nil }; throw Failure.unsafe }
        guard length <= budget else { throw Failure.tooLarge }
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        guard count == length else { throw Failure.changed }
        budget -= length
        return data
    }
    private static func attributeNames(_ url: URL) throws -> [String] {
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length >= 0, length <= 64 * 1024 else { throw Failure.tooLarge }
        if length == 0 { return [] }
        var data = [CChar](repeating: 0, count: length)
        guard listxattr(url.path, &data, length, XATTR_NOFOLLOW) == length else { throw Failure.changed }
        let parts = data.map { UInt8(bitPattern: $0) }.split(separator: 0)
        guard parts.count <= 256 else { throw Failure.tooLarge }
        return try parts.map { part in
            guard let key = String(bytes: part, encoding: .utf8), !key.isEmpty else { throw Failure.unsafe }
            return key
        }.sorted()
    }
    private static func writeAttribute(_ key: String, value: Data?, at url: URL) throws {
        if let value {
            let status = value.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw Failure.unsafe }
        } else if removexattr(url.path, key, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw Failure.unsafe }
    }
}
