import Foundation

extension HubFileDropPlan {
    /// Only URL validation belongs on drag updates. File metadata and security
    /// scopes are prepared by the sharing controller after the actual drop.
    static func airDrop(urls: [URL], allowed: Bool) -> HubFileDropPlan? {
        guard allowed, (try? HubAirDropPolicy.uniqueFiles(urls)) != nil else { return nil }
        return HubFileDropPlan(workspaceID: nil, directory: nil, item: nil,
                               title: "AirDrop", action: .airDrop)
    }
}
