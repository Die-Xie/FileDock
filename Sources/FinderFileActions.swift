import AppKit
import Carbon
import UniformTypeIdentifiers

enum HubFinderLabel: Int, CaseIterable, Sendable, Identifiable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
    var id: Int { rawValue }
    static let colors: [Self] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
    var name: String {
        switch self {
        case .none: return L("无颜色")
        case .gray: return L("灰色")
        case .green: return L("绿色")
        case .purple: return L("紫色")
        case .blue: return L("蓝色")
        case .yellow: return L("黄色")
        case .red: return L("红色")
        case .orange: return L("橙色")
        }
    }
    var color: NSColor {
        switch self {
        case .none, .blue: return .systemBlue
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }
    @MainActor private static var menuIcons: [Int: NSImage] = [:]
    @MainActor func menuIcon(selected: Bool) -> NSImage {
        let key = rawValue * 2 + (selected ? 1 : 0)
        if let cached = Self.menuIcons[key] { return cached }
        let tint = color
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            tint.setFill(); NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
            if selected {
                NSColor.white.setStroke()
                let check = NSBezierPath(); check.lineWidth = 1.7
                check.move(to: NSPoint(x: 4, y: 8)); check.line(to: NSPoint(x: 7, y: 5)); check.line(to: NSPoint(x: 12, y: 11)); check.stroke()
            }
            return true
        }
        image.isTemplate = false; Self.menuIcons[key] = image
        return image
    }
}

enum HubFolderIconChange: Sendable, Equatable {
    case unchanged, system, artwork(Data)
}

enum HubFinderAction: Sendable, Equatable {
    case label(Int), folderStyle(Int, HubFolderIconChange), duplicate, alias, compress, information
    // Chinese Finder calls duplication “复制”, while clipboard copying is
    // “拷贝”. Its English title must not reuse the general Copy translation.
    static var duplicateMenuTitle: String { HubLocalization.language == .english ? L("制作副本") : L("复制") }
    static func shortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch keyCode {
        case 2: return .duplicate
        case 34: return .information
        case 37: return .alias
        default: return nil
        }
    }
}

enum HubFinderActionError: LocalizedError {
    case invalidSelection, notFolder, invalidImage, iconWrite, archiveFailed, duplicateArchiveNames, tooManyInfo, finderDenied, finderUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return L("请选择可访问的本机文件或文件夹。")
        case .notFolder: return L("只能更改实际文件夹的样式，应用程序包与符号链接不适用。")
        case .invalidImage: return L("无法读取图标图片，请选择不超过 16 MiB 的有效图片。")
        case .iconWrite: return L("无法更改文件夹图标，请检查访问权限或磁盘状态。")
        case .archiveFailed: return L("压缩未完成，原文件保持不变。请检查可用空间与文件访问权限。")
        case .duplicateArchiveNames: return L("所选项目包含同名文件，请分别压缩或先更改名称。")
        case .tooManyInfo: return L("一次最多显示 20 个项目的简介。")
        case .finderDenied: return L("未获准控制访达。请在系统设置的“隐私与安全性 → 自动化”中允许 FileDock 访问访达。")
        case .finderUnavailable: return L("访达暂时无法显示简介，请重试或在访达中打开该项目。")
        }
    }
}

struct HubFinderActionResult: Sendable {
    var created: [URL] = []
    var changed: [URL] = []
    var failures: [String] = []
}

/// Native file metadata and Finder-compatible operations. Call on file workers,
/// never during menu construction, pointer tracking or SwiftUI rendering.
enum HubFinderFileActions {
    private static let iconLock = NSLock()
    private static let informationLock = NSLock()

