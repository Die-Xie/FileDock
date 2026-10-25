import AppKit
import Foundation

private final class ScopeCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0
    func start(_ url: URL) -> Bool { lock.lock(); started += 1; lock.unlock(); return true }
    func stop(_ url: URL) { lock.lock(); stopped += 1; lock.unlock() }
    var balance: Int { lock.lock(); defer { lock.unlock() }; return started - stopped }
}

@MainActor private final class FakeAirDropService: HubAirDropSharing {
    var completion: ((Result<Void, Error>) -> Void)?
    var willPresentTransfer: (() -> Void)?
    var accepts = true
    var immediateResult: Result<Void, Error>?
    var deferredPresentation = false
    var received: [URL] = []
    func canShare(_ urls: [URL]) -> Bool { accepts }
    func perform(_ urls: [URL], from window: NSWindow?) {
        received = urls
        if !deferredPresentation { willPresentTransfer?() }
        if let immediateResult { completion?(immediateResult) }
    }
}

@MainActor private final class WeakService {
    weak var value: FakeAirDropService?
}

@main struct AirDropTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDock-AirDrop-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: file)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let application = root.appendingPathComponent("sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("alias.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        expectThrows({ _ = try HubAirDropPolicy.uniqueFiles([]) }, "Empty selection must not open system UI")
        expectThrows({ _ = try HubAirDropPolicy.uniqueFiles([file, URL(string: "https://example.com/file")!]) }, "A mixed URL batch is rejected without partial sending")
        expectThrows({ _ = try HubAirDropPolicy.uniqueFiles([URL(string: "file://another-host/tmp/item")!]) }, "Remote-authority file URLs must not silently target a local path")
        let duplicates = try HubAirDropPolicy.uniqueFiles([file, file, folder, folder, link])
        expect(duplicates == [file, folder, link], "Deduplication preserves selection order and symbolic-link identity")
        expectThrows({ _ = try HubAirDropPolicy.uniqueFiles((0...1000).map { root.appendingPathComponent(String($0)) }) }, "Huge selections are bounded")
        for url in [file, folder, application, link] { try HubAirDropPolicy.validateFile(url) }
        expectThrows({ try HubAirDropPolicy.validateFile(root.appendingPathComponent("missing")) }, "Missing files fail before the sharing service starts")
        expect(HubAirDropPolicy.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)), "Cocoa cancellation is quiet")
        expect(HubAirDropPolicy.isCancellation(NSError(domain: NSOSStatusErrorDomain, code: -128)), "System cancellation is quiet")
        expect(!HubAirDropPolicy.isCancellation(NSError(domain: "test", code: -128)), "Unrelated errors must not be treated as cancellation")
        expect(!HubAirDropPolicy.allowsService(title: "隔空投送", airDropTitle: "隔空投送", allowsAirDrop: false), "Disabled AirDrop is matched against the system's localized title")
        expect(HubAirDropPolicy.allowsService(title: "信息", airDropTitle: "隔空投送", allowsAirDrop: false), "Disabling AirDrop preserves other sharing services")
        expect(HubAirDropPolicy.allowsService(title: "AirDrop", airDropTitle: "AirDrop", allowsAirDrop: true), "Enabled AirDrop remains available")
        expect(HubAirDropPolicy.allowsService(title: "Mail", airDropTitle: nil, allowsAirDrop: false), "An unavailable AirDrop service cannot remove unrelated services")

        let scopes = ScopeCounts(), holder = WeakService()
        var changes: [Bool] = [], errors: [String] = []
        let controller = HubAirDropController(serviceFactory: {
            let service = FakeAirDropService(); holder.value = service; return service
        }, validate: { url in
            expect(!Thread.isMainThread, "Filesystem validation must run off the main thread")
            try HubAirDropPolicy.validateFile(url)
        }, makeLease: { HubAirDropScopeLease(urls: $0, start: scopes.start, stop: scopes.stop) })
        controller.presentationStateDidChange = { changes.append($0) }
        controller.onError = { errors.append($0) }
        controller.send([file, folder, file], securityScopedURLs: [root])
        expect(controller.state == .preparing && changes.isEmpty, "Preparing files must not display or hide windows")
        await wait { holder.value?.received == [file, folder] }
        expect(controller.state == .sharing && changes == [true], "Validated batch invokes one system service")
        expect(scopes.balance == 3, "Independent access to ancestor and selected URLs remains active during sending")
        expect(holder.value != nil, "Controller retains the delegate/service for the whole request")
        controller.send([application])
        expect(errors.count == 1 && holder.value?.received == [file, folder], "A second request cannot replace a live transfer")
        let staleCompletion = holder.value?.completion
        holder.value?.completion?(.success(()))
        expect(!controller.isBusy && changes == [true, false] && scopes.balance == 0, "Completion restores presentation and releases every scope")
        expect(holder.value == nil, "Completion releases the service")
        staleCompletion?(.failure(HubAirDropError.unavailable))
        expect(errors.count == 1 && changes.count == 2, "Late duplicate service callbacks have no effect")

        controller.send([file])
        await wait { holder.value?.received == [file] }
        holder.value?.completion?(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        expect(!controller.isBusy && errors.count == 1 && scopes.balance == 0, "User cancellation is quiet and fully cleans up")
        controller.send([file])
        await wait { holder.value?.received == [file] }
        holder.value?.completion?(.failure(HubAirDropError.unreadable("image.svg")))
        expect(errors.count == 2 && !controller.isBusy && scopes.balance == 0, "Transmission failures are surfaced after cleanup")

        let noService = HubAirDropController(serviceFactory: { nil }, makeLease: {
            HubAirDropScopeLease(urls: $0, start: scopes.start, stop: scopes.stop)
        })
        noService.onError = { errors.append($0) }
        noService.presentationStateDidChange = { _ in preconditionFailure("Unavailable services must not hide windows") }
        noService.send([file])
        await wait { !noService.isBusy }
        expect(scopes.balance == 0 && errors.count == 3, "Unavailable services release prepared file scopes")

        let rejected = HubAirDropController(serviceFactory: {
            let service = FakeAirDropService(); service.accepts = false; return service
        }, makeLease: { HubAirDropScopeLease(urls: $0, start: scopes.start, stop: scopes.stop) })
        rejected.onError = { errors.append($0) }
        rejected.presentationStateDidChange = { _ in preconditionFailure("Rejected batches must not hide windows") }
        rejected.send([file])
        await wait { !rejected.isBusy }
        expect(scopes.balance == 0 && errors.count == 4, "A service rejecting the batch releases its prepared lease")

        var validationErrors: [String] = []
        let failing = HubAirDropController(serviceFactory: { preconditionFailure("A failed validation must never construct the sharing service") },
            validate: { _ in throw HubAirDropError.unreadable("image.svg") },
            makeLease: { HubAirDropScopeLease(urls: $0, start: scopes.start, stop: scopes.stop) })
        failing.onError = { validationErrors.append($0) }
        failing.send([file])
        await wait { !failing.isBusy }
        expect(scopes.balance == 0 && validationErrors.count == 1, "A permission failure releases the lease and produces an understandable error")

        // A selected service can finish synchronously; no busy flag or scopes
        // should remain after perform returns.
        let immediate = HubAirDropController(serviceFactory: {
            let service = FakeAirDropService(); service.immediateResult = .success(()); return service
        })
        var immediateChanges: [Bool] = []
        immediate.presentationStateDidChange = { immediateChanges.append($0) }
        immediate.send([file])
        await wait { !immediate.isBusy }
        expect(immediateChanges == [true, false], "Synchronous service completion balances presentation exactly once")

        let deferredHolder = WeakService()
        let deferred = HubAirDropController(serviceFactory: {
            let service = FakeAirDropService(); service.deferredPresentation = true
            deferredHolder.value = service; return service
        })
        var deferredChanges: [Bool] = []
        deferred.presentationStateDidChange = { deferredChanges.append($0) }
        deferred.send([file])
        await wait { deferredHolder.value?.received == [file] }
        expect(deferred.isBusy && deferredChanges.isEmpty, "A service picker holds the lease without hiding its source browser")
        deferredHolder.value?.willPresentTransfer?()
        deferredHolder.value?.willPresentTransfer?()
        expect(deferredChanges == [true], "Choosing a service suspends presentation exactly once")
        deferredHolder.value?.completion?(.success(()))
        expect(deferredChanges == [true, false] && !deferred.isBusy, "Chosen service completion balances deferred presentation")

        try await testCancellationAndTimeout(file: file)
        try await testBoundedWorkers(file: file)
        testPickerCancellation(file: file)
        testPickerAirDropFilter(file: file)
        let native = HubNativeAirDropService.make()
        print("Native AirDrop service available: \(native != nil); accepts local file/folder: \(native?.canShare([file, folder]) == true) (no UI or transmission requested)")
        print("AirDrop policy, scope, worker, cancellation and lifecycle tests passed")
    }

    @MainActor private static func testCancellationAndTimeout(file: URL) async throws {
        for timeoutMode in [false, true] {
            let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            let scopes = ScopeCounts()
            var errors: [String] = [], serviceRequests = 0
            let controller = HubAirDropController(preparer: HubAirDropPreparer(),
                timeoutNanoseconds: timeoutMode ? 100_000_000 : 5_000_000_000,
                serviceFactory: { serviceRequests += 1; return FakeAirDropService() },
                validate: { _ in entered.signal(); released.wait() },
                makeLease: { HubAirDropScopeLease(urls: $0, start: scopes.start, stop: scopes.stop) })
            controller.onError = { errors.append($0) }
            controller.send([file])
            await wait { scopes.balance == 1 }
            expect(entered.wait(timeout: .now()) == .success, "Worker begins validation")
            if timeoutMode { await wait { !controller.isBusy } }
            else { controller.cancelPreparation() }
            expect(!controller.isBusy && scopes.balance == 1, "Cancellation does not release scopes under a still-running filesystem call")
            expect(errors.count == (timeoutMode ? 1 : 0), "Only a timeout reports an error")
            released.signal()
            await wait { scopes.balance == 0 }
            await Task.yield()
            expect(serviceRequests == 0, "Cancelled or timed-out preparation must never send later")
        }
    }

    @MainActor private static func testBoundedWorkers(file: URL) async throws {
        let preparer = HubAirDropPreparer(), release = DispatchSemaphore(value: 0)
        let scopeCounts = ScopeCounts()
        let jobs = [HubAirDropPreparation(), HubAirDropPreparation(), HubAirDropPreparation()]
        for index in 0..<2 {
            expect(preparer.prepare([file], scopeURLs: [], job: jobs[index], validate: { _ in release.wait() },
                makeLease: { HubAirDropScopeLease(urls: $0, start: scopeCounts.start, stop: scopeCounts.stop) },
                completion: { _ in }), "Two workers may prepare concurrently")
        }
        await wait { scopeCounts.balance == 2 }
        expect(!preparer.prepare([file], scopeURLs: [], job: jobs[2], completion: { _ in }), "Stalled workers cannot create an unbounded backlog")
        jobs.forEach { $0.cancel() }
        release.signal(); release.signal()
        await wait { scopeCounts.balance == 0 }
    }

    @MainActor private static func testPickerCancellation(file: URL) {
        let view = NSView(frame: .zero)
        let service = HubNativeSharingPicker(relativeTo: .zero, of: view, preferredEdge: .minY)
        let picker = NSSharingServicePicker(items: [file])
        var completions = 0, presentations = 0
        service.completion = { _ in completions += 1 }
        service.willPresentTransfer = { presentations += 1 }
        service.sharingServicePicker(picker, didChoose: nil)
        service.sharingServicePicker(picker, didChoose: nil)
        expect(completions == 1 && presentations == 0, "Dismissing a picker is idempotent and never hides the browser")

        let chosen = HubNativeSharingPicker(relativeTo: .zero, of: view, preferredEdge: .minY)
        let actual = NSSharingService(title: "Fixture", image: NSImage(), alternateImage: nil, handler: {})
        chosen.willPresentTransfer = { presentations += 1 }
        chosen.completion = { _ in completions += 1 }
        expect(chosen.sharingServicePicker(picker, delegateFor: actual) === chosen, "Chosen service receives the retained delegate")
        chosen.sharingServicePicker(picker, didChoose: actual)
        expect(presentations == 1, "Only explicitly choosing a service begins the transfer presentation")
        chosen.sharingService(actual, didShareItems: [file])
        chosen.sharingService(actual, didShareItems: [file])
        expect(completions == 2, "Repeated native completion is ignored")
    }

    @MainActor private static func testPickerAirDropFilter(file: URL) {
        let view = NSView(frame: .zero), picker = NSSharingServicePicker(items: [file])
        let unrelated = NSSharingService(title: "Unrelated Fixture", image: NSImage(), alternateImage: nil, handler: {})
        let nativeAirDrop = NSSharingService(named: .sendViaAirDrop)
        let proposed = [unrelated] + [nativeAirDrop].compactMap { $0 }
        let disabled = HubNativeSharingPicker(relativeTo: .zero, of: view, preferredEdge: .minY, allowsAirDrop: false)
        let filtered = disabled.sharingServicePicker(picker, sharingServicesForItems: [file], proposedSharingServices: proposed)
        expect(filtered.count == 1 && filtered.first === unrelated, "The public picker delegate removes only AirDrop, preserving identity/order of remaining services")
        let enabled = HubNativeSharingPicker(relativeTo: .zero, of: view, preferredEdge: .minY, allowsAirDrop: true)
        let all = enabled.sharingServicePicker(picker, sharingServicesForItems: [file], proposedSharingServices: proposed)
        expect(all.count == proposed.count && zip(all, proposed).allSatisfy { $0 === $1 }, "Enabled picker returns all proposed service objects in their original order")
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for asynchronous test state")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func expectThrows(_ operation: () throws -> Void, _ message: String) {
        do { try operation(); preconditionFailure(message) } catch {}
    }
}
