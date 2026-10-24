import Foundation

private final class RecentMetadataItemFixture: NSMetadataItem {
    let values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
        super.init()
    }

    override func value(forAttribute key: String) -> Any? { values[key] }
}

/// No Spotlight query is started by this test. This substitute exercises the
/// provider's lifetime, snapshots and public query configuration deterministically.
private final class RecentMetadataQueryFixture: NSMetadataQuery {
    var rows: [[String: Any]] = []
    var fixtureGathering = true
    var starts = 0
    var stops = 0
    var disabled = 0
    var enabled = 0
    var canStart = true

    override func start() -> Bool { starts += 1; return canStart }
    override func stop() { stops += 1 }
    override var isGathering: Bool { fixtureGathering }
    override var resultCount: Int { rows.count }
    override func disableUpdates() { disabled += 1 }
    override func enableUpdates() { enabled += 1 }
    override func value(ofAttribute attributeName: String, forResultAt index: Int) -> Any? {
        precondition(disabled == enabled + 1, "Snapshots must pause query updates while accessing indexed metadata")
        // Real NSMetadataQuery returns the cached lastUsed sort field here,
        // while path/URL/content type can be nil despite a populated item.
        return attributeName == "kMDItemLastUsedDate" ? rows[index][attributeName] : nil
    }
    override func result(at index: Int) -> Any {
        precondition(disabled == enabled + 1, "Metadata items are read while query updates are paused")
        return RecentMetadataItemFixture(values: rows[index])
    }
    override var results: [Any] { preconditionFailure("The binding-oriented query.results proxy must never be used") }
}

