import AppKit
import SwiftUI
import Combine
import Carbon
import Quartz
import ServiceManagement

@MainActor
final class HubPanel: NSPanel {
    weak var hubDelegate: AppDelegate?
    weak var clipboardModel: HubModel?
    var allowsScreenTopOverlap = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsScreenTopOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if HubMarqueeSelectionState.isSelecting { HubMarqueeSelectionState.cancel(); return }
        if HubFileDragState.isDragging || HubWorkspaceDragState.isDragging { return }
        hubDelegate?.hidePanel()
    }
    private var canHandleFileClipboard: Bool {
        isKeyWindow && attachedSheet == nil && NSApp.modalWindow == nil &&
            !HubInlinePreviewFocus.contains(firstResponder) && !(firstResponder is NSTextView) &&
            !HubFileDragState.isDragging && !HubWorkspaceDragState.isDragging && !HubMarqueeSelectionState.isSelecting
    }
    @objc func copy(_ sender: Any?) {
        guard canHandleFileClipboard else { return }
        clipboardModel?.copySelectedFiles()
    }
    @objc func paste(_ sender: Any?) {
        guard canHandleFileClipboard else { return }
        clipboardModel?.pasteFiles()
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canHandleFileClipboard && clipboardModel?.selectedURLs.isEmpty == false }
        if item.action == #selector(paste(_:)) { return canHandleFileClipboard && clipboardModel?.canPasteFiles == true }
        return super.validateUserInterfaceItem(item)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = hubDelegate
        panel.delegate = hubDelegate
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var model: HubModel!
    private var music: HubQQMusicController!
    private let sharing = HubAirDropController()
    private let sharingWindows = HubSharingWindowSuspension()
    private var updater: FileDockUpdater!
    private var pendingTermination: Task<Void, Never>?
    private var panel: HubPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var notchClickMonitors: [Any] = []
    private var hoverActivation = HubHoverActivation()
    private var hoverDismissal = HubHoverDismissal()
    private var fileDragDismissal = HubFileDragDismissal()
    private var fileDragReentry = HubFileDragReentry()
    private let triggerSuppression = HubTriggerSuppressionMonitor()
    private var hoverSettingsSignature: String?
    private var windowAttachment = HubWindowAttachmentPolicy()
    private var windowDragSession: (origin: NSPoint, wasAttached: Bool, corner: String?)?
    private var windowDragReleased = false
    private var anchoredCorner: String?
    private var cornerKeepAliveFrame: NSRect?
    private var lastRefresh = Date.distantPast
    private var lastSettingsData: Data?
    private var previewURLs: [URL] = []
    private var shownFromHover = false
    private var restoringSize = false
    private var registeredTriggerMode: String?
    private var registeredShortcuts: HubGlobalShortcuts?
    private var shortcutRecordingActive = false
    private var registeredActions: [UInt32: Bool] = [:]
    private var nextHotKeyID: UInt32 = 0
    private var panelPointerEntered = false
    private var surface: HubNotchSurface!
    private var bridgePanel: NSPanel!
    private var bridgeView: HubNotchBridgeView!
    private var attachedToNotch = false
    private let auxiliaryWindowLevels = HubAuxiliaryWindowLevels()
    private var desiredVisible = false
    private var transitionGeneration = 0
    private var attachedScreenNumber: NSNumber?
    private let presentation = HubPresentationState()

    private var embeddedAtNotch: Bool {
        attachedToNotch && model.settings.resolvedNotchIntegrationStyle == "embedded"
    }

    func applicationDidHide(_ notification: Notification) {
        // Keep the presentation state aligned with the system's Hide command.
        // Otherwise the next shortcut would try to close an invisible panel.
        hidePanel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let fixture = CommandLine.arguments.firstIndex(of: "--data").flatMap { index -> URL? in
            guard CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        model = HubModel(storageURL: fixture, demo: demo)
        model.externalFileWorkInProgress = { HubImportActivity.isBusy }
        sharing.onError = { [weak self] in self?.model.errorMessage = $0 }
        sharing.presentationStateDidChange = { [weak self] in self?.setSharingPresentation($0) }
        sharing.$state.sink { [weak self] state in
            self?.model.sharingInProgress = state != .idle
        }.store(in: &subscriptions)
        music = HubQQMusicController()
        music.setPlayerSelection(HubMusicPlayerSelection(rawValue: model.settings.resolvedMusicPlayer) ?? .automatic)
        updater = FileDockUpdater()
        updater.presentationBusy = { [weak self] in
            self?.sharing.isBusy == true || HubWindowPresentation.isPresentingDialog || NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
        }
        updater.filesBusy = { [weak self] in
            guard let self else { return false }
            return self.model.stagingTransferInProgress || self.model.fileOperationsInProgress > 0 || self.sharing.isBusy ||
                HubImportActivity.isBusy || HubFileDragState.isDragging || HubWorkspaceDragState.isDragging ||
                HubMarqueeSelectionState.isSelecting || HubWindowPresentation.isPresentingDialog || NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
        }
        updater.$sessionInProgress.sink { [weak self] active in
            guard active else { return }
            self?.setPanelLevel(.normal)
        }.store(in: &subscriptions)
        music.setEnabled(model.settings.resolvedQQMusicEnabled)
        if model.isInitialConfiguration && model.settings.launchAtLogin && fixture == nil && !demo {
            setLoginItem(true)
        } else { model.settings.launchAtLogin = SMAppService.mainApp.status == .enabled }
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configurePanel()
        configureMenuBar()
        configureHotKeys()
        configureNotifications()
        configureKeyboard()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.wakeFromNotchClick() }) { notchClickMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in self?.wakeFromNotchClick(); return event }) { notchClickMonitors.append(monitor) }
        model.$settings.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }.store(in: &subscriptions)
        model.$pinned.sink { [weak self] pinned in
            self?.windowAttachment.didChangePin(pinned)
        }.store(in: &subscriptions)
        let hoverTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        hoverTimer.tolerance = 0.003
        RunLoop.main.add(hoverTimer, forMode: .common)
        timer = hoverTimer
        applySettings()
        showPanel(atCursor: false)
    }

    private func configurePanel() {
        panel = HubPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.hubDelegate = self
        panel.clipboardModel = model
        panel.delegate = self
        panel.title = "FileDock"
        panel.identifier = NSUserInterfaceItemIdentifier("FileDockPanel")
        panel.minSize = NSSize(width: 600, height: 300)
        panel.maxSize = NSSize(width: 1600, height: 1100)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        let root = HubView(model: model, presentation: presentation, music: music, onSettings: { [weak self] in self?.showSettings() },
                           onClose: { [weak self] in self?.hidePanel() })
        surface = HubNotchSurface(contentView: NSHostingView(rootView: root))
        panel.contentView = surface
        surface.configure(attached: false, sourceWidth: 186, bodyColor: bodyColor, reduceMotion: reduceMotion)
        surface.setPresented(false, animated: false) {}
        bridgePanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bridgePanel.backgroundColor = .clear
        bridgePanel.isOpaque = false
        bridgePanel.hasShadow = false
        bridgePanel.ignoresMouseEvents = true
        bridgePanel.hidesOnDeactivate = false
        bridgePanel.isReleasedWhenClosed = false
        bridgePanel.level = .statusBar
        bridgePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        bridgeView = HubNotchBridgeView(frame: .zero)
        bridgePanel.contentView = bridgeView
        bridgeView.configure(sourceWidth: 186, bodyColor: bodyColor, reduceMotion: reduceMotion)
        bridgeView.setPresented(false, animated: false) {}
        let animationChanged: () -> Void = { [weak self] in
            guard let self else { return }
            self.presentation.setSurfaceAnimating(self.surface.isAnimating || self.bridgeView.isAnimating)
        }
        surface.animationStateChanged = animationChanged
        bridgeView.animationStateChanged = animationChanged
        surface.effectiveAppearanceDidChange = { [weak self] in self?.updateSurfaceStyle() }
        HubWindowPresentation.backgroundWindows = { [weak self] in
            guard let self else { return [] }
            let preview = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
            let color = NSColorPanel.sharedColorPanelExists ? NSColorPanel.shared : nil
            return [self.panel, self.bridgePanel, self.settingsWindow, preview, color]
                .compactMap { $0 }.filter(\.isVisible)
        }
        HubWindowPresentation.modalStateDidChange = { [weak self] active in
            guard let self else { return }
            if active {
                self.suspendHotKeys()
            } else {
                self.configureHotKeys()
                self.updatePanelLevel()
            }
        }
    }

    private func configureMainMenu() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FileDock")
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "收起窗口", action: #selector(hideApplicationWindows), keyEquivalent: "h")
        hide.target = self
        appMenu.addItem(hide)
        appMenu.addItem(withTitle: "退出 FileDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menuBar.addItem(editItem)
        NSApp.mainMenu = menuBar
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = FileDockMenuBarIcon.make()
            button.image?.isTemplate = true
            button.toolTip = "FileDock · 右键打开菜单"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "显示 / 隐藏面板", action: #selector(toggleFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "在光标位置显示", action: #selector(showAtCursor), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            menu.addItem(withTitle: "使用说明", action: #selector(showHelp), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 FileDock", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { togglePanel(atCursor: false) }
    }

    @objc private func toggleFromMenu() { togglePanel(atCursor: false) }
    @objc private func showAtCursor() { togglePanel(atCursor: true) }
    @objc private func hideApplicationWindows() {
        guard !hasActiveDialog else { return }
        hidePanel()
        settingsWindow?.orderOut(nil)
        music.setConfigurationVisible(false)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func suspendHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        registeredActions.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
    }

    private func configureHotKeys() {
        suspendHotKeys()
        registeredTriggerMode = model.settings.triggerMode
        let shortcuts = model.settings.resolvedGlobalShortcuts
        registeredShortcuts = shortcuts
        let topLabel = shortcuts.top.map { " · \($0.displayString) 显示 / 隐藏" } ?? ""
        statusItem?.button?.toolTip = "FileDock\(topLabel) · 右键打开菜单"
        guard !HubWindowPresentation.isPresentingDialog, !shortcutRecordingActive else { return }
        model.shortcutRegistrationErrors = [:]
        guard model.settings.triggerMode != "hover" else { return }
        defer { preserveMenuBarAccess() }
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard result == noErr else { return result }
            guard identity.signature == 0x46485250 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let keyID = identity.id
            DispatchQueue.main.async { owner.receivedHotKey(keyID) }
            return noErr
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
                                           Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard installed == noErr else {
            model.shortcutRegistrationErrors = ["top": "无法注册快捷键（\(installed)），可通过菜单栏呼出。"]
            return
        }
        var accepted: [HubShortcut] = []
        for (name, shortcut, atCursor) in [("top", shortcuts.top, false), ("cursor", shortcuts.cursor, true)] {
            guard let shortcut else { continue }
            if let error = shortcut.validationError {
                model.shortcutRegistrationErrors[name] = error
                continue
            }
            guard !accepted.contains(shortcut) else {
                model.shortcutRegistrationErrors[name] = "两个呼出动作不能使用同一个快捷键。"
                continue
            }
            accepted.append(shortcut)
            nextHotKeyID &+= 1
            let id = nextHotKeyID
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x46485250, id: id),
                                            GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                hotKeys.append(ref)
                registeredActions[id] = atCursor
            } else {
                model.shortcutRegistrationErrors[name] = "\(shortcut.displayString) 未能注册，可能已被系统或其他应用占用。请录制其他组合。"
            }
        }
    }

    private func receivedHotKey(_ id: UInt32) {
        guard !shortcutRecordingActive, !hasActiveDialog, !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging, model.settings.triggerMode != "hover",
              let atCursor = registeredActions[id] else { return }
        togglePanel(atCursor: atCursor)
    }

    private func preserveMenuBarAccess() {
        guard !shortcutRecordingActive, !HubWindowPresentation.isPresentingDialog,
              !model.settings.showMenuBarIcon, model.settings.triggerMode == "keyboard", hotKeys.isEmpty else { return }
        model.settings.showMenuBarIcon = true
        statusItem?.isVisible = true
    }

    private func configureNotifications() {
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeAuxiliaryWindows() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: hubWindowDragWillBegin, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.panel,
                      self.desiredVisible, !self.hasActiveDialog else { return }
                self.windowDragSession = (self.panel.frame.origin, self.attachedToNotch, self.anchoredCorner)
                self.windowDragReleased = false
            }
        })
        for name in ["HubPreview", "HubShare", "HubAirDrop", "HubAirDropFiles", "HubSettings", "HubMusicSettings", "HubLaunchAtLogin", "HubHelp", "HubShortcutRecording"] {
            let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case "HubPreview": self.showPreview(note.userInfo?["urls"] as? [URL] ?? self.model.selectedURLs)
                    case "HubShare": self.share(note.userInfo?["urls"] as? [URL] ?? self.model.selectedURLs)
                    case "HubAirDrop": self.sendAirDrop(note.userInfo?["urls"] as? [URL] ?? self.model.selectedURLs)
                    case "HubAirDropFiles":
                        // A drop captures its own URLs. Never replace an empty
                        // or stale batch with the current selection or a picker.
                        guard let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
                        self.sendAirDrop(urls)
                    case "HubSettings": self.showSettings()
                    case "HubMusicSettings":
                        self.showSettings()
                        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("HubSelectMusicSettings"), object: nil) }
                    case "HubLaunchAtLogin": self.setLoginItem(note.userInfo?["enabled"] as? Bool ?? false)
                    case "HubShortcutRecording":
                        self.shortcutRecordingActive = note.userInfo?["active"] as? Bool ?? false
                        if self.shortcutRecordingActive { self.suspendHotKeys() }
                        else { self.configureHotKeys() }
                    default: self.showHelp()
                    }
                }
            }
            notificationTokens.append(token)
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverActivation.reset()
                self.hoverDismissal.reset()
                self.triggerSuppression.refresh()
                guard self.desiredVisible else { return }
                if self.attachedToNotch { self.layoutAttachedPanel(on: self.attachmentScreen) }
                else if self.anchoredCorner != nil { self.layoutCornerPanel(on: self.attachmentScreen) }
            }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateSurfaceStyle()
                if self.reduceMotion, self.desiredVisible {
                    self.surface.cancelAnimationsAndShow()
                    self.bridgeView.cancelAnimationsAndShow()
                }
            }
        })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didWakeNotification {
                        self.hoverActivation.reset()
                        self.hoverDismissal.reset()
                        self.triggerSuppression.refresh()
                    }
                    self.model.refresh()
                }
            }
            notificationTokens.append(token)
        }
    }

    private func configureKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var handled = false
            MainActor.assumeIsolated {
                handled = self?.handleKeyboard(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleKeyboard(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if panel.isKeyWindow, HubMarqueeSelectionState.isSelecting {
            if event.keyCode == UInt16(kVK_Escape) { HubMarqueeSelectionState.cancel() }
            return true
        }
        guard !shortcutRecordingActive, !hasActiveDialog, !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging, panel.isKeyWindow else { return false }
        if flags.contains(.command), event.charactersIgnoringModifiers == "," { showSettings(); return true }
        if flags.contains(.command), flags.contains(.shift),
           let character = event.charactersIgnoringModifiers, character == "[" || character == "]" {
            switchWorkspace(character == "[" ? -1 : 1); return true
        }
        if HubInlinePreviewFocus.contains(panel.firstResponder) || panel.firstResponder is NSTextView { return false }
        if event.keyCode == UInt16(kVK_Escape) { hidePanel(); return true }
        return false
    }

    private func switchWorkspace(_ delta: Int) {
        model.nextWorkspace(delta)
    }

    func showPanel(atCursor: Bool) {
        guard !hasActiveDialog else { return }
        fileDragReentry.reset()
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screenContaining(pointer, among: screens) ?? NSScreen.main ?? screens.first
        guard let screen else { return }
        let wasVisible = panel.isVisible
        desiredVisible = true
        presentation.previewVisible = true
        music.setVisible(true)
        transitionGeneration += 1
        anchoredCorner = !atCursor && model.settings.hotCorner != "notch" ? model.settings.hotCorner : nil
        cornerKeepAliveFrame = nil
        attachedToNotch = !atCursor && anchoredCorner == nil
        if !atCursor { model.pinned = windowAttachment.didAttach(currentlyPinned: model.pinned) }
        panel.allowsScreenTopOverlap = embeddedAtNotch
        if atCursor {
            presentation.header = .init()
            updatePanelLevel()
            bridgePanel.orderOut(nil)
            bridgeView.setPresented(false, animated: false) {}
            let frame = screen.visibleFrame
            let width = min(max(model.settings.width, 600), frame.width - 24)
            let height = min(max(model.settings.height, 300), frame.height - 24)
            restoringSize = true
            panel.setFrame(NSRect(x: min(max(pointer.x - width / 2, frame.minX + 12), frame.maxX - width - 12),
                                  y: min(max(pointer.y - height - 14, frame.minY + 12), frame.maxY - height - 4),
                                  width: width, height: height), display: true)
            restoringSize = false
            updateSurfaceStyle()
        } else if anchoredCorner != nil { layoutCornerPanel(on: screen) }
        else { layoutAttachedPanel(on: screen) }
        if !wasVisible {
            surface.setPresented(false, animated: false) {}
            bridgeView.setPresented(false, animated: false) {}
        }
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        if attachedToNotch && !embeddedAtNotch {
            bridgePanel.alphaValue = 1
            bridgePanel.orderFrontRegardless()
            bridgeView.setPresented(true, animated: true) {}
        }
        surface.setPresented(true, animated: true) { [weak self] in
            guard let self, self.desiredVisible else { return }
            self.panel.invalidateShadow()
            // Show the existing snapshot immediately. File-system work must not
            // postpone the first animation frame after the hover deadline.
            guard !self.hasActiveDialog else { return }
            self.lastRefresh = Date()
            self.model.refreshInBackground(ifDue: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        hoverDismissal.reset()
        panelPointerEntered = false
        fileDragDismissal.reset()
    }

    func hidePanel() {
        guard desiredVisible, !hasActiveDialog else { return }
        fileDragReentry.reset()
        HubMarqueeSelectionState.cancel()
        desiredVisible = false
        cornerKeepAliveFrame = nil
        music.setVisible(false)
        transitionGeneration += 1
        let generation = transitionGeneration
        panel.ignoresMouseEvents = true
        var remainingSurfaces = 2
        let finish: () -> Void = { [weak self] in
            guard let self, self.transitionGeneration == generation, !self.desiredVisible else { return }
            remainingSurfaces -= 1
            guard remainingSurfaces == 0 else { return }
            self.panel.orderOut(nil)
            self.presentation.previewVisible = false
            self.bridgePanel.orderOut(nil)
            self.panel.ignoresMouseEvents = false
        }
        surface.setPresented(false, animated: true, completion: finish)
        bridgeView.setPresented(false, animated: attachedToNotch && !embeddedAtNotch, completion: finish)
        shownFromHover = false
        hoverDismissal.reset()
        fileDragDismissal.reset()
        hoverActivation.dismiss(regionID: hoveredRegionID, now: ProcessInfo.processInfo.systemUptime)
    }

    private func togglePanel(atCursor: Bool) {
        guard !hasActiveDialog else { return }
        shownFromHover = false
        if desiredVisible { hidePanel() } else { showPanel(atCursor: atCursor) }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var attachmentScreen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == attachedScreenNumber }
            ?? panel.screen ?? NSScreen.main
    }

    private var bodyColor: NSColor {
        let dark = model.settings.resolvedAppearance == "dark" || (model.settings.resolvedAppearance == "system" && panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if model.settings.resolvedBackgroundTheme == "liquidGlass" {
            return NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1)
        }
        let text = (dark ? model.settings.darkBackgroundHex : model.settings.lightBackgroundHex).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let hex = UInt32(text, radix: 16) else { return .windowBackgroundColor }
        return NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private func updateSurfaceStyle(sourceWidth: CGFloat? = nil) {
        surface.configure(attached: attachedToNotch, sourceWidth: sourceWidth ?? bridgeView?.sourceWidth ?? 186,
                          bodyColor: bodyColor, reduceMotion: reduceMotion, animationSpeed: model.settings.resolvedAnimationSpeed,
                          embedded: embeddedAtNotch, liquidGlass: model.settings.resolvedBackgroundTheme == "liquidGlass")
        bridgeView?.configure(sourceWidth: sourceWidth ?? bridgeView?.sourceWidth ?? 186,
                              bodyColor: bodyColor, reduceMotion: reduceMotion, animationSpeed: model.settings.resolvedAnimationSpeed,
                              liquidGlass: model.settings.resolvedBackgroundTheme == "liquidGlass")
    }

    private func layoutAttachedPanel(on screen: NSScreen?) {
        guard let screen else { return }
        let wasEmbedded = presentation.header.embedded
        panel.allowsScreenTopOverlap = embeddedAtNotch
        if wasEmbedded != embeddedAtNotch && desiredVisible && panel.isVisible {
            surface.cancelAnimationsAndShow()
            bridgeView.setPresented(false, animated: false) {}
        }
        if embeddedAtNotch {
            attachedScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            updatePanelLevel()
            let placement = HubEmbeddedPlacement.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                      safeTop: screen.safeAreaInsets.top,
                                                      leftAuxiliary: screen.auxiliaryTopLeftArea, rightAuxiliary: screen.auxiliaryTopRightArea,
                                                      requestedSize: NSSize(width: model.settings.width, height: model.settings.height))
            restoringSize = true
            if panel.frame != placement.bodyFrame { panel.setFrame(placement.bodyFrame, display: true) }
            restoringSize = false
            presentation.header = .init(embedded: true, exclusionWidth: placement.headerExclusionWidth,
                                        topInset: placement.topInset, split: placement.usesSplitHeader)
            bridgePanel.orderOut(nil)
            bridgeView.setPresented(false, animated: false) {}
            updateSurfaceStyle(sourceWidth: placement.sourceWidth)
            updatePanelLevel()
            return
        }
        presentation.header = .init()
        let placement = HubNotchPlacement.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                               safeTop: screen.safeAreaInsets.top,
                                               leftAuxiliary: screen.auxiliaryTopLeftArea, rightAuxiliary: screen.auxiliaryTopRightArea,
                                               requestedSize: NSSize(width: model.settings.width, height: model.settings.height))
        attachedScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        restoringSize = true
        if panel.frame != placement.bodyFrame { panel.setFrame(placement.bodyFrame, display: true) }
        if bridgePanel.frame != placement.bridgeFrame { bridgePanel.setFrame(placement.bridgeFrame, display: true) }
        restoringSize = false
        updateSurfaceStyle(sourceWidth: placement.sourceWidth)
        updatePanelLevel()
        if wasEmbedded && desiredVisible && panel.isVisible {
            bridgePanel.orderFrontRegardless()
            bridgeView.setPresented(true, animated: false) {}
        }
    }

    private func layoutCornerPanel(on screen: NSScreen?) {
        guard let screen, let corner = anchoredCorner,
              let placement = HubCornerPlacement.make(corner: corner, screenFrame: screen.frame,
                  visibleFrame: screen.visibleFrame,
                  requestedSize: NSSize(width: model.settings.width, height: model.settings.height)) else { return }
        attachedToNotch = false
        panel.allowsScreenTopOverlap = false
        presentation.header = .init()
        attachedScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        cornerKeepAliveFrame = placement.keepAliveFrame
        bridgePanel.orderOut(nil)
        bridgeView.setPresented(false, animated: false) {}
        restoringSize = true
        panel.setFrame(placement.bodyFrame, display: true)
        restoringSize = false
        updateSurfaceStyle()
        updatePanelLevel()
    }

    private func updatePanelLevel() {
        guard panel != nil else { return }
        // The modal coordinator owns levels until its scoped restoration ends.
        guard !HubWindowPresentation.isPresentingDialog else { return }
        if updater?.sessionInProgress == true { setPanelLevel(.normal); return }
        let level = HubWindowPresentation.browserLevel(embedded: embeddedAtNotch)
        setPanelLevel(level)
    }

    private func setPanelLevel(_ level: NSWindow.Level) {
        let effective = embeddedAtNotch ? HubWindowPresentation.browserLevel(embedded: true) : level
        if panel.level != effective { panel.level = effective }
        synchronizeAuxiliaryWindows()
        if QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(), preview.isVisible {
            let previewLevel = HubWindowPresentation.previewLevel(browserLevel: effective)
            if preview.level != previewLevel { preview.level = previewLevel }
        }
    }

    private func synchronizeAuxiliaryWindows() {
        guard panel != nil, !HubWindowPresentation.isPresentingDialog else { return }
        var windows = [settingsWindow].compactMap { $0 }
        if NSColorPanel.sharedColorPanelExists { windows.append(NSColorPanel.shared) }
        windows.append(contentsOf: [NSApp.modalWindow, panel.attachedSheet, settingsWindow?.attachedSheet].compactMap { $0 })
        if updater?.sessionInProgress == true {
            windows.append(contentsOf: NSApp.windows.filter {
                $0.isVisible && $0 !== panel && $0 !== bridgePanel &&
                    !($0 is QLPreviewPanel)
            })
        }
        let excluded = [panel, bridgePanel, statusItem?.button?.window].compactMap { $0 }
        auxiliaryWindowLevels.synchronize(windows, excluding: excluded, above: panel.level)
    }

    func windowWillMove(_ notification: Notification) {
        guard !restoringSize, let window = notification.object as? NSWindow, window === panel,
              desiredVisible, !panel.inLiveResize, attachedToNotch || anchoredCorner != nil else { return }
        attachedToNotch = false
        anchoredCorner = nil
        cornerKeepAliveFrame = nil
        presentation.beginWindowMove(pinned: model.pinned)
        model.pinned = windowAttachment.didDetach(currentlyPinned: model.pinned)
        hoverDismissal.reset()
        panel.allowsScreenTopOverlap = false
        updatePanelLevel()
        bridgePanel.orderOut(nil)
        bridgeView.setPresented(false, animated: false) {}
        surface.cancelAnimationsAndShow()
        updateSurfaceStyle()
    }

    private func finishWindowDragIfReleased() {
        guard let session = windowDragSession else {
            if presentation.windowMoving && NSEvent.pressedMouseButtons & 1 == 0 { presentation.endWindowMove(reduceMotion: reduceMotion) }
            return
        }
        guard (NSEvent.pressedMouseButtons & 1) == 0 else { windowDragReleased = false; return }
        // performDrag returns immediately and may not deliver mouseUp. The
        // common-mode timer observes release, then lets the final frame settle.
        guard windowDragReleased else { windowDragReleased = true; return }
        windowDragSession = nil
        windowDragReleased = false
        presentation.endWindowMove(reduceMotion: reduceMotion)
        guard desiredVisible, !attachedToNotch, anchoredCorner == nil, !hasActiveDialog, let screen = panel.screen else { return }
        let moved = panel.frame.origin != session.origin
        if !moved, let corner = session.corner {
            anchoredCorner = corner
            model.pinned = windowAttachment.didAttach(currentlyPinned: model.pinned)
            hoverDismissal.reset()
            layoutCornerPanel(on: screen)
            return
        }
        guard (moved && model.settings.hotCorner == "notch" && HubWindowAttachmentPolicy.shouldReattach(frame: panel.frame,
                    screenVisibleFrame: screen.visibleFrame, sourceWidth: bridgeView.sourceWidth)) ||
                (!moved && session.wasAttached) else { return }
        attachedToNotch = true
        model.pinned = windowAttachment.didAttach(currentlyPinned: model.pinned)
        hoverDismissal.reset()
        layoutAttachedPanel(on: screen)
        if !embeddedAtNotch {
            bridgePanel.orderFrontRegardless()
            bridgeView.setPresented(true, animated: true) {}
        }
    }

    private func wakeFromNotchClick() {
        guard let model, model.settings.usesNotchClickToWake,
              model.settings.triggerMode != "keyboard", !desiredVisible,
              windowDragSession == nil, settingsWindow?.isVisible != true,
              !hasActiveDialog, !NSMenuHasTrackingMenu(),
              !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging else { return }
        let pointer = NSEvent.mouseLocation
        guard hoverActivationRegion(at: pointer).id != nil,
              !triggerSuppression.shouldSuppressHover(at: pointer,
                blockedBundleIDs: model.settings.resolvedBlockedApplicationBundleIDs,
                suppressFullScreen: model.settings.resolvedSuppressHoverInFullScreen) else { return }
        shownFromHover = true
        showPanel(atCursor: false)
    }

    private func tick() {
        HubFileDragState.reconcile(mousePressed: NSEvent.pressedMouseButtons & 1 != 0, now: ProcessInfo.processInfo.systemUptime)
        guard let model, let panel else { return }
        finishWindowDragIfReleased()
        updatePanelLevel()
        let fileDrag = HubFileDragState.isDragging || (presentation.fileDragActive && (NSEvent.pressedMouseButtons & 1) != 0)
        presentation.setFileDragActive(fileDrag)
        let now = Date()
        let pointer = NSEvent.mouseLocation
        let regionID = hoveredRegionIdentifier(at: pointer)
        let hovering = regionID != nil
        let activationRegion = hoverActivationRegion(at: pointer)
        let mousePressed = (NSEvent.pressedMouseButtons & 1) != 0
        let fileSessionID = HubFileDragState.current?.id
        let canReturnFromFileDrag = fileDragReentry.isArmed && fileSessionID != nil && mousePressed &&
            model.settings.resolvedHideOnFileDragExit && model.settings.triggerMode != "keyboard" &&
            !desiredVisible && windowDragSession == nil && settingsWindow?.isVisible != true && !hasActiveDialog &&
            !HubWorkspaceDragState.isDragging &&
            !HubFileDragDismissal.menuBlocksDismissal(tracking: NSMenuHasTrackingMenu(), sessionID: fileSessionID, mousePressed: mousePressed)
        if fileDragReentry.update(sessionID: fileSessionID, mousePressed: mousePressed, regionID: activationRegion.id,
                                   now: ProcessInfo.processInfo.systemUptime, delay: model.settings.hoverDelay,
                                   strictDwell: activationRegion.strictDwell,
                                   enabled: canReturnFromFileDrag && !triggerSuppression.shouldSuppressHover(at: pointer,
                                    blockedBundleIDs: model.settings.resolvedBlockedApplicationBundleIDs,
                                    suppressFullScreen: model.settings.resolvedSuppressHoverInFullScreen)) {
            shownFromHover = true
            showPanel(atCursor: false)
        }
        let hoverEnabled = model.settings.triggerMode != "keyboard" && !desiredVisible && windowDragSession == nil &&
            settingsWindow?.isVisible != true && !hasActiveDialog && !NSMenuHasTrackingMenu() && !HubFileDragState.isDragging && !HubWorkspaceDragState.isDragging &&
            !triggerSuppression.shouldSuppressHover(at: pointer,
                blockedBundleIDs: model.settings.resolvedBlockedApplicationBundleIDs,
                suppressFullScreen: model.settings.resolvedSuppressHoverInFullScreen)
        if hoverActivation.update(regionID: activationRegion.id, now: ProcessInfo.processInfo.systemUptime,
                                  delay: model.settings.hoverDelay, enabled: hoverEnabled && !model.settings.usesNotchClickToWake,
                                  strictDwell: activationRegion.strictDwell) {
            shownFromHover = true
            showPanel(atCursor: false)
        }
        guard !hasActiveDialog else { hoverDismissal.reset(); fileDragDismissal.reset(); return }
        if panel.isVisible, desiredVisible {
            guard !surface.isAnimating, !bridgeView.isAnimating else { hoverDismissal.reset(); fileDragDismissal.reset(); return }
            let localPoint = surface.convert(panel.convertPoint(fromScreen: pointer), from: nil)
            let insideSurface = surface.containsVisiblePoint(localPoint)
            let bridgePoint = bridgeView.convert(bridgePanel.convertPoint(fromScreen: pointer), from: nil)
            let insideBridge = attachedToNotch && !embeddedAtNotch && bridgeView.containsVisiblePoint(bridgePoint)
            if insideSurface { panelPointerEntered = true }
            if !HubFileDragState.isDragging, !HubWorkspaceDragState.isDragging, !HubMarqueeSelectionState.isSelecting, !panel.inLiveResize,
               windowDragSession == nil, now.timeIntervalSince(lastRefresh) > 2 {
                model.refreshInBackground(ifDue: true); lastRefresh = now
            }
            let menuOpen = HubFileDragDismissal.menuBlocksDismissal(tracking: NSMenuHasTrackingMenu(), sessionID: fileSessionID, mousePressed: mousePressed)
            let sheetOpen = hasActiveDialog || menuOpen || HubInlineFileNameEditor.isEditing(in: panel)
            let previewVisible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
            let insideCornerPath = cornerKeepAliveFrame.map { HubHoverGeometry.containsTriggerPoint(pointer, in: $0) } ?? false
            let outside = !insideSurface && !insideBridge && !insideCornerPath && !panel.frame.insetBy(dx: -12, dy: -12).contains(pointer) && !hovering
            // Source ownership, pasteboard and native drag session remain alive
            // while the panel animates out. Never end/cancel the drag to hide it.
            // This explicit preference also allows pinned panels to make room.
            let dragOutside = !insideSurface && !insideBridge && !panel.frame.insetBy(dx: -12, dy: -12).contains(pointer)
            let canDismissDrag = model.settings.resolvedHideOnFileDragExit && !sheetOpen && !previewVisible &&
                settingsWindow?.isVisible != true && !HubWorkspaceDragState.isDragging && !HubMarqueeSelectionState.isSelecting &&
                !panel.inLiveResize && windowDragSession == nil
            if fileDragDismissal.update(sessionID: fileSessionID, mousePressed: mousePressed, outside: dragOutside,
                                        now: ProcessInfo.processInfo.systemUptime, delay: model.settings.resolvedAutoHideDelay,
                                        enabled: canDismissDrag) {
                hidePanel()
                if !desiredVisible, let fileSessionID { fileDragReentry.arm(sessionID: fileSessionID) }
                return
            }
            // Keyboard/menu entry stays until focus leaves or the pointer has entered.
            // A drag or resize starts a fresh delay after it ends, never during it.
            let canDismiss = !model.pinned && !sheetOpen && !previewVisible && settingsWindow?.isVisible != true &&
                !HubFileDragState.isDragging && !HubWorkspaceDragState.isDragging && !panel.inLiveResize && (NSEvent.pressedMouseButtons & 1) == 0 &&
                (shownFromHover || panelPointerEntered || !panel.isKeyWindow)
            if hoverDismissal.update(outside: outside, now: ProcessInfo.processInfo.systemUptime,
                                     delay: model.settings.resolvedAutoHideDelay, enabled: canDismiss) { hidePanel() }
        } else { hoverDismissal.reset(); fileDragDismissal.reset() }
    }

    private func hotspot(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        switch model.settings.hotCorner {
        case "topLeft": return NSRect(x: f.minX, y: f.maxY - 12, width: 18, height: 12)
        case "topRight": return NSRect(x: f.maxX - 18, y: f.maxY - 12, width: 18, height: 12)
        case "bottomLeft": return NSRect(x: f.minX, y: f.minY, width: 18, height: 12)
        case "bottomRight": return NSRect(x: f.maxX - 18, y: f.minY, width: 18, height: 12)
        default:
            let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
            let notchWidth = left.flatMap { l in right.map { $0.minX - l.maxX } } ?? 186
            let width = max(210, min(360, notchWidth + 32))
            let height = max(18, screen.safeAreaInsets.top + 10)
            return NSRect(x: f.midX - width / 2, y: f.maxY - height, width: width, height: height)
        }
    }

    private var hoveredRegionID: String? {
        hoveredRegionIdentifier(at: NSEvent.mouseLocation)
    }

    private func screenContaining(_ pointer: NSPoint, among screens: [NSScreen]) -> NSScreen? {
        // Prefer the normal half-open screen ownership at shared display edges;
        // include the exact outer top/right edge when the pointer is clamped there.
        // Determine ownership before eligibility, so an excluded display never
        // donates its shared boundary to an enabled neighbour.
        let allScreens = NSScreen.screens
        guard let owner = allScreens.first(where: { $0.frame.contains(pointer) })
            ?? allScreens.first(where: { HubHoverGeometry.containsTriggerPoint(pointer, in: $0.frame) }),
              screens.contains(where: { $0 === owner }) else { return nil }
        return owner
    }

    private func hoveredRegionIdentifier(at pointer: NSPoint) -> String? {
        let screens = model.settings.secondaryScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        guard let screen = screenContaining(pointer, among: screens),
              HubHoverGeometry.containsTriggerPoint(pointer, in: hotspot(on: screen)) else { return nil }
        return hoverRegionIdentifier(on: screen)
    }

    /// Entry uses the actual notch and cursor footprint. The expanded hotspot
    /// remains a separate keep-alive area while the panel is already visible.
    private func hoverActivationRegion(at pointer: NSPoint) -> (id: String?, strictDwell: Bool) {
        let screens = model.settings.secondaryScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        guard let screen = screenContaining(pointer, among: screens) else { return (nil, false) }
        let notch = model.settings.hotCorner == "notch" ? HubHoverGeometry.notchRect(
            screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea) : nil
        if model.settings.hotCorner == "notch", screen.safeAreaInsets.top > 0, notch == nil {
            // A temporarily unavailable notch geometry must not turn its
            // stricter entry rule back into a single-point trigger.
            return (nil, true)
        }
        guard HubHoverGeometry.containsTriggerPoint(pointer, in: hotspot(on: screen)) else { return (nil, notch != nil) }
        if let notch {
            // A fixed visible arrow footprint avoids transparent padding and
            // transient I-beam/resize cursors changing a stationary hover.
            guard let footprint = HubHoverCursor.footprint,
                  HubHoverGeometry.cursorQualifies(pointer: pointer, footprint: footprint, region: notch) else { return (nil, true) }
        }
        return (hoverRegionIdentifier(on: screen), notch != nil)
    }

    private func hoverRegionIdentifier(on screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "\(number?.stringValue ?? String(describing: screen.frame)):\(model.settings.hotCorner)"
    }

    private var hasActiveDialog: Bool {
        sharing.isBusy || updater?.sessionInProgress == true || HubWindowPresentation.isPresentingDialog || NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func applySettings() {
        guard model != nil, panel != nil else { return }
        music.setPlayerSelection(HubMusicPlayerSelection(rawValue: model.settings.resolvedMusicPlayer) ?? .automatic)
        music.setEnabled(model.settings.resolvedQQMusicEnabled)
        if registeredTriggerMode != model.settings.triggerMode || registeredShortcuts != model.settings.resolvedGlobalShortcuts { configureHotKeys() }
        preserveMenuBarAccess()
        let data = try? JSONEncoder().encode(model.settings)
        guard data != lastSettingsData else { return }
        lastSettingsData = data
        triggerSuppression.configure(enabled: model.settings.triggerMode != "keyboard",
                                     needsWindowProbe: model.settings.resolvedSuppressHoverInFullScreen)
        let triggerSignature = [String(model.settings.usesNotchClickToWake), model.settings.triggerMode, model.settings.hotCorner,
                                String(model.settings.secondaryScreens), String(model.settings.hoverDelay),
                                String(model.settings.resolvedSuppressHoverInFullScreen)] + model.settings.resolvedBlockedApplicationBundleIDs
        let signature = triggerSignature.joined(separator: "\u{0}")
        if signature != hoverSettingsSignature {
            hoverSettingsSignature = signature
            hoverActivation.cancelPendingDwell()
            triggerSuppression.refresh()
        }
        let appearance: NSAppearance?
        switch model.settings.resolvedAppearance {
        case "dark": appearance = NSAppearance(named: .darkAqua)
        case "light": appearance = NSAppearance(named: .aqua)
        default: appearance = nil
        }
        panel.appearance = appearance
        bridgePanel?.appearance = appearance
        settingsWindow?.appearance = appearance
        statusItem?.isVisible = model.settings.showMenuBarIcon
        updateSurfaceStyle()
        if desiredVisible, panel.isVisible, let screen = panel.screen {
            if attachedToNotch || anchoredCorner != nil {
                if model.settings.hotCorner == "notch" {
                    anchoredCorner = nil; cornerKeepAliveFrame = nil; attachedToNotch = true
                    layoutAttachedPanel(on: attachmentScreen)
                    if desiredVisible && !embeddedAtNotch {
                        bridgePanel.orderFrontRegardless()
                        bridgeView.setPresented(true, animated: false) {}
                    }
                } else {
                    anchoredCorner = model.settings.hotCorner
                    layoutCornerPanel(on: attachmentScreen)
                }
                return
            }
            let visible = screen.visibleFrame
            let width = min(max(600, model.settings.width), visible.width - 24)
            let height = min(max(300, model.settings.height), visible.height - 24)
            if abs(panel.frame.width - width) > 1 || abs(panel.frame.height - height) > 1 {
                let top = panel.frame.maxY
                let x = min(max(panel.frame.minX, visible.minX + 12), visible.maxX - width - 12)
                let y = min(max(top - height, visible.minY + 12), visible.maxY - height - 4)
                restoringSize = true
                panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
                restoringSize = false
            }
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, desiredVisible else { return }
        model.beginInteractiveResize()
        surface.cancelAnimationsAndShow()
        if attachedToNotch && !embeddedAtNotch { bridgeView.cancelAnimationsAndShow() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        model.endInteractiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        guard desiredVisible, !restoringSize, let window = notification.object as? NSWindow, window === panel else { return }
        var settings = model.settings
        settings.width = panel.frame.width
        settings.height = panel.frame.height
        model.settings = settings
        if attachedToNotch { layoutAttachedPanel(on: attachmentScreen) }
        else if anchoredCorner != nil { layoutCornerPanel(on: attachmentScreen) }
    }

    @objc private func checkForUpdates() {
        guard !hasActiveDialog else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
        setPanelLevel(.normal)
        updater.checkForUpdates()
    }

    @objc func showSettings() {
        guard !hasActiveDialog else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FileDock 设置"
            window.level = .floating
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: HubSettingsView(model: model, music: music, updater: updater))
            window.center()
            settingsWindow = window
            settingsWindow?.appearance = panel.appearance
        }
        setPanelLevel(.floating)
        music.setConfigurationVisible(true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            music.setConfigurationVisible(false)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { music.setConfigurationVisible(false) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { music.setConfigurationVisible(true) }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                model.errorMessage = "请在系统设置 → 通用 → 登录项中允许 FileDock。"
            }
        } catch { model.errorMessage = "开机启动设置失败：\(error.localizedDescription)" }
        model.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showPreview(_ urls: [URL]) {
        guard !hasActiveDialog else { return }
        previewURLs = HubInlinePreviewPolicy.quickLookURLs(urls)
        if previewURLs.isEmpty {
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
            return
        }
        guard !previewURLs.isEmpty, let preview = QLPreviewPanel.shared() else { return }
        preview.dataSource = self
        preview.delegate = self
        preview.reloadData()
        updatePanelLevel()
        preview.level = HubWindowPresentation.previewLevel(browserLevel: panel.level)
        preview.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }

    private func share(_ urls: [URL]) {
        guard !hasActiveDialog else { return }
        guard canStartSharing else { return }
        guard !urls.isEmpty, let view = panel.contentView else { return }
        sharing.showPicker(urls, securityScopedURLs: model.securityScopesForSharing(urls),
                           relativeTo: NSRect(x: view.bounds.midX, y: 30, width: 1, height: 1), of: view,
                           allowsAirDrop: model.settings.resolvedAirDropEnabled)
    }

    private func sendAirDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !hasActiveDialog else {
            model.errorMessage = "请先完成或取消当前共享或对话框，再使用 AirDrop。"
            return
        }
        guard model.settings.resolvedAirDropEnabled else { return }
        guard canStartSharing else { return }
        sharing.send(urls, securityScopedURLs: model.securityScopesForSharing(urls), from: panel)
    }

    private var canStartSharing: Bool {
        guard model.fileOperationsInProgress == 0, !model.stagingTransferInProgress, !HubImportActivity.isBusy else {
            model.errorMessage = "请等待当前文件操作完成后再共享。"
            return false
        }
        return true
    }

    private func setSharingPresentation(_ active: Bool) {
        hoverActivation.cancelPendingDwell()
        hoverDismissal.reset()
        if active {
            transitionGeneration += 1
            surface.cancelAnimationsAndShow()
            music.setVisible(false)
            // A Quick Look panel may own the same URLs. Closing it also avoids
            // restoring stale previews after the system sharing UI finishes.
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
            var windows = [panel, bridgePanel, settingsWindow].compactMap { $0 }
            if NSColorPanel.sharedColorPanelExists { windows.append(NSColorPanel.shared) }
            sharingWindows.begin(windows)
        } else {
            let restore = !NSApp.isHidden && pendingTermination == nil
            sharingWindows.end(restoring: restore)
            if !restore { desiredVisible = false; presentation.previewVisible = false }
            music.setVisible(restore && desiredVisible)
            panelPointerEntered = false
            lastRefresh = Date()
        }
    }

    @objc private func showHelp() {
        guard !hasActiveDialog else { return }
        let alert = NSAlert()
        alert.messageText = "FileDock"
        let shortcuts = model.settings.resolvedGlobalShortcuts
        let topKey = shortcuts.top?.displayString ?? "未设置"
        let cursorKey = shortcuts.cursor?.displayString ?? "未设置"
        alert.informativeText = """
        将鼠标移至设置中选择的触发位置，或使用全局快捷键。在触发位置呼出：\(topKey)；光标旁呼出：\(cursorKey)。可在「设置 → 快捷键」中点击录制。

        文件夹工作区实时浏览目录；收藏工作区只保留文件引用。拖入文件夹默认移动，按住 Option 则复制；拖入收藏仅添加引用。通过「＋ → 固定最近使用到右上角」开启最近使用时钟入口，最近打开的文件排在前面。

        收藏旁的暂存区保存文件引用，可拖入、拖出，或批量复制／移动到指定文件夹；清空仅移除引用。设置 → 文件与工作区可关闭暂存入口；设置 → 呼出与交互可添加黑名单，或在全屏时暂停鼠标自动呼出；手动快捷键不受影响。

        右上角的收藏星标可右键隐藏，并可从「＋」菜单恢复。右键工作区标签可切换「仅显示图标」。

        ⌘↑ 返回上级并选中刚离开的文件夹；⌘↓ 进入所选文件夹，所选文件则由默认应用打开。⌘[ / ⌘] 或 ⌥← / ⌥→ 后退、前进。

        双击打开 · 空格预览 · ⌘C 复制 · ⌘⌥C 复制路径 · ⌘⌫ 移到废纸篓（确认后） · ⌘⇧[ / ] 切换工作区。

        面板可以拖动和调整大小。图钉使其保持显示。设置提供外观、触发位置、延迟、滚动和图标大小。
        """
        alert.addButton(withTitle: "知道了")
        if panel.isVisible { alert.beginSheetModal(for: panel) } else { _ = HubWindowPresentation.runModal(alert) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // File transfers run off-main. Quitting (including install-on-quit)
        // waits for actual writes instead of terminating halfway through a move.
        sharing.cancelPreparation()
        guard model != nil, model.fileOperationsInProgress > 0 || model.stagingTransferInProgress || HubImportActivity.isBusy || sharing.isBusy else { return .terminateNow }
        if pendingTermination == nil {
            pendingTermination = Task { [weak self] in
                while let self, self.model.fileOperationsInProgress > 0 || self.model.stagingTransferInProgress || HubImportActivity.isBusy || self.sharing.isBusy {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                guard self != nil, !Task.isCancelled else { return }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(atCursor: false)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.save()
        music?.setVisible(false)
        timer?.invalidate()
        triggerSuppression.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        notchClickMonitors.forEach { NSEvent.removeMonitor($0) }
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

// NSMenu exposes no public global tracking flag. A visible menu is represented
// by the app's event loop mode, which also covers ordinary context menus.
@MainActor
private func NSMenuHasTrackingMenu() -> Bool { RunLoop.current.currentMode == .eventTracking }

@main
struct FileDockMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
