import Foundation

/// A metadata snapshot only: deciding what to preview never reads file contents.
struct HubInlinePreviewCandidate {
    let url: URL?
    let exists: Bool
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date?
}

struct HubInlinePreviewIdentity: Equatable {
    let url: URL
    let size: Int64
    let modified: Date?

    init(url: URL, size: Int64, modified: Date?) {
        self.url = url.isFileURL ? url.standardizedFileURL : url
        self.size = size
        self.modified = modified
    }
}

enum HubInlinePreviewDisposition: Equatable {
    case empty
    case unavailable
    case directory
    case file(HubInlinePreviewIdentity)
}

enum HubInlinePreviewPolicy {
    static func disposition(for candidate: HubInlinePreviewCandidate) -> HubInlinePreviewDisposition {
        guard let url = candidate.url else { return .empty }
        guard url.isFileURL, candidate.exists else { return .unavailable }
        guard !candidate.isDirectory || candidate.isPackage else { return .directory }
        return .file(HubInlinePreviewIdentity(url: url, size: candidate.size, modified: candidate.modified))
    }
}

enum HubInlinePreviewUpdate: Equatable {
    case unchanged
    case replace
    case refresh
    case clear

    /// Repeated SwiftUI updates preserve the native preview's scroll/page state.
    /// Metadata changes refresh the same item rather than replacing its identity.
    static func action(previous: HubInlinePreviewIdentity?, next: HubInlinePreviewIdentity?) -> HubInlinePreviewUpdate {
        switch (previous, next) {
        case (nil, nil): return .unchanged
        case (_, nil): return .clear
        case (nil, _): return .replace
        case let (previous?, next?):
            guard previous.url == next.url else { return .replace }
            return previous == next ? .unchanged : .refresh
        }
    }
}

/// Keep both directory columns readable while the preview fills all remaining
/// space. A narrow viewport scrolls horizontally instead of crushing the preview.
struct HubColumnsLayout {
    static let minimumPreviewWidth: CGFloat = 280

    let parentWidth: CGFloat
    let directoryWidth: CGFloat
    let separatorWidth: CGFloat
    let separatorCount: Int
    let previewWidth: CGFloat
    let totalWidth: CGFloat
    let needsHorizontalScroll: Bool

    static func make(availableWidth: CGFloat, hasParent: Bool) -> HubColumnsLayout {
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let parent: CGFloat = hasParent ? 190 : 0
        let directory: CGFloat = 260
        let separator: CGFloat = 1
        let count = hasParent ? 2 : 1
        let fixedWidth = parent + directory + CGFloat(count) * separator
        let preview = max(minimumPreviewWidth, available - fixedWidth)
        let total = fixedWidth + preview
        return HubColumnsLayout(parentWidth: parent, directoryWidth: directory,
                                separatorWidth: separator, separatorCount: count,
                                previewWidth: preview, totalWidth: total,
                                needsHorizontalScroll: total > available)
    }
}
