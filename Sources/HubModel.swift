import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case folder, references, recents
    var id: String { rawValue }
    var title: String { self == .folder ? "子文件夹" : self == .recents ? "最近使用" : "文件夹与文件" }
    var description: String { self == .folder ? "浏览文件夹中的全部项目，新文件自动出现。" : self == .recents ? "自动显示最近打开过的文件。" : "收藏所选文件与文件夹，只保存引用。" }
}

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case name, size, kind, created, modified, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .kind: return "种类"
        case .created: return "创建日期"
        case .modified: return "修改日期"
        case .added: return "添加日期"
        }
    }
}

enum HubViewMode: String, Codable, CaseIterable, Identifiable {
    case grid, list, columns
    var id: String { rawValue }
    var title: String { self == .grid ? "图标" : self == .list ? "列表" : "分栏" }
    var symbol: String { self == .grid ? "square.grid.2x2" : self == .list ? "list.bullet" : "rectangle.split.3x1" }
}

enum HubAppearance: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { self == .system ? "跟随系统" : self == .dark ? "深色" : "浅色" }
}

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case both, hover, keyboard
    var id: String { rawValue }
    var title: String { self == .both ? "鼠标与快捷键" : self == .hover ? "仅鼠标" : "仅快捷键" }
}

enum HotCorner: String, Codable, CaseIterable, Identifiable {
    case notch, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notch: return "顶部居中 / 刘海"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

struct HubSettings: Codable, Equatable {
    var appearance: String = "dark"
    var backgroundTheme: String? = nil
    var fontSize: Double = 13
    var iconSize: Double = 46
    var horizontalScroll = false
    var showScrollbar = true
    var notchClickToWake: Bool? = nil
    var usesNotchClickToWake: Bool { hotCorner == "notch" && notchClickToWake == true }
    var hoverDelay: Double = 0.12
    var autoHideDelay: Double? = nil
    var globalShortcuts: HubGlobalShortcuts? = nil
    var animationSpeed: Double? = nil
    var notchIntegrationStyle: String? = nil
    var qqMusicEnabled: Bool? = nil
    var favoriteWorkspaceID: UUID? = nil
    var favoriteShortcutEnabled: Bool? = nil
    var blockedApplicationBundleIDs: [String]? = nil
    var suppressHoverInFullScreen: Bool? = nil
    var stagingWorkspaceID: UUID? = nil
    var stagingEnabled: Bool? = nil
    var switchDelay: Double = 0.2
    var triggerMode: String = "both"
    var hotCorner: String = "notch"
    var secondaryScreens = true
    var showMenuBarIcon = true
    var funAnimation = false
    var width: Double = 900
    var height: Double = 480
    var launchAtLogin = false
    var lightBackgroundHex = "F4F5F7"
    var darkBackgroundHex = "191B20"

    var resolvedGlobalShortcuts: HubGlobalShortcuts { globalShortcuts ?? .defaults }
    var resolvedBackgroundTheme: String { backgroundTheme == "liquidGlass" ? "liquidGlass" : "solid" }
    var resolvedAppearance: String { resolvedBackgroundTheme == "liquidGlass" ? "dark" : appearance }
    var resolvedAnimationSpeed: Double {
        let value = animationSpeed ?? 1
        return value.isFinite ? min(2, max(0.5, value)) : 1
    }
    var resolvedQQMusicEnabled: Bool { qqMusicEnabled ?? true }
    var resolvedFavoriteShortcutEnabled: Bool { favoriteShortcutEnabled ?? true }
    var resolvedBlockedApplicationBundleIDs: [String] {
        Array(Set((blockedApplicationBundleIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("\u{0}") })).sorted()
    }
    var resolvedSuppressHoverInFullScreen: Bool { suppressHoverInFullScreen ?? true }
    var resolvedStagingEnabled: Bool { stagingEnabled ?? true }
    var resolvedNotchIntegrationStyle: String { notchIntegrationStyle == "embedded" ? "embedded" : "connected" }
    var resolvedAutoHideDelay: Double {
        let value = autoHideDelay ?? 0.55
        return value.isFinite ? min(3, max(0, value)) : 0.55
    }

