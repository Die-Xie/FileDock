import AppKit
import Foundation

/// Delivers a real progress callback while withholding the final snapshot.
@MainActor private final class PartialReferenceLoader: HubDirectoryLoading {
    var prefixCount = 3
    func load(id: UUID, request: HubDirectoryRequest,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        load(id: id, request: request, progress: { _ in }, completion: completion)
    }
    func load(id: UUID, request: HubDirectoryRequest, progress: @escaping (HubDirectorySnapshot) -> Void,
              completion: @escaping (Result<HubDirectorySnapshot, Error>) -> Void) {
        guard request.directory == nil else { completion(.success(.init(entries: [], canonicalDirectoryPath: nil))); return }
        let entries = request.references.prefix(prefixCount).map { FileEntry(url: URL(fileURLWithPath: $0)) }
        progress(.init(entries: entries, canonicalDirectoryPath: nil))
    }
    func cancel(id: UUID) {}
}

@main struct PartialReferenceReorderTests {
    @MainActor static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("FileDock-PartialReferenceReorder-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let files = ["match-a.txt", "match-b.txt", "match-c.txt", ".hidden.txt", "unloaded.txt"].map { root.appendingPathComponent($0) }
        for file in files { try Data("preserve contents".utf8).write(to: file) }

        for staging in [false, true] {
            let storage = root.appendingPathComponent(staging ? "staging.json" : "collection.json")
            let loader = PartialReferenceLoader()
            let model = HubModel(storageURL: storage, directoryLoader: loader)
            if staging { model.stageFiles(files); model.openStagingWorkspace() }
            else { model.addWorkspace(name: "References", mode: .references, urls: files) }
            let id = model.selectedWorkspaceID!
            precondition(model.directoryLoading && model.entries.count == 3)
            do { try model.importConfiguration(data: Data("invalid json".utf8)); preconditionFailure("Invalid import must fail") }
            catch { }
            precondition(model.directoryLoading && model.entries.count == 3,
                         "An invalid import cannot cancel an unrelated progressive directory read")
            model.search = "match"
            // The input order is reversed; a multi-drag keeps displayed order.
            model.reorderEntries([files[2], files[1]], before: files[0])
            let first = [files[1], files[2], files[0], files[3], files[4]]
            precondition(model.selectedWorkspace?.referencePaths == first.map(\.path),
                         "Partial reorder must preserve every unread and hidden reference")
            precondition(model.directoryLoading && model.visibleEntries.count == 3)
            model.reorderEntries([files[1]], before: nil)
            let last = [files[2], files[0], files[3], files[4], files[1]]
            precondition(model.selectedWorkspace?.referencePaths == last.map(\.path),
                         "Dropping at the end must follow the complete reference list")

            let restored = makeTestModel(storageURL: storage)
            precondition(restored.workspaces.first { $0.id == id }?.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == last.map(\.path),
                         "All reference paths must survive a configuration reload")
            restored.search = "match"
            restored.reorderEntries([files[0]], before: files[2])
            precondition(Set(restored.selectedWorkspace!.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) == Set(files.map(\.path)),
                         "Search-filtered reorder must retain hidden and filtered-out items")
            for file in files {
                let bytes = try Data(contentsOf: file)
                precondition(bytes == Data("preserve contents".utf8), "Reordering cannot modify file data")
            }
        }
        print("PASS: partial collection and staging reorder, unread/hidden/search-filtered references, stable multi-selection, end insertion and persistence")
    }
}
