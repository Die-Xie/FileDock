import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case folder, references, recents
    var id: String { rawValue }
    var title: String { self == .folder ? L("子文件夹") : self == .recents ? L("最近使用") : L("文件夹与文件") }
    var description: String { self == .folder ? L("浏览文件夹中的全部项目，新文件自动出现。") : self == .recents ? L("自动显示最近打开过的文件。") : L("收藏所选文件与文件夹，只保存引用。") }
}

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case name, size, kind, created, modified, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return L("名称")
        case .size: return L("大小")
        case .kind: return L("种类")
        case .created: return L("创建日期")
        case .modified: return L("修改日期")
        case .added: return L("添加日期")
        }
    }
}

enum HubViewMode: String, Codable, CaseIterable, Identifiable {
    case grid, list, columns
    var id: String { rawValue }
    var title: String { self == .grid ? L("图标") : self == .list ? L("列表") : L("分栏") }
    var symbol: String { self == .grid ? "square.grid.2x2" : self == .list ? "list.bullet" : "rectangle.split.3x1" }
}

enum HubAppearance: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { self == .system ? L("跟随系统") : self == .dark ? L("深色") : L("浅色") }
}

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case both, hover, keyboard
    var id: String { rawValue }
    var title: String { self == .both ? L("鼠标与快捷键") : self == .hover ? L("仅鼠标") : L("仅快捷键") }
}

enum HotCorner: String, Codable, CaseIterable, Identifiable {
    case notch, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notch: return L("顶部居中 / 刘海")
        case .topLeft: return L("左上角")
        case .topRight: return L("右上角")
        case .bottomLeft: return L("左下角")
        case .bottomRight: return L("右下角")
        }
    }
}

struct HubSettings: Codable, Equatable {
    // Missing in older configurations: preserve the existing Chinese interface.
    var language: String? = "system"
    var resolvedLanguage: HubLanguage { language.flatMap(HubLanguage.init(rawValue:)) ?? .simplifiedChinese }
    var appearance: String = "system"
    var backgroundTheme: String? = "liquidGlass"
    var fontSize: Double = 13
    var iconSize: Double = 46
    var horizontalScroll = false
    var showScrollbar = true
    var notchClickToWake: Bool? = false
    var usesNotchClickToWake: Bool { hotCorner == "notch" && notchClickToWake == true }
    var hoverDelay: Double = 0
    var autoHideDelay: Double? = 0
    var hideOnFileDragExit: Bool? = true
    var globalShortcuts: HubGlobalShortcuts? = nil
    var animationSpeed: Double? = 1.3
    var notchIntegrationStyle: String? = "embedded"
    var qqMusicEnabled: Bool? = true
    // Keep the existing enablement key and the previous QQ selection on upgrade.
    var musicPlayer: String? = "automatic"
    var favoriteWorkspaceID: UUID? = nil
    var favoriteShortcutEnabled: Bool? = true
    var recentShortcutEnabled: Bool? = false
    var shortcutOrder: [String]? = nil
    var blockedApplicationBundleIDs: [String]? = nil
    var suppressHoverInFullScreen: Bool? = nil
    var clickWakeWhenSuppressed: Bool? = false
    var stagingWorkspaceID: UUID? = nil
    var stagingEnabled: Bool? = true
    var airDropEnabled: Bool? = true
    var foldersFirst: Bool? = false
    var switchDelay: Double = 0.1
    var triggerMode: String = "both"
    var hotCorner: String = "notch"
    var secondaryScreens = true
    var showMenuBarIcon = true
    var width: Double = 683
    var height: Double = 400
    var launchAtLogin = true
    var lightBackgroundHex = "F4F5F7"
    var darkBackgroundHex = "#1C1C1C"

    var resolvedGlobalShortcuts: HubGlobalShortcuts { globalShortcuts ?? .defaults }
    var resolvedBackgroundTheme: String { backgroundTheme == "liquidGlass" ? "liquidGlass" : "solid" }
    var resolvedAppearance: String { resolvedBackgroundTheme == "liquidGlass" ? "dark" : appearance }
    var resolvedAnimationSpeed: Double {
        let value = animationSpeed ?? 1
        return value.isFinite ? min(2, max(0.5, value)) : 1
    }
    var resolvedQQMusicEnabled: Bool { qqMusicEnabled ?? true }
    var resolvedAirDropEnabled: Bool { airDropEnabled ?? true }
    var resolvedMusicPlayer: String {
        guard let musicPlayer else { return "qqMusic" }
        return ["automatic", "qqMusic", "appleMusic", "neteaseMusic"].contains(musicPlayer) ? musicPlayer : "automatic"
    }
    var resolvedFavoriteShortcutEnabled: Bool { favoriteShortcutEnabled ?? true }
    var resolvedRecentShortcutEnabled: Bool { recentShortcutEnabled ?? false }
    var resolvedShortcutOrder: [HubShortcutItem] { HubShortcutItem.normalized(shortcutOrder) }
    var resolvedBlockedApplicationBundleIDs: [String] {
        Array(Set((blockedApplicationBundleIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("\u{0}") })).sorted()
    }
    var resolvedSuppressHoverInFullScreen: Bool { suppressHoverInFullScreen ?? true }
    var resolvedClickWakeWhenSuppressed: Bool { clickWakeWhenSuppressed ?? false }
    var resolvedStagingEnabled: Bool { stagingEnabled ?? true }
    var resolvedFoldersFirst: Bool { foldersFirst ?? true }
    var resolvedNotchIntegrationStyle: String { notchIntegrationStyle == "embedded" ? "embedded" : "connected" }
    var resolvedAutoHideDelay: Double {
        let value = autoHideDelay ?? 0.55
        return value.isFinite ? min(3, max(0, value)) : 0.55
    }
    var resolvedHideOnFileDragExit: Bool { hideOnFileDragExit ?? true }

    mutating func normalize() {
        if let language, HubLanguage(rawValue: language) == nil { self.language = "system" }
        if shortcutOrder != nil { shortcutOrder = resolvedShortcutOrder.map(\.rawValue) }
        if !["system", "dark", "light"].contains(appearance) { appearance = "dark" }
        if backgroundTheme != nil { backgroundTheme = resolvedBackgroundTheme }
        if !["both", "hover", "keyboard"].contains(triggerMode) { triggerMode = "both" }
        if !["notch", "topLeft", "topRight", "bottomLeft", "bottomRight"].contains(hotCorner) { hotCorner = "notch" }
        fontSize = min(22, max(10, fontSize.isFinite ? fontSize : 13))
        iconSize = min(100, max(24, iconSize.isFinite ? iconSize : 46))
        hoverDelay = min(3, max(0, hoverDelay.isFinite ? hoverDelay : 0.12))
        switchDelay = min(2, max(0, switchDelay.isFinite ? switchDelay : 0.2))
        width = min(2000, max(540, width.isFinite ? width : 900))
        height = min(1400, max(300, height.isFinite ? height : 480))
        if animationSpeed != nil { animationSpeed = resolvedAnimationSpeed }
        if notchIntegrationStyle != nil { notchIntegrationStyle = resolvedNotchIntegrationStyle }
        if autoHideDelay != nil { autoHideDelay = resolvedAutoHideDelay }
        if musicPlayer != nil { musicPlayer = resolvedMusicPlayer }
        if blockedApplicationBundleIDs != nil { blockedApplicationBundleIDs = resolvedBlockedApplicationBundleIDs }
    }
}

struct Workspace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String = "folder"
    var customIconPath: String? = nil
    var iconOnly: Bool? = nil
    var mode: WorkspaceMode = .folder
    var rootPath: String? = nil
    var referencePaths: [String] = []
    // Canonical directory path -> child names; aliases such as /var and
    // /private/var share an order, while symlink entries keep distinct names.
    var directoryOrders: [String: [String]]? = nil
    var rootURL: URL? { rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

struct HubPathComponent: Identifiable, Equatable {
    let id: String
    let title: String
    // A reference collection is a virtual location, never a fabricated file URL.
    let url: URL?
}

struct FileEntry: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    let kind: String
    let created: Date?
    let modified: Date?
    let added: Date?
    let attributesModified: Date?
    let labelNumber: Int
    let tagNames: [String]
    let folderAppearance: HubFolderAppearance
    let exists: Bool
    @MainActor var icon: NSImage { HubFileIconCache.image(for: self) }
    /// Includes every displayed property, including Finder labels and custom-icon changes.
    var snapshotSignature: String {
        func timestamp(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate) } ?? "nil" }
        let fields = [url.path, name, String(isDirectory), String(isPackage), String(size), kind,
                      timestamp(created), timestamp(modified), timestamp(added), timestamp(attributesModified), String(labelNumber), String(exists), String(folderAppearance.customIcon), folderAppearance.customization.base64EncodedString()] + tagNames
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
    var canNavigate: Bool { isDirectory && !isPackage }
    var sizeText: String { isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    static let resourceKeys: Set<URLResourceKey> = [.nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey, .attributeModificationDateKey, .labelNumberKey, .tagNamesKey]

    static func resourceValues(for url: URL,
        read: (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }) -> URLResourceValues? {
        if let values = try? read(url, resourceKeys) { return values }
        // LaunchServices may have no localized kind string for an otherwise
        // readable item. Optional display metadata must not turn a directory
        // into a file or make navigation try to launch an application.
        if let values = try? read(url, resourceKeys.subtracting([.localizedTypeDescriptionKey])) { return values }
        if let values = try? read(url, [.nameKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]) { return values }
        if let values = try? read(url, [.isDirectoryKey, .isPackageKey]) { return values }
        // Some providers also omit size, timestamps, or package metadata. The
        // directory bit alone still prevents an ordinary folder being opened as
        // a file when only optional attributes are unavailable.
        return try? read(url, [.isDirectoryKey])
    }

    init(url: URL, preservingResourceCache: Bool = false) {
        // Ordinary callers need a fresh revision; new directory enumerators
        // already provide fresh, prefetched metadata for their current scan.
        var freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
        freshURL.removeAllCachedResourceValues()
        self.url = freshURL
        let values = Self.resourceValues(for: preservingResourceCache ? url : freshURL)
        exists = values?.isDirectory != nil || FileManager.default.fileExists(atPath: freshURL.path)
        name = values?.localizedName ?? values?.name ?? url.lastPathComponent
        isDirectory = values?.isDirectory ?? false
        isPackage = values?.isPackage ?? false
        size = Int64(values?.fileSize ?? 0)
        kind = exists ? (values?.localizedTypeDescription ?? (isDirectory ? L("文件夹") : url.pathExtension.uppercased() + L(" 文件"))) : L("项目不可用")
        created = values?.creationDate
        modified = values?.contentModificationDate
        added = values?.addedToDirectoryDate
        attributesModified = values?.attributeModificationDate
        labelNumber = values?.labelNumber ?? 0
        tagNames = (values?.tagNames ?? []).sorted()
        folderAppearance = isDirectory && !isPackage ? HubFolderAppearance.read(freshURL) : HubFolderAppearance()
    }
}

