import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias FileURLCallback = @Sendable (NSSecureCoding?, Error?) -> Void

private final class FileURLGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: FileURLCallback?
    var started: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    func hold(_ callback: @escaping FileURLCallback) { lock.lock(); self.callback = callback; lock.unlock() }
    func release(_ item: NSSecureCoding?, error: Error? = nil) {
        lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
        callback?(item, error)
    }
}

private final class FileURLProvider: NSItemProvider, @unchecked Sendable {
    private let handler: (@escaping FileURLCallback) -> Void
    private let type: String
    init(type: String = UTType.fileURL.identifier, handler: @escaping (@escaping FileURLCallback) -> Void) {
        self.type = type; self.handler = handler; super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var registeredTypeIdentifiers: [String] { [type] }
    override func hasItemConformingToTypeIdentifier(_ identifier: String) -> Bool { identifier == type }
    override func loadItem(forTypeIdentifier identifier: String, options: [AnyHashable: Any]?,
                           completionHandler: FileURLCallback?) {
        precondition(!Thread.isMainThread, "A synchronous provider must never execute its loading work on UI")
        precondition(identifier == UTType.fileURL.identifier, "The AirDrop bridge must never request image coercion")
        if let completionHandler { handler(completionHandler) }
    }
}

@main struct AirDropFileDropTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-AirDropDrag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vector.svg")
        let bytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try bytes.write(to: file)
        try await sourceOrderAndCopy(file: file, root: root, bytes: bytes)
        try await atomicFailure(file: file)
        try await timeoutAndStateChanges(file: file)
        try await boundedProviderInvocations(file: file)
        admission(file: file)
        precondition(!HubImportActivity.isBusy)
        precondition(HubAirDropFileDropDelegate.contentTypes == [.fileURL])
        precondition(HubAirDropFileDropDelegate.proposal(allowed: true).operation == .copy,
                     "AirDrop must never tell the source to delete a moved file")
        precondition(HubAirDropFileDropDelegate.proposal(allowed: false).operation == .cancel)
        print("PASS: AirDrop file-URL drops, copy semantics, async/duplicate providers, atomic rejection, timeout/late isolation, final enablement checks and bounded real workers")
    }

    private static func provider(_ item: NSSecureCoding?, error: Error? = nil) -> FileURLProvider {
        FileURLProvider { callback in callback(item, error) }
    }

    @MainActor private static func sourceOrderAndCopy(file: URL, root: URL, bytes: Data) async throws {
        let gate = FileURLGate()
        let first = FileURLProvider { gate.hold($0) }
        var outputs: [[URL]] = [], errors: [String] = []
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let alias = URL(fileURLWithPath: root.path + "/nested/../" + file.lastPathComponent)
        precondition(HubAirDropFileDropReceiver.receive(providers: [first, provider(file as NSURL), provider(alias.absoluteString as NSString), provider(root as NSURL)],
            canReceive: { !HubImportActivity.isBusy }, completion: {
                precondition(Thread.isMainThread && !HubImportActivity.isBusy)
                outputs.append($0)
            }, onError: { errors.append($0) }))
        precondition(outputs.isEmpty && HubImportActivity.count == 1, "Accepted provider drops complete asynchronously")
        try await wait { gate.started }
        gate.release(file.dataRepresentation as NSData)
        try await wait { !outputs.isEmpty || !errors.isEmpty }
        precondition(errors.isEmpty && outputs == [[file, root]], "Normalize only for deduplication, preserve source order and original file URLs")
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let currentBytes = try Data(contentsOf: file)
        precondition(before == after && currentBytes == bytes, "AirDrop URL parsing must not move, copy, rewrite, or materialize files")

        var duplicateCalls = 0
        let duplicate = FileURLProvider { callback in
            callback(file as NSURL, nil)
            callback(root as NSURL, nil)
        }
        precondition(HubAirDropFileDropReceiver.receive(providers: [duplicate, provider(root as NSURL)], canReceive: { true },
            completion: { urls in duplicateCalls += 1; precondition(urls == [file, root]) }, onError: { preconditionFailure($0) }))
        try await wait { duplicateCalls == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(duplicateCalls == 1)
    }

    @MainActor private static func atomicFailure(file: URL) async throws {
        let invalid: [NSSecureCoding?] = [nil, "not a URL" as NSString,
            URL(string: "https://example.invalid/file")! as NSURL,
            URL(string: "file://another-host/tmp/file")! as NSURL]
        for item in invalid {
            var errors = 0, completions = 0
            precondition(HubAirDropFileDropReceiver.receive(providers: [provider(file as NSURL), provider(item)],
                canReceive: { true }, completion: { _ in completions += 1 }, onError: { _ in
                    precondition(Thread.isMainThread && !HubImportActivity.isBusy); errors += 1
                }))
            try await wait { errors == 1 }
            precondition(completions == 0, "A malformed item must reject the entire selection, never share a subset")
        }
        var failures = 0
        precondition(HubAirDropFileDropReceiver.receive(providers: [provider(file as NSURL, error: CocoaError(.fileReadUnknown))],
            canReceive: { true }, completion: { _ in preconditionFailure("Provider errors cannot be ignored") }, onError: { _ in failures += 1 }))
        try await wait { failures == 1 }
    }

    @MainActor private static func timeoutAndStateChanges(file: URL) async throws {
        let timeout = FileURLGate()
        var timeoutErrors = 0, outputs = 0
        precondition(HubAirDropFileDropReceiver.receive(providers: [provider(file as NSURL), FileURLProvider { timeout.hold($0) }],
            timeout: 0.03, canReceive: { true }, completion: { _ in outputs += 1 }, onError: { _ in timeoutErrors += 1 }))
        try await wait { timeout.started }
        try await wait { timeoutErrors == 1 && !HubImportActivity.isBusy }
        timeout.release(file as NSURL)
        // A late previous callback must not suppress or duplicate a later drop.
        precondition(HubAirDropFileDropReceiver.receive(providers: [provider(file as NSURL)], canReceive: { true },
            completion: { _ in outputs += 1 }, onError: { preconditionFailure($0) }))
        try await wait { outputs == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(outputs == 1 && timeoutErrors == 1)

        for disabled in [true, false] {
            let gate = FileURLGate()
            var enabled = true, busy = false, errors = 0
            precondition(HubAirDropFileDropReceiver.receive(providers: [FileURLProvider { gate.hold($0) }],
                canReceive: { enabled && !busy }, completion: { _ in preconditionFailure("State changed before delivery") }, onError: { _ in errors += 1 }))
            try await wait { gate.started }
            if disabled { enabled = false } else { busy = true }
            gate.release(file as NSURL)
            try await wait { errors == 1 && !HubImportActivity.isBusy }
        }
    }

    @MainActor private static func boundedProviderInvocations(file: URL) async throws {
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let blocking = FileURLProvider { callback in
            entered.signal(); release.wait(); callback(file as NSURL, nil); returned.signal()
        }
        var errors = 0
        for _ in 0..<2 {
            precondition(HubAirDropFileDropReceiver.receive(providers: [blocking], timeout: 0.03, canReceive: { true },
                completion: { _ in preconditionFailure("Timed-out work must not share later") }, onError: { _ in errors += 1 }))
        }
        try await wait { errors == 2 }
        precondition(entered.wait(timeout: .now()) == .success && entered.wait(timeout: .now()) == .success)
        let excess = FileURLProvider { _ in preconditionFailure("Stalled calls must retain the real worker slots") }
        precondition(HubAirDropFileDropReceiver.receive(providers: [excess], canReceive: { true },
            completion: { _ in preconditionFailure("No worker available") }, onError: { _ in errors += 1 }))
        try await wait { errors == 3 && !HubImportActivity.isBusy }
        release.signal(); release.signal()
        try await wait { returned.wait(timeout: .now()) == .success }
        try await wait { returned.wait(timeout: .now()) == .success }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(errors == 3)
    }

    @MainActor private static func admission(file: URL) {
        let valid = provider(file as NSURL)
        let image = FileURLProvider(type: UTType.png.identifier) { _ in preconditionFailure("No image conversion") }
        var begins = 0, ends = 0, callbacks = 0
        func accept(_ providers: [NSItemProvider], allowed: Bool = true, ticket: UUID? = UUID()) -> Bool {
            HubAirDropFileDropReceiver.receive(providers: providers, canReceive: { allowed },
                beginActivity: { begins += 1; return ticket }, endActivity: { _ in ends += 1 },
                completion: { _ in callbacks += 1 }, onError: { _ in callbacks += 1 })
        }
        precondition(!accept([]) && !accept([valid], allowed: false) && !accept([valid, image])
                     && !accept(Array(repeating: valid, count: 1001)))
        precondition(begins == 0 && callbacks == 0 && ends == 0)
        precondition(!accept([valid], ticket: nil) && begins == 1 && callbacks == 0 && ends == 0)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Timed out waiting for provider state")
    }
}
