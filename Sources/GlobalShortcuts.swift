import AppKit
import Carbon

struct HubShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    var validationError: String? {
        guard keyCode <= 127 else { return "此按键无法用作全局快捷键，请重新录制。" }
        guard ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else {
            return "请再按一个字母、数字、方向键或功能键。"
        }
        guard modifiers & ~Self.modifierMask == 0 else { return "包含暂不支持的修饰键，请重新录制。" }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            return "请至少包含 ⌘、⌃ 或 ⌥ 中的一个修饰键。"
        }
        return nil
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyLabel(keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func keyLabel(_ code: UInt32) -> String {
        let named: [UInt32: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤",
                                        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
                                        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        if let text = named[code] { return text }
        if code <= 127, let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            // Translation borrows the layout's bytes. Keep their owning input
            // source and CFData alive until UCKeyTranslate has finished reading.
            let translated: String? = withExtendedLifetime(source) {
                let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
                return withExtendedLifetime(data) { () -> String? in
                    guard let bytes = CFDataGetBytePtr(data) else { return nil }
                    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                    var dead: UInt32 = 0
                    var count = 0
                    var characters = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &count, &characters)
                    guard status == noErr, count > 0 else { return nil }
                    let text = String(utf16CodeUnits: characters, count: count).uppercased()
                    return text.rangeOfCharacter(from: .controlCharacters) == nil ? text : nil
                }
            }
            if let translated { return translated }
        }
        return "键 \(code)"
    }
}

struct HubGlobalShortcuts: Codable, Equatable {
    var top: HubShortcut?
    var cursor: HubShortcut?

    static let defaults = HubGlobalShortcuts(
        top: HubShortcut(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(cmdKey | optionKey)),
        cursor: HubShortcut(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(cmdKey | optionKey)))

    var validationErrors: [String: String] {
        var errors: [String: String] = [:]
        if let error = top?.validationError { errors["top"] = error }
        if let error = cursor?.validationError { errors["cursor"] = error }
        if let top, let cursor, top == cursor, top.validationError == nil {
            errors["top"] = "与“光标旁呼出”重复，请更换其中一个。"
            errors["cursor"] = "与“在触发位置呼出”重复，请更换其中一个。"
        }
        return errors
    }
}