enum HubFileError: LocalizedError {
    case missing(URL), invalidDestination, descendant, invalidName, noWorkspace, corruptConfig, configurationTooLarge, partial([String])
    var errorDescription: String? {
        switch self {
        case .missing(let url): return L("找不到项目：\(url.lastPathComponent)")
        case .invalidDestination: return L("请选择可写入的目标文件夹。")
        case .descendant: return L("不能把文件夹放入它自己或它的子文件夹。")
        case .invalidName: return L("名称不能为空，也不能包含 /、:，或使用 . 与 ..。")
        case .noWorkspace: return L("请先选择或添加一个工作区。")
        case .corruptConfig: return L("配置文件格式无效。")
        case .configurationTooLarge: return L("配置超过 16 MiB，未覆盖原有设置。请减少工作区或文件引用后重试。")
        case .partial(let messages): return messages.joined(separator: "\n")
        }
    }
}

/// Safe native file operations, separate from UI state so they can be exercised with fixture folders.
enum HubFileOperations {
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw HubFileError.invalidName
        }
    }

    /// Resolve parent/child selections only on a file worker, preserving the
    /// caller's order and never traversing symlinked directories as parents.
    static func topLevelURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        var roots = Set<String>(), accepted = Set<String>()
        for source in unique.sorted(by: { $0.path.count < $1.path.count }) {
            var parent = source.deletingLastPathComponent(), nested = false
            while parent.path != source.path {
                if roots.contains(parent.path) { nested = true; break }
                if parent.path == "/" { break }
                parent.deleteLastPathComponent()
            }
            if nested { continue }
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true { roots.insert(source.path) }
            accepted.insert(source.path)
        }
        return unique.filter { accepted.contains($0.path) }
    }

    static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: base.path) { return base }
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let ext = isDirectory.boolValue ? "" : source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let filename = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let result = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: result.path) { return result }
            index += 1
        }
    }

    @discardableResult
    static func transfer(_ source: URL, to directory: URL, copy: Bool) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard source.isFileURL, fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw HubFileError.missing(source) }
        var targetIsDir: ObjCBool = false
        guard directory.isFileURL, fm.fileExists(atPath: directory.path, isDirectory: &targetIsDir), targetIsDir.boolValue else {
            throw HubFileError.invalidDestination
        }
        let sourcePath = canonical(source).path
        let destinationPath = canonical(directory).path
        if isDir.boolValue && (sourcePath == "/" || sourcePath == destinationPath || destinationPath.hasPrefix(sourcePath + "/")) {
            throw HubFileError.descendant
        }
        if !copy && canonical(source.deletingLastPathComponent()) == canonical(directory) { return source }
        let target = uniqueDestination(for: source, in: directory)
        // FileManager refuses existing paths. Never remove an existing item to make a transfer succeed.
        if copy { try fm.copyItem(at: source, to: target) }
        else { try fm.moveItem(at: source, to: target) }
        return target
    }
}

@MainActor final class HubModel: ObservableObject {
    @Published var shortcutRegistrationErrors: [String: String] = [:]
    @Published var workspaces: [Workspace] = [] { didSet { invalidateEntryOrder(); cachedStagedURLs = nil; persistIfReady() } }
    @Published var selectedWorkspaceID: UUID? { didSet { persistIfReady() } }
    @Published var entries: [FileEntry] = [] { didSet { invalidateEntryOrder() } }
    @Published var selectedIDs = Set<URL>()
    @Published var search = ""
    @Published var sortKey: SortKey = .modified { didSet {
        invalidateEntryOrder()
        beginPersistenceTransaction(); defer { endPersistenceTransaction() }
        referenceManualOrder = false; if readyToSave { clearDirectoryOrder() }; persistIfReady()
    } }
    @Published var ascending = false { didSet {
        invalidateEntryOrder()
        beginPersistenceTransaction(); defer { endPersistenceTransaction() }
        referenceManualOrder = false; if readyToSave { clearDirectoryOrder() }; persistIfReady()
    } }
    @Published var referenceManualOrder = true { didSet { invalidateEntryOrder(); persistIfReady() } }
    @Published var viewMode: HubViewMode = .grid { didSet { persistIfReady() } }
    @Published var settings = HubSettings() { didSet {
        if settings.resolvedLanguage != oldValue.resolvedLanguage { HubLocalization.select(settings.resolvedLanguage) }
        if settings.resolvedFoldersFirst != oldValue.resolvedFoldersFirst { invalidateEntryOrder() }
        if settings.stagingWorkspaceID != oldValue.stagingWorkspaceID || settings.favoriteWorkspaceID != oldValue.favoriteWorkspaceID { cachedStagedURLs = nil }
        persistIfReady()
    } }
    @Published var pinned = false
    @Published var errorMessage: String?
    @Published private(set) var currentURL: URL? { didSet { invalidateEntryOrder() } }
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyIndex = -1
    @Published var showHiddenFiles = false { didSet { refresh() } }
    @Published private(set) var recentFilesLoading = false
    @Published private(set) var recentFilesMessage: String?
    @Published private(set) var stagingTransferInProgress = false
    @Published private(set) var fileOperationsInProgress = 0
    @Published var sharingInProgress = false

    private let fm = FileManager.default
    private let configurationURL: URL
    private var bookmarkData: [String: Data] = [:]
    private var activeScopes: [URL] = []
    private(set) var isInitialConfiguration = false
    private var readyToSave = false
    private var persistenceDepth = 0
    private var persistencePending = false
    private var deferringInteractiveResize = false
    private var transferScopeURLs: [URL] = []
    private var dropScopeURLs: [UUID: [URL]] = [:]
    private(set) var configurationWriteCount = 0
    private static let maximumConfigurationBytes = 16 * 1024 * 1024
    static let maximumWorkspaces = 2000
    static let maximumReferences = 20000
    /// Provider imports are owned by the UI; the model also guards their lifetime
    /// before replacing configuration or releasing its security scopes.
    var externalFileWorkInProgress: () -> Bool = { false }
    private var refreshTimer: Timer?
    private var refreshGeneration = 0
    private let directoryLoader: HubDirectoryLoading
    private var activeDirectoryLoad: UUID?
    private var displayedDirectoryContext: RefreshContext?
    private let directorySnapshots = HubDirectorySnapshotCache<DirectorySnapshotKey>()
    private struct DirectorySnapshotKey: Hashable {
        var workspaceID: UUID?
        var directory: URL?
        var references: [String]
        var hidden: Bool
    }
    private func snapshotKey(_ context: RefreshContext) -> DirectorySnapshotKey? {
        guard context.directory != nil || workspaces.first(where: { $0.id == context.workspaceID })?.mode == .references else { return nil }
        return DirectorySnapshotKey(workspaceID: context.workspaceID, directory: context.directory, references: context.references, hidden: context.showHiddenFiles)
    }
    private var canonicalDirectoryPath: String? { didSet { if oldValue != canonicalDirectoryPath { invalidateEntryOrder() } } }
    private var cachedStagedURLs: [URL]?
    private var cachedOrderedEntries: [FileEntry]?
    private var cachedVisibleEntries: (search: String, entries: [FileEntry])?
    private(set) var entryOrderCalculationCount = 0
    private var nextPeriodicRefresh: TimeInterval = 0
    private var retryDirectoryNavigation: (url: URL, selecting: URL?)?
    @Published private(set) var directoryLoading = false
    @Published private(set) var directoryLoadMessage: String?
    private var backgroundRefreshRequested = false
    private(set) var backgroundRefreshCount = 0
    var isRefreshingInBackground: Bool { activeDirectoryLoad != nil }
    private let recentFiles: HubRecentFilesProviding
    private var recentRecords: [HubRecentFile] = []
    private var observingRecents = false
    private var recentGeneration = 0

    private struct SavedState: Codable {
        var version = 1
        var workspaces: [Workspace]
        var selectedWorkspaceID: UUID?
        var settings: HubSettings
        var sortKey: SortKey
        var ascending: Bool
        var viewMode: HubViewMode
        var bookmarks: [String: Data]
        var referenceManualOrder: Bool? = nil
    }

