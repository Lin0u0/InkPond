import Foundation
import Testing
@testable import InkPond

@Suite(.serialized)
@MainActor
struct OperationSnapshotTests {
    @Test func acceptedBytesAndValuesSurviveOriginalMutationAndNextCaptureSeesChanges() throws {
        let f = try Fixture()
        defer { f.remove() }
        var input = f.input
        input.textOverlays = ["main.typ": "unsaved entry", "chapter.typ": "unsaved chapter"]
        input.source = "effective unsaved entry"
        let first = try f.capture(input)
        try f.write("project/image.png", "new image")
        try f.write("font.ttf", "new font")
        try f.write("local/local/demo/1.0.0/lib.typ", "new package")
        try f.write("cache/preview/demo/1.0.0/lib.typ", "new cached package")
        try f.write("project/chapter.typ", "new disk chapter")
        input.title = "New title"
        input.source = "new effective source"
        input.settings = ["setting": "new"]
        input.textOverlays = ["main.typ": "new entry", "chapter.typ": "new chapter"]
        #expect(first.title == "Old title")
        #expect(first.source == "effective unsaved entry")
        #expect(first.settings == ["setting": "old"])
        #expect(try text(first.projectRoot, "image.png") == "old image")
        #expect(try text(first.projectRoot, "chapter.typ") == "unsaved chapter")
        #expect(try String(contentsOfFile: first.fontPaths[0], encoding: .utf8) == "old font")
        #expect(!FileManager.default.fileExists(atPath: first.rootURL.appendingPathComponent("local-packages").path))
        #expect(!FileManager.default.fileExists(atPath: first.rootURL.appendingPathComponent("package-cache").path))
        let next = try f.capture(input)
        #expect(next.rootURL != first.rootURL)
        #expect(next.title == "New title")
        #expect(next.source == "new effective source")
        #expect(next.settings == ["setting": "new"])
        #expect(try text(next.projectRoot, "image.png") == "new image")
        #expect(try text(next.projectRoot, "chapter.typ") == "new chapter")
        #expect(try String(contentsOfFile: next.fontPaths[0], encoding: .utf8) == "new font")
        let a = try ExportManager.temporaryTypURL(snapshot: first, fileName: "chapter.typ")
        let b = try ExportManager.temporaryTypURL(snapshot: next, fileName: "chapter.typ")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a != b)
        #expect(try String(contentsOf: a, encoding: .utf8) == "unsaved chapter")
        #expect(try String(contentsOf: b, encoding: .utf8) == "new chapter")
    }

    enum AppMutation: Sendable, CaseIterable {
        case editorSave, replaceImage, addImage
    }

    /// Pause the actual detached capture, complete a production application write,
    /// then resume. No sleeps, synthetic Stamp changes, or replacement writer.
    /// Test both the rejection boundary and the allowed complete-old-copy outcome.
    @Test(arguments: AppMutation.allCases, [false, true])
    func applicationWritesDuringCaptureRejectOrKeepCompleteOldCopy(
        mutation: AppMutation, afterVerification: Bool
    ) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let document = InkPondDocument(title: "Capture interleaving")
        document.imageDirectoryName = ""
        let project = f.root.appendingPathComponent("project")
        try BookmarkManager.saveBookmark(for: project, projectID: document.projectID)
        defer { BookmarkManager.removeBookmark(projectID: document.projectID) }
        let registry = ProjectReliabilityWriterRegistry()
        let projectID = document.stableProjectID
        let metadata = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        defer { try? FileManager.default.removeItem(at: metadata) }
        func request(_ content: String) -> ProjectReliabilityWriteRequest {
            .init(rootURL: project, backendKind: .local, projectID: projectID,
                  displayName: document.title, entryRelativePath: "main.typ",
                  relativePath: "chapter.typ", data: Data(content.utf8))
        }
        // Establish the real save context/metadata before the observed interval.
        try await registry.write(request("old disk chapter"))
        var input = f.input
        input.textOverlays = ["main.typ": "dirty entry", "chapter.typ": "dirty imported chapter"]
        input.source = "dirty entry"
        let frozenInput = input
        let staging = f.staging
        let reached = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let task = Task.detached {
            // The gate is bounded; allow more than the normal capture budget on
            // slow CI machines without changing production defaults.
            var limits = SnapshotCaptureLimits()
            limits.maximumSeconds = 60
            return try OperationSnapshot.capture(frozenInput, limits: limits, stagingParent: staging) { point in
                let shouldPause: Bool
                switch point {
                case .projectCopied: shouldPause = !afterVerification
                case .inputsVerified: shouldPause = afterVerification
                }
                guard shouldPause else { return }
                reached.continuation.yield(())
                reached.continuation.finish()
                guard resume.wait(timeout: .now() + 30) == .success else {
                    throw SnapshotCaptureError.limitExceeded
                }
            }
        }
        // Also finish on early capture failure, so the test cannot wait forever.
        let completion = Task {
            _ = await task.result
            reached.continuation.finish()
        }
        var events = reached.stream.makeAsyncIterator()
        let didReach = await events.next() != nil
        if didReach {
            do {
                switch mutation {
                case .editorSave:
                    // This is the same registry used by DocumentSession saves.
                    try await registry.write(request("saved imported chapter"))
                case .replaceImage:
                    try ProjectFileManager.saveImage(data: Data("new image, different size".utf8),
                                                     fileName: "image.png", for: document)
                case .addImage:
                    try ProjectFileManager.saveImage(data: Data("new resource".utf8),
                                                     fileName: "added.png", for: document)
                }
            } catch {
                resume.signal()
                _ = await task.result
                await registry.close(projectID: projectID, rootURL: project)
                throw error
            }
        }
        resume.signal()
        let result = await task.result
        await completion.value
        await registry.close(projectID: projectID, rootURL: project)
        #expect(didReach)
        if afterVerification {
            let snapshot = try result.get()
            #expect(snapshot.source == "dirty entry")
            #expect(try text(snapshot.projectRoot, "main.typ") == "dirty entry")
            #expect(try text(snapshot.projectRoot, "chapter.typ") == "dirty imported chapter")
            #expect(try text(snapshot.projectRoot, "image.png") == "old image")
            #expect(!FileManager.default.fileExists(atPath: snapshot.projectRoot.appendingPathComponent("added.png").path))
            // Subsequent intent sees the completed write, not a cached capture.
            let next = try f.capture(f.input)
            switch mutation {
            case .editorSave:
                #expect(try text(next.projectRoot, "chapter.typ") == "saved imported chapter")
            case .replaceImage:
                #expect(try text(next.projectRoot, "image.png") == "new image, different size")
            case .addImage:
                #expect(try text(next.projectRoot, "added.png") == "new resource")
            }
        } else {
            switch result {
            case .success: Issue.record("Capture accepted an application write across validation")
            case .failure(let error):
                guard case SnapshotCaptureError.inputChanged = error else {
                    Issue.record("Expected inputChanged, got \(error)")
                    return
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test func unrelatedHugeOrUnreadablePackageTreesAreNotCaptured() throws {
        let f = try Fixture()
        defer { f.remove() }
        let cache = f.root.appendingPathComponent("cache")
        let huge = cache.appendingPathComponent("unrelated.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(SnapshotCaptureLimits().maximumBytes + 1))
        try handle.close()
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("broken-link"),
            withDestinationURL: cache.appendingPathComponent("missing"))
        let capture = try f.capture(f.input)
        #expect(capture.capturedBytes < 1024)
        #expect(capture.preparation.packageCacheRoot == cache)
        #expect(!FileManager.default.fileExists(atPath: capture.rootURL.appendingPathComponent("package-cache").path))
    }

    @Test func failedCapturesRemoveStagingAndNeverFallBack() throws {
        let f = try Fixture()
        defer { f.remove() }
        var missing = f.input
        missing.fontPaths = [f.root.appendingPathComponent("missing.ttf").path]
        #expect(throws: (any Error).self) { try f.capture(missing) }
        var invalid = f.input
        invalid.textOverlays = ["../escape.typ": "escape"]
        #expect(throws: (any Error).self) { try f.capture(invalid) }
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("project/link"), withDestinationURL: f.root.appendingPathComponent("font.ttf"))
        #expect(throws: (any Error).self) { try f.capture(f.input) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func boundedRepeatedCaptureReportsSizeAndTimeAndReleasesLease() throws {
        let f = try Fixture()
        defer { f.remove() }
        var limits = SnapshotCaptureLimits()
        limits.maximumBytes = 1
        #expect(throws: SnapshotCaptureError.self) { try f.capture(f.input, limits: limits) }
        limits = .init()
        limits.maximumSeconds = -1
        #expect(throws: SnapshotCaptureError.self) { try f.capture(f.input, limits: limits) }
        for _ in 0..<20 {
            var snapshot: OperationSnapshot? = try f.capture(f.input)
            let path = try #require(snapshot?.rootURL.path)
            #expect(snapshot!.capturedBytes > 0)
            #expect(snapshot!.capturedBytes <= SnapshotCaptureLimits().maximumBytes)
            #expect(snapshot!.capturedEntries > 0)
            #expect(snapshot!.captureSeconds >= 0)
            #expect(snapshot!.captureSeconds <= SnapshotCaptureLimits().maximumSeconds)
            snapshot = nil
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func cancelledCaptureCleansUp() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.input
        let staging = f.staging
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OperationSnapshot.capture(input, stagingParent: staging)
        }
        do { _ = try await task.value; Issue.record("Cancelled capture accepted") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// Drive the production scheduler. Only the synchronous native call is
    /// replaced by a gate, so cancellation is tested during actual worker work.
    @Test func compilerCancellationRetainsStagingUntilWorkerReturns() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let started = AsyncStream<String>.makeStream()
        let finished = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let compiler = TypstCompiler(compileWorker: { _, fonts, root, _ in
            guard let root else { return .failure(.compilerNotLinked) }
            started.continuation.yield(root)
            started.continuation.finish()
            let released = release.wait(timeout: .now() + 10) == .success
            let exists = FileManager.default.fileExists(atPath: root)
                && fonts.allSatisfy { FileManager.default.fileExists(atPath: $0) }
            finished.continuation.yield(released && exists)
            finished.continuation.finish()
            return .failure(.compilerNotLinked)
        })
        compiler.compile(input: f.input, mode: .immediate)
        var starts = started.stream.makeAsyncIterator()
        let root = try #require(await starts.next())
        compiler.cancel()
        #expect(FileManager.default.fileExists(atPath: root))
        release.signal()
        var finishes = finished.stream.makeAsyncIterator()
        #expect(await finishes.next() == true)
    }

    @Test func concurrentCapturesAndExportsHaveIndependentPaths() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.input
        let staging = f.staging
        let snapshots = try await withThrowingTaskGroup(of: OperationSnapshot.self) { group in
            for _ in 0..<4 {
                group.addTask { try OperationSnapshot.capture(input, stagingParent: staging) }
            }
            var result: [OperationSnapshot] = []
            for try await snapshot in group { result.append(snapshot) }
            return result
        }
        #expect(Set(snapshots.map(\.rootURL)).count == 4)
        var urls: [URL] = []
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        for snapshot in snapshots {
            urls.append(try ExportManager.zipProject(snapshot: snapshot))
            urls.append(try ExportManager.temporaryPDFURL(data: Data("pdf".utf8), title: snapshot.title))
        }
        #expect(Set(urls).count == 8)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func text(_ root: URL, _ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private struct Fixture {
        let root: URL
        let staging: URL
        var input: OperationSnapshotInput {
            OperationSnapshotInput(projectID: "test", title: "Old title", entryFileName: "main.typ",
                source: "old source", projectRoot: root.appendingPathComponent("project"),
                fontPaths: [root.appendingPathComponent("font.ttf").path], settings: ["setting": "old"],
                localPackagesRoot: root.appendingPathComponent("local"), packageCacheRoot: root.appendingPathComponent("cache"))
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            staging = root.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try write("project/main.typ", "old source")
            try write("project/chapter.typ", "old disk chapter")
            try write("project/image.png", "old image")
            try write("font.ttf", "old font")
            try write("local/local/demo/1.0.0/lib.typ", "old package")
            try write("cache/preview/demo/1.0.0/lib.typ", "old cached package")
        }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        func capture(_ input: OperationSnapshotInput, limits: SnapshotCaptureLimits = .init()) throws -> OperationSnapshot {
            try OperationSnapshot.capture(input, limits: limits, stagingParent: staging)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
