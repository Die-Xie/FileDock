import Foundation
import Darwin
import UniformTypeIdentifiers

enum HubStagingImportError: LocalizedError {
    case invalidLocation, unsupportedSource, recursiveCopy, dataTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLocation: return L("暂存文件必须保存在本地目录。")
        case .unsupportedSource: return L("无法保存此临时文件，请拖入普通文件或文件夹。")
        case .recursiveCopy: return L("暂存目录不能位于待复制的文件夹内部。")
        case .dataTooLarge: return L("临时文件数据超过 32 MB，未保存。")
        }
    }
}

/// Synchronous storage for a background import. In a file-representation
/// callback, finish copyFile before returning: the provider may then remove its
/// temporary source. Each import owns an isolated directory, so parallel imports
/// cannot overwrite one another. Removing staging references does not delete
/// these imported files; they remain user content, without automatic cleanup.
struct HubStagingImportStore: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = (rootURL ?? support.appendingPathComponent("FileDock/Staged Imports", isDirectory: true))
            .standardizedFileURL
    }

    func saveImage(data: Data, suggestedName: String? = nil) throws -> URL {
        // Validate and normalize first; a rejected image leaves no empty import.
        let png = try HubImageImport.pngData(from: data)
        let safeName = Self.safeName(suggestedName, fallback: L("拖入的图片"))
        let stem = (safeName as NSString).deletingPathExtension
        let name = (stem.isEmpty ? L("拖入的图片") : stem) + ".png"
        return try store(name: name) { destination in
            try png.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    /// Preserve provider-owned documents such as SVG without rasterizing or
    /// executing them. Ordinary local file URLs continue to be references.
    func saveFileData(_ data: Data, typeIdentifier: String, suggestedName: String? = nil) throws -> URL {
        guard data.count <= 32 * 1024 * 1024 else { throw HubStagingImportError.dataTooLarge }
        let suffix = UTType(typeIdentifier)?.preferredFilenameExtension ?? "data"
        var name = Self.safeName(suggestedName, fallback: L("暂存文件"))
        if (name as NSString).pathExtension.isEmpty { name = Self.safeName(name + "." + suffix, fallback: L("暂存文件.data")) }
        return try store(name: name) { destination in
            try data.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    func copyFile(at source: URL, suggestedName: String? = nil) throws -> URL {
        guard Self.isLocalFileURL(source) else { throw HubStagingImportError.invalidLocation }
        // A provider's top-level symlink can point at another temporary file.
        // Materialize its target so the saved file survives provider cleanup.
        let sourceURL = source.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw HubStagingImportError.unsupportedSource }
        if type == .typeDirectory {
            let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = sourceURL.path == "/" ? "/" : sourceURL.path + "/"
            guard root != sourceURL.path && !root.hasPrefix(prefix) else { throw HubStagingImportError.recursiveCopy }
        }
        var name = Self.safeName(suggestedName, fallback: Self.safeName(source.lastPathComponent, fallback: L("暂存文件")))
        let sourceExtension = sourceURL.pathExtension
        if (name as NSString).pathExtension.isEmpty, !sourceExtension.isEmpty, sourceExtension.utf8.count <= 32 {
            name = Self.safeName(name + "." + sourceExtension, fallback: name)
        }
        return try store(name: name) { destination in
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            // The private container protects a package's contents while their
            // executable bits and directory structure remain intact. Standalone
            // executables retain owner execute; ordinary files are owner-only.
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let mode = type == .typeDirectory || (permissions & 0o100) != 0 ? 0o700 : 0o600
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
    }

    private func store(name: String, write: (URL) throws -> Void) throws -> URL {
        let container = try makeContainer()
        let destination = container.appendingPathComponent(name, isDirectory: false)
        do {
            try write(destination)
            return destination
        } catch {
            // Only this invocation's exclusively created UUID container is ours.
            removeFailedImport(container)
            throw error
        }
    }

    private func removeFailedImport(_ container: URL) {
        let manager = FileManager.default
        // A copied read-only directory can otherwise prevent cleanup after a
        // later copy error. Repair only our private directories, never symlinks
        // (which could point back at source files or another user directory).
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
        if let children = manager.enumerator(at: container, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let child as URL in children {
                if let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                   values.isDirectory == true, values.isSymbolicLink != true {
                    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
                }
            }
        }
        try? manager.removeItem(at: container)
    }

    private func makeContainer() throws -> URL {
        guard Self.isLocalFileURL(rootURL) else { throw HubStagingImportError.invalidLocation }
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        while true {
            let container = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            // mkdir is exclusive, unlike createDirectory's existing-directory
            // success. Cleanup can therefore never target another import.
            let result = container.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                guard let path else { return (-1, EINVAL) }
                let status = Darwin.mkdir(path, 0o700)
                return (status, errno)
            }
            if result.0 == 0 { return container }
            if result.1 == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.1), userInfo: [NSFilePathErrorKey: container.path])
        }
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
    }

    private static func safeName(_ proposed: String?, fallback: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = (proposed ?? "").precomposedStringWithCanonicalMapping.unicodeScalars
            .map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
        // Leave space below the filesystem component limit, preserving a normal
        // extension even when the provider supplies a very long display name.
        let suffix = (cleaned as NSString).pathExtension
        let keepSuffix = !suffix.isEmpty && suffix.utf8.count <= 32
        let ending = keepSuffix ? "." + suffix : ""
        let stem = keepSuffix ? (cleaned as NSString).deletingPathExtension : cleaned
        var bounded = ""
        for character in stem {
            let piece = String(character)
            guard bounded.utf8.count + piece.utf8.count + ending.utf8.count <= 220 else { break }
            bounded += piece
        }
        return bounded.isEmpty ? fallback : bounded + ending
    }
}