    init(storageURL: URL? = nil, demo: Bool = false, monitor: Bool = false,
         recentFiles: HubRecentFilesProviding? = nil, directoryLoader: HubDirectoryLoading? = nil) {
        self.directoryLoader = directoryLoader ?? HubDirectoryLoader()
        self.recentFiles = recentFiles ?? HubRecentFilesSource()
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FileDock", isDirectory: true)
        self.configurationURL = storageURL ?? support.appendingPathComponent(demo ? "demo-config.json" : "config.json")
        if storageURL == nil {
            let legacy = support.deletingLastPathComponent().appendingPathComponent("FolderHubReplica", isDirectory: true)
            if !fm.fileExists(atPath: support.path), fm.fileExists(atPath: legacy.path) {
                do { try fm.moveItem(at: legacy, to: support) }
                catch { errorMessage = L("旧配置迁移失败：\(error.localizedDescription)"); return }
            }
        }

        isInitialConfiguration = !fm.fileExists(atPath: self.configurationURL.path)
        var loadedConfiguration = false
        if fm.fileExists(atPath: self.configurationURL.path) {
            do {
                try apply(data: Data(contentsOf: self.configurationURL))
                loadedConfiguration = true
            }
            catch {
                errorMessage = L("配置未能读取：\(error.localizedDescription)。原文件已保留。")
                let backup = self.configurationURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
                do { try fm.copyItem(at: self.configurationURL, to: backup) }
                catch { errorMessage = L("配置未能读取，且无法保存备份。请检查文件权限。"); return }
            }
        }
        if workspaces.isEmpty && !loadedConfiguration {
            if demo { seedDemo(in: support.appendingPathComponent("Demo Files", isDirectory: true)) }
            else {
                workspaces = [
                    Workspace(name: "应用程序", symbol: "app.dashed", rootPath: "/Applications"),
                    Workspace(name: "收藏", symbol: "star", mode: .references)
                ]
            }
        }
        bindFavoriteWorkspaceIfNeeded()
        HubLocalization.select(settings.resolvedLanguage)
        let initial = availableWorkspaces.first(where: { $0.id == selectedWorkspaceID }) ?? availableWorkspaces.first
        selectedWorkspaceID = initial?.id
        currentURL = initial?.mode == .folder ? initial?.rootURL : nil
        if let root = currentURL { history = [root]; historyIndex = 0 }
        readyToSave = true
        refresh()
        persistIfReady()
        if monitor {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshInBackground(ifDue: true) }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()

        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
    }

