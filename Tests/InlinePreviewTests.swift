import Foundation

@main
struct InlinePreviewTests {
    private static let report = URL(fileURLWithPath: "/tmp/preview/report.pdf")
    private static let originalDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func candidate(url: URL? = report, exists: Bool = true,
                                  directory: Bool = false, package: Bool = false,
                                  size: Int64 = 512, modified: Date? = originalDate) -> HubInlinePreviewCandidate {
        HubInlinePreviewCandidate(url: url, exists: exists, isDirectory: directory,
                                  isPackage: package, size: size, modified: modified)
    }

    private static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(actual.isFinite && abs(actual - expected) < 0.001,
                     "\(message): \(actual) != \(expected)")
    }

    private static func checkLayout(_ width: CGFloat, parent: Bool) -> HubColumnsLayout {
        let layout = HubColumnsLayout.make(availableWidth: width, hasParent: parent)
        near(layout.parentWidth, parent ? 190 : 0, "The parent column is present only below the root")
        near(layout.directoryWidth, 260, "The directory list retains a readable fixed width")
        near(layout.separatorWidth, 1, "Separators participate in the width budget")
        precondition(layout.separatorCount == (parent ? 2 : 1))
        precondition(layout.previewWidth >= HubColumnsLayout.minimumPreviewWidth)
        near(layout.parentWidth + layout.directoryWidth + CGFloat(layout.separatorCount) * layout.separatorWidth + layout.previewWidth,
             layout.totalWidth, "No width is lost between directory columns and preview")
        return layout
    }

    static func main() {
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(url: nil)) == .empty,
                     "Clearing selection must not leave the previous document visible")
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(exists: false)) == .unavailable,
                     "Deleted references cannot be handed to the native preview")
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(url: URL(string: "https://example.com/report.pdf")!)) == .unavailable,
                     "A preview candidate must never turn a remote URL into a network request")
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(directory: true)) == .directory,
                     "Ordinary folders use directory information instead of a document preview")
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(exists: false, directory: true)) == .unavailable,
                     "Missing directories remain unavailable instead of displaying stale directory metadata")

        let first = HubInlinePreviewIdentity(url: report, size: 512, modified: originalDate)
        precondition(HubInlinePreviewPolicy.disposition(for: candidate()) == .file(first))
        let packageURL = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(url: packageURL, directory: true, package: true)) ==
                     .application,
                     "Applications must never reach Quick Look or start a bundle preview provider")
        for ext in ["APP", "app", "appex", "xpc", "bundle", "plugin", "prefPane"] {
            let url = URL(fileURLWithPath: "/tmp/Example." + ext)
            precondition(HubInlinePreviewPolicy.disposition(for: candidate(url: url, directory: true, package: true)) == .application)
        }
        for ext in ["pages", "key", "rtfd"] {
            let url = URL(fileURLWithPath: "/tmp/Example." + ext)
            precondition(HubInlinePreviewPolicy.disposition(for: candidate(url: url, directory: true, package: true)) ==
                         .file(.init(url: url, size: 512, modified: originalDate)))
        }
        precondition(HubInlinePreviewPolicy.quickLookURLs([packageURL, report, URL(string: "https://example.com/")!]) == [report],
                     "Space/multi-selection Quick Look must filter executable bundles and remote URLs")
        precondition(HubInlinePreviewPolicy.quickLookURLs([packageURL]).isEmpty)
        let emptyFile = HubInlinePreviewIdentity(url: report, size: 0, modified: nil)
        precondition(HubInlinePreviewPolicy.disposition(for: candidate(size: 0, modified: nil)) == .file(emptyFile),
                     "An existing empty file is still a valid preview candidate")

        let equivalent = HubInlinePreviewIdentity(url: URL(fileURLWithPath: "/tmp/preview/../preview/report.pdf"),
                                                  size: 512, modified: originalDate)
        precondition(first == equivalent, "Equivalent lexical file paths share a preview identity without filesystem access")
        precondition(HubInlinePreviewUpdate.action(previous: nil, next: nil) == .unchanged)
        precondition(HubInlinePreviewUpdate.action(previous: nil, next: first) == .replace)
        precondition(HubInlinePreviewUpdate.action(previous: first, next: equivalent) == .unchanged,
                     "Unrelated view recomputes must preserve the document page and scroll position")
        let edited = HubInlinePreviewIdentity(url: report, size: 512, modified: originalDate.addingTimeInterval(1))
        precondition(HubInlinePreviewUpdate.action(previous: first, next: edited) == .refresh,
                     "A same-length edit of the selected file refreshes its contents")
        let resized = HubInlinePreviewIdentity(url: report, size: 1024, modified: originalDate)
        precondition(HubInlinePreviewUpdate.action(previous: first, next: resized) == .refresh,
                     "Size changes refresh even when modification timestamps are unchanged")
        let dated = HubInlinePreviewIdentity(url: report, size: 0, modified: originalDate)
        precondition(HubInlinePreviewUpdate.action(previous: emptyFile, next: dated) == .refresh,
                     "Metadata becoming available must refresh the existing file")
        let other = HubInlinePreviewIdentity(url: URL(fileURLWithPath: "/tmp/preview/other.pdf"), size: 512, modified: originalDate)
        precondition(HubInlinePreviewUpdate.action(previous: first, next: other) == .replace,
                     "Switching files replaces the item even when their metadata matches")
        precondition(HubInlinePreviewUpdate.action(previous: other, next: first) == .replace,
                     "Rapidly switching back selects the requested document instead of a stale prior item")
        precondition(HubInlinePreviewUpdate.action(previous: first, next: nil) == .clear)
        precondition(HubInlinePreviewUpdate.action(previous: nil, next: first) == .replace,
                     "Selecting a document after an empty or unsupported item loads it again")

        let narrow = checkLayout(600, parent: true)
        near(narrow.previewWidth, 280, "At minimum window width the preview retains its usable minimum")
        near(narrow.totalWidth, 732, "Narrow layouts retain readable columns inside a scrolling content width")
        precondition(narrow.needsHorizontalScroll)
        let rootNarrow = checkLayout(600, parent: false)
        near(rootNarrow.previewWidth, 339, "The root has no blank parent column")
        near(rootNarrow.totalWidth, 600, "The root preview fills its entire remaining viewport")
        precondition(!rootNarrow.needsHorizontalScroll)
        for (width, parentPreview, rootPreview) in [(CGFloat(927), CGFloat(475), CGFloat(666)), (1600, 1148, 1339)] {
            let parent = checkLayout(width, parent: true)
            let root = checkLayout(width, parent: false)
            near(parent.previewWidth, parentPreview, "Wider nested views devote spare width to the document")
            near(root.previewWidth, rootPreview, "Wider root views devote spare width to the document")
            near(parent.totalWidth, width, "Nested columns fill the viewport without unused trailing space")
            near(root.totalWidth, width, "Root columns fill the viewport without unused trailing space")
            precondition(!parent.needsHorizontalScroll && !root.needsHorizontalScroll)
        }
        precondition(!checkLayout(732, parent: true).needsHorizontalScroll,
                     "An exact fit needs no horizontal scrolling")
        precondition(checkLayout(731.5, parent: true).needsHorizontalScroll,
                     "A viewport just below minimum content width scrolls instead of shrinking the preview")
        precondition(!checkLayout(541, parent: false).needsHorizontalScroll)
        for invalid: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
            for parent in [true, false] {
                let layout = checkLayout(invalid, parent: parent)
                near(layout.previewWidth, 280, "Transient invalid geometry cannot propagate into native preview sizing")
                near(layout.totalWidth, parent ? 732 : 541, "Invalid geometry falls back to a finite minimum content width")
                precondition(layout.needsHorizontalScroll)
            }
        }
        print("PASS: Inline preview selects safe local items, preserves document identity and fills column viewport")
    }
}
