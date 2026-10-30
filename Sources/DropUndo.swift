import Foundation
import CryptoKit
import Darwin

/// A bounded, in-memory journal of completed drag operations. All capture and
/// undo work must run off the main thread; no file contents are persisted.
enum HubDropUndo {
    enum Transfer: Sendable { case copy, move, metadataOnly }
    struct CopySnapshot: Sendable { fileprivate let digest: Data }
    /// nil data means the xattr was absent, which differs from empty data.
    struct TagSnapshot: Equatable, Sendable { fileprivate let data: Data? }
    struct Record: Sendable {
        let source: URL?
        let destination: URL
        let transfer: Transfer
        let originalLabel: Int?
        let appliedLabel: Int?
        let originalTags: [String]?
        let originalTagSnapshot: TagSnapshot?
        fileprivate let appliedTagSnapshot: TagSnapshot?
        fileprivate let appliedTags: [String]?
        fileprivate let identity: Identity
        fileprivate let fingerprint: Data?
    }
    struct Result: Sendable {
        var restored: [URL] = []
        /// Current destination and its restored original path, for bookmark repair.
        var relocations: [(URL, URL)] = []
        var failures: [String] = []
        var remaining: [Record] = []
    }
    fileprivate struct Identity: Equatable, Sendable { let device: UInt64; let inode: UInt64 }
    enum Failure: LocalizedError {
        case unsafe, changed, occupied, labelChanged, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsafe: return L("无法安全验证此项目。")
            case .changed: return L("此项目在拖放后已发生变化。")
            case .occupied: return L("原位置已有同名项目。")
            case .labelChanged: return L("此项目的颜色标签在拖放后已发生变化。")
            case .tooLarge: return L("此项目过大，无法安全验证并撤销。")
            }
        }
    }

    /// Must be called immediately before copying. Comparison ignores only
    /// the Finder color bits while retaining names and all other attributes.
    static func captureCopySource(_ source: URL) throws -> CopySnapshot {
        CopySnapshot(digest: try fingerprint(source.standardizedFileURL, portable: true))
    }

    private static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
    static func captureTags(_ url: URL) throws -> TagSnapshot {
        guard url.isFileURL else { throw Failure.unsafe }
        let size = getxattr(url.path, tagAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return TagSnapshot(data: nil) }
            throw Failure.unsafe
        }
        guard size <= 4 * 1024 * 1024 else { throw Failure.tooLarge }
        var data = Data(count: size)
        let actual = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, tagAttribute, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard actual == size else { throw Failure.changed }
        return TagSnapshot(data: data)
    }

    static func capture(source: URL?, destination: URL, transfer: Transfer,
                        originalLabel: Int?, appliedLabel: Int?, originalTags: [String]? = nil,
                        copySource: CopySnapshot? = nil, originalTagSnapshot: TagSnapshot? = nil) throws -> Record {
        guard destination.isFileURL, (transfer != .move || source?.isFileURL == true),
              (originalLabel == nil) == (appliedLabel == nil),
              originalLabel == nil || originalTagSnapshot != nil else { throw Failure.unsafe }
        let destination = destination.standardizedFileURL
        let identity = try identity(destination)
        if transfer == .copy {
            guard let copySource, try fingerprint(destination, portable: true) == copySource.digest else { throw Failure.changed }
        }
        // Metadata-only undo never removes or moves content and checks its
        // current label independently. Transfers need a complete tree digest.
        let digest = transfer == .metadataOnly ? nil : try fingerprint(destination)
        var fresh = destination; fresh.removeAllCachedResourceValues()
        let currentTags = appliedLabel == nil ? nil : try (fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).sorted()
        let currentTagSnapshot = appliedLabel == nil ? nil : try captureTags(destination)
        return Record(source: source?.standardizedFileURL, destination: destination, transfer: transfer,
                      originalLabel: originalLabel, appliedLabel: appliedLabel, originalTags: originalTags,
                      originalTagSnapshot: originalTagSnapshot, appliedTagSnapshot: currentTagSnapshot,
                      appliedTags: currentTags, identity: identity, fingerprint: digest)
    }

    static func undo(_ records: [Record], trash: (URL) throws -> Void = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }) -> Result {
        var result = Result()
        // Reverse order makes repeated operations on a common path predictable.
        for record in records.reversed() {
            var mutationStarted = false
            do {
                guard try identity(record.destination) == record.identity else { throw Failure.changed }
                if let expected = record.fingerprint, try fingerprint(record.destination) != expected { throw Failure.changed }
                if let applied = record.appliedLabel {
                    var fresh = record.destination; fresh.removeAllCachedResourceValues()
                    let values = try fresh.resourceValues(forKeys: [.labelNumberKey, .tagNamesKey])
                    guard (values.labelNumber ?? 0) == applied, (values.tagNames ?? []).sorted() == record.appliedTags,
                          try captureTags(record.destination) == record.appliedTagSnapshot else { throw Failure.labelChanged }
                }
                guard try identity(record.destination) == record.identity else { throw Failure.changed }
                switch record.transfer {
                case .copy:
                    try trash(record.destination)
                    mutationStarted = true
                    result.restored.append(record.destination)
                case .move:
                    guard let source = record.source, source != record.destination else { throw Failure.unsafe }
                    guard !FileManager.default.fileExists(atPath: source.path) else { throw Failure.occupied }
                    // moveItem refuses collisions, including races after the check.
                    try FileManager.default.moveItem(at: record.destination, to: source)
                    mutationStarted = true
                    result.relocations.append((record.destination, source))
                    if let label = record.originalLabel {
                        try restoreLabel(label, tags: record.originalTagSnapshot, url: source)
                    }
                    result.restored.append(source)
                case .metadataOnly:
                    guard let label = record.originalLabel else { throw Failure.unsafe }
                    mutationStarted = true
                    try restoreLabel(label, tags: record.originalTagSnapshot, url: record.destination)
                    result.restored.append(record.destination)
                }
            } catch {
                result.failures.append("\(record.destination.lastPathComponent)：\(error.localizedDescription)")
                if !mutationStarted, (try? identity(record.destination)) == record.identity { result.remaining.insert(record, at: 0) }
            }
        }
        return result
    }

    private static func restoreLabel(_ label: Int, tags: TagSnapshot?, url: URL) throws {
        guard let tags else { throw Failure.unsafe }
        let outcome = try HubFinderFileActions.setLabel(label, urls: [url])
        if !outcome.failures.isEmpty { throw Failure.unsafe }
        if let data = tags.data {
            let status = data.withUnsafeBytes { buffer in
                setxattr(url.path, tagAttribute, buffer.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            if status != 0 { throw Failure.unsafe }
        } else if removexattr(url.path, tagAttribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw Failure.unsafe }
    }

    private static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure.unsafe }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, kind != S_IFREG || info.st_nlink == 1 else { throw Failure.unsafe }
        return Identity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// Hash every regular file in a directory, including hidden descendants.
    /// Reject links and special files instead of following or deleting them.
    private static func fingerprint(_ root: URL, portable: Bool = false) throws -> Data {
        var hash = SHA256()
        var count = 0
        var bytes: Int64 = 0
        var metadataBytes = 0
        func add(_ value: String) { hash.update(data: Data(value.utf8)); hash.update(data: Data([0])) }
        func addExtendedAttributes(_ url: URL) throws {
            let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            guard length >= 0, length <= 1024 * 1024 else { throw Failure.unsafe }
            if length == 0 { return }
            var names = [CChar](repeating: 0, count: length)
            let actual = listxattr(url.path, &names, length, XATTR_NOFOLLOW)
            guard actual == length else { throw Failure.changed }
            let parts = names.map { UInt8(bitPattern: $0) }.split(separator: 0)
            guard parts.count <= 1024 else { throw Failure.tooLarge }
            let keys = try parts.map { part -> String in
                guard let key = String(bytes: part, encoding: .utf8), !key.isEmpty else { throw Failure.unsafe }
                return key
            }.sorted()
            for key in keys {
                let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw Failure.changed }
                metadataBytes += size
                guard metadataBytes <= 4 * 1024 * 1024 else { throw Failure.tooLarge }
                var data = Data(count: size)
                let read = data.withUnsafeMutableBytes { buffer in
                    getxattr(url.path, key, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
                guard read == size else { throw Failure.changed }
                if portable && key == "com.apple.FinderInfo" {
                    guard data.count == 32 else { throw Failure.unsafe }
                    data[9] &= 0xf1 // kColor bits in the big-endian finderFlags.
                    if data.allSatisfy({ $0 == 0 }) { continue }
                }
                add(key); add("\(size)"); hash.update(data: data)
            }
        }
        func visit(_ url: URL, relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Failure.unsafe }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR, kind != S_IFREG || info.st_nlink == 1 else { throw Failure.unsafe }
            count += 1
            if kind == S_IFREG {
                guard info.st_size >= 0, info.st_size <= 64 * 1024 * 1024 - bytes else { throw Failure.tooLarge }
                bytes += info.st_size
            }
            guard count <= 1024 else { throw Failure.tooLarge }
            add(relative)
            if !portable { add("\(info.st_dev):\(info.st_ino)") }
            let size = portable && kind == S_IFDIR ? 0 : info.st_size
            add("\(info.st_mode):\(info.st_uid):\(info.st_gid):\(size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)")
            try addExtendedAttributes(url)
            if !portable {
                var fresh = url; fresh.removeAllCachedResourceValues()
                let tags = try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
                for tag in tags.sorted() { add(tag) }
            }
            // Portable comparison already hashes every real user-tag xattr.
            // tagNames may also synthesize "Red" / "Blue" from FinderInfo's
            // color bits, which intentionally differ after assigning a label.
            if kind == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try visit(child, relative: relative + "/" + child.lastPathComponent) }
            } else {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure.unsafe }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
                      (opened.st_mode & S_IFMT) == S_IFREG, opened.st_nlink == 1 else { throw Failure.changed }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                var finished = stat()
                guard fstat(fd, &finished) == 0, finished.st_size == info.st_size,
                      finished.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                      finished.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw Failure.changed }
            }
            var after = stat()
            guard lstat(url.path, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
                  info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.changed }
        }
        try visit(root, relative: "")
        return Data(hash.finalize())
    }
}
