import Foundation

@main struct FileDropBatchTests {
    @MainActor static func main() async throws {
        let a = URL(fileURLWithPath: "/drop/A"), b = URL(fileURLWithPath: "/drop/B")
        var outputs: [[URL]] = []
        let first = HubDropBatch(count: 2, timeout: 0.1) { outputs.append($0) }
        first.finish(index: -1, url: a)
        first.finish(index: 1, url: b)
        first.finish(index: 1, url: b)
        first.finish(index: 0, url: a)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(outputs == [[a, b]], "Out-of-order/duplicate callbacks must deliver once in source order")
        let timeout = HubDropBatch(count: 2, timeout: 0.02) { outputs.append($0) }
        timeout.finish(index: 0, url: a)
        try await Task.sleep(nanoseconds: 50_000_000)
        timeout.finish(index: 1, url: b)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(outputs == [[a, b], []], "Timeout must reject the entire selection and ignore late providers")
        let invalid = HubDropBatch(count: 2) { outputs.append($0) }
        invalid.finish(index: 0, url: a)
        invalid.finish(index: 1, url: URL(string: "https://example.invalid/B")!)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(outputs.last!.isEmpty)
        print("PASS: complete file-provider batches, callback ordering, duplicate/invalid index guards, timeout/late callback isolation and atomic rejection of malformed selections")
    }
}
