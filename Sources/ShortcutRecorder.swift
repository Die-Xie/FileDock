import AppKit
import SwiftUI

@MainActor
struct HubShortcutRecorder: NSViewRepresentable {
    var name: String
    var shortcut: HubShortcut?
    var onChange: (HubShortcut?) -> Void

    func makeNSView(context: Context) -> RecordingButton {
        let button = RecordingButton()
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: RecordingButton, context: Context) {
        button.recordingName = name
        button.shortcut = shortcut
        button.onChange = onChange
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: RecordingButton, coordinator: ()) { button.stopRecording(); button.removeObservers() }

    @MainActor final class RecordingButton: NSButton {
        fileprivate var recordingName = ""
        fileprivate var shortcut: HubShortcut?
        fileprivate var onChange: ((HubShortcut?) -> Void)?
        private var isRecording = false
        private var prompt: String?
        private var pendingShortcut: HubShortcut?
        private var pendingKeyCode: UInt16?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private static weak var activeButton: RecordingButton?

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            // SF's regular system symbols keep their natural widths; in the
            // monospaced font even a thin space becomes a full character wide.
            font = .systemFont(ofSize: 12, weight: .medium)
            target = self
            action = #selector(toggleRecording)
            setButtonType(.momentaryPushIn)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopRecording()
            removeObservers()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopRecording() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            })
        }

        override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }

        @objc private func toggleRecording() {
            if isRecording { stopRecording(); return }
            guard let window else { return }
            Self.activeButton?.stopRecording()
            guard window.makeFirstResponder(self) else { return }
            Self.activeButton = self
            isRecording = true
            prompt = nil
            refreshTitle()
            NotificationCenter.default.post(name: Notification.Name("HubShortcutRecording"), object: nil, userInfo: ["active": true])
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.isRecording else { return event }
                if event.type == .keyUp {
                    guard event.window === self.window, self.window?.isKeyWindow == true else { self.stopRecording(); return event }
                    guard event.keyCode == self.pendingKeyCode else { return event }
                    let value = self.pendingShortcut
                    self.onChange?(value)
                    self.shortcut = value
                    self.stopRecording()
                    return nil
                }
                if event.type != .keyDown {
                    if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stopRecording() }
                    return event
                }
                guard event.window === self.window else { self.stopRecording(); return event }
                if event.keyCode == 53 { self.stopRecording(); return nil }
                // Do not restore Carbon registration while this key is still
                // held: auto-repeat could immediately trigger the new binding.
                if self.pendingKeyCode != nil { return nil }
                let modifiers = HubShortcut.carbonModifiers(from: event.modifierFlags)
                if event.keyCode == 48 && modifiers == 0 { self.stopRecording(); return event }
                if event.keyCode == 51 || event.keyCode == 117 { self.stage(nil, keyCode: event.keyCode); return nil }
                let shortcut = HubShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                if shortcut.validationError != nil {
                    self.prompt = L("请包含 ⌘ / ⌃ / ⌥")
                    self.refreshTitle()
                } else { self.stage(shortcut, keyCode: event.keyCode) }
                return nil
            }
        }

        private func stage(_ value: HubShortcut?, keyCode: UInt16) {
            pendingShortcut = value
            pendingKeyCode = keyCode
            prompt = L("松开按键以保存…")
            refreshTitle()
        }

        fileprivate func stopRecording() {
            guard isRecording else { return }
            isRecording = false
            prompt = nil
            pendingShortcut = nil
            pendingKeyCode = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if Self.activeButton === self { Self.activeButton = nil }
            refreshTitle()
            NotificationCenter.default.post(name: Notification.Name("HubShortcutRecording"), object: nil, userInfo: ["active": false])
        }

        fileprivate func refreshTitle() {
            let display = isRecording ? (prompt ?? L("请按快捷键…")) :
                (shortcut.map { $0.displayComponents.joined(separator: "\u{2009}") } ?? L("未设置 · 点击录制"))
            title = display
            contentTintColor = isRecording ? .controlAccentColor : nil
            setAccessibilityLabel(L("\(recordingName)快捷键"))
            setAccessibilityValue(isRecording ? L("正在录制，按 Escape 取消，按 Delete 清除") : (shortcut?.displayString ?? display))
            setAccessibilityHelp(L("点击录制，组合至少包含 Command、Control 或 Option。点击其他位置取消。"))
        }

        fileprivate func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            // Dismantle/window removal normally stops capture first. This also
            // restores registration if a host destroys the recorder directly.
            if isRecording {
                NotificationCenter.default.post(name: Notification.Name("HubShortcutRecording"), object: nil, userInfo: ["active": false])
            }
        }
    }
}
