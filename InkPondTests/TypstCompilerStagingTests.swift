import Foundation
import Testing
@testable import InkPond

@Suite(.serialized)
@MainActor
struct TypstCompilerStagingTests {
    @Test(arguments: [false, true])
    func supersededCaptureCannotPublishAndOnlyLatestInputStages(oldFails: Bool) async throws {
        let started = AsyncStream<URL>.makeStream()
        let compiled = AsyncStream<String>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let compiler = TypstCompiler(compileWorker: { source, _, _, _ in
            compiled.continuation.yield(source)
            return .failure(.compilerNotLinked)
        }, snapshotStager: { input in
            #expect(!Thread.isMainThread)
            let snapshot = try OperationSnapshot.capture(input)
            if input.source == "old" {
                started.continuation.yield(snapshot.rootURL)
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw SnapshotCaptureError.limitExceeded
                }
                if oldFails { throw SnapshotCaptureError.inputChanged }
            }
            return snapshot
        })
        compiler.compile(input: input("old"), mode: .immediate)
        var starts = started.stream.makeAsyncIterator()
        let oldRoot = try #require(await starts.next())
        // Executing this main-actor code while capture is blocked proves that
        // staging does not occupy the actor. Intermediate inputs must coalesce.
        compiler.compile(input: input("intermediate"), mode: .immediate)
        compiler.compile(input: input("latest"), mode: .immediate)
        #expect(compiler.isCompileQueued)
        #expect(!compiler.isCompiling)
        release.signal()
        var results = compiled.stream.makeAsyncIterator()
        #expect(await results.next() == "latest")
        #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
        #expect(compiler.errorMessage != SnapshotCaptureError.inputChanged.localizedDescription)
        compiler.cancel()
    }

    @Test func cancellationReleasesUnacceptedSnapshotAndDoesNotPublish() async throws {
        let started = AsyncStream<URL>.makeStream()
        let next = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let compiler = TypstCompiler(compileWorker: { source, _, _, _ in
            #expect(source == "next")
            return .failure(.compilerNotLinked)
        }, snapshotStager: { input in
            #expect(!Thread.isMainThread)
            let snapshot = try OperationSnapshot.capture(input)
            if input.source == "cancel" {
                started.continuation.yield(snapshot.rootURL)
                _ = release.wait(timeout: .now() + 10)
            } else {
                next.continuation.yield(true)
            }
            return snapshot
        })
        compiler.compile(input: input("cancel"), mode: .immediate)
        var starts = started.stream.makeAsyncIterator()
        let root = try #require(await starts.next())
        compiler.cancel()
        #expect(!compiler.isPreviewUpdating)
        #expect(compiler.errorMessage == nil)
        // Starting a subsequent capture is a deterministic drain barrier: the
        // single staging slot cannot start it until cancelled capture returns.
        compiler.compile(input: input("next"), mode: .immediate)
        release.signal()
        var nexts = next.stream.makeAsyncIterator()
        #expect(await nexts.next() == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        compiler.cancel()
    }

    @Test func debouncePrecedesStagingAndInputValuesAreFrozen() async throws {
        let sleeping = AsyncStream<Bool>.makeStream()
        let gate = StagingDebounceGate()
        let staged = AsyncStream<String>.makeStream()
        let captureStarted = StagingCaptureFlag()
        let compiler = TypstCompiler(compileWorker: { _, _, _, _ in
            .failure(.compilerNotLinked)
        }, snapshotStager: { input in
            #expect(!Thread.isMainThread)
            captureStarted.mark()
            staged.continuation.yield(input.source)
            return try OperationSnapshot.capture(input)
        }, sleep: { _ in
            await gate.wait(started: sleeping.continuation)
        })
        var value = input("intent")
        compiler.compile(input: value)
        value.source = "mutated"
        var sleeps = sleeping.stream.makeAsyncIterator()
        #expect(await sleeps.next() == true)
        #expect(compiler.isCompileQueued)
        #expect(!compiler.isCompiling)
        #expect(!captureStarted.value)
        await gate.release()
        var stages = staged.stream.makeAsyncIterator()
        #expect(await stages.next() == "intent")
        compiler.cancel()
    }

    @Test func cancellationDuringPreparationRetainsLeaseAndPhysicalSlot() async throws {
        let started = AsyncStream<URL>.makeStream()
        let next = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let preparationStarted = StagingCaptureFlag()
        defer { release.signal() }
        let compiler = TypstCompiler(compileWorker: { _, _, _, _ in
            Issue.record("A failed/cancelled preparation must never reach the worker")
            return .failure(.compilerNotLinked)
        }, snapshotPreparer: { capture in
            #expect(!Thread.isMainThread)
            if capture.source == "cancel" {
                started.continuation.yield(capture.rootURL)
                #expect(release.wait(timeout: .now() + 10) == .success)
                #expect(FileManager.default.fileExists(atPath: capture.projectRoot.path))
                throw CancellationError()
            }
            preparationStarted.mark()
            next.continuation.yield(true)
            throw TypstBridgeError.snapshotFailed(.dependencyMiss, "next preparation failed")
        })
        compiler.compile(input: input("cancel"), mode: .immediate)
        var starts = started.stream.makeAsyncIterator()
        let root = try #require(await starts.next())
        compiler.cancel()
        #expect(FileManager.default.fileExists(atPath: root.path))
        compiler.compile(input: input("next"), mode: .immediate)
        #expect(!preparationStarted.value)
        release.signal()
        var nexts = next.stream.makeAsyncIterator()
        #expect(await nexts.next() == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(compiler.previewArtifact == nil)
        compiler.cancel()
    }

    @Test(arguments: [false, true])
    func preparationTimeoutRetainsLeaseAndSlotUntilNativeReturns(cancelAfterTimeout: Bool) async throws {
        let started = AsyncStream<URL>.makeStream()
        let sleeping = AsyncStream<Bool>.makeStream()
        let next = AsyncStream<Bool>.makeStream()
        let deadline = StagingDebounceGate()
        let release = DispatchSemaphore(value: 0)
        let nextStarted = StagingCaptureFlag()
        defer { release.signal() }
        let compiler = TypstCompiler(compileWorker: { _, _, _, _ in
            Issue.record("Timed-out preparation must never invoke the final worker")
            return .failure(.compilerNotLinked)
        }, snapshotPreparer: { capture in
            #expect(!Thread.isMainThread)
            if capture.source == "blocked" {
                started.continuation.yield(capture.rootURL)
                #expect(release.wait(timeout: .now() + 10) == .success)
                #expect(FileManager.default.fileExists(atPath: capture.projectRoot.path))
                throw TypstBridgeError.snapshotFailed(.dependencyMiss, "late native failure")
            }
            nextStarted.mark()
            next.continuation.yield(true)
            throw CancellationError()
        }, sleep: { duration in
            #expect(duration == .seconds(30))
            await deadline.wait(started: sleeping.continuation)
        })
        compiler.compile(input: input("blocked"), mode: .immediate)
        var starts = started.stream.makeAsyncIterator()
        let root = try #require(await starts.next())
        var sleeps = sleeping.stream.makeAsyncIterator()
        #expect(await sleeps.next() == true)
        await deadline.release()
        // Allow the main-actor deadline task to publish without wall-clock sleeps.
        for _ in 0..<1_000 {
            if compiler.errorMessage != nil { break }
            await Task.yield()
        }
        #expect(compiler.errorMessage == L10n.tr("error.typst.compilation_timeout"))
        #expect(!compiler.isPreviewUpdating)
        #expect(compiler.previewArtifact == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
        if cancelAfterTimeout { compiler.cancel() }
        compiler.compile(input: input("next"), mode: .immediate)
        #expect(!nextStarted.value)
        #expect(FileManager.default.fileExists(atPath: root.path))
        release.signal()
        var nexts = next.stream.makeAsyncIterator()
        #expect(await nexts.next() == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(compiler.errorMessage != "late native failure")
        #expect(compiler.previewArtifact == nil)
        compiler.cancel()
        // The injected clock intentionally ignores cancellation; drain its waiter.
        #expect(await sleeps.next() == true)
        await deadline.release()
    }

    private func input(_ source: String) -> OperationSnapshotInput {
        OperationSnapshotInput(projectID: "staging-test", title: "Test", entryFileName: "main.typ",
            source: source, projectRoot: nil, fontPaths: [], textOverlays: ["main.typ": source],
            localPackagesRoot: nil, packageCacheRoot: nil)
    }
}

private actor StagingDebounceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(started: AsyncStream<Bool>.Continuation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.yield(true)
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

nonisolated private final class StagingCaptureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
    func mark() {
        lock.lock()
        defer { lock.unlock() }
        started = true
    }
}
