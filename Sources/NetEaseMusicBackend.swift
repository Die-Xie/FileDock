import AppKit
import ApplicationServices

// Use uniquely identified native playback menu items rather than assuming a
// scripting interface or forwarding global media keys to an unrelated player.
enum HubNetEaseMusicAccessibility {
    static let menuTitles = ["控制", "播放", "播放控制", "Control", "Controls", "Playback"]
    static func matches(_ action: HubQQMusicAction, title: String) -> Bool {
        switch action {
        case .toggle: return ["播放", "暂停", "播放/暂停", "播放 / 暂停", "播放／暂停", "Play", "Pause", "Play/Pause", "Play / Pause"].contains(title)
        case .previous: return ["上一首", "上一曲", "Previous", "Previous Track"].contains(title)
        case .next: return ["下一首", "下一曲", "Next", "Next Track"].contains(title)
        }
    }
    static func uniqueCommand(_ action: HubQQMusicAction, in items: [(role: String, title: String, enabled: Bool)]) -> Int? {
        let matches = items.indices.filter { items[$0].role == kAXMenuItemRole && items[$0].enabled && Self.matches(action, title: items[$0].title) }
        return matches.count == 1 ? matches[0] : nil
    }
    static func state(_ title: String) -> Bool? {
        if ["暂停", "Pause"].contains(title) { return true }
        if ["播放", "Play"].contains(title) { return false }
        return nil
    }
    static func track(from windowTitle: String) -> (title: String, artist: String)? {
        // Only parse an explicitly branded now-playing title. A general window
        // title or playlist heading must never be presented as a song.
        for suffix in [" - 网易云音乐", " – 网易云音乐", " - NetEase Cloud Music"] where windowTitle.hasSuffix(suffix) {
            let value = String(windowTitle.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = value.range(of: " - ", options: .backwards) else { return nil }
            let title = String(value[..<separator.lowerBound]), artist = String(value[separator.upperBound...])
            guard !title.isEmpty, !artist.isEmpty else { return nil }
            return (title, artist)
        }
        return nil
    }
}

final class HubNetEaseMusicBackend: HubQQMusicBackend {
    func probe() -> HubQQMusicProbe {
        let bundleID = HubMusicPlayer.neteaseMusic.bundleID
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
        return HubQQMusicProbe(installed: app != nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
                               pid: app?.processIdentifier, trusted: AXIsProcessTrusted())
    }
    func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func snapshot(for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        do {
            let reader = Reader()
            let capture = try playbackMenu(pid: pid, reader: reader)
            guard let toggle = HubNetEaseMusicAccessibility.uniqueCommand(.toggle, in: capture.labels) else {
                throw HubQQMusicFailure.unavailable(L("网易云音乐未提供可用的播放菜单，请打开主窗口。"))
            }
            var track: (title: String, artist: String)?
            let application = AXUIElementCreateApplication(pid)
            if let window = try reader.element(application, kAXMainWindowAttribute) {
                track = HubNetEaseMusicAccessibility.track(from: try reader.string(window, kAXTitleAttribute))
            }
            try validate(pid)
            return .success(HubQQMusicSnapshot(pid: pid, title: track?.title ?? "", artist: track?.artist ?? "",
                                               isPlaying: HubNetEaseMusicAccessibility.state(capture.labels[toggle].title)))
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable(L("网易云音乐暂时没有响应，请稍后重试。"))) }
    }
    func perform(_ action: HubQQMusicAction, for pid: pid_t) -> Result<HubQQMusicSnapshot, HubQQMusicFailure> {
        do {
            let reader = Reader(), capture = try playbackMenu(pid: pid, reader: reader)
            guard let index = HubNetEaseMusicAccessibility.uniqueCommand(action, in: capture.labels) else {
                throw HubQQMusicFailure.unavailable(L("网易云音乐当前未提供唯一、可用的播放控制。"))
            }
            let item = capture.items[index]
            let title = try reader.string(item, kAXTitleAttribute)
            guard title == capture.labels[index].title, HubNetEaseMusicAccessibility.matches(action, title: title),
                  try reader.enabled(item), try reader.string(item, kAXRoleAttribute) == kAXMenuItemRole else {
                throw HubQQMusicFailure.unavailable(L("网易云音乐播放菜单已变化，请重试。"))
            }
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(item, &actualPID) == .success, actualPID == pid else { throw HubQQMusicFailure.wrongTarget }
            try validate(pid)
            AXUIElementSetMessagingTimeout(item, 0.3)
            let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard error == .success else {
                throw error == .apiDisabled ? HubQQMusicFailure.permission : .unavailable(L("网易云音乐当前不接受播放控制。"))
            }
            return snapshot(for: pid)
        } catch let error as HubQQMusicFailure { return .failure(error) }
        catch { return .failure(.unavailable(L("网易云音乐暂时没有响应，请稍后重试。"))) }
    }
    private struct Menu {
        let items: [AXUIElement]
        let labels: [(role: String, title: String, enabled: Bool)]
    }
    private func playbackMenu(pid: pid_t, reader: Reader) throws -> Menu {
        try validate(pid)
        let application = AXUIElementCreateApplication(pid)
        guard let bar = try reader.element(application, kAXMenuBarAttribute) else {
            throw HubQQMusicFailure.unavailable(L("网易云音乐当前没有提供原生菜单。"))
        }
        var matches: [Menu] = []
        for menuItem in try reader.elements(bar, kAXChildrenAttribute, limit: 16) {
            guard try reader.string(menuItem, kAXRoleAttribute) == kAXMenuBarItemRole,
                  HubNetEaseMusicAccessibility.menuTitles.contains(try reader.string(menuItem, kAXTitleAttribute)) else { continue }
            for submenu in try reader.elements(menuItem, kAXChildrenAttribute, limit: 2) {
                guard try reader.string(submenu, kAXRoleAttribute) == kAXMenuRole else { continue }
                let items = try reader.elements(submenu, kAXChildrenAttribute, limit: 40)
                let labels = try items.map { (role: try reader.string($0, kAXRoleAttribute), title: try reader.string($0, kAXTitleAttribute), enabled: try reader.enabled($0)) }
                if HubNetEaseMusicAccessibility.uniqueCommand(.toggle, in: labels) != nil {
                    matches.append(Menu(items: items, labels: labels))
                }
            }
        }
        guard matches.count == 1 else {
            throw HubQQMusicFailure.unavailable(L("未找到网易云音乐的唯一播放菜单，请打开主窗口后重新检测。"))
        }
        return matches[0]
    }
    private func validate(_ pid: pid_t) throws {
        guard AXIsProcessTrusted() else { throw HubQQMusicFailure.permission }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw HubQQMusicFailure.notRunning }
        guard app.bundleIdentifier == HubMusicPlayer.neteaseMusic.bundleID else { throw HubQQMusicFailure.wrongTarget }
    }
    private final class Reader {
        private let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        private func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HubQQMusicFailure.unavailable(L("网易云音乐响应较慢，请稍后重试。")) }
            AXUIElementSetMessagingTimeout(element, 0.3)
            var result: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, attribute as CFString, &result) {
            case .success: return result
            case .noValue, .attributeUnsupported: return nil
            case .apiDisabled: throw HubQQMusicFailure.permission
            default: throw HubQQMusicFailure.unavailable(L("网易云音乐暂时没有响应，请稍后重试。"))
            }
        }
        func string(_ element: AXUIElement, _ attribute: String) throws -> String {
            (try value(element, attribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func enabled(_ element: AXUIElement) throws -> Bool { (try value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true }
        func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
            guard let result = try value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        func elements(_ element: AXUIElement, _ attribute: String, limit: Int) throws -> [AXUIElement] {
            Array((try value(element, attribute) as? [AXUIElement] ?? []).prefix(limit))
        }
    }
}
