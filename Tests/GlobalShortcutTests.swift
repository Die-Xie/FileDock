import AppKit
import Carbon

@main
struct GlobalShortcutTests {
    @MainActor static func main() throws {
        let defaults = HubGlobalShortcuts.defaults
        precondition(defaults.top?.keyCode == UInt32(kVK_DownArrow))
        precondition(defaults.cursor?.keyCode == UInt32(kVK_RightArrow))
        precondition(defaults.validationErrors.isEmpty)
        precondition(defaults.top?.displayString == "⌥⌘↓")
        precondition(defaults.cursor?.displayString == "⌥⌘→")
        precondition(defaults.top?.displayComponents == ["⌥", "⌘", "↓"])

        for modifier in [UInt32(cmdKey), UInt32(controlKey), UInt32(optionKey), UInt32(cmdKey | shiftKey)] {
            precondition(HubShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: modifier).validationError == nil)
        }
        for modifier in [UInt32(0), UInt32(shiftKey), UInt32(alphaLock), UInt32(cmdKey | alphaLock)] {
            precondition(HubShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: modifier).validationError != nil)
        }
        precondition(HubShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)).validationError != nil)
        precondition(HubShortcut(keyCode: 128, modifiers: UInt32(cmdKey)).validationError != nil)
        precondition(HubShortcut(keyCode: 0, modifiers: UInt32.max).validationError != nil)
        precondition(HubShortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey)).displayString == "⌃F20")
        precondition(HubShortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey)).displayComponents == ["⌃", "F20"],
                     "The multi-character key label remains one visual unit")
        precondition(HubShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)).displayString == "⌃⌥⇧⌘空格")

        let flags: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .capsLock, .function, .numericPad]
        precondition(HubShortcut.carbonModifiers(from: flags) == HubShortcut.modifierMask,
                     "Caps Lock and device flags must never leak into Carbon registration")
        let duplicate = HubGlobalShortcuts(top: defaults.top, cursor: defaults.top)
        precondition(duplicate.validationErrors["top"] != nil && duplicate.validationErrors["cursor"] != nil)
        precondition(HubGlobalShortcuts(top: defaults.top, cursor: nil).validationErrors.isEmpty)
        precondition(HubGlobalShortcuts(top: nil, cursor: nil).validationErrors.isEmpty,
                     "Both bindings may be explicitly disabled")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        // The optional field must not be required when loading pre-recorder configs.
        var settings = HubSettings()
        let oldData = try encoder.encode(settings)
        var oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        oldObject.removeValue(forKey: "globalShortcuts")
        let legacy = try decoder.decode(HubSettings.self, from: JSONSerialization.data(withJSONObject: oldObject))
        precondition(legacy.globalShortcuts == nil && legacy.resolvedGlobalShortcuts == defaults)

        settings.globalShortcuts = HubGlobalShortcuts(top: nil, cursor: nil)
        let disabled = try decoder.decode(HubSettings.self, from: encoder.encode(settings))
        precondition(disabled.globalShortcuts != nil && disabled.resolvedGlobalShortcuts.top == nil && disabled.resolvedGlobalShortcuts.cursor == nil,
                     "Explicitly unbound keys must not turn back into defaults after restart")

        let custom = HubShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        settings.globalShortcuts = HubGlobalShortcuts(top: custom, cursor: defaults.cursor)
        let roundTrip = try decoder.decode(HubSettings.self, from: encoder.encode(settings))
        precondition(roundTrip.resolvedGlobalShortcuts.top == custom && roundTrip.resolvedGlobalShortcuts.cursor == defaults.cursor)
        precondition(custom.displayString.hasPrefix("⌃⌥") && custom.displayString.count >= 3)
        settings.globalShortcuts = nil
        precondition(settings.resolvedGlobalShortcuts == defaults)

        print("PASS: shortcut modifiers, key validation, labels, duplicate checks, legacy settings, explicit unbinding and custom binding persistence")
        print("LIMIT: recording focus/key-release behavior and OS-level shortcut conflicts require native UI verification")
    }
}