    static func files(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty, urls.count <= 1000 else { throw HubFinderActionError.invalidSelection }
        var seen = Set<String>()
        return try urls.map { url in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/"), !url.path.contains("\0"), url.query == nil, url.fragment == nil else {
                throw HubFinderActionError.invalidSelection
            }
            return url.standardizedFileURL
        }.filter { seen.insert($0.path).inserted }
    }

    static func setLabel(_ label: Int, urls: [URL]) throws -> HubFinderActionResult {
        guard HubFinderLabel(rawValue: label) != nil else { throw HubFinderActionError.invalidSelection }
        let urls = try files(urls), scopes = HubFolderWorkspaceScopes(urls)
        defer { _ = scopes }
        var result = HubFinderActionResult()
        for var url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw HubFinderActionError.invalidSelection }
                var update = URLResourceValues(); update.labelNumber = label
                try url.setResourceValues(update)
                result.changed.append(url)
            } catch { result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    static func folderStyle(_ original: URL, label: Int, icon: HubFolderIconChange) throws -> HubFinderActionResult {
        var url = try files([original])[0]
        guard HubFinderLabel(rawValue: label) != nil else { throw HubFinderActionError.invalidSelection }
        let scopes = HubFolderWorkspaceScopes([original]); defer { _ = scopes }
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .labelNumberKey])
        guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else { throw HubFinderActionError.notFolder }
        let image: NSImage?
        switch icon {
        case .unchanged, .system: image = nil
        case .artwork(let data):
            guard data.count <= 4 * 1024 * 1024, let decoded = HubFolderArtwork.decode(data) else { throw HubFinderActionError.invalidImage }
            image = NSImage(cgImage: decoded, size: NSSize(width: 512, height: 512))
        }
        var update = URLResourceValues(); update.labelNumber = label
        try url.setResourceValues(update)
        if case .unchanged = icon {} else {
            iconLock.lock()
            let changed = NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
            iconLock.unlock()
            if !changed {
                var restore = URLResourceValues(); restore.labelNumber = values.labelNumber ?? 0
                try? url.setResourceValues(restore)
                throw HubFinderActionError.iconWrite
            }
        }
        return HubFinderActionResult(changed: [url])
    }

    static func aliases(_ input: [URL], suffix: String) throws -> HubFinderActionResult {
        let urls = try files(input), scopes = HubFolderWorkspaceScopes(input)
        defer { _ = scopes }
        var result = HubFinderActionResult()
        for source in urls {
            do {
                let parent = source.deletingLastPathComponent()
                let temp = try temporaryFolder(in: parent)
                defer { try? FileManager.default.removeItem(at: temp) }
                let data = try source.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
                let staged = temp.appendingPathComponent("item.alias")
                try URL.writeBookmarkData(data, to: staged)
                let name = source.lastPathComponent + " " + suffix
                result.created.append(try publish(staged, in: parent, name: name))
            } catch { result.failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    /// Finder's public asynchronous duplication preserves aliases, metadata and
    /// native naming. Retain real work/scopes until its callback, even if slow.
    static func duplicate(_ input: [URL]) throws -> HubFinderActionResult {
        let urls = try files(input), scopes = HubFolderWorkspaceScopes(input)
        defer { _ = scopes }
        final class Reply: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var value = HubFinderActionResult()
        }
        let reply = Reply()
        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.duplicate(urls) { mapping, error in
                reply.value.created = urls.compactMap { mapping[$0] }
                if let error { reply.value.failures = [error.localizedDescription] }
                reply.done.signal()
            }
        }
        reply.done.wait()
        return reply.value
    }

    static func archive(_ input: [URL], destination: URL?, defaultName: String) throws -> HubFinderActionResult {
        let scopes = HubFolderWorkspaceScopes(input + (destination.map { [$0] } ?? [])); defer { _ = scopes }
        let urls = HubFileOperations.topLevelURLs(try files(input))
        guard let first = urls.first else { throw HubFinderActionError.invalidSelection }
        let parent = destination ?? first.deletingLastPathComponent()
        _ = try files([parent])
        // Creating an archive inside a selected source would include its own
        // growing output. Resolve ancestors on this worker before starting.
        let targetPath = HubFileOperations.canonical(parent).path
        for source in urls {
            let path = HubFileOperations.canonical(source).path
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true &&
                (path == "/" || targetPath == path || targetPath.hasPrefix(path + "/")) { throw HubFileError.invalidDestination }
        }
        guard Set(urls.map(\.lastPathComponent)).count == urls.count else { throw HubFinderActionError.duplicateArchiveNames }
        let temp = try temporaryFolder(in: parent)
        defer { try? FileManager.default.removeItem(at: temp) }
        let staged = temp.appendingPathComponent("archive.zip")
        let process = Process()
        if urls.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, staged.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["--format", "zip", "-cf", staged.path] + urls.flatMap { ["-C", $0.deletingLastPathComponent().path, "./" + $0.lastPathComponent] }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw HubFinderActionError.archiveFailed }
        let name = (urls.count == 1 ? first.lastPathComponent : defaultName) + ".zip"
        return HubFinderActionResult(created: [try publish(staged, in: parent, name: name)])
    }

    /// User-provided paths are event arguments, never interpolated source code.
    /// Finder's own public scripting dictionary owns the information windows.
    static func informationEvent(_ urls: [URL]) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "showfileinfo"), forKeyword: AEKeyword(keyASSubroutineName))
        let paths = NSAppleEventDescriptor.list()
        for (index, url) in try files(urls).enumerated() { paths.insert(NSAppleEventDescriptor(string: url.path), at: index + 1) }
        let args = NSAppleEventDescriptor.list(); args.insert(paths, at: 1)
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    static func showInformation(_ urls: [URL]) throws -> HubFinderActionResult {
        guard urls.count <= 20 else { throw HubFinderActionError.tooManyInfo }
        let scopes = HubFolderWorkspaceScopes(urls); defer { _ = scopes }
        informationLock.lock(); defer { informationLock.unlock() }
        let event = try informationEvent(urls)
        let script = NSAppleScript(source: informationScript)!
        var error: NSDictionary?
        _ = script.executeAppleEvent(event, error: &error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 { throw HubFinderActionError.finderDenied }
            throw HubFinderActionError.finderUnavailable
        }
        return HubFinderActionResult()
    }

    static let informationScript = """
        on showfileinfo(thePaths)
            with timeout of 10 seconds
                tell application id "com.apple.finder"
                    repeat with thePath in thePaths
                        set theItem to POSIX file (contents of thePath) as alias
                        open information window of theItem
                    end repeat
                    activate
                end tell
            end timeout
        end showfileinfo
        """

    private static func temporaryFolder(in parent: URL) throws -> URL {
        let temp = parent.appendingPathComponent(".FileDock-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return temp
    }

    private static func publish(_ staged: URL, in parent: URL, name: String) throws -> URL {
        try HubFileOperations.validateName(name)
        for index in 0..<10000 {
            let original = URL(fileURLWithPath: name)
            let ext = original.pathExtension
            let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
            let next = index == 0 ? name : stem + " \(index + 1)" + (ext.isEmpty ? "" : "." + ext)
            let target = parent.appendingPathComponent(next)
            do { try FileManager.default.moveItem(at: staged, to: target); return target }
            catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw HubFileError.invalidDestination
    }
}
