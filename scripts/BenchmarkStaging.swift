import AppKit
import Foundation

/// End-to-end benchmark using isolated real files; never reads user configuration.
@main
struct StagingBenchmark {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("FileDockBenchmark-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let count = 500
        let files = try (0..<count).map { index -> URL in
            let file = directory.appendingPathComponent("file-\(index).txt")
            try Data().write(to: file)
            return file
        }
        let configuration = directory.appendingPathComponent("config.json")
        let model = HubModel(storageURL: configuration)
        let start = ProcessInfo.processInfo.systemUptime
        precondition(model.stageFiles(files))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let afterAdd = try Data(contentsOf: configuration).count
        model.clearStagedFiles()
        let afterClear = try Data(contentsOf: configuration).count
        print("Stage \(count) real files: \(String(format: "%.4f", elapsed))s; config after add \(afterAdd) bytes; after clear \(afterClear) bytes")
    }
}
