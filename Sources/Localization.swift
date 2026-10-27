import Foundation

enum HubLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> HubLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
    var locale: Locale { Locale(identifier: resolved().rawValue) }
}

/// Explicit interpolation keeps file names and other user data separate from
/// translated templates. Arguments are inserted once; their content is never parsed.
struct HubLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

enum HubLocalization {
    // Model updates run on main; error messages can also be created by bounded
    // background workers. A tiny lock protects only the selected language.
    private static let lock = NSLock()
    private static var selected: HubLanguage = .simplifiedChinese
    static var language: HubLanguage {
        lock.lock(); defer { lock.unlock() }; return selected
    }
    static func select(_ language: HubLanguage) {
        lock.lock(); selected = language.resolved(); lock.unlock()
    }
    static func text(_ key: String) -> String {
        language == .english ? HubLocalizationCatalog.english[key] ?? key : key
    }
    static func render(_ message: HubLocalizedMessage) -> String {
        render(template: text(message.key), arguments: message.arguments)
    }
    static func render(template: String, arguments: [String]) -> String {
        guard !arguments.isEmpty else { return template }
        // Walk the template, not a sequence of replacements: a file called
        // "{1}.pdf" or "%@" must remain literal and cannot become another argument.
        var result = "", cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(index) {
                result += arguments[index]; cursor = template.index(after: end)
            } else { result.append(template[cursor]); cursor = template.index(after: cursor) }
        }
        return result
    }
}

func L(_ message: HubLocalizedMessage) -> String { HubLocalization.render(message) }
