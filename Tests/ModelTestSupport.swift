import Foundation

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
