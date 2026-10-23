import AppKit
import ApplicationServices
import Combine
import OSLog

struct HubQQMusicProbe: Sendable {
    let installed: Bool
    let pid: pid_t?
    let trusted: Bool
}

struct HubQQMusicSnapshot: Sendable {
    let pid: pid_t
    let title: String
    let artist: String
    let isPlaying: Bool?
}

enum HubQQMusicAction: Sendable { case toggle, previous, next }

enum HubQQMusicFailure: Error, Sendable {
    case permission, wrongTarget, notRunning, unavailable(String)
}

// Injection keeps tests entirely separate from the user's running music app and TCC.
protocol HubQQMusicBackend: AnyObject, Sendable {
    func probe() -> HubQQMusicProbe
    func requestAccess() -> Bool
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure>
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure>
}

enum HubQQMusicAccessibility {
    static let bundleID = "com.tencent.QQMusicMac"
    static let panelName = "播放控制栏"

    static func isNativeButton(role: String, roleDescription: String) -> Bool {
        role == kAXButtonRole || (role == kAXUnknownRole && ["按钮", "button"].contains(roleDescription.lowercased()))
    }

    static func isPlaybackPanel(role: String, names: [String]) -> Bool {
        // QQ 11.9.1 exposes this native panel as AXUnknown with the localized
        // role description “面板”. Its exact name and direct main-window
        // position remain mandatory; unknown containers are never searched.
        (role == kAXGroupRole || role == kAXToolbarRole || role == kAXUnknownRole) && names.contains(panelName)
    }

    static func matches(_ action: HubQQMusicAction, role: String, names: [String]) -> Bool {
        guard role == kAXButtonRole else { return false }
        switch action {
        case .toggle: return playbackState(role: role, names: names) != nil
        case .previous: return names.contains("上一首")
        case .next: return names.contains("下一首")
        }
    }

    static func playbackState(role: String, names: [String]) -> Bool? {
        guard role == kAXButtonRole else { return nil }
        let pause = names.contains("暂停") || names.contains("暂停播放"), play = names.contains("播放")
        return pause != play ? pause : nil
    }

    static func uniqueControlIndex(for action: HubQQMusicAction, controls: [(role: String, names: [String])]) -> Int? {
        let indices = controls.indices.filter { matches(action, role: controls[$0].role, names: controls[$0].names) }
        return indices.count == 1 ? indices[0] : nil
    }

    static func playbackState(controls: [(role: String, names: [String])]) -> Bool? {
        guard let index = uniqueControlIndex(for: .toggle, controls: controls) else { return nil }
        return playbackState(role: controls[index].role, names: controls[index].names)
    }

    static func uniquePlaybackMenuIndex(in items: [(role: String, title: String)]) -> Int? {
        let indices = items.indices.filter { items[$0].role == kAXMenuBarItemRole && items[$0].title == "播放控制" }
        return indices.count == 1 ? indices[0] : nil
    }

    static func matchesMenuCommand(_ action: HubQQMusicAction, role: String, title: String) -> Bool {
        guard role == kAXMenuItemRole else { return false }
        switch action {
        case .toggle: return title == "播放" || title == "暂停"
        case .previous: return title == "上一首"
        case .next: return title == "下一首"
        }
    }

    static func uniqueMenuCommandIndex(for action: HubQQMusicAction, in items: [(role: String, title: String)], isPlaying: Bool?) -> Int? {
        var indices = items.indices.filter { matchesMenuCommand(action, role: items[$0].role, title: items[$0].title) }
        if case .toggle = action, indices.count > 1, let isPlaying {
            let desiredTitle = isPlaying ? "暂停" : "播放"
            indices = indices.filter { items[$0].title == desiredTitle }
        }
        return indices.count == 1 ? indices[0] : nil
    }

    static func parseTrack(_ text: String) -> (title: String, artist: String)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, separator) in [("歌曲名：", " - 歌手名："), ("歌曲名:", " - 歌手名:")] {
            guard value.hasPrefix(prefix), let range = value.range(of: separator, options: .backwards) else { continue }
            let title = String(value[value.index(value.startIndex, offsetBy: prefix.count)..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (title, artist)
        }
        return nil
    }
}

