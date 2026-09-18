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

    /// A bounded real-save collision, using the same successful gate pattern as
    /// OperationSnapshotTests. Do not close the writer or await a synthetic clock
    /// while the first capture is still waiting for the test to release it.
    @Test(.timeLimit(.minutes(1)))
    func applicationSaveCollisionAutomaticallyRecapturesFrozenIntent() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("disk entry".utf8).write(to: project.appendingPathComponent("main.typ"))
        let projectID = ProjectID()
        let metadata = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        defer { try? FileManager.default.removeItem(at: metadata) }
        let registry = ProjectReliabilityWriterRegistry()
        func save(_ text: String) async throws {
            try await registry.write(.init(rootURL: project, backendKind: .local,
                projectID: projectID, displayName: "Test", entryRelativePath: "main.typ",
                relativePath: "chapter.typ", data: Data(text.utf8)))
        }
        try await save("old disk chapter")
        let reached = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<String>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let attempts = StagingAttemptCounter()
        let rejections = StagingAttemptCounter()
        let compiler = TypstCompiler(compileWorker: { source, _, capturedRoot, _ in
            #expect(capturedRoot != project.path)
            if let capturedRoot {
                let chapter = URL(fileURLWithPath: capturedRoot).appendingPathComponent("chapter.typ")
                #expect((try? String(contentsOf: chapter, encoding: .utf8)) == "dirty chapter")
            }
            completed.continuation.yield(source)
            completed.continuation.finish()
            return .failure(.compilerNotLinked) // reachability, not native-output proof
        }, snapshotStager: { value in
            let attempt = attempts.increment()
            #expect(value.source == "frozen entry")
            #expect(value.settings == ["setting": "frozen"])
            #expect(value.frozenUnixSeconds == 123)
            do {
                var limits = SnapshotCaptureLimits()
                limits.maximumSeconds = 60
                return try OperationSnapshot.capture(value, limits: limits, stagingParent: staging) { point in
                    guard attempt == 1, case .projectCopied = point else { return }
                    reached.continuation.yield(())
                    reached.continuation.finish()
                    guard release.wait(timeout: .now() + 30) == .success else {
                        throw SnapshotCaptureError.limitExceeded
                    }
                }
            } catch {
                if case SnapshotCaptureError.inputChanged = error { _ = rejections.increment() }
                throw error
            }
        })
        var value = input("frozen entry")
        value.projectRoot = project
        value.textOverlays["chapter.typ"] = "dirty chapter"
        value.settings = ["setting": "frozen"]
        value.frozenUnixSeconds = 123
        compiler.compile(input: value, mode: .immediate)
        var checkpoints = reached.stream.makeAsyncIterator()
        #expect(await checkpoints.next() != nil)
        do { try await save("application autosave with different bytes") }
        catch { release.signal(); compiler.cancel(); await registry.close(projectID: projectID, rootURL: project); throw error }
        value.source = "new live source"
        value.textOverlays["chapter.typ"] = "new live chapter"
        value.settings = [:]
        value.frozenUnixSeconds = 456
        release.signal()
        var results = completed.stream.makeAsyncIterator()
        #expect(await results.next() == "frozen entry")
        #expect(attempts.value == 2)
        #expect(rejections.value == 1)
        print("[M2CaptureRecovery] imported-file save: one inputChanged rejection, frozen overlays/settings/time retained across automatic recapture")
        compiler.cancel()
        await registry.close(projectID: projectID, rootURL: project)
    }

    @Test(arguments: ["changed", "unreadable", "limit", "unsupported", "native"])
    func captureRecoveryIsBoundedAndClassified(kind: String) async throws {
        let attempts = StagingAttemptCounter()
        let delays = StagingAttemptCounter()
        let compiler = TypstCompiler(compileWorker: { _, _, _, _ in
            Issue.record("Rejected input reached final worker")
            return .failure(.compilerNotLinked)
        }, snapshotStager: { _ in
            _ = attempts.increment()
            switch kind {
            case "changed": throw SnapshotCaptureError.inputChanged
            case "unreadable": throw CocoaError(.fileReadNoPermission)
            case "limit": throw SnapshotCaptureError.limitExceeded
            case "unsupported": throw SnapshotCaptureError.unsupportedInput
            default: throw TypstBridgeError.snapshotFailed(.inputChanged, "native failure")
            }
        }, sleep: { duration in
            #expect(duration == .milliseconds(150))
            _ = delays.increment()
        })
        compiler.compile(input: input("private source"), mode: .immediate)
        for _ in 0..<10_000 {
            if compiler.errorMessage != nil { break }
            await Task.yield()
        }
        #expect(compiler.errorMessage != nil)
        #expect(attempts.value == (kind == "changed" ? 3 : 1))
        #expect(delays.value == (kind == "changed" ? 2 : 0))
        #expect(compiler.previewArtifact == nil)
        compiler.cancel()
    }

    @Test(arguments: [false, true])
    func retryDelayCancellationKeepsSlotAndCannotPublish(supersede: Bool) async throws {
        let sleeping = AsyncStream<Bool>.makeStream()
        let compiled = AsyncStream<String>.makeStream()
        let gate = StagingDebounceGate()
        let attempts = StagingAttemptCounter()
        let compiler = TypstCompiler(compileWorker: { source, _, _, _ in
            compiled.continuation.yield(source)
            return .success(TypstPreviewArtifact(svgPages: [], pdfData: nil, sourceMap: nil))
        }, snapshotStager: { value in
            _ = attempts.increment()
            if value.source == "old" { throw SnapshotCaptureError.inputChanged }
            return try OperationSnapshot.capture(value)
        }, sleep: { _ in
            // Intentionally cancellation-insensitive to prove the explicit check.
            await gate.wait(started: sleeping.continuation)
        })
        compiler.compile(input: input("old"), mode: .immediate)
        var sleeps = sleeping.stream.makeAsyncIterator()
        #expect(await sleeps.next() == true)
        if !supersede { compiler.cancel() }
        compiler.compile(input: input("latest"), mode: .immediate)
        #expect(attempts.value == 1) // old physical slot is still occupied
        #expect(compiler.previewArtifact == nil)
        await gate.release()
        var results = compiled.stream.makeAsyncIterator()
        #expect(await results.next() == "latest")
        #expect(attempts.value == 2) // no second old capture
        #expect(compiler.errorMessage == nil)
        compiler.cancel()
    }

    @Test(arguments: [false, true], [false, true])
    func preparationInputChangedNeverRecaptures(existingCapture: Bool, nativeFailure: Bool) async throws {
        let captures = StagingAttemptCounter()
        let preparations = StagingAttemptCounter()
        let compiler = TypstCompiler(compileWorker: { _, _, _, _ in
            Issue.record("Failed preparation reached worker")
            return .failure(.compilerNotLinked)
        }, snapshotStager: { value in
            _ = captures.increment()
            return try OperationSnapshot.capture(value)
        }, snapshotPreparer: { _ in
            _ = preparations.increment()
            if nativeFailure {
                throw TypstBridgeError.snapshotFailed(.inputChanged, "native changed")
            }
            // Even the Swift error is not retryable outside the capture phase.
            throw SnapshotCaptureError.inputChanged
        })
        if existingCapture {
            compiler.compile(snapshot: try OperationSnapshot.capture(input("frozen")), mode: .immediate)
        } else { compiler.compile(input: input("frozen"), mode: .immediate) }
        for _ in 0..<10_000 {
            if compiler.errorMessage != nil { break }
            await Task.yield()
        }
        #expect(compiler.errorMessage == (nativeFailure ? "native changed" : SnapshotCaptureError.inputChanged.localizedDescription))
        #expect(captures.value == (existingCapture ? 0 : 1))
        #expect(preparations.value == 1)
        compiler.cancel()
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

nonisolated private final class StagingAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