@main
struct RecentFilesSourceTests {
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private static func createFile(_ relative: String, home: URL) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Fixture document".utf8).write(to: url)
        return url
    }

    private static func row(_ url: URL, date: Date = date) -> [String: Any] {
        [NSMetadataItemPathKey: url.path, "kMDItemLastUsedDate": date,
         NSMetadataItemContentTypeTreeKey: ["public.content", "public.text"]]
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Asynchronous recent query did not finish")
    }

    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("FileDockRecentTests-\(UUID().uuidString)", isDirectory: true)
        let home = fixture.appendingPathComponent("user", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }

        let report = try createFile("Documents/report.md", home: home)
        let second = try createFile("Desktop/second.pdf", home: home)
        let archive = try createFile("Downloads/archive.zip", home: home)
        let library = try createFile("Library/Application Support/Private/secret.txt", home: home)
        let cloud = try createFile("Library/Mobile Documents/com~apple~CloudDocs/report.txt", home: home)
        let providerCloud = try createFile("Library/CloudStorage/ExampleDrive/report.txt", home: home)
        let hidden = try createFile("Documents/.private/report.txt", home: home)
        let hiddenFile = try createFile("Documents/.hidden.txt", home: home)
        let appFile = try createFile("Applications/Test.APP/Contents/Resources/report.txt", home: home)
        let extensionFile = try createFile("Applications/Plugin.appex/Contents/report.txt", home: home)
        let sibling = try createFile("Documents/wrong-user.txt", home: fixture.appendingPathComponent("user-other"))
        let directory = home.appendingPathComponent("Documents")
        let missing = home.appendingPathComponent("Documents/deleted.txt")

        for url in [report, second, archive, cloud, providerCloud] {
            let candidate = HubRecentFilesCandidate(url: url, lastUsed: date)
            let file = HubRecentFilesPolicy.file(for: candidate, homeURL: home)
            precondition(file?.url == url && file?.metadataOnly == false,
                         "Visible home documents, archives and cloud-storage documents remain eligible")
        }
        for url in [library, hidden, hiddenFile, appFile, extensionFile, sibling, directory, missing,
                    URL(string: "https://example.com/report.txt")!] {
            precondition(HubRecentFilesPolicy.file(for: HubRecentFilesCandidate(url: url, lastUsed: date), homeURL: home) == nil,
                         "Private, hidden, application, out-of-scope and missing local paths must be filtered: \(url)")
        }
        precondition(!HubRecentFilesPolicy.allowsPath(home.appendingPathComponent("Library/CloudStorage-fake/document.txt"), homeURL: home))
        precondition(!HubRecentFilesPolicy.allowsPath(home.appendingPathComponent("Library/Mobile Documents-fake/document.txt"), homeURL: home))
        precondition(!HubRecentFilesPolicy.allowsPath(home, homeURL: home))
        precondition(!HubRecentFilesPolicy.allowsPath(report, homeURL: URL(string: "https://example.com")!))

        let normalized = home.appendingPathComponent("Documents/../Documents/report.md")
        precondition(HubRecentFilesPolicy.file(for: HubRecentFilesCandidate(url: normalized, lastUsed: date), homeURL: home)?.url == report,
                     "Metadata paths are standardized before scope comparison and deduplication")
        var invisible = HubRecentFilesCandidate(url: report, lastUsed: date)
        invisible.invisible = true
        precondition(HubRecentFilesPolicy.file(for: invisible, homeURL: home) == nil)
        for excludedType in ["public.folder", "com.apple.application-bundle"] {
            var candidate = HubRecentFilesCandidate(url: report, lastUsed: date)
            candidate.contentTypeTree = [excludedType]
            precondition(HubRecentFilesPolicy.file(for: candidate, homeURL: home) == nil)
        }
        for name in ["report.pages", "slides.key", "table.numbers"] {
            let package = home.appendingPathComponent("Documents/\(name)", isDirectory: true)
            try manager.createDirectory(at: package, withIntermediateDirectories: true)
            let values = try package.resourceValues(forKeys: [.isPackageKey, .isApplicationKey])
            precondition(values.isPackage == true && values.isApplication == false,
                         "The fixture is a native document package instead of an ordinary folder")
            let candidate = HubRecentFilesCandidate(url: package, lastUsed: date,
                                                   contentTypeTree: ["public.content", "public.composite-content", "com.apple.package"])
            let file = HubRecentFilesPolicy.file(for: candidate, homeURL: home)
            precondition(file?.url == package && file?.metadataOnly == false,
                         "Document packages remain eligible even when their filesystem type is a directory")
        }
        let appPackage = home.appendingPathComponent("Applications/Test.APP", isDirectory: true)
        precondition(HubRecentFilesPolicy.file(for: HubRecentFilesCandidate(url: appPackage, lastUsed: date), homeURL: home) == nil,
                     "Supporting document packages must not include application bundles")
        let symlink = home.appendingPathComponent("Documents/private-link.txt")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: hidden)
        precondition(HubRecentFilesPolicy.file(for: HubRecentFilesCandidate(url: symlink, lastUsed: date), homeURL: home) == nil,
                     "A symlink must not bypass the private-path filter")
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        var flagHidden = try createFile("Documents/finder-hidden.txt", home: home)
        try flagHidden.setResourceValues(hiddenValues)
        precondition(HubRecentFilesPolicy.file(for: HubRecentFilesCandidate(url: flagHidden, lastUsed: date), homeURL: home) == nil,
                     "Finder's hidden flag is honored even when its filename is visible")

        let cloudOnlyURL = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/cloud-only.pdf")
        var cloudOnly = HubRecentFilesCandidate(url: cloudOnlyURL, lastUsed: date)
        cloudOnly.ubiquitous = true
        cloudOnly.downloadingStatus = NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        let placeholder = HubRecentFilesPolicy.file(for: cloudOnly, homeURL: home)
        precondition(placeholder?.url == cloudOnlyURL && placeholder?.metadataOnly == true,
                     "Indexed iCloud placeholders do not need a downloaded local document to appear")
        cloudOnly.downloadingStatus = nil
        precondition(HubRecentFilesPolicy.file(for: cloudOnly, homeURL: home) != nil,
                     "Older providers may not expose a downloading status for an iCloud placeholder")
        cloudOnly.downloadingStatus = NSMetadataUbiquitousItemDownloadingStatusCurrent
        precondition(HubRecentFilesPolicy.file(for: cloudOnly, homeURL: home) == nil,
                     "A supposedly current local file which disappeared should not become a stale placeholder")
        precondition(!manager.fileExists(atPath: cloudOnlyURL.path), "Listing cloud metadata must not create or download a local document")
        var evictedLocal = HubRecentFilesCandidate(url: cloud, lastUsed: date)
        evictedLocal.ubiquitous = true
        evictedLocal.downloadingStatus = NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        precondition(manager.fileExists(atPath: cloud.path))
        precondition(HubRecentFilesPolicy.file(for: evictedLocal, homeURL: home)?.metadataOnly == true,
                     "An evicted iCloud placeholder may have a local inode without downloaded document contents")
        for status in [NSMetadataUbiquitousItemDownloadingStatusDownloaded, NSMetadataUbiquitousItemDownloadingStatusCurrent] {
            evictedLocal.downloadingStatus = status
            precondition(HubRecentFilesPolicy.file(for: evictedLocal, homeURL: home)?.metadataOnly == false,
                         "Downloaded and current documents retain ordinary local-file availability")
        }
        evictedLocal.ubiquitous = false
        evictedLocal.downloadingStatus = NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        precondition(HubRecentFilesPolicy.file(for: evictedLocal, homeURL: home)?.metadataOnly == false,
                     "A download-status string alone must not turn an ordinary local file into an iCloud placeholder")

        let old = HubRecentFile(url: report, lastUsed: date)
        let new = HubRecentFile(url: second, lastUsed: date.addingTimeInterval(1))
        let duplicates = HubRecentFilesPolicy.sorted([old, new, HubRecentFile(url: normalized, lastUsed: date.addingTimeInterval(-1))])
        precondition(duplicates == [new, old], "Recents deduplicate normalized URLs and sort by last use, not modification time")
        let newerDuplicate = HubRecentFilesPolicy.sorted([old, HubRecentFile(url: normalized, lastUsed: date.addingTimeInterval(2))])
        precondition(newerDuplicate == [HubRecentFile(url: report, lastUsed: date.addingTimeInterval(2))])
        let metadataDuplicate = HubRecentFile(url: normalized, lastUsed: date, metadataOnly: true)
        precondition(HubRecentFilesPolicy.sorted([metadataDuplicate, old]) == [old] &&
                     HubRecentFilesPolicy.sorted([old, metadataDuplicate]) == [old],
                     "Equal-date duplicates prefer an available local file over an indexed placeholder")
        let newestPlaceholder = HubRecentFile(url: normalized, lastUsed: date.addingTimeInterval(2), metadataOnly: true)
        precondition(HubRecentFilesPolicy.sorted([old, newestPlaceholder]) ==
                     [HubRecentFile(url: report, lastUsed: newestPlaceholder.lastUsed, metadataOnly: true)],
                     "Standardization and recency ordering preserve a surviving placeholder's availability flag")
        let tied = HubRecentFilesPolicy.sorted([old, HubRecentFile(url: archive, lastUsed: date)])
        precondition(tied.map(\.url.path) == [report.path, archive.path].sorted(), "Equal dates use a stable path tie-breaker")
        let many = (0..<600).map { index in
            HubRecentFile(url: home.appendingPathComponent("Documents/\(index).txt"), lastUsed: date.addingTimeInterval(Double(index)))
        }
        let limited = HubRecentFilesPolicy.sorted(many)
        precondition(limited.count == 500 && limited.first?.lastUsed == date.addingTimeInterval(599) && limited.last?.lastUsed == date.addingTimeInterval(100))

        let center = NotificationCenter()
        var made: [RecentMetadataQueryFixture] = []
        var source: HubRecentFilesSource? = HubRecentFilesSource(homeURL: home, notificationCenter: center, makeQuery: {
            let query = RecentMetadataQueryFixture()
            made.append(query)
            return query
        })
        var snapshots: [HubRecentFilesSnapshot] = []
        precondition(made.isEmpty, "Constructing a provider never starts Spotlight in an unused workspace")
        source?.refresh()
        precondition(made.isEmpty && snapshots.isEmpty)
        source?.start { value in
            precondition(Thread.isMainThread)
            snapshots.append(value)
        }
        precondition(made.count == 1 && made[0].starts == 1)
        precondition(snapshots.count == 1 && snapshots[0].gathering && snapshots[0].files.isEmpty && snapshots[0].message != nil)
        let query = made[0]
        precondition(query.searchScopes as? [String] == [NSMetadataQueryUserHomeScope], "The provider uses a public home-only scope")
        precondition(query.sortDescriptors.first?.key == "kMDItemLastUsedDate" && query.sortDescriptors.first?.ascending == false)
        precondition(query.operationQueue === OperationQueue.main)
        precondition(query.predicate != nil && NSPredicate(fromMetadataQueryString: HubRecentFilesSource.rawQuery) != nil,
                     "Finder's raw metadata syntax is parsed through the dedicated public initializer")
        precondition(!HubRecentFilesSource.rawQuery.contains("kMDItemFSInvisible"),
                     "FSInvisible may be absent from the index; filtering it in RawQuery silently hides every otherwise eligible document")
        precondition(HubRecentFilesSource.rawQuery.contains(#"kMDItemLastUsedDate = "*""#) &&
                     HubRecentFilesSource.rawQuery.contains("public.content") &&
                     HubRecentFilesSource.rawQuery.contains(#""com.microsoft.*"cdw"#) &&
                     HubRecentFilesSource.rawQuery.contains("public.archive"),
                     "The query retains Finder's recent-use/content expression while hidden items are filtered after querying")

        query.rows = [row(second, date: new.lastUsed), row(report), row(hidden), row(directory)]
        query.disableUpdates()
        precondition(query.value(ofAttribute: NSMetadataItemPathKey, forResultAt: 0) == nil &&
                     query.value(ofAttribute: NSMetadataItemURLKey, forResultAt: 0) == nil,
                     "The fixture reproduces uncached query-level attributes instead of masking missing paths")
        let metadataItem = query.result(at: 0) as? NSMetadataItem
        precondition(metadataItem?.value(forAttribute: NSMetadataItemPathKey) as? String == second.path &&
                     metadataItem?.value(forAttribute: NSMetadataItemURLKey) == nil,
                     "A real metadata item exposes its filesystem path even without a URL attribute")
        query.enableUpdates()
        let progressCount = snapshots.count
        center.post(name: NSNotification.Name.NSMetadataQueryGatheringProgress, object: query)
        try await wait { snapshots.count > progressCount }
        precondition(snapshots.last?.gathering == true && snapshots.last?.files == [new, old])
        query.fixtureGathering = false
        let finishCount = snapshots.count
        center.post(name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query)
        try await wait { snapshots.count > finishCount }
        precondition(snapshots.last?.gathering == false && snapshots.last?.message == nil)
        precondition(query.disabled == query.enabled)

        query.rows = [[NSMetadataItemURLKey: archive, "kMDItemLastUsedDate": date]]
        let refreshCount = snapshots.count
        source?.refresh()
        try await wait { snapshots.count > refreshCount }
        precondition(snapshots.last?.files.map(\.url) == [archive] && query.starts == 1 && made.count == 1,
                     "Refresh publishes live results without restarting a long-running query")
        query.rows = []
        let emptyCount = snapshots.count
        center.post(name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
        try await wait { snapshots.count > emptyCount }
        precondition(snapshots.last?.files.isEmpty == true && snapshots.last?.message != nil && snapshots.last?.gathering == false)
        let beforeStop = snapshots.count
        source?.stop()
        precondition(query.stops == 1)
        center.post(name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
        source?.refresh()
        precondition(snapshots.count == beforeStop, "Stopping removes observers and no longer delivers updates")

        source?.start { snapshots.append($0) }
        precondition(made.count == 2 && made[1].starts == 1, "A stopped provider can start afresh on workspace re-entry")
        let newCount = snapshots.count
        center.post(name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
        precondition(snapshots.count == newCount, "A previous query cannot deliver stale results into its replacement")
        source = nil
        precondition(made[1].stops == 1, "Deinitialization stops a live query and releases its notification registrations")

        let failedQuery = RecentMetadataQueryFixture()
        failedQuery.canStart = false
        let failed = HubRecentFilesSource(homeURL: home, notificationCenter: center, makeQuery: { failedQuery })
        var failures: [HubRecentFilesSnapshot] = []
        failed.start { failures.append($0) }
        precondition(failures.count == 2 && failures.first?.gathering == true && failures.last?.gathering == false && failures.last?.message != nil)
        precondition(failedQuery.starts == 1 && failedQuery.stops == 1)
        failedQuery.canStart = true
        failed.refresh()
        precondition(failedQuery.starts == 2 && failures.count == 3 && failures.last?.gathering == true,
                     "Refreshing after a failed start retries the query with its existing receiver")
        failedQuery.fixtureGathering = false
        failedQuery.rows = [row(report)]
        let recoveryCount = failures.count
        center.post(name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: failedQuery)
        try await wait { failures.count > recoveryCount }
        precondition(failures.last?.files == [old] && failures.last?.gathering == false,
                     "A recovered query delivers actual results to the original receiver")
        failed.stop()
        let afterRecoveryStop = failures.count
        failed.refresh()
        precondition(failedQuery.starts == 2 && failedQuery.stops == 2 && failures.count == afterRecoveryStop,
                     "Refreshing a stopped provider must not recreate a query or revive its receiver")

        var reentrant: HubRecentFilesSource? = HubRecentFilesSource(homeURL: home, notificationCenter: center, makeQuery: { RecentMetadataQueryFixture() })
        reentrant?.start { _ in reentrant?.stop() }
        reentrant = nil
        print("PASS: Recent files use bounded metadata queries, safe home paths, cloud placeholders and restartable asynchronous snapshots delivered on main")
    }
}