// Every access to mutable state is protected by lock, including cancellation from deinit.
private final class HubQQMusicEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
    func contains(_ expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == expected
    }
}

@MainActor
final class HubQQMusicController: ObservableObject {
    enum Status: Equatable { case notInstalled, notRunning, needsPermission, connecting, ready, unavailable }

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var isPlaying: Bool?
    @Published private(set) var status: Status = .notRunning
    @Published private(set) var message: String?

    private let backend: HubQQMusicBackend
    private let queue = DispatchQueue(label: "app.folderhub.qqmusic.accessibility", qos: .userInitiated)
    private let epoch = HubQQMusicEpoch()
    private let pollInterval: TimeInterval
    private var generation: UInt64 = 0
    private var enabled = false
    private var visible = false
    private enum RequestKind { case read, action }
    private var requestKind: RequestKind?
    private var busy: Bool { requestKind != nil }
    private var targetPID: pid_t?
    private var timer: Timer?

    init(backend: HubQQMusicBackend = HubQQMusicAXBackend(), pollInterval: TimeInterval = 1.5) {
        self.backend = backend
        self.pollInterval = max(1, pollInterval)
    }

    deinit { timer?.invalidate(); _ = epoch.advance() }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        updatePolling()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        updatePolling()
    }

    private func updatePolling() {
        timer?.invalidate()
        timer = nil
        generation = epoch.advance()
        requestKind = nil
        guard enabled && visible else { return }
        refresh()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func openQQMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HubQQMusicAccessibility.bundleID) else {
            clear(status: .notInstalled, message: "尚未安装 QQ 音乐。")
            return
        }
        status = .connecting
        message = nil
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.clear(status: .unavailable, message: "无法打开 QQ 音乐：\(error.localizedDescription)")
                } else if self.enabled && self.visible {
                    self.generation = self.epoch.advance()
                    self.requestKind = nil
                    self.refresh()
                }
            }
        }
    }

    // This is the only path that may ask macOS to show an Accessibility prompt.
    func requestAccess() {
        guard enabled && visible else { return }
        submit(prompt: true)
    }

    // A transient player or layout failure is not a request for system access.
    func reconnect() { refresh() }

    func togglePlayback() { control(.toggle) }
    func previousTrack() { control(.previous) }
    func nextTrack() { control(.next) }

    private func control(_ action: HubQQMusicAction) {
        guard enabled && visible && requestKind != .action && status == .ready, let pid = targetPID else { return }
        // A click supersedes a passive read, then executes on the same serial
        // queue once that read finishes. Its stale result cannot overwrite the
        // action, while further clicks cannot enqueue duplicate toggles.
        submit(action: action, expectedPID: pid)
    }

    private func refresh() {
        guard enabled && visible && !busy else { return }
        submit()
    }

    private func submit(prompt: Bool = false, action: HubQQMusicAction? = nil, expectedPID: pid_t? = nil) {
        generation = epoch.advance()
        let request = generation
        requestKind = action == nil ? .read : .action
        // Passive polls retain the last useful state instead of repeatedly
        // removing and recreating the connection button while permission is off.
        if prompt { status = .connecting }
        let backend = backend, epoch = epoch
        queue.async { [weak self] in
            guard epoch.contains(request) else { return }
            if prompt { _ = backend.requestAccess() }
            guard epoch.contains(request) else { return }
            let probe = backend.probe()
            var result: Result<HubQQMusicSnapshot, HubQQMusicFailure>?
            if probe.installed, probe.trusted, let pid = probe.pid {
                if let expectedPID, expectedPID != pid {
                    result = .failure(.wrongTarget)
                } else if epoch.contains(request) {
                    result = action.map { backend.perform($0, for: pid) } ?? backend.snapshot(for: pid)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request, epoch.contains(request), self.enabled && self.visible else { return }
                self.requestKind = nil
                self.accept(probe: probe, result: result)
            }
        }
    }

    private func accept(probe: HubQQMusicProbe, result: Result<HubQQMusicSnapshot, HubQQMusicFailure>?) {
        guard probe.installed else { clear(status: .notInstalled, message: "尚未安装 QQ 音乐。"); return }
        guard let pid = probe.pid else { clear(status: .notRunning, message: "打开 QQ 音乐后即可连接。"); return }
        guard probe.trusted else {
            clear(status: .needsPermission, message: "连接需要辅助功能权限。请在系统设置 → 隐私与安全性 → 辅助功能中允许 FileDock。")
            return
        }
        guard let result else { return }
        switch result {
        case .success(let snapshot):
            guard snapshot.pid == pid else {
                clear(status: .unavailable, message: "QQ 音乐进程已变化，请稍后重试。")
                return
            }
            targetPID = pid
            title = snapshot.title
            artist = snapshot.artist
            isPlaying = snapshot.isPlaying
            status = .ready
            message = nil
        case .failure(let error):
            switch error {
            case .permission:
                clear(status: .needsPermission, message: "请在系统设置的辅助功能中允许 FileDock，再重新连接。")
            case .notRunning: clear(status: .notRunning, message: "打开 QQ 音乐后即可连接。")
            case .wrongTarget: clear(status: .unavailable, message: "QQ 音乐进程已变化，请稍后重试。")
            case .unavailable(let detail): clear(status: .unavailable, message: detail)
            }
        }
    }

    private func clear(status: Status, message: String) {
        targetPID = nil
        title = ""
        artist = ""
        isPlaying = nil
        self.status = status
        self.message = message
    }
}

