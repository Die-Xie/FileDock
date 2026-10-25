import Foundation

enum HubShortcutItem: String, Codable, CaseIterable, Identifiable {
    case favorite, airDrop, recents, staging

    var id: String { rawValue }
    static let defaultOrder: [HubShortcutItem] = [.favorite, .airDrop, .recents, .staging]

    /// Feature identities are independent of lazily created workspaces and
    /// remain stable across launches, imports, and shortcut visibility changes.
    var dragID: UUID {
        switch self {
        case .favorite: return UUID(uuidString: "3E8D642C-BD2F-4D73-813E-000000000001")!
        case .airDrop: return UUID(uuidString: "3E8D642C-BD2F-4D73-813E-000000000002")!
        case .recents: return UUID(uuidString: "3E8D642C-BD2F-4D73-813E-000000000003")!
        case .staging: return UUID(uuidString: "3E8D642C-BD2F-4D73-813E-000000000004")!
        }
    }

    static func normalized(_ stored: [String]?) -> [HubShortcutItem] {
        var seen = Set<HubShortcutItem>()
        let valid = (stored ?? []).compactMap(Self.init(rawValue:)).filter { seen.insert($0).inserted }
        return valid + defaultOrder.filter { seen.insert($0).inserted }
    }
}