    mutating func normalize() {
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
    let exists: Bool
    @MainActor var icon: NSImage { HubFileIconCache.image(for: self) }
    /// Includes every displayed property, including Finder labels and custom-icon changes.
    var snapshotSignature: String {
        func timestamp(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate) } ?? "nil" }
        let fields = [url.path, name, String(isDirectory), String(isPackage), String(size), kind,
                      timestamp(created), timestamp(modified), timestamp(added), timestamp(attributesModified), String(labelNumber), String(exists)] + tagNames
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
    var canNavigate: Bool { isDirectory && !isPackage }
    var sizeText: String { isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    init(url: URL) {
        // Directory enumerators and callers can retain URL resource caches across refreshes.
        var freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
        freshURL.removeAllCachedResourceValues()
        self.url = freshURL
        let keys: Set<URLResourceKey> = [.nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey, .attributeModificationDateKey, .labelNumberKey, .tagNamesKey]
        let values = try? freshURL.resourceValues(forKeys: keys)
        exists = FileManager.default.fileExists(atPath: freshURL.path)
        name = values?.localizedName ?? values?.name ?? url.lastPathComponent
        isDirectory = values?.isDirectory ?? false
        isPackage = values?.isPackage ?? false
        size = Int64(values?.fileSize ?? 0)
        kind = exists ? (values?.localizedTypeDescription ?? (isDirectory ? "文件夹" : url.pathExtension.uppercased() + " 文件")) : "项目不可用"
        created = values?.creationDate
        modified = values?.contentModificationDate
        added = values?.addedToDirectoryDate
        attributesModified = values?.attributeModificationDate
        labelNumber = values?.labelNumber ?? 0
        tagNames = (values?.tagNames ?? []).sorted()
    }
}

enum HubFileError: LocalizedError {
    case missing(URL), invalidDestination, descendant, invalidName, noWorkspace, corruptConfig, configurationTooLarge, partial([String])
    var errorDescription: String? {
        switch self {
        case .missing(let url): return "找不到项目：\(url.lastPathComponent)"
        case .invalidDestination: return "请选择可写入的目标文件夹。"
        case .descendant: return "不能把文件夹放入它自己或它的子文件夹。"
        case .invalidName: return "名称不能为空，也不能包含 /、:，或使用 . 与 ..。"
        case .noWorkspace: return "请先选择或添加一个工作区。"
        case .corruptConfig: return "配置文件格式无效。"
        case .configurationTooLarge: return "配置超过 16 MiB，未覆盖原有设置。请减少工作区或文件引用后重试。"
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
    @Published var workspaces: [Workspace] = [] { didSet { persistIfReady() } }
    @Published var selectedWorkspaceID: UUID? { didSet { persistIfReady() } }
    @Published var entries: [FileEntry] = []
    @Published var selectedIDs = Set<URL>()
    @Published var search = ""
    @Published var sortKey: SortKey = .name { didSet {
        beginPersistenceTransaction(); defer { endPersistenceTransaction() }
        referenceManualOrder = false; if readyToSave { clearDirectoryOrder() }; persistIfReady()
    } }
    @Published var ascending = true { didSet {
        beginPersistenceTransaction(); defer { endPersistenceTransaction() }
        referenceManualOrder = false; if readyToSave { clearDirectoryOrder() }; persistIfReady()
    } }
    @Published var referenceManualOrder = true { didSet { persistIfReady() } }
    @Published var viewMode: HubViewMode = .grid { didSet { persistIfReady() } }
    @Published var settings = HubSettings() { didSet { persistIfReady() } }
    @Published var pinned = false
    @Published var errorMessage: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyIndex = -1
    @Published var showHiddenFiles = false { didSet { refresh() } }
    @Published private(set) var recentFilesLoading = false
    @Published private(set) var recentFilesMessage: String?
    @Published private(set) var stagingTransferInProgress = false

    private let fm = FileManager.default
    private let configurationURL: URL
    private var bookmarkData: [String: Data] = [:]
    private var activeScopes: [URL] = []
    private var readyToSave = false
    private var persistenceDepth = 0
    private var persistencePending = false
    private var deferringInteractiveResize = false
    private var transferScopeURLs: [URL] = []
    private(set) var configurationWriteCount = 0
    private static let maximumConfigurationBytes = 16 * 1024 * 1024
    private var refreshTimer: Timer?
    private var refreshGeneration = 0
    private let directoryLoader: HubDirectoryLoading
    private var activeDirectoryLoad: UUID?
    private var displayedDirectoryContext: RefreshContext?
    private var canonicalDirectoryPath: String?
    private var retryDirectoryNavigation: (url: URL, selecting: URL?)?
    @Published private(set) var directoryLoading = false
    @Published private(set) var directoryLoadMessage: String?
    private var backgroundRefreshRequested = false
    private(set) var backgroundRefreshCount = 0
    var isRefreshingInBackground: Bool { activeDirectoryLoad != nil }
    private var lastSnapshot: [String] = []
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
                catch { errorMessage = "旧配置迁移失败：\(error.localizedDescription)"; return }
            }
        }