    var selectedWorkspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    /// Translate only built-in labels. Persisted names and user-created
    /// collections are never rewritten when the interface language changes.
    func displayName(for workspace: Workspace) -> String {
        if workspace.mode == .recents && workspace.name == "最近使用" { return L("最近使用") }
        if workspace.id == settings.stagingWorkspaceID && workspace.name == "暂存区" { return L("暂存区") }
        if workspace.name == "收藏" && workspace.id == favoriteWorkspace?.id { return L("收藏") }
        if workspace.rootPath == "/Applications" && workspace.name == "应用程序" { return L("应用程序") }
        return workspace.name
    }
    var favoriteWorkspace: Workspace? {
        if let id = settings.favoriteWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == id && $0.mode == .references }) { return workspace }
        return workspaces.first { $0.mode == .references && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "收藏" }
    }
    var fixedFavoriteWorkspace: Workspace? { settings.resolvedFavoriteShortcutEnabled ? favoriteWorkspace : nil }
    var recentWorkspace: Workspace? { workspaces.first { $0.mode == .recents } }
    var fixedRecentWorkspace: Workspace? { settings.resolvedRecentShortcutEnabled ? recentWorkspace : nil }
    var stagingWorkspace: Workspace? {
        guard let id = settings.stagingWorkspaceID, id != settings.favoriteWorkspaceID else { return nil }
        return workspaces.first { $0.id == id && $0.mode == .references }
    }
    var stagedURLs: [URL] {
        if let cachedStagedURLs { return cachedStagedURLs }
        let paths = stagingWorkspace?.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? []
        let result = uniquePaths(paths).map { URL(fileURLWithPath: $0) }
        cachedStagedURLs = result
        return result
    }
    var isStagingWorkspace: Bool { stagingWorkspace?.id == selectedWorkspaceID && selectedWorkspaceID != nil }
    var isStagingRoot: Bool { isStagingWorkspace && currentURL == nil }
    private var availableWorkspaces: [Workspace] {
        let stagingID = stagingWorkspace?.id
        let recentID = fixedRecentWorkspace?.id
        let favoriteID = favoriteWorkspace?.id
        return workspaces.filter {
            (settings.resolvedStagingEnabled || $0.id != stagingID) &&
            (settings.resolvedFavoriteShortcutEnabled || $0.id != favoriteID) &&
            ($0.mode != .recents || $0.id == recentID)
        }
    }
    var tabWorkspaces: [Workspace] {
        let favoriteID = favoriteWorkspace?.id
        let stagingID = stagingWorkspace?.id
        return workspaces.filter { $0.id != favoriteID && $0.mode != .recents && $0.id != stagingID }
    }
    var visibleShortcutItems: [HubShortcutItem] {
        settings.resolvedShortcutOrder.filter { item in
            switch item {
            case .favorite: return fixedFavoriteWorkspace != nil
            case .airDrop: return settings.resolvedAirDropEnabled
            case .recents: return fixedRecentWorkspace != nil
            case .staging: return settings.resolvedStagingEnabled
            }
        }
    }

    func reorderShortcut(sourceID: UUID, targetID: UUID, after: Bool) {
        var visible = visibleShortcutItems
        guard sourceID != targetID,
              let source = visible.firstIndex(where: { $0.dragID == sourceID }),
              visible.contains(where: { $0.dragID == targetID }) else { return }
        let moved = visible.remove(at: source)
        guard let target = visible.firstIndex(where: { $0.dragID == targetID }) else { return }
        visible.insert(moved, at: target + (after ? 1 : 0))
        let members = Set(visible), previous = settings.resolvedShortcutOrder
        var position = 0
        let reordered = previous.map { item -> HubShortcutItem in
            guard members.contains(item) else { return item }
            defer { position += 1 }
            return visible[position]
        }
        // Hidden features keep their slots, and dragging only changes the
        // toolbar order: no workspace selection, query, or file data changes.
        if reordered != previous { settings.shortcutOrder = reordered.map(\.rawValue) }
    }
    var selectedURLs: [URL] { entries.filter { selectedIDs.contains($0.url) }.map(\.url) }
    var selectedEntries: [FileEntry] { entries.filter { selectedIDs.contains($0.url) } }
    var canGoBack: Bool { historyIndex > 0 || (isVirtualWorkspace && currentURL != nil) }
    var canGoForward: Bool { historyIndex >= -1 && historyIndex + 1 < history.count }
    var canGoUp: Bool { currentURL != nil && currentURL?.path != "/" }
    var isReferenceRoot: Bool { selectedWorkspace?.mode == .references && currentURL == nil }
    var isVirtualWorkspace: Bool { selectedWorkspace?.mode == .references || selectedWorkspace?.mode == .recents }
    var isRecentsRoot: Bool { selectedWorkspace?.mode == .recents && currentURL == nil }
    var canReorderEntries: Bool { isReferenceRoot || currentURL != nil }
    var currentLocationDescription: String {
        currentURL?.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "~")
            ?? (isStagingRoot ? L("暂存文件引用 · 拖出或选择复制／移动到文件夹") : isRecentsRoot ? L("最近使用 · 按最近打开时间排列") : L("文件引用 · 原文件保持在原位置"))
    }
    func lastUsedDate(for url: URL) -> Date? {
        isRecentsRoot ? recentRecords.first { $0.url == url.standardizedFileURL }?.lastUsed : nil
    }
    func isCloudPlaceholder(_ entry: FileEntry) -> Bool {
        isRecentsRoot && recentRecords.contains { $0.url == entry.url && $0.metadataOnly }
    }
    func canOpen(_ entry: FileEntry) -> Bool { entry.exists || isCloudPlaceholder(entry) }
    var breadcrumbs: [URL] {
        guard let currentURL else { return [] }
        var result = [currentURL]
        var cursor = currentURL
        while cursor.path != "/" {
            cursor.deleteLastPathComponent()
            result.insert(cursor, at: 0)
        }
        return result
    }
    var pathComponents: [HubPathComponent] {
        guard let workspace = selectedWorkspace else { return [] }
        let prefix = workspace.id.uuidString
        var components: [HubPathComponent] = []
        if isVirtualWorkspace {
            components.append(HubPathComponent(id: prefix + ":" + workspace.mode.rawValue,
                                               title: workspace.name.isEmpty ? workspace.mode == .recents ? L("最近使用") : L("文件合集") : displayName(for: workspace), url: nil))
        }
        components.append(contentsOf: breadcrumbs.map { url in
            HubPathComponent(id: prefix + ":file:" + url.path,
                             title: url.path == "/" ? "/" : url.lastPathComponent, url: url)
        })
        return components
    }
    var visibleEntries: [FileEntry] {
        if let cached = cachedVisibleEntries, cached.search == search { return cached.entries }
        let ordered = orderedEntries
        let result = search.isEmpty ? ordered : ordered.filter { $0.name.localizedStandardContains(search) }
        cachedVisibleEntries = (search, result)
        return result
    }

    func sortByColumn(_ key: SortKey) {
        guard !isRecentsRoot else { return }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if sortKey == key && !isManualEntryOrder { ascending.toggle() }
        else { sortKey = key; ascending = true }
    }

    var fileOrderURLs: [URL] { orderedEntries.map(\.url) }

    private var directoryOrderPath: String { canonicalDirectoryPath ?? currentURL?.standardizedFileURL.path ?? "" }

    var isManualEntryOrder: Bool {
        if isReferenceRoot { return referenceManualOrder }
        guard currentURL != nil else { return false }
        let path = directoryOrderPath
        return selectedWorkspace?.directoryOrders?[path] != nil
    }

    private func invalidateEntryOrder() { cachedOrderedEntries = nil; cachedVisibleEntries = nil }

    private var orderedEntries: [FileEntry] {
        if let cachedOrderedEntries { return cachedOrderedEntries }
        entryOrderCalculationCount += 1
        let result = calculateEntryOrder()
        cachedOrderedEntries = result
        return result
    }

    private func entryOrder(directory: URL?) -> HubDirectoryOrder {
        HubDirectoryOrder(key: sortKey, ascending: ascending, foldersFirst: settings.resolvedFoldersFirst,
                          preservesInputOrder: directory == nil && (isRecentsRoot || referenceManualOrder),
                          directoryOrders: directory == nil ? [:] : selectedWorkspace?.directoryOrders ?? [:])
    }

    private func calculateEntryOrder() -> [FileEntry] {
        // Explicit user sort changes can use this cached fallback. Directory
        // loading prepares the same order on the worker, before publishing.
        (try? entryOrder(directory: currentURL).sorted(entries, canonicalPath: directoryOrderPath)) ?? entries
    }

    func selectWorkspace(_ id: UUID) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard let workspace = availableWorkspaces.first(where: { $0.id == id }) else { return }
        stopRecentFiles()
        selectedWorkspaceID = id
        currentURL = workspace.mode == .folder ? workspace.rootURL : nil
        history = currentURL.map { [$0] } ?? []
        historyIndex = history.isEmpty ? -1 : 0
        selectedIDs = []
        search = ""
        refresh()
    }

    func nextWorkspace(_ delta: Int = 1) {
        let choices = availableWorkspaces
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(where: { $0.id == selectedWorkspaceID }) ?? 0
        selectWorkspace(choices[(index + delta % choices.count + choices.count) % choices.count].id)
    }

    /// A disabled virtual workspace keeps its saved data, but cannot keep a
    /// query, pending directory navigation, or stale selection alive offscreen.
    private func selectFallbackWorkspace(at index: Int = 0) {
        let choices = availableWorkspaces
        if !choices.isEmpty { selectWorkspace(choices[min(max(0, index), choices.count - 1)].id) }
        else { clearWorkspaceSelection() }
    }

    private func clearWorkspaceSelection() {
        invalidateBackgroundRefresh()
        stopRecentFiles()
        retryDirectoryNavigation = nil
        displayedDirectoryContext = nil
        canonicalDirectoryPath = nil
        directoryLoadMessage = nil
        recentRecords = []
        selectedWorkspaceID = nil; currentURL = nil
        entries = []; selectedIDs = []; search = ""
        history = []; historyIndex = -1
    }

    @discardableResult
    func addWorkspace(name: String, symbol: String = "folder", mode: WorkspaceMode, urls: [URL]) -> Workspace? {
        if mode == .recents, recentWorkspace != nil { return addRecentWorkspace() }
        guard canAddWorkspace() else { return nil }
        let selected = mode == .recents ? [] : urls.filter(\.isFileURL).map(\.standardizedFileURL)
        let paths = mode == .references ? uniquePaths(selected.map(\.path)) : []
        guard canStoreReferences(paths) else { return nil }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        (mode == .folder ? Array(selected.prefix(1)) : selected).forEach(remember)
        let workspace = Workspace(name: clean.isEmpty ? "新工作区" : clean, symbol: symbol, mode: mode,
                                  rootPath: mode == .folder ? selected.first?.path : nil,
                                  referencePaths: paths)
        workspaces.append(workspace)
        // Make the newly admitted feature selectable before opening it. A
        // rejected creation must never persist an enabled, missing shortcut.
        if mode == .recents { settings.recentShortcutEnabled = true }
        bindFavoriteWorkspaceIfNeeded()
        selectWorkspace(workspace.id)
        return workspace
    }

    @discardableResult
    func addRecentWorkspace() -> Workspace? {
        if let existing = recentWorkspace {
            beginPersistenceTransaction()
            defer { endPersistenceTransaction() }
            settings.recentShortcutEnabled = true
            selectWorkspace(existing.id)
            return existing
        }
        return addWorkspace(name: "最近使用", symbol: "clock", mode: .recents, urls: [])
    }

    /// The recent collection is a toggleable feature, never a regular tab.
    /// Turning it off preserves its identity and settings for the next enable.
    func setRecentShortcutVisible(_ visible: Bool) {
        guard settings.resolvedRecentShortcutEnabled != visible || (visible && recentWorkspace == nil) else { return }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if visible && recentWorkspace == nil {
            guard addRecentWorkspace() != nil else { return }
        }
        settings.recentShortcutEnabled = visible
        if !visible && selectedWorkspace?.mode == .recents { selectFallbackWorkspace() }
        else if visible && selectedWorkspaceID == nil, let recent = fixedRecentWorkspace { selectWorkspace(recent.id) }
    }

    func setFavoriteShortcutVisible(_ visible: Bool) {
        guard settings.resolvedFavoriteShortcutEnabled != visible || (visible && favoriteWorkspace == nil) else { return }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if visible {
            let creating = favoriteWorkspace == nil
            guard let favorite = favoriteWorkspace ?? addWorkspace(name: "收藏", symbol: "star", mode: .references, urls: []) else { return }
            settings.favoriteWorkspaceID = favorite.id
            settings.favoriteShortcutEnabled = true
            if creating || selectedWorkspaceID == nil { selectWorkspace(favorite.id) }
        } else {
            let wasSelected = selectedWorkspaceID == favoriteWorkspace?.id
            settings.favoriteShortcutEnabled = false
            if wasSelected { selectFallbackWorkspace() }
        }
    }

    func setWorkspaceIconOnly(id: UUID, enabled: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].iconOnly = enabled
    }

    /// The shelf is created lazily, without changing the user's current location.
    private func ensureStagingWorkspace() -> Workspace? {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if let existing = stagingWorkspace { return existing }
        guard canAddWorkspace() else { return nil }
        let workspace = Workspace(name: "暂存区", symbol: "tray", mode: .references)
        workspaces.append(workspace)
        settings.stagingWorkspaceID = workspace.id
        return workspace
    }

    func openStagingWorkspace() {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard settings.resolvedStagingEnabled else { return }
        guard let workspace = ensureStagingWorkspace() else { return }
        selectWorkspace(workspace.id)
    }

    func setStagingEnabled(_ enabled: Bool) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        let wasSelected = isStagingWorkspace
        settings.stagingEnabled = enabled
        if !enabled && wasSelected { selectFallbackWorkspace() }
    }

    /// Staging only records paths/bookmarks. It never relocates or copies source data.
    @discardableResult
    func stageFiles(_ urls: [URL]) -> Bool {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard settings.resolvedStagingEnabled, !stagingTransferInProgress else { return false }
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !files.isEmpty else { return false }
        let paths = uniquePaths(stagedURLs.map(\.path) + files.map(\.path))
        guard canStoreReferences(paths), let workspace = ensureStagingWorkspace(),
              let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return false }
        files.forEach(remember)
        workspaces[index].referencePaths = paths
        if isStagingRoot { refresh() }
        return true
    }

    func removeStagedFiles(_ urls: [URL]) {
        guard !stagingTransferInProgress else { return }
        removeStagedPaths(Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }))
    }

    func clearStagedFiles() { removeStagedFiles(stagedURLs) }

    private func removeStagedPaths(_ paths: Set<String>) {
        guard let id = stagingWorkspace?.id, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].referencePaths.removeAll { paths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        if isStagingRoot { refresh() }
    }

    /// Completed items leave the shelf; failed items remain available for retry.
    /// FileManager refuses collisions; unique destinations preserve pre-existing content.
    @discardableResult
    func transferStagedFiles(_ urls: [URL], to directory: URL, copy: Bool) async throws -> [URL] {
        guard !stagingTransferInProgress else { return [] }
        let stagedPaths = Set(stagedURLs.map(\.path))
        let requested = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { stagedPaths.contains($0.path) }
        guard !requested.isEmpty else { return [] }
        let shelfID = stagingWorkspace?.id
        stagingTransferInProgress = true
        transferScopeURLs = requested + [directory.standardizedFileURL]
        remember(directory)
        defer { stagingTransferInProgress = false }
        let result = await Task.detached(priority: .userInitiated) {
            var completed: [(source: URL, destination: URL, directory: Bool)] = []
            var failures: [String] = []
            for source in HubFileOperations.topLevelURLs(requested) {
                let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
                do {
                    let target = try HubFileOperations.transfer(source, to: directory, copy: copy).standardizedFileURL
                    completed.append((source, target, isDirectory))
                } catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
            }
            return (completed, failures)
        }.value
        // Do not keep a persistence transaction open across await: other user actions
        // remain independently saveable while a large transfer runs.
        beginPersistenceTransaction()
        defer {
            transferScopeURLs = []
            persistIfReady()
            endPersistenceTransaction()
        }
        var completedPaths = Set<String>()
        for item in result.0 {
            let matches: (String) -> Bool = { $0 == item.source.path || (item.directory && $0.hasPrefix(item.source.path + "/")) }
            completedPaths.formUnion(stagedPaths.filter(matches))
            if !copy && item.source != item.destination {
                relocateReferences(from: item.source, to: item.destination, includingChildren: item.directory)
            }
        }
        if shelfID == stagingWorkspace?.id {
            // Moved references now point at their new locations.
            for item in result.0 where !copy {
                completedPaths.insert(item.destination.path)
                if item.directory {
                    for path in stagedPaths where path.hasPrefix(item.source.path + "/") {
                        completedPaths.insert(item.destination.path + String(path.dropFirst(item.source.path.count)))
                    }
                }
            }
            removeStagedPaths(completedPaths)
        }
        refresh()
        if !result.1.isEmpty { throw HubFileError.partial(result.1) }
        return result.0.map(\.destination)
    }

    private func relocateReferences(from source: URL, to destination: URL, includingChildren: Bool) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        func relocated(_ path: String) -> String {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if normalized == source.path { return destination.path }
            if includingChildren && normalized.hasPrefix(source.path + "/") { return destination.path + String(normalized.dropFirst(source.path.count)) }
            return path
        }
        var updated = workspaces
        let oldPath = HubFileOperations.canonical(source).path
        let newPath = HubFileOperations.canonical(destination).path
        for index in updated.indices {
            updated[index].referencePaths = uniquePaths(updated[index].referencePaths.map(relocated))
            if let root = updated[index].rootPath { updated[index].rootPath = relocated(root) }
            if let orders = updated[index].directoryOrders {
                let moves: (String) -> Bool = { $0 == oldPath || (includingChildren && $0.hasPrefix(oldPath + "/")) }
                var migrated = orders.filter { !moves($0.key) }
                // Source order wins over stale metadata at the new path,
                // independent of Dictionary iteration order.
                for (path, names) in orders where moves(path) {
                    migrated[newPath + String(path.dropFirst(oldPath.count))] = names
                }
                updated[index].directoryOrders = migrated
            }
        }
        if workspaces != updated { workspaces = updated }
        if let location = currentURL, relocated(location.path) != location.path {
            currentURL = URL(fileURLWithPath: relocated(location.path), isDirectory: true)
        }
        let movedHistory = history.map { url in
            relocated(url.path) == url.path ? url : URL(fileURLWithPath: relocated(url.path), isDirectory: true)
        }
        if movedHistory != history { history = movedHistory }
        for oldPath in Array(bookmarkData.keys) where relocated(oldPath) != oldPath {
            bookmarkData.removeValue(forKey: oldPath)
            remember(URL(fileURLWithPath: relocated(oldPath)))
        }
        remember(destination)
    }

    func chooseStagingTransfer(copy: Bool, urls: [URL]? = nil) {
        guard !stagingTransferInProgress else { return }
        let files = urls ?? (isStagingRoot && !selectedURLs.isEmpty ? selectedURLs : stagedURLs)
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = copy ? L("复制暂存文件到…") : L("移动暂存文件到…")
        panel.prompt = copy ? L("复制到这里") : L("移动到这里")
        panel.message = L("成功转移的项目会从暂存区移除。同名文件会自动改名，保留目标文件。")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard HubWindowPresentation.runModal(panel) == .OK, let directory = panel.url else { return }
        transferStagingFilesToFolder(files, directory: directory, copy: copy)
    }

    func transferStagingToCurrentFolder(copy: Bool) {
        guard let directory = currentURL else { return }
        transferStagingFilesToFolder(stagedURLs, directory: directory, copy: copy)
    }

    private func transferStagingFilesToFolder(_ files: [URL], directory: URL, copy: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await transferStagedFiles(files, to: directory, copy: copy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func bindFavoriteWorkspaceIfNeeded() {
        guard let favorite = favoriteWorkspace, settings.favoriteWorkspaceID != favorite.id else { return }
        settings.favoriteWorkspaceID = favorite.id
    }

    func updateWorkspace(_ workspace: Workspace) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var updated = workspace
        if workspace.id == stagingWorkspace?.id { updated.mode = .references; updated.rootPath = nil }
        if updated.mode == .recents {
            updated.rootPath = nil; updated.referencePaths = []; updated.directoryOrders = nil
        }
        updated.name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty && updated.symbol.isEmpty && updated.customIconPath == nil { errorMessage = L("请至少保留工作区名称或图标。"); return }
        updated.referencePaths = uniquePaths(updated.referencePaths)
        guard canStoreReferences(updated.referencePaths) else { return }
        // Capture a legacy name-based favorite only after admission succeeds.
        bindFavoriteWorkspaceIfNeeded()
        if let iconPath = updated.customIconPath { remember(URL(fileURLWithPath: iconPath)) }
        let rootChanged = workspaces[index].rootPath != updated.rootPath || workspaces[index].mode != updated.mode
        if fixedRecentWorkspace?.id == workspace.id && updated.mode != .recents {
            settings.recentShortcutEnabled = false
        }
        workspaces[index] = updated
        if let selectedWorkspaceID, !availableWorkspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectFallbackWorkspace(at: index)
        } else if selectedWorkspaceID == workspace.id {
            if rootChanged { selectWorkspace(workspace.id) }
            else { refresh() }
        }
    }

    func removeWorkspace(_ id: UUID) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if id == stagingWorkspace?.id { setStagingEnabled(false); return }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedWorkspaceID == id
        if fixedRecentWorkspace?.id == id { settings.recentShortcutEnabled = false }
        workspaces.remove(at: index)
        if wasSelected { selectFallbackWorkspace(at: index) }
    }

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        let selected = source.sorted().compactMap { workspaces.indices.contains($0) ? workspaces[$0] : nil }
        let adjusted = max(0, min(workspaces.count - selected.count, destination - source.filter { $0 < destination }.count))
        for index in source.sorted(by: >) where workspaces.indices.contains(index) { workspaces.remove(at: index) }
        workspaces.insert(contentsOf: selected, at: adjusted)
    }

    func reorderWorkspace(_ id: UUID, before target: UUID) {
        reorderWorkspace(id, relativeTo: target, after: false)
    }

    func reorderWorkspace(_ sourceID: UUID, relativeTo targetID: UUID, after: Bool) {
        guard sourceID != targetID,
              let source = workspaces.firstIndex(where: { $0.id == sourceID }),
              workspaces.contains(where: { $0.id == targetID }) else { return }
        var reordered = workspaces
        let workspace = reordered.remove(at: source)
        guard let target = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        reordered.insert(workspace, at: target + (after ? 1 : 0))
        // Persist once, and leave the selected workspace and its navigation intact.
        if reordered != workspaces { workspaces = reordered }
    }

    func chooseWorkspace(mode: WorkspaceMode = .folder) {
        if mode == .recents { addRecentWorkspace(); return }
        let panel = NSOpenPanel()
        panel.title = mode == .folder ? L("选择工作区文件夹") : L("选择文件或文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = mode == .references
        panel.allowsMultipleSelection = mode == .references
        guard HubWindowPresentation.runModal(panel) == .OK else { return }
        let first = panel.urls.first
        addWorkspace(name: mode == .folder ? first?.lastPathComponent ?? "工作区" : "收藏", symbol: mode == .folder ? "folder" : "star", mode: mode, urls: panel.urls)
    }

    func chooseRoot() {
        guard !isStagingWorkspace else { return }
        guard var workspace = selectedWorkspace else { errorMessage = HubFileError.noWorkspace.localizedDescription; return }
        guard workspace.mode != .recents else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择文件夹并授权访问")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = workspace.rootURL
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        remember(url)
        workspace.mode = .folder
        workspace.rootPath = url.standardizedFileURL.path
        updateWorkspace(workspace)
    }

    func addReferences() {
        guard selectedWorkspace?.mode == .references else { chooseWorkspace(mode: .references); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard HubWindowPresentation.runModal(panel) == .OK else { return }
        appendReferences(panel.urls)
    }

    func appendReferences(_ urls: [URL]) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if isStagingRoot { _ = stageFiles(urls); return }
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }), workspaces[index].mode == .references else { return }
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        let paths = uniquePaths(workspaces[index].referencePaths + files.map(\.path))
        guard canStoreReferences(paths) else { return }
        files.forEach(remember)
        workspaces[index].referencePaths = paths
        refresh()
    }

    func removeReferences(_ urls: [URL]) {
        if isStagingWorkspace { removeStagedFiles(urls); return }
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }), workspaces[index].mode == .references else { return }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        workspaces[index].referencePaths.removeAll { paths.contains($0) }
        selectedIDs.subtract(urls)
        refresh()
    }

    func reorderReference(_ url: URL, before target: URL) {
        guard isReferenceRoot else { return }
        reorderEntries([url], before: target)
    }

    /// Changes presentation order only. No file-system move, rename or copy is performed.
    func reorderEntries(_ urls: [URL], before target: URL?) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }),
              canReorderEntries else { return }
        let requested = Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        var original = orderedEntries.map { $0.url.path }
        if isReferenceRoot {
            // During a progressive read, entries is only a displayed prefix.
            // Keep the complete collection as the source of membership so a
            // reorder cannot discard unread references or revive removed ones.
            let references = uniquePaths(workspaces[index].referencePaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
            let members = Set(references)
            original.removeAll { !members.contains($0) }
            let displayed = Set(original)
            original.append(contentsOf: references.filter { !displayed.contains($0) })
        }
        let moving = original.filter { requested.contains($0) }
        guard !moving.isEmpty else { return }
        let targetPath = target?.standardizedFileURL.path
        if let targetPath, !original.contains(targetPath) || requested.contains(targetPath) { return }
        var result = original.filter { !requested.contains($0) }
        let destination = targetPath.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(contentsOf: moving, at: destination)
        if isReferenceRoot {
            workspaces[index].referencePaths = result
            referenceManualOrder = true
        } else if currentURL != nil {
            var orders = workspaces[index].directoryOrders ?? [:]
            orders[directoryOrderPath] = result.map { URL(fileURLWithPath: $0).lastPathComponent }
            workspaces[index].directoryOrders = orders
        }
        refresh()
    }

    func setManualEntryOrder(_ enabled: Bool) {
        if isReferenceRoot { referenceManualOrder = enabled; return }
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }), currentURL != nil else { return }
        let path = directoryOrderPath
        if enabled {
            var orders = workspaces[index].directoryOrders ?? [:]
            orders[path] = orderedEntries.map { $0.url.lastPathComponent }
            workspaces[index].directoryOrders = orders
        } else { clearDirectoryOrder() }
    }

    private func clearDirectoryOrder() {
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }), currentURL != nil else { return }
        let path = directoryOrderPath
        guard workspaces[index].directoryOrders?[path] != nil else { return }
        workspaces[index].directoryOrders?.removeValue(forKey: path)
    }

    func navigate(to url: URL) {
        if let entry = entries.first(where: { $0.url == url.standardizedFileURL }), !entry.canNavigate {
            open(entry); return
        }
        navigateDirectory(to: url)
    }

    private func navigateDirectory(to url: URL, selecting: URL? = nil) {
        let target = url.standardizedFileURL
        guard target != currentURL else { return }
        invalidateBackgroundRefresh()
        let context = refreshContext
        retryDirectoryNavigation = (target, selecting)
        let request = HubDirectoryRequest(directory: target, showHiddenFiles: showHiddenFiles)
        beginDirectoryLoad(request, context: context, reportErrors: true) { [weak self] in
            guard let self else { return }
            self.stopRecentFiles()
            self.retryDirectoryNavigation = nil
            self.currentURL = target
            if self.historyIndex + 1 < self.history.count { self.history.removeSubrange((self.historyIndex + 1)..<self.history.count) }
            self.history.append(target); self.historyIndex = self.history.count - 1
            self.search = ""; self.selectedIDs = selecting.map { [$0] } ?? []
        }
    }

    func navigatePathComponent(_ component: HubPathComponent) {
        // A drop-down/menu can outlive its location or workspace. Reject stale actions.
        guard pathComponents.contains(component) else { return }
        if let url = component.url {
            navigate(to: url)
        } else if currentURL != nil && isVirtualWorkspace {
            currentURL = nil
            historyIndex = -1
            selectedIDs = []
            search = ""
            refresh()
        }
    }

    func goBack() {
        if historyIndex > 0 { historyIndex -= 1; currentURL = history[historyIndex]; selectedIDs = []; refresh() }
        else if isVirtualWorkspace && currentURL != nil { currentURL = nil; historyIndex = -1; selectedIDs = []; search = ""; refresh() }
    }
    func goForward() { guard canGoForward else { return }; historyIndex += 1; currentURL = history[historyIndex]; selectedIDs = []; refresh() }
    func goUp() {
        guard let departedDirectory = currentURL, departedDirectory.path != "/" else { return }
        let parent = departedDirectory.deletingLastPathComponent()
        navigateDirectory(to: parent, selecting: departedDirectory)
    }
    func goHome() { if let id = selectedWorkspaceID { selectWorkspace(id) } }

    private struct RefreshContext: Equatable {
        let workspaceID: UUID?
        let directory: URL?
        let references: [String]
        let showHiddenFiles: Bool
        let recentRecords: [HubRecentFile]
    }

    private var refreshContext: RefreshContext {
        RefreshContext(workspaceID: selectedWorkspaceID, directory: currentURL,
                       references: isReferenceRoot ? selectedWorkspace?.referencePaths ?? [] : [],
                       showHiddenFiles: showHiddenFiles, recentRecords: isRecentsRoot ? recentRecords : [])
    }

    private func invalidateBackgroundRefresh() {
        refreshGeneration += 1
        backgroundRefreshRequested = false
        nextPeriodicRefresh = 0
        if let activeDirectoryLoad { directoryLoader.cancel(id: activeDirectoryLoad) }
        activeDirectoryLoad = nil
        directoryLoading = false
    }

    func refreshInBackground(ifDue: Bool = false) {
        guard selectedWorkspace != nil else { return }
        if isRecentsRoot {
            if ifDue { recentFiles.refreshIfNeeded() } else { recentFiles.refresh() }
            return
        }
        guard directoryLoadMessage == nil else { return }
        if activeDirectoryLoad != nil {
            if !ifDue { backgroundRefreshRequested = true }
            return
        }
        if ifDue && ProcessInfo.processInfo.systemUptime < nextPeriodicRefresh { return }
        backgroundRefreshCount += 1
        beginDirectoryLoad(currentDirectoryRequest, context: refreshContext, reportErrors: false)
    }

    private var currentDirectoryRequest: HubDirectoryRequest {
        HubDirectoryRequest(directory: currentURL,
            references: isRecentsRoot ? recentRecords.map { $0.url.path } : refreshContext.references,
            showHiddenFiles: showHiddenFiles,
            metadataOnlyPaths: isRecentsRoot ? Set(recentRecords.filter(\.metadataOnly).map { $0.url.path }) : nil)
    }

    private func beginDirectoryLoad(_ request: HubDirectoryRequest, context: RefreshContext,
                                    reportErrors: Bool, commitNavigation: (() -> Void)? = nil) {
        let id = UUID(), generation = refreshGeneration
        let started = ProcessInfo.processInfo.systemUptime
        var orderedRequest = request
        orderedRequest.order = entryOrder(directory: request.directory)
        var expectedContext = context
        var navigationCommitted = false
        // Background/warm refreshes keep the complete old snapshot until done.
        let showPartial = entries.isEmpty || commitNavigation != nil
        activeDirectoryLoad = id
        let loading = reportErrors || entries.isEmpty
        if directoryLoading != loading { directoryLoading = loading }
        if directoryLoadMessage != nil { directoryLoadMessage = nil }
        func acceptsResult(_ model: HubModel) -> Bool {
            model.activeDirectoryLoad == id && model.refreshGeneration == generation && model.refreshContext == expectedContext
        }
        func apply(_ model: HubModel, snapshot: HubDirectorySnapshot, complete: Bool) {
            if !navigationCommitted {
                commitNavigation?()
                navigationCommitted = true
                expectedContext = model.refreshContext
            }
            model.canonicalDirectoryPath = snapshot.canonicalDirectoryPath
            model.displayedDirectoryContext = model.refreshContext
            model.publishEntries(snapshot.entries, complete: complete)
            if let order = snapshot.order, order == model.entryOrder(directory: model.currentURL), let ordered = snapshot.orderedEntries {
                model.cachedOrderedEntries = ordered
                model.cachedVisibleEntries = nil
            }
        }
        directoryLoader.load(id: id, request: orderedRequest, progress: { [weak self] snapshot in
            guard let self, acceptsResult(self), showPartial else { return }
            apply(self, snapshot: snapshot, complete: false)
        }) { [weak self] result in
            guard let self, acceptsResult(self) else { return }
            self.activeDirectoryLoad = nil
            if self.directoryLoading { self.directoryLoading = false }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            self.nextPeriodicRefresh = ProcessInfo.processInfo.systemUptime + min(30, max(2, elapsed * 3))
            switch result {
            case .success(let snapshot):
                apply(self, snapshot: snapshot, complete: true)
                if let key = self.snapshotKey(self.refreshContext) { self.directorySnapshots.insert(snapshot, for: key) }
            case .failure(let error):
                self.directoryLoadMessage = error.localizedDescription
            }
            let repeatRefresh = self.backgroundRefreshRequested
            self.backgroundRefreshRequested = false
            if repeatRefresh && self.directoryLoadMessage == nil { self.refreshInBackground() }
        }
    }

    private func publishEntries(_ next: [FileEntry], complete: Bool = true) {
        // FileEntry equality compares metadata directly; avoid allocating a long
        // string signature for every file on every refresh/batch.
        if entries != next { entries = next }
        if complete && !selectedIDs.isEmpty {
            let remaining = selectedIDs.intersection(Set(next.map(\.url)))
            if remaining != selectedIDs { selectedIDs = remaining }
        }
    }

    func retryDirectoryLoad() {
        if let retry = retryDirectoryNavigation { navigateDirectory(to: retry.url, selecting: retry.selecting) }
        else { refresh() }
    }

    func refresh(reportErrors: Bool = true) {
        guard selectedWorkspace != nil else { clearWorkspaceSelection(); return }
        invalidateBackgroundRefresh()
        retryDirectoryNavigation = nil
        if isRecentsRoot {
            directoryLoadMessage = nil
            if observingRecents { recentFiles.refresh() }
            else { startRecentFiles() }
            return
        }
        stopRecentFiles()
        let context = refreshContext
        if displayedDirectoryContext != context {
            selectedIDs = []
            if let key = snapshotKey(context), let cached = directorySnapshots.snapshot(for: key) {
                canonicalDirectoryPath = cached.canonicalDirectoryPath
                displayedDirectoryContext = context
                publishEntries(cached.entries)
            } else {
                entries = []; canonicalDirectoryPath = nil; displayedDirectoryContext = nil
            }
        }
        beginDirectoryLoad(currentDirectoryRequest, context: context, reportErrors: reportErrors)
    }

    private func startRecentFiles() {
        guard isRecentsRoot, let workspaceID = selectedWorkspaceID else { return }
        observingRecents = true
        recentGeneration += 1
        let generation = recentGeneration
        recentFilesLoading = true
        recentFilesMessage = nil
        recentRecords = []
        entries = []; selectedIDs = []
        recentFiles.start { [weak self] snapshot in
            guard let self, self.observingRecents, self.recentGeneration == generation,
                  self.selectedWorkspaceID == workspaceID, self.isRecentsRoot,
                  self.retryDirectoryNavigation == nil else { return }
            if self.recentFilesLoading != snapshot.gathering { self.recentFilesLoading = snapshot.gathering }
            if self.recentFilesMessage != snapshot.message { self.recentFilesMessage = snapshot.message }
            var byURL: [URL: HubRecentFile] = [:]
            for file in snapshot.files where file.url.isFileURL {
                let url = file.url.standardizedFileURL
                if let previous = byURL[url], previous.lastUsed > file.lastUsed { continue }
                if let previous = byURL[url], previous.lastUsed == file.lastUsed, !previous.metadataOnly { continue }
                byURL[url] = HubRecentFile(url: url, lastUsed: file.lastUsed, metadataOnly: file.metadataOnly)
            }
            var records: [HubRecentFile] = Array(byURL.values)
            records.sort { left, right in
                if left.lastUsed == right.lastUsed { return left.url.path < right.url.path }
                return left.lastUsed > right.lastUsed
            }
            // A timer or Spotlight notification can repeat the same records
            // while metadata is still loading. Do not cancel healthy progress.
            if records == self.recentRecords {
                guard self.activeDirectoryLoad == nil, self.directoryLoadMessage == nil else { return }
            } else {
                self.invalidateBackgroundRefresh()
                self.recentRecords = records
            }
            self.beginDirectoryLoad(self.currentDirectoryRequest, context: self.refreshContext, reportErrors: false)
        }
    }

    private func stopRecentFiles() {
        guard observingRecents else { return }
        recentGeneration += 1
        observingRecents = false
        recentFiles.stop()
        recentFilesLoading = false
        recentFilesMessage = nil
    }

    func open(_ entry: FileEntry) {
        guard canOpen(entry) else { errorMessage = HubFileError.missing(entry.url).localizedDescription; return }
        if entry.canNavigate { navigate(to: entry.url) }
        else if !NSWorkspace.shared.open(entry.url) { errorMessage = L("无法打开 \(entry.name)。") }
    }
    func openExternally(_ url: URL) { if !NSWorkspace.shared.open(url) { errorMessage = L("无法打开 \(url.lastPathComponent)。") } }
    func openWith(_ urls: [URL], application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
        }
    }
    func applications(for url: URL) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: url) }
    func reveal(_ entry: FileEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    func copyPath(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
    func copyFiles(_ urls: [URL]) { guard !urls.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]) }
    func openSelected() { for entry in selectedEntries { open(entry) } }
    func revealSelected() { reveal(selectedURLs) }
    func copySelectedPaths() { copyPath(selectedURLs) }
    func copySelectedFiles() { copyFiles(selectedURLs) }
    func trashSelected() { trash(selectedURLs) }

    /// UI file commands share admission/lifetime accounting with drag/drop.
    /// No persistence transaction spans await, and pending writes retain scopes.
    private func performFileWork<Value: Sendable>(scopes: [URL],
        work: @escaping @Sendable () throws -> Value,
        complete: @escaping @MainActor (Result<Value, Error>) -> Void) {
        guard fileOperationsInProgress < 3 else { errorMessage = L("已有文件操作正在进行，请稍后重试。"); return }
        let id = UUID()
        dropScopeURLs[id] = scopes
        beginPersistenceTransaction()
        scopes.forEach(remember)
        endPersistenceTransaction()
        fileOperationsInProgress += 1
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            beginPersistenceTransaction()
            defer {
                fileOperationsInProgress -= 1; dropScopeURLs.removeValue(forKey: id)
                persistIfReady(); endPersistenceTransaction()
            }
            complete(result)
        }
    }

    func createFolder(named name: String = L("未命名文件夹")) {
        guard let directory = currentURL else { errorMessage = HubFileError.invalidDestination.localizedDescription; return }
        do { try HubFileOperations.validateName(name) } catch { errorMessage = error.localizedDescription; return }
        let workspaceID = selectedWorkspaceID, selection = selectedIDs
        performFileWork(scopes: [directory], work: {
            let proposed = directory.appendingPathComponent(name, isDirectory: true)
            let target = HubFileOperations.uniqueDestination(for: proposed, in: directory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let target):
                self.refresh()
                if self.selectedWorkspaceID == workspaceID && self.currentURL == directory && self.selectedIDs == selection { self.selectedIDs = [target] }
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func rename(_ entry: FileEntry, to name: String) {
        do { try HubFileOperations.validateName(name) } catch { errorMessage = error.localizedDescription; return }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        guard entry.url != target else { return }
        let workspaceID = selectedWorkspaceID, location = currentURL, selection = selectedIDs
        let wasDisplayed = entries.contains { $0.url == entry.url }
        performFileWork(scopes: [entry.url, entry.url.deletingLastPathComponent()], work: {
            let parent = HubFileOperations.canonical(entry.url.deletingLastPathComponent()).path
            let link = (try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            try FileManager.default.moveItem(at: entry.url, to: target)
            return (parent, entry.canNavigate && !link)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (parent, children)):
                let selectResult = wasDisplayed && self.selectedWorkspaceID == workspaceID && self.currentURL == location && self.selectedIDs == selection
                self.relocateReferences(from: entry.url, to: target, includingChildren: children)
                for index in self.workspaces.indices {
                    if var orders = self.workspaces[index].directoryOrders, let names = orders[parent] {
                        orders[parent] = names.filter { $0 != name }.map { $0 == entry.url.lastPathComponent ? name : $0 }
                        self.workspaces[index].directoryOrders = orders
                    }
                }
                self.refresh()
                if selectResult && self.currentURL == location { self.selectedIDs = [target] }
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func trash(_ urls: [URL]) {
        if isStagingRoot { removeStagedFiles(urls); return }
        trashDraggedFiles(urls)
    }

    /// The system Trash destination refers to the real files even if the
    /// source was a staging/favorite reference or navigation changed mid-drag.
    func trashDraggedFiles(_ urls: [URL]) {
        guard !stagingTransferInProgress else { errorMessage = L("请等待暂存文件传输完成后再移到废纸篓。"); return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        performFileWork(scopes: files, work: {
            var completed: [(URL, Bool)] = []
            var failures: [String] = []
            for url in HubFileOperations.topLevelURLs(files) {
                do {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let directory = values?.isDirectory == true && values?.isSymbolicLink != true
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    completed.append((url, directory))
                }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            return (completed, failures)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (completed, failures)):
                self.finishTrashing(completed)
                if !failures.isEmpty { self.errorMessage = HubFileError.partial(failures).localizedDescription }
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    private func finishTrashing(_ completed: [(URL, Bool)]) {
        let paths = Set(completed.map { $0.0.standardizedFileURL.path })
        let directories = Set(completed.filter { $0.1 }.map { $0.0.standardizedFileURL.path })
        func removed(_ raw: String) -> Bool {
            var path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if paths.contains(path) { return true }
            while path != "/" {
                path = (path as NSString).deletingLastPathComponent
                if directories.contains(path) { return true }
            }
            return false
        }
        let selection = selectedIDs.filter { !removed($0.path) }
        if !paths.isEmpty {
            var updated = workspaces
            for index in updated.indices { updated[index].referencePaths.removeAll(where: removed) }
            if workspaces != updated { workspaces = updated }
            // Do not let saved bookmarks silently follow deleted references
            // into Trash at the next launch.
            bookmarkData = bookmarkData.filter { !removed($0.key) }
            recentRecords.removeAll { removed($0.url.path) }
            publishEntries(entries.filter { !removed($0.url.path) })
        }
        refresh()
        // Refresh may replace a reference context. Preserve the user's current
        // unrelated selection rather than a selection captured at drag start.
        if selectedIDs != selection { selectedIDs = selection }
    }

    /// A drop captures its destination at release. Subsequent spring navigation
    /// never redirects files or rejects a legitimate asynchronous transfer.
    @discardableResult
    func acceptFileDrop(_ urls: [URL], workspaceID: UUID?, directory: URL?, copy: Bool,
                        insertionOrder: [URL]? = nil, before: URL? = nil) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }), workspaces[index].mode != .recents,
              !urls.isEmpty, urls.count <= Self.maximumReferences, fileOperationsInProgress < 3 else { return false }
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !files.isEmpty else { return false }
        // Remembering every source must not write the entire configuration once
        // per item when a real folder receives a batch.
        beginPersistenceTransaction(); defer { endPersistenceTransaction() }
        if directory == nil && workspaceID == settings.stagingWorkspaceID {
            let accepted = stageFiles(files)
            if accepted, let insertionOrder {
                recordDropInsertion(files, workspaceID: workspaceID, directoryPath: nil, priorOrder: insertionOrder, before: before)
                if isStagingRoot { refresh() }
            }
            return accepted
        }
        if directory == nil && workspaces[index].mode == .references {
            beginPersistenceTransaction(); defer { endPersistenceTransaction() }
            let paths = uniquePaths(workspaces[index].referencePaths + files.map(\.path))
            guard canStoreReferences(paths) else { return false }
            files.forEach(remember)
            workspaces[index].referencePaths = paths
            if let insertionOrder { recordDropInsertion(files, workspaceID: workspaceID, directoryPath: nil, priorOrder: insertionOrder, before: before) }
            if selectedWorkspaceID == workspaceID { refresh() }
            return true
        }
        guard let directory else { return false }
        let orderPath = selectedWorkspaceID == workspaceID && currentURL?.standardizedFileURL == directory.standardizedFileURL
            ? directoryOrderPath : directory.standardizedFileURL.path
        let operationID = UUID()
        dropScopeURLs[operationID] = files + [directory]
        files.forEach(remember); remember(directory)
        fileOperationsInProgress += 1
        Task { @MainActor in
            defer { fileOperationsInProgress -= 1; dropScopeURLs.removeValue(forKey: operationID); persistIfReady() }
            let result = await Task.detached(priority: .userInitiated) {
                var completed: [(URL, URL, Bool)] = [], failures: [String] = []
                for source in HubFileOperations.topLevelURLs(files) {
                    let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let directorySource = values?.isDirectory == true && values?.isSymbolicLink != true
                    do { completed.append((source, try HubFileOperations.transfer(source, to: directory, copy: copy), directorySource)) }
                    catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
                }
                let positions = Dictionary(files.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: min)
                completed.sort { positions[$0.0.path, default: .max] < positions[$1.0.path, default: .max] }
                return (completed, failures)
            }.value
            beginPersistenceTransaction(); defer { endPersistenceTransaction() }
            if !copy {
                for (source, target, children) in result.0 where source != target {
                    relocateReferences(from: source, to: target, includingChildren: children)
                }
            }
            if let insertionOrder, !result.0.isEmpty {
                recordDropInsertion(result.0.map { $0.1 }, workspaceID: workspaceID, directoryPath: orderPath, priorOrder: insertionOrder, before: before)
            }
            refreshInBackground()
            if !result.1.isEmpty { errorMessage = result.1.joined(separator: "\n") }
        }
        return true
    }

    private func recordDropInsertion(_ urls: [URL], workspaceID: UUID?, directoryPath: String?, priorOrder: [URL], before: URL?) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        func key(_ url: URL) -> String { directoryPath == nil ? url.standardizedFileURL.path : url.lastPathComponent }
        var seen = Set<String>()
        let inserted = urls.map(key).filter { seen.insert($0).inserted }
        let moving = Set(inserted)
        let current = directoryPath.flatMap { workspaces[index].directoryOrders?[$0] } ?? (directoryPath == nil ? workspaces[index].referencePaths : priorOrder.map(key))
        seen = []
        var result = (current + priorOrder.map(key)).filter { !moving.contains($0) && seen.insert($0).inserted }
        let position = before.map(key).flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(contentsOf: inserted, at: position)
        if let directoryPath {
            var orders = workspaces[index].directoryOrders ?? [:]
            orders[directoryPath] = result; workspaces[index].directoryOrders = orders
        } else {
            workspaces[index].referencePaths = result; referenceManualOrder = true
        }
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    private func canAddWorkspace() -> Bool {
        guard workspaces.count < Self.maximumWorkspaces else {
            errorMessage = L("最多可添加 \(Self.maximumWorkspaces) 个工作区。"); return false
        }
        return true
    }

    private func canStoreReferences(_ paths: [String]) -> Bool {
        guard paths.count <= Self.maximumReferences else {
            errorMessage = L("合集或暂存区最多可容纳 \(Self.maximumReferences) 个项目。"); return false
        }
        return true
    }

    /// Preserve the original scoped URL objects while a sharing service owns
    /// descendants. Enumerating lexical ancestors avoids a stat per item on UI.
    func securityScopesForSharing(_ urls: [URL]) -> [URL] {
        Self.matchingSecurityScopes(activeScopes, for: urls)
    }

    static func matchingSecurityScopes(_ scopes: [URL], for urls: [URL]) -> [URL] {
        var ancestors = Set<String>()
        for url in urls where url.isFileURL {
            var path = url.standardizedFileURL.path
            while ancestors.insert(path).inserted && path != "/" {
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return scopes.filter { ancestors.contains($0.standardizedFileURL.path) }
    }

    func remember(_ url: URL) {
        guard url.isFileURL else { return }
        do {
            bookmarkData[url.standardizedFileURL.path] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            if !activeScopes.contains(url), url.startAccessingSecurityScopedResource() { activeScopes.append(url) }
        } catch {
            // An unsandboxed build can use ordinary paths when scoped bookmarks are unavailable.
            // Preserve an ordinary bookmark so moved files can still be resolved on restart.
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarkData[url.standardizedFileURL.path] = data
            }
        }
        persistIfReady()
    }

    private func apply(data: Data) throws {
        guard data.count <= Self.maximumConfigurationBytes else { throw HubFileError.corruptConfig }
        var state = try JSONDecoder().decode(SavedState.self, from: data)
        // Retire stored paths inside the migrated support directory as well.
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldRoot = support.appendingPathComponent("FolderHubReplica").path
        let newRoot = support.appendingPathComponent("FileDock").path
        func migrated(_ path: String) -> String {
            guard path == oldRoot || path.hasPrefix(oldRoot + "/") else { return path }
            return newRoot + path.dropFirst(oldRoot.count)
        }
        for index in state.workspaces.indices {
            state.workspaces[index].rootPath = state.workspaces[index].rootPath.map(migrated)
            state.workspaces[index].customIconPath = state.workspaces[index].customIconPath.map(migrated)
            state.workspaces[index].referencePaths = state.workspaces[index].referencePaths.map(migrated)
            if let orders = state.workspaces[index].directoryOrders {
                state.workspaces[index].directoryOrders = Dictionary(orders.map { (migrated($0.key), $0.value.map(migrated)) }, uniquingKeysWith: { first, _ in first })
            }
        }
        for index in state.workspaces.indices where state.workspaces[index].mode == .recents {
            state.workspaces[index].rootPath = nil
            state.workspaces[index].referencePaths = []
            state.workspaces[index].directoryOrders = nil
        }
        guard state.version == 1, state.workspaces.count <= Self.maximumWorkspaces, Set(state.workspaces.map(\.id)).count == state.workspaces.count,
              state.workspaces.allSatisfy({ ($0.rootPath == nil || $0.rootPath!.hasPrefix("/")) && $0.referencePaths.count <= Self.maximumReferences && $0.referencePaths.allSatisfy { $0.hasPrefix("/") } }) else { throw HubFileError.corruptConfig }
        workspaces = state.workspaces
        selectedWorkspaceID = state.workspaces.contains(where: { $0.id == state.selectedWorkspaceID }) ? state.selectedWorkspaceID : state.workspaces.first?.id
        settings = state.settings
        settings.normalize()
        if settings.resolvedRecentShortcutEnabled && recentWorkspace == nil { settings.recentShortcutEnabled = false }
        bindFavoriteWorkspaceIfNeeded()
        sortKey = state.sortKey; ascending = state.ascending; viewMode = state.viewMode
        referenceManualOrder = state.referenceManualOrder ?? true
        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
        activeScopes = []
        bookmarkData = state.bookmarks
        for (oldPath, data) in state.bookmarks {
            var stale = false
            var resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if resolved == nil { resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            guard let url = resolved else { continue }
            if url.startAccessingSecurityScopedResource() { activeScopes.append(url) }
            if url.path != oldPath {
                for index in workspaces.indices {
                    if workspaces[index].rootPath == oldPath { workspaces[index].rootPath = url.path }
                    workspaces[index].referencePaths = workspaces[index].referencePaths.map { $0 == oldPath ? url.path : $0 }
                }
                bookmarkData.removeValue(forKey: oldPath)
                bookmarkData[url.path] = data
            }
            if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarkData[url.path] = renewed
            }
        }
        if !availableWorkspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = availableWorkspaces.first?.id
        }
    }

    private func encodedConfiguration() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SavedState(workspaces: workspaces, selectedWorkspaceID: selectedWorkspaceID, settings: settings, sortKey: sortKey, ascending: ascending, viewMode: viewMode, bookmarks: bookmarkData, referenceManualOrder: referenceManualOrder))
        guard data.count <= Self.maximumConfigurationBytes else { throw HubFileError.configurationTooLarge }
        return data
    }

    private func beginPersistenceTransaction() { persistenceDepth += 1 }
    private func endPersistenceTransaction() {
        precondition(persistenceDepth > 0)
        persistenceDepth -= 1
        if persistenceDepth == 0 && persistencePending {
            persistencePending = false
            persistIfReady()
        }
    }

    private func pruneUnusedBookmarks() {
        var paths = workspaces.flatMap { $0.referencePaths + [$0.rootPath, $0.customIconPath].compactMap { $0 } }
        paths += (history + transferScopeURLs + dropScopeURLs.values.flatMap { $0 } + [currentURL].compactMap { $0 }).map(\.path)
        // A folder bookmark may be the only authorization for a retained child.
        // Building ancestor membership once avoids bookmarks × references scans.
        var neededAncestors = Set<String>()
        for path in paths {
            var location = URL(fileURLWithPath: path).standardizedFileURL
            while neededAncestors.insert(location.path).inserted && location.path != "/" {
                location.deleteLastPathComponent()
            }
        }
        bookmarkData = bookmarkData.filter { neededAncestors.contains(URL(fileURLWithPath: $0.key).standardizedFileURL.path) }
        activeScopes.removeAll { url in
            guard !neededAncestors.contains(url.standardizedFileURL.path) else { return false }
            url.stopAccessingSecurityScopedResource()
            return true
        }
    }

    /// Resize notifications can be duplicated or interrupted. One matching end
    /// releases only the resize's deferral, preserving any surrounding transaction.
    func beginInteractiveResize() {
        guard !deferringInteractiveResize else { return }
        deferringInteractiveResize = true
        beginPersistenceTransaction()
    }

    func endInteractiveResize() {
        guard deferringInteractiveResize else { return }
        deferringInteractiveResize = false
        endPersistenceTransaction()
    }

    // Explicit save (including application termination) flushes a live resize.
    func save() { persistIfReady(force: true) }
    private func persistIfReady(force: Bool = false) {
        guard readyToSave else { return }
        guard force || persistenceDepth == 0 else { persistencePending = true; return }
        persistencePending = false
        pruneUnusedBookmarks()
        do {
            // Validate the complete bytes before creating/replacing anything on disk.
            let data = try encodedConfiguration()
            try fm.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: configurationURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
            configurationWriteCount += 1
        } catch { errorMessage = L("无法保存设置：\(error.localizedDescription)") }
    }

    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L("FileDock 配置.json"); panel.allowedContentTypes = [.json]
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        do { try encodedConfiguration().write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }
    func importConfiguration() {
        guard !configurationImportIsBlocked else { errorMessage = L("请等文件操作或分享完成后再导入配置。"); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        do {
            try importConfiguration(data: Data(contentsOf: url))
        } catch { errorMessage = error.localizedDescription }
    }

    /// Shared by file import and configuration round-trip tests.
    func importConfiguration(data: Data) throws {
        guard !configurationImportIsBlocked else { throw HubFileError.partial([L("请等文件操作或分享完成后再导入配置。")]) }
        let wasReady = readyToSave
        readyToSave = false
        defer { readyToSave = wasReady }
        try apply(data: data)
        invalidateBackgroundRefresh()
        if let id = selectedWorkspaceID { selectWorkspace(id) }
        else { clearWorkspaceSelection() }
        readyToSave = wasReady
        persistIfReady()
    }

    private var configurationImportIsBlocked: Bool {
        stagingTransferInProgress || fileOperationsInProgress > 0 || sharingInProgress || externalFileWorkInProgress()
    }

    private func seedDemo(in root: URL) {
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for directory in ["Design", "Documents", "Screenshots", "Archive"] {
                try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            let files = ["Project Notes.md": "# Project Notes\n\nAn independent native macOS file workspace.\n", "Quick Start.txt": "Double-click to open. Drag files to organize them.\n", "Workspace Ideas.md": "Design\nResearch\nDaily essentials\n"]
            for (name, text) in files where !fm.fileExists(atPath: root.appendingPathComponent(name).path) {
                try Data(text.utf8).write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            }
            workspaces = [Workspace(name: "下载", symbol: "arrow.down.circle", rootPath: root.path),
                          Workspace(name: "设计", symbol: "paintpalette", rootPath: root.appendingPathComponent("Design").path),
                          Workspace(name: "文稿", symbol: "doc.text", rootPath: root.appendingPathComponent("Documents").path),
                          Workspace(name: "应用程序", symbol: "app.dashed", rootPath: "/Applications"),
                          Workspace(name: "收藏", symbol: "star", mode: .references, referencePaths: [root.appendingPathComponent("Project Notes.md").path])]
        } catch { errorMessage = L("无法创建演示目录：\(error.localizedDescription)") }
    }
}