// All methods run on the controller's serial background queue. Only the exact
// QQ main-window playback group is inspected; web views and playlists are excluded.
final class HubQQMusicAXBackend: HubQQMusicBackend {
    private let timeout: Float = 0.35
    private static let logger = Logger(subsystem: "app.folderhub.qqmusic", category: "PlaybackLayout")

    func probe() -> HubQQMusicProbe {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HubQQMusicAccessibility.bundleID) != nil
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: HubQQMusicAccessibility.bundleID)
            .first { !$0.isTerminated }
        return HubQQMusicProbe(installed: installed, pid: app?.processIdentifier, trusted: AXIsProcessTrusted())
    }

    func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        capture(for: pid).map { $0.snapshot }
    }

    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        do {
            let currentState = try capture(for: pid).get().snapshot.isPlaying
            try validate(pid)
            let reader = Reader(timeout: timeout)
            let application = AXUIElementCreateApplication(pid)
            guard let menuBar = try reader.element(application, kAXMenuBarAttribute),
                  try reader.string(menuBar, kAXRoleAttribute) == kAXMenuBarRole else {
                throw HubQQMusicFailure.unavailable("QQ 音乐当前未提供原生播放菜单。")
            }
            let menuBarItems = try reader.elements(menuBar, kAXChildrenAttribute, limit: 16)
            let menuBarLabels = try menuBarItems.map { (role: try reader.string($0, kAXRoleAttribute), title: try reader.string($0, kAXTitleAttribute)) }
            guard let menuIndex = HubQQMusicAccessibility.uniquePlaybackMenuIndex(in: menuBarLabels) else {
                throw HubQQMusicFailure.unavailable("无法唯一识别 QQ 音乐的“播放控制”菜单。")
            }
            // Only this exact menu is inspected. Do not open the menu, descend
            // into other menus, or attempt the unsupported custom player button.
            let menus = try reader.elements(menuBarItems[menuIndex], kAXChildrenAttribute, limit: 4)
                .filter { try reader.string($0, kAXRoleAttribute) == kAXMenuRole }
            guard menus.count == 1 else { throw HubQQMusicFailure.unavailable("QQ 音乐播放菜单暂时不可用。") }
            let items = try reader.elements(menus[0], kAXChildrenAttribute, limit: 32)
            let labels = try items.map { (role: try reader.string($0, kAXRoleAttribute), title: try reader.string($0, kAXTitleAttribute)) }
            guard let itemIndex = HubQQMusicAccessibility.uniqueMenuCommandIndex(for: action, in: labels, isPlaying: currentState) else {
                throw HubQQMusicFailure.unavailable("无法唯一识别 QQ 音乐的播放菜单项。")
            }
            let item = items[itemIndex]
            let role = try reader.string(item, kAXRoleAttribute)
            let title = try reader.string(item, kAXTitleAttribute)
            guard title == labels[itemIndex].title,
                  HubQQMusicAccessibility.matchesMenuCommand(action, role: role, title: title),
                  try reader.explicitlyEnabled(item) else {
                throw HubQQMusicFailure.unavailable("QQ 音乐当前的播放菜单项不可用，请重试。")
            }
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(item, &actualPID) == .success, actualPID == pid else { throw HubQQMusicFailure.wrongTarget }
            try validate(pid)
            // Execute exactly once. A toggle must never be retried automatically
            // after an action error or a delayed readback.
            let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
            Self.logger.debug("Native playback menu action result=\(error.rawValue)")
            if error == .actionUnsupported { throw HubQQMusicFailure.unavailable("QQ 音乐原生菜单暂不接受播放控制。") }
            guard error == .success else { throw failure(error) }
            // A readback (or the next poll) supplies state; never optimistically flip playback.
            return snapshot(for: pid)
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable("暂时无法连接 QQ 音乐。")) }
    }

    private struct Button {
        let element: AXUIElement
        let role: String
        let names: [String]
    }
    private struct Capture {
        let snapshot: HubQQMusicSnapshot
        let buttons: [Button]
    }

    private func capture(for pid: pid_t) -> Result<Capture, HubQQMusicFailure> {
        do {
            try validate(pid)
            let reader = Reader(timeout: timeout)
            let application = AXUIElementCreateApplication(pid)
            let appRole = try reader.string(application, kAXRoleAttribute)
            var windows = try reader.elements(application, kAXWindowsAttribute, limit: 8)
            if windows.isEmpty {
                for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                    if let window = try reader.element(application, attribute),
                       try reader.string(window, kAXRoleAttribute) == kAXWindowRole,
                       try reader.string(window, kAXIdentifierAttribute) == "QQMianWindow" {
                        var windowPID: pid_t = 0
                        if AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid {
                            windows = [window]
                            break
                        }
                    }
                }
            }
            if windows.isEmpty {
                // Some native AX providers expose their windows only through
                // application children. Inspect roles only, never descend into
                // non-window children or relax the exact main-window match.
                windows = try reader.elements(application, kAXChildrenAttribute, limit: 8).filter {
                    try reader.string($0, kAXRoleAttribute) == kAXWindowRole
                }
            }
            var playbackPanel: AXUIElement?
            var windowIDs: [String] = []
            var mainFound = false, exactPanelName = false
            var childRoles: [String: Int] = [:]
            for window in windows {
                let identifier = try reader.string(window, kAXIdentifierAttribute)
                windowIDs.append(identifier)
                guard identifier == "QQMianWindow" else { continue }
                mainFound = true
                for child in try reader.elements(window, kAXChildrenAttribute, limit: 24) {
                    let role = try reader.string(child, kAXRoleAttribute)
                    childRoles[role, default: 0] += 1
                    guard role != "AXWebArea" else { continue }
                    let names = try reader.names(child)
                    exactPanelName = exactPanelName || names.contains(HubQQMusicAccessibility.panelName)
                    if HubQQMusicAccessibility.isPlaybackPanel(role: role, names: names) {
                        playbackPanel = child
                        break
                    }
                }
                break
            }
            guard let playbackPanel else {
                // Structural diagnostics contain no titles, track names, account
                // data or child labels; they help identify QQ layout changes.
                let identifiers = windowIDs.joined(separator: ",")
                let roles = childRoles.keys.sorted().map { "\($0):\(childRoles[$0]!)" }.joined(separator: ",")
                Self.logger.debug("Playback layout unavailable: pid=\(pid) appRole=\(appRole, privacy: .public) windows=\(windows.count) ids=\(identifiers, privacy: .public) main=\(mainFound) roles=\(roles, privacy: .public) exactPanel=\(exactPanelName)")
                throw HubQQMusicFailure.unavailable("未找到 QQ 音乐播放控制栏，请打开 QQ 音乐主窗口。")
            }
            var pending: [(AXUIElement, Int)] = [(playbackPanel, 0)]
            var index = 0, title = "", artist = ""
            var buttons: [Button] = []
            while index < pending.count && index < 40 {
                let (element, depth) = pending[index]
                index += 1
                let role = try reader.string(element, kAXRoleAttribute)
                guard role != "AXWebArea" else { continue }
                let controlRole = try reader.controlRole(element, knownRole: role)
                let names = try reader.names(element)
                if controlRole == kAXButtonRole {
                    buttons.append(Button(element: element, role: controlRole, names: names))
                }
                for text in names + [try reader.string(element, kAXValueAttribute)] {
                    if let track = HubQQMusicAccessibility.parseTrack(text) { title = track.title; artist = track.artist }
                }
                if depth < 3 && controlRole != kAXButtonRole && pending.count < 40 {
                    pending.append(contentsOf: try reader.elements(element, kAXChildrenAttribute, limit: 40 - pending.count).map { ($0, depth + 1) })
                }
            }
            guard !buttons.isEmpty else { throw HubQQMusicFailure.unavailable("QQ 音乐播放控制栏暂时不可用。") }
            try validate(pid)
            let playing = HubQQMusicAccessibility.playbackState(controls: buttons.map { ($0.role, $0.names) })
            return .success(Capture(snapshot: HubQQMusicSnapshot(pid: pid, title: title, artist: artist, isPlaying: playing), buttons: buttons))
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable("暂时无法读取 QQ 音乐。")) }
    }

    private func validate(_ pid: pid_t) throws {
        guard AXIsProcessTrusted() else { throw HubQQMusicFailure.permission }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw HubQQMusicFailure.notRunning }
        guard app.bundleIdentifier == HubQQMusicAccessibility.bundleID else { throw HubQQMusicFailure.wrongTarget }
    }

    private func failure(_ error: AXError) -> HubQQMusicFailure {
        if error == .apiDisabled { return .permission }
        if error == .actionUnsupported { return .unavailable("QQ 音乐当前不接受播放控制。") }
        return .unavailable("QQ 音乐暂时没有响应，请稍后重试。")
    }

    private final class Reader {
        private let timeout: Float
        private let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        init(timeout: Float) { self.timeout = timeout }

        private func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HubQQMusicFailure.unavailable("QQ 音乐响应较慢，请稍后重试。") }
            AXUIElementSetMessagingTimeout(element, timeout)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            switch error {
            case .success: return value
            case .attributeUnsupported, .noValue: return nil
            case .apiDisabled: throw HubQQMusicFailure.permission
            default: throw HubQQMusicFailure.unavailable("QQ 音乐暂时没有响应，请稍后重试。")
            }
        }

        func string(_ element: AXUIElement, _ attribute: String) throws -> String {
            try value(element, attribute) as? String ?? ""
        }
        func names(_ element: AXUIElement) throws -> [String] {
            try [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func controlRole(_ element: AXUIElement, knownRole: String? = nil) throws -> String {
            let role = try knownRole ?? string(element, kAXRoleAttribute)
            let description = role == kAXUnknownRole ? try string(element, kAXRoleDescriptionAttribute) : ""
            return HubQQMusicAccessibility.isNativeButton(role: role, roleDescription: description) ? kAXButtonRole : role
        }
        func elements(_ element: AXUIElement, _ attribute: String, limit: Int) throws -> [AXUIElement] {
            guard limit > 0, let values = try value(element, attribute) as? [AXUIElement] else { return [] }
            return Array(values.prefix(limit))
        }
        func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
            guard let result = try value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        func explicitlyEnabled(_ element: AXUIElement) throws -> Bool {
            guard let value = try value(element, kAXEnabledAttribute) else { return false }
            return (value as? NSNumber)?.boolValue ?? false
        }
    }
}
