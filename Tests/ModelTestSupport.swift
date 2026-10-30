import Foundation
import Darwin

/// Finder's on-disk tag format is available on the minimum supported OS;
/// URLResourceValues.tagNames became writable only in macOS 26.
func setFixtureTags(_ names: [String], on url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: names.map { "\($0)\n0" }, format: .binary, options: 0)
    let result = data.withUnsafeBytes { bytes in
        setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Existing model semantics are exercised with an immediate fixture loader;
/// DirectoryLoadingTests separately exercise the real asynchronous scheduler.
@MainActor private final class ImmediateDirectoryFixture: HubDirectoryLoading {
    func load(id: UUID, request: HubDirectoryRequest, completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        completion(Result { try HubDirectoryLoader.readSnapshot(request) })
    }
    func cancel(id: UUID) {}
}
@MainActor func makeTestModel(storageURL: URL? = nil, demo: Bool = false, monitor: Bool = false,
                             recentFiles: HubRecentFilesProviding? = nil) -> HubModel {
    HubModel(storageURL: storageURL, demo: demo, monitor: monitor, recentFiles: recentFiles,
             directoryLoader: ImmediateDirectoryFixture())
}