        var loadedConfiguration = false
        if fm.fileExists(atPath: self.configurationURL.path) {
            do {
                try apply(data: Data(contentsOf: self.configurationURL))
                loadedConfiguration = true
            }
            catch {
                errorMessage = "配置未能读取：\(error.localizedDescription)。原文件已保留。"
                let backup = self.configurationURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
                do { try fm.copyItem(at: self.configurationURL, to: backup) }
                catch { errorMessage = "配置未能读取，且无法保存备份。请检查文件权限。"; return }
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
        let initial = availableWorkspaces.first(where: { $0.id == selectedWorkspaceID }) ?? availableWorkspaces.first
        selectedWorkspaceID = initial?.id
        currentURL = initial?.mode == .folder ? initial?.rootURL : nil
        if let root = currentURL { history = [root]; historyIndex = 0 }
        readyToSave = true
        refresh()
        persistIfReady()
        if monitor {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshInBackground() }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()

        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
    }

    var selectedWorkspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    var favoriteWorkspace: Workspace? {
        if let id = settings.favoriteWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == id && $0.mode == .references }) { return workspace }
        return workspaces.first { $0.mode == .references && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "收藏" }
    }
    var fixedFavoriteWorkspace: Workspace? { settings.resolvedFavoriteShortcutEnabled ? favoriteWorkspace : nil }
    var stagingWorkspace: Workspace? {
        guard let id = settings.stagingWorkspaceID, id != settings.favoriteWorkspaceID else { return nil }
        return workspaces.first { $0.id == id && $0.mode == .references }
    }
    var stagedURLs: [URL] {
        let paths = stagingWorkspace?.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? []
        return uniquePaths(paths).map { URL(fileURLWithPath: $0) }
    }
    var isStagingWorkspace: Bool { stagingWorkspace?.id == selectedWorkspaceID && selectedWorkspaceID != nil }
    var isStagingRoot: Bool { isStagingWorkspace && currentURL == nil }
    private var availableWorkspaces: [Workspace] {
        workspaces.filter { settings.resolvedStagingEnabled || $0.id != stagingWorkspace?.id }
    }
    var tabWorkspaces: [Workspace] {
        let fixedID = fixedFavoriteWorkspace?.id
        return workspaces.filter { $0.id != fixedID && $0.id != stagingWorkspace?.id }
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
            ?? (isStagingRoot ? "暂存文件引用 · 拖出或选择复制／移动到文件夹" : isRecentsRoot ? "最近使用 · 按最近打开时间排列" : "文件引用 · 原文件保持在原位置")
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
                                               title: workspace.name.isEmpty ? workspace.mode == .recents ? "最近使用" : "文件合集" : workspace.name, url: nil))
        }
        components.append(contentsOf: breadcrumbs.map { url in
            HubPathComponent(id: prefix + ":file:" + url.path,
                             title: url.path == "/" ? "/" : url.lastPathComponent, url: url)
        })
        return components
    }
    var visibleEntries: [FileEntry] {
        let ordered = orderedEntries
        return search.isEmpty ? ordered : ordered.filter { $0.name.localizedStandardContains(search) }
    }

    func sortByColumn(_ key: SortKey) {
        guard !isRecentsRoot else { return }
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if sortKey == key && !isManualEntryOrder { ascending.toggle() }
        else { sortKey = key; ascending = true }
    }

    private var directoryOrderPath: String { canonicalDirectoryPath ?? currentURL?.standardizedFileURL.path ?? "" }

    var isManualEntryOrder: Bool {
        if isReferenceRoot { return referenceManualOrder }
        guard currentURL != nil else { return false }
        let path = directoryOrderPath
        return selectedWorkspace?.directoryOrders?[path] != nil
    }

    private var orderedEntries: [FileEntry] {
        if isRecentsRoot { return entries }
        if isReferenceRoot && referenceManualOrder { return entries }
        if currentURL != nil, let order = selectedWorkspace?.directoryOrders?[directoryOrderPath] {
            let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            return entries.sorted {
                let left = positions[$0.url.lastPathComponent] ?? Int.max, right = positions[$1.url.lastPathComponent] ?? Int.max
                return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
            }
        }
        return entries.sorted { left, right in
            if left.canNavigate != right.canNavigate { return left.canNavigate }
            let result: ComparisonResult
            switch sortKey {
            case .name: result = left.name.localizedStandardCompare(right.name)
            case .kind: result = left.kind.localizedStandardCompare(right.kind)
            case .size: result = left.size == right.size ? .orderedSame : left.size < right.size ? .orderedAscending : .orderedDescending
            case .created: result = compareDates(left.created, right.created)
            case .modified: result = compareDates(left.modified, right.modified)
            case .added: result = compareDates(left.added, right.added)
            }
            if result == .orderedSame { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast, right = rhs ?? .distantPast
        return left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
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
        lastSnapshot = []
        refresh()
    }

    func nextWorkspace(_ delta: Int = 1) {
        let choices = availableWorkspaces
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(where: { $0.id == selectedWorkspaceID }) ?? 0
        selectWorkspace(choices[(index + delta % choices.count + choices.count) % choices.count].id)
    }

    @discardableResult
    func addWorkspace(name: String, symbol: String = "folder", mode: WorkspaceMode, urls: [URL]) -> Workspace {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = mode == .recents ? [] : urls.filter(\.isFileURL).map(\.standardizedFileURL)
        selected.forEach(remember)
        let workspace = Workspace(name: clean.isEmpty ? "新工作区" : clean, symbol: symbol, mode: mode,
                                  rootPath: mode == .folder ? selected.first?.path : nil,
                                  referencePaths: mode == .references ? uniquePaths(selected.map(\.path)) : [])
        workspaces.append(workspace)
        bindFavoriteWorkspaceIfNeeded()
        selectWorkspace(workspace.id)
        return workspace
    }

    @discardableResult
    func addRecentWorkspace() -> Workspace {
        if let existing = workspaces.first(where: { $0.mode == .recents }) {
            selectWorkspace(existing.id)
            return existing
        }
        return addWorkspace(name: "最近使用", symbol: "clock", mode: .recents, urls: [])
    }

    func setFavoriteShortcutVisible(_ visible: Bool) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if visible {
            let favorite = favoriteWorkspace ?? addWorkspace(name: "收藏", symbol: "star", mode: .references, urls: [])
            settings.favoriteWorkspaceID = favorite.id
        }
        settings.favoriteShortcutEnabled = visible
    }

    func setWorkspaceIconOnly(id: UUID, enabled: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].iconOnly = enabled
    }

    /// The shelf is created lazily, without changing the user's current location.
    private func ensureStagingWorkspace() -> Workspace {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        if let existing = stagingWorkspace { return existing }
        let workspace = Workspace(name: "暂存区", symbol: "tray", mode: .references)
        workspaces.append(workspace)
        settings.stagingWorkspaceID = workspace.id
        return workspace
    }

    func openStagingWorkspace() {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard settings.resolvedStagingEnabled else { return }
        selectWorkspace(ensureStagingWorkspace().id)
    }

    func setStagingEnabled(_ enabled: Bool) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        let wasSelected = isStagingWorkspace
        settings.stagingEnabled = enabled
        if !enabled && wasSelected {
            if let next = availableWorkspaces.first { selectWorkspace(next.id) }
            else {
                stopRecentFiles(); selectedWorkspaceID = nil; currentURL = nil
                entries = []; selectedIDs = []; history = []; historyIndex = -1
            }
        }
    }

    /// Staging only records paths/bookmarks. It never relocates or copies source data.
    @discardableResult
    func stageFiles(_ urls: [URL]) -> Bool {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        guard settings.resolvedStagingEnabled, !stagingTransferInProgress else { return false }
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !files.isEmpty else { return false }
        let workspace = ensureStagingWorkspace()
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return false }
        let paths = uniquePaths(stagedURLs.map(\.path) + files.map(\.path))
        guard paths.count <= 20000 else { errorMessage = "暂存区最多可容纳 20000 个项目。"; return false }
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
        let files = normalizedTopLevelURLs(requested)
        guard !files.isEmpty else { return [] }
        let shelfID = stagingWorkspace?.id
        stagingTransferInProgress = true
        transferScopeURLs = files + [directory.standardizedFileURL]
        remember(directory)
        defer { stagingTransferInProgress = false }
        let result = await Task.detached(priority: .userInitiated) {
            var completed: [(source: URL, destination: URL, directory: Bool)] = []
            var failures: [String] = []
            for source in files {
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
        for index in updated.indices {
            updated[index].referencePaths = uniquePaths(updated[index].referencePaths.map(relocated))
            if let root = updated[index].rootPath { updated[index].rootPath = relocated(root) }
            if let orders = updated[index].directoryOrders {
                updated[index].directoryOrders = Dictionary(orders.map { (relocated($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
            }
        }
        workspaces = updated
        if let location = currentURL { currentURL = URL(fileURLWithPath: relocated(location.path)) }
        history = history.map { URL(fileURLWithPath: relocated($0.path)) }
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
        panel.title = copy ? "复制暂存文件到…" : "移动暂存文件到…"
        panel.prompt = copy ? "复制到这里" : "移动到这里"
        panel.message = "成功转移的项目会从暂存区移除。同名文件会自动改名，保留目标文件。"
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
        // Capture a legacy name-based favorite before a rename changes its label.
        bindFavoriteWorkspaceIfNeeded()
        var updated = workspace
        if workspace.id == stagingWorkspace?.id { updated.mode = .references; updated.rootPath = nil }
        if updated.mode == .recents {
            updated.rootPath = nil; updated.referencePaths = []; updated.directoryOrders = nil
        }
        updated.name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty && updated.symbol.isEmpty && updated.customIconPath == nil { errorMessage = "请至少保留工作区名称或图标。"; return }
        if let iconPath = updated.customIconPath { remember(URL(fileURLWithPath: iconPath)) }
        updated.referencePaths = uniquePaths(updated.referencePaths)
        let rootChanged = workspaces[index].rootPath != updated.rootPath || workspaces[index].mode != updated.mode
        workspaces[index] = updated
        if selectedWorkspaceID == workspace.id {
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
        workspaces.remove(at: index)
        if wasSelected {
            if !availableWorkspaces.isEmpty { selectWorkspace(availableWorkspaces[min(index, availableWorkspaces.count - 1)].id) }
            else { stopRecentFiles(); selectedWorkspaceID = nil; currentURL = nil; entries = []; selectedIDs = []; history = []; historyIndex = -1 }
        }
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
        panel.title = mode == .folder ? "选择工作区文件夹" : "选择文件或文件夹"
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
        panel.title = "选择文件夹并授权访问"
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
        files.forEach(remember)
        workspaces[index].referencePaths = uniquePaths(workspaces[index].referencePaths + files.map(\.path))
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
        let original = orderedEntries.map { $0.url.path }
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
        if let activeDirectoryLoad { directoryLoader.cancel(id: activeDirectoryLoad) }
        activeDirectoryLoad = nil
        directoryLoading = false
    }

    func refreshInBackground() {
        if isRecentsRoot { recentFiles.refresh(); return }
        guard directoryLoadMessage == nil else { return }
        if activeDirectoryLoad != nil { backgroundRefreshRequested = true; return }
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
        activeDirectoryLoad = id
        directoryLoading = reportErrors || entries.isEmpty; directoryLoadMessage = nil
        directoryLoader.load(id: id, request: request) { [weak self] result in
            guard let self, self.activeDirectoryLoad == id,
                  self.refreshGeneration == generation, self.refreshContext == context else { return }
            self.activeDirectoryLoad = nil; self.directoryLoading = false
            switch result {
            case .success(let snapshot):
                commitNavigation?()
                self.canonicalDirectoryPath = snapshot.canonicalDirectoryPath
                self.displayedDirectoryContext = self.refreshContext
                self.publishEntries(snapshot.entries)
            case .failure(let error):
                self.directoryLoadMessage = error.localizedDescription
            }
            let repeatRefresh = self.backgroundRefreshRequested
            self.backgroundRefreshRequested = false
            if repeatRefresh && self.directoryLoadMessage == nil { self.refreshInBackground() }
        }
    }

    private func publishEntries(_ next: [FileEntry]) {
        let snapshot = next.map(\.snapshotSignature)
        if snapshot != lastSnapshot || entries.count != next.count {
            entries = next
            lastSnapshot = snapshot
            selectedIDs.formIntersection(Set(next.map(\.url)))
        }
    }

    func retryDirectoryLoad() {
        if let retry = retryDirectoryNavigation { navigateDirectory(to: retry.url, selecting: retry.selecting) }
        else { refresh() }
    }

    func refresh(reportErrors: Bool = true) {
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
            entries = []; lastSnapshot = []; selectedIDs = []; canonicalDirectoryPath = nil
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
        entries = []; lastSnapshot = []; selectedIDs = []
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
            self.invalidateBackgroundRefresh()
            self.recentRecords = records
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
        else if !NSWorkspace.shared.open(entry.url) { errorMessage = "无法打开 \(entry.name)。" }
    }
    func openExternally(_ url: URL) { if !NSWorkspace.shared.open(url) { errorMessage = "无法打开 \(url.lastPathComponent)。" } }
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

    func createFolder(named name: String = "未命名文件夹") {
        guard let currentURL else { errorMessage = HubFileError.invalidDestination.localizedDescription; return }
        do {
            try HubFileOperations.validateName(name)
            let proposed = currentURL.appendingPathComponent(name, isDirectory: true)
            let target = HubFileOperations.uniqueDestination(for: proposed, in: currentURL)
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            refresh(); selectedIDs = [target]
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ entry: FileEntry, to name: String) {
        beginPersistenceTransaction()
        defer { endPersistenceTransaction() }
        do {
            try HubFileOperations.validateName(name)
            let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
            if entry.url == target { return }
            let parentPath = HubFileOperations.canonical(entry.url.deletingLastPathComponent()).path
            let symbolicLink = (try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let oldDirectoryPath = entry.canNavigate && !symbolicLink ? HubFileOperations.canonical(entry.url).path : nil
            try fm.moveItem(at: entry.url, to: target)
            for index in workspaces.indices {
                workspaces[index].referencePaths = workspaces[index].referencePaths.map { $0 == entry.url.path ? target.path : $0 }
                if workspaces[index].rootPath == entry.url.path { workspaces[index].rootPath = target.path }
                if var orders = workspaces[index].directoryOrders {
                    if let names = orders[parentPath] {
                        orders[parentPath] = names.filter { $0 != name }.map { $0 == entry.url.lastPathComponent ? name : $0 }
                    }
                    if let oldDirectoryPath {
                        let newDirectoryPath = HubFileOperations.canonical(target).path
                        let isSource: (String) -> Bool = { $0 == oldDirectoryPath || $0.hasPrefix(oldDirectoryPath + "/") }
                        var migrated = orders.filter { !isSource($0.key) }
                        for (path, names) in orders where isSource(path) {
                            let newPath = newDirectoryPath + String(path.dropFirst(oldDirectoryPath.count))
                            migrated[newPath] = names
                        }
                        orders = migrated
                    }
                    workspaces[index].directoryOrders = orders
                }
            }
            remember(target)
            refresh(); selectedIDs = [target]
        } catch { errorMessage = error.localizedDescription }
    }

    func trash(_ urls: [URL]) {
        if isStagingRoot { removeStagedFiles(urls); return }
        var failures: [String] = []
        for url in normalizedTopLevelURLs(urls) {
            do { try fm.trashItem(at: url, resultingItemURL: nil) }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        refresh()
        if !failures.isEmpty { errorMessage = HubFileError.partial(failures).localizedDescription }
    }

    /// Drops at a curated root add references. Drops into a real folder transfer filesystem items.
    @discardableResult
    func handleDrop(urls: [URL], to directory: URL? = nil, copy: Bool = false) throws -> Bool {
        if isRecentsRoot { throw HubFileError.invalidDestination }
        if directory == nil && isStagingRoot { return stageFiles(urls) }
        if directory == nil && isReferenceRoot {
            let references = urls.filter(\.isFileURL)
            guard !references.isEmpty else { return false }
            appendReferences(references); return true
        }
        let files = normalizedTopLevelURLs(urls)
        guard !files.isEmpty else { return false }
        guard let destination = directory ?? currentURL else { throw HubFileError.invalidDestination }
        var failures: [String] = []
        for url in files {
            do { try HubFileOperations.transfer(url, to: destination, copy: copy) }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        refresh()
        if !failures.isEmpty { throw HubFileError.partial(failures) }
        return true
    }

    func pasteFiles(copy: Bool = true) {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        do { _ = try handleDrop(urls: urls, copy: copy) }
        catch { errorMessage = error.localizedDescription }
    }

    private func normalizedTopLevelURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        let directories = Set(unique.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true ? url.path : nil
        })
        return unique.filter { candidate in
            var parent = candidate.deletingLastPathComponent()
            while parent.path != candidate.path {
                if directories.contains(parent.path) { return false }
                if parent.path == "/" { break }
                parent.deleteLastPathComponent()
            }
            return true
        }
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
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
        guard state.version == 1, state.workspaces.count <= 2000, Set(state.workspaces.map(\.id)).count == state.workspaces.count,
              state.workspaces.allSatisfy({ ($0.rootPath == nil || $0.rootPath!.hasPrefix("/")) && $0.referencePaths.count <= 20000 && $0.referencePaths.allSatisfy { $0.hasPrefix("/") } }) else { throw HubFileError.corruptConfig }
        workspaces = state.workspaces
        selectedWorkspaceID = state.workspaces.contains(where: { $0.id == state.selectedWorkspaceID }) ? state.selectedWorkspaceID : state.workspaces.first?.id
        settings = state.settings
        settings.normalize()
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
        paths += (history + transferScopeURLs + [currentURL].compactMap { $0 }).map(\.path)
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
        } catch { errorMessage = "无法保存设置：\(error.localizedDescription)" }
    }

    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "FileDock 配置.json"; panel.allowedContentTypes = [.json]
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        do { try encodedConfiguration().write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }
    func importConfiguration() {
        guard !stagingTransferInProgress else { errorMessage = "请等暂存文件转移完成后再导入配置。"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard HubWindowPresentation.runModal(panel) == .OK, let url = panel.url else { return }
        do {
            try importConfiguration(data: Data(contentsOf: url))
        } catch { errorMessage = error.localizedDescription }
    }

    /// Shared by file import and configuration round-trip tests.
    func importConfiguration(data: Data) throws {
        guard !stagingTransferInProgress else { throw HubFileError.partial(["请等暂存文件转移完成后再导入配置。"]) }
        invalidateBackgroundRefresh()
        let wasReady = readyToSave
        readyToSave = false
        defer { readyToSave = wasReady }
        try apply(data: data)
        if let id = selectedWorkspaceID { selectWorkspace(id) }
        else {
            stopRecentFiles(); currentURL = nil; entries = []; selectedIDs = []
            history = []; historyIndex = -1
        }
        readyToSave = wasReady
        persistIfReady()
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
        } catch { errorMessage = "无法创建演示目录：\(error.localizedDescription)" }
    }
}
