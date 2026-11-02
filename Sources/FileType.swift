import Foundation

/// Stable browsing identifiers. Extensions have their own namespace so a real
/// `.folder` or `.__none__` file cannot collide with a structural category.
enum HubFileType {
    static let folder = "folder"
    static let noExtension = "__none__"
    static let defaultShortcuts = ["ext:md", "ext:pdf", "ext:zip", folder]
    static let maximumShortcuts = 12
    static let maximumEditorBytes = 4096
    private static let maximumShortcutCandidates = 256

    static func key(for entry: FileEntry) -> String {
        if entry.canNavigate { return folder }
        let ext = entry.url.pathExtension.lowercased()
        return ext.isEmpty ? noExtension : "ext:" + ext
    }

    static func normalizedIdentifier(_ value: String) -> String? {
        guard value.utf8.count <= 1028 else { return nil }
        let canonical = value.lowercased()
        if canonical.hasPrefix("ext:") {
            let ext = String(canonical.dropFirst(4))
            // Preserve literal suffix whitespace in opaque panel identifiers.
            guard !ext.isEmpty, ext.utf8.count <= 1024, !ext.contains("/"), !ext.contains("\0") else { return nil }
            return "ext:" + ext
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed == folder || trimmed == "文件夹" { return folder }
        if trimmed == noExtension || trimmed == "无扩展名" || trimmed == "none" { return noExtension }
        let ext = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        guard validShortcutExtension(ext) else { return nil }
        return "ext:" + ext
    }

    private static func validShortcutExtension(_ ext: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-"))
        return !ext.isEmpty && ext.utf8.count <= 32 && ext.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func normalizedShortcuts(_ values: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in values.prefix(maximumShortcutCandidates) {
            guard let key = normalizedIdentifier(value),
                  !key.hasPrefix("ext:") || validShortcutExtension(String(key.dropFirst(4))),
                  seen.insert(key).inserted else { continue }
            result.append(key)
            if result.count == maximumShortcuts { break }
        }
        return result
    }

    static func parseShortcuts(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；"))
        let bounded = String(decoding: text.utf8.prefix(maximumEditorBytes), as: UTF8.self)
        return normalizedShortcuts(bounded.components(separatedBy: separators).filter { !$0.isEmpty })
    }

    /// Keep available favorites in the user's order, then fill unused slots
    /// from the loaded panel's existing type order. This does not inspect the
    /// active browsing filter, mutate preferences, or create absent categories.
    static func displayedShortcuts(preferred: [String], available: [HubFileTypeOption]) -> [String] {
        let favorites = normalizedShortcuts(preferred)
        guard !favorites.isEmpty else { return [] }
        let favoriteSet = Set(favorites)
        var presentFavorites = Set<String>()
        var fallback: [String] = [], fallbackSet = Set<String>()
        for option in available where option.count > 0 {
            if favoriteSet.contains(option.id) {
                presentFavorites.insert(option.id)
            } else if fallback.count < favorites.count, !fallbackSet.contains(option.id),
                      normalizedIdentifier(option.id) == option.id {
                fallback.append(option.id)
                fallbackSet.insert(option.id)
            }
            // Later types cannot change the result once all preferred slots
            // are present. Otherwise retain at most favorites.count fallback
            // IDs while scanning for a preferred type near the end.
            if presentFavorites.count == favorites.count { break }
        }
        let retained = favorites.filter(presentFavorites.contains)
        return retained + fallback.prefix(favorites.count - retained.count)
    }

    static func editingText(for shortcuts: [String]) -> String {
        normalizedShortcuts(shortcuts).map { key in
            if key == folder { return folder }
            if key == noExtension { return "none" }
            let ext = String(key.dropFirst(4))
            return [folder, noExtension, "none"].contains(ext) ? "." + ext : ext
        }.joined(separator: ", ")
    }

    static func title(for key: String) -> String {
        if key == folder { return L("文件夹") }
        if key == noExtension { return L("无扩展名") }
        let suffix = key.hasPrefix("ext:") ? String(key.dropFirst(4)) : key
        return suffix.uppercased()
    }
}

struct HubFileTypeOption: Identifiable, Equatable {
    let id: String
    let count: Int
    var title: String { HubFileType.title(for: id) }
}
