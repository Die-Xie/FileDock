import AppKit

enum HubClipboardShortcut: Equatable {
    case copy, copyPaths, paste
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        let keys = modifiers.intersection([.command, .control, .shift, .option])
        if keyCode == 8, keys == [.command, .option] { return .copyPaths }
        guard keys == .command || keys == .control else { return nil }
        switch keyCode { case 8: return .copy; case 9: return .paste; default: return nil }
    }
}
