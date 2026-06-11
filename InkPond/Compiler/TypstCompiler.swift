//
//  TypstCompiler.swift
//  InkPond
//
//  Debounced compile pipeline: source → Rust FFI → SVG preview artifact.
//

import Observation
import Foundation
import os
import PDFKit

enum TypstCompileMode: Sendable {
    case debounced
    case immediate
}

enum TypstPreviewCachePolicy: Sendable {
    case useCacheIfValid
    case bypassCache
}

typealias TypstCompileWorker = @Sendable (String, [String], String?, String?) -> Result<TypstPreviewArtifact, TypstBridgeError>
typealias TypstDocumentBuilder = @Sendable (Data) -> PDFDocument?
typealias TypstCompilerSleep = @Sendable (Duration) async throws -> Void
typealias PreviewPackagePrefetcher = @Sendable ([String]) -> Result<Void, TypstBridgeError>

private struct TypstCompileRequest: Sendable {
    let source: String
    let fontPaths: [String]
    let rootDir: String?
    let mode: TypstCompileMode
    let previewCachePolicy: TypstPreviewCachePolicy
    let previewCacheDescriptor: CompiledPreviewCacheDescriptor?
    let generation: UInt64
}

private enum TypstWorkerResult: Sendable {
    case success(TypstPreviewArtifact, loadedFromCache: Bool)
    case failure(TypstBridgeError)
}

private struct TypstCompileTimeoutError: Error {}

private typealias PreviewPackageReference = (name: String, version: String, spec: String)

@MainActor
@Observable
final class TypstCompiler {
    nonisolated private static let compileDelay = Duration.milliseconds(350)
    nonisolated private static let errorVisibilityDelay = Duration.seconds(1)
    nonisolated private static let compileTimeout = Duration.seconds(30)
    nonisolated private static let uncachedPreviewPackageCompileTimeout = Duration.seconds(120)
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InkPond",
        category: "TypstCompiler"
    )
    nonisolated private static let signposter = OSSignposter(logger: logger)

    private(set) var previewArtifact: TypstPreviewArtifact?
    private(set) var pdfDocument: PDFDocument?
    private(set) var pdfData: Data?
    private(set) var errorMessage: String?
    private(set) var isCompileQueued: Bool = false
    private(set) var isCompiling: Bool = false
    /// Tracks whether a compiled preview artifact is currently available.
    private(set) var compiledOnce: Bool = false
    /// Source map from the most recent successful compilation.
    private(set) var sourceMap: SourceMap?

    var pageCount: Int {
        previewArtifact?.pageCount ?? pdfDocument?.pageCount ?? 0
    }

    var isPreviewUpdating: Bool {
        isCompileQueued || isCompiling
    }

    private let compileWorker: TypstCompileWorker
    private let documentBuilder: TypstDocumentBuilder
    private let sleep: TypstCompilerSleep
    private let previewCacheStore: CompiledPreviewCacheStore
    private let typstVersionProvider: @Sendable () -> String?
    private let packageCacheDirectory: URL?
    private let previewPackagePrefetcher: PreviewPackagePrefetcher

    private var debounceTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var delayedErrorTask: Task<Void, Never>?
    private var scheduledRequest: TypstCompileRequest?
    private var pendingRequest: TypstCompileRequest?
    private var compileGeneration: UInt64 = 0

    init(
        compileWorker: @escaping TypstCompileWorker = { source, fontPaths, rootDir, sessionKey in
            TypstBridge.compilePreviewSVG(
                source: source,
                fontPaths: fontPaths,
                rootDir: rootDir,
                sessionKey: sessionKey
            )
        },
        documentBuilder: @escaping TypstDocumentBuilder = { PDFDocument(data: $0) },
        sleep: @escaping TypstCompilerSleep = { try await Task.sleep(for: $0) },
        previewCacheStore: CompiledPreviewCacheStore = CompiledPreviewCacheStore(),
        typstVersionProvider: @escaping @Sendable () -> String? = { TypstBridge.runtimeVersion },
        packageCacheDirectory: URL? = TypstBridge.packageCacheDirectoryURL,
        previewPackagePrefetcher: @escaping PreviewPackagePrefetcher = { specs in
            for spec in specs {
                switch TypstBridge.prefetchPreviewPackage(spec: spec) {
                case .success:
                    continue
                case .failure(let error):
                    return .failure(error)
                }
            }
            return .success(())
        }
    ) {
        self.compileWorker = compileWorker
        self.documentBuilder = documentBuilder
        self.sleep = sleep
        self.previewCacheStore = previewCacheStore
        self.typstVersionProvider = typstVersionProvider
        self.packageCacheDirectory = packageCacheDirectory
        self.previewPackagePrefetcher = previewPackagePrefetcher
    }

    nonisolated static func taskPriority(for mode: TypstCompileMode) -> TaskPriority {
        switch mode {
        case .debounced:
            // Preview refreshes should yield to direct user actions.
            return .utility
        case .immediate:
            // Match the typical QoS of Rust's worker pool to avoid inversion warnings.
            return .medium
        }
    }

    func compile(
        source: String,
        fontPaths: [String],
        rootDir: String? = nil,
        mode: TypstCompileMode = .debounced,
        previewCachePolicy: TypstPreviewCachePolicy = .bypassCache,
        previewCacheDescriptor: CompiledPreviewCacheDescriptor? = nil
    ) {
        compileGeneration &+= 1
        // Invalidate the source map immediately so stale mappings are not used
        // while the new compilation is in flight.
        sourceMap = nil
        if mode == .debounced {
            cancelDelayedError()
            errorMessage = nil
        }
        let request = TypstCompileRequest(
            source: source,
            fontPaths: fontPaths,
            rootDir: rootDir,
            mode: mode,
            previewCachePolicy: previewCachePolicy,
            previewCacheDescriptor: previewCacheDescriptor,
            generation: compileGeneration
        )
        enqueue(request, mode: mode)
    }

    func compileNow(
        source: String,
        fontPaths: [String],
        rootDir: String? = nil,
        previewCachePolicy: TypstPreviewCachePolicy = .bypassCache,
        previewCacheDescriptor: CompiledPreviewCacheDescriptor? = nil
    ) {
        compile(
            source: source,
            fontPaths: fontPaths,
            rootDir: rootDir,
            mode: .immediate,
            previewCachePolicy: previewCachePolicy,
            previewCacheDescriptor: previewCacheDescriptor
        )
    }

    /// Clear current preview content and cancel any in-flight compilation.
    func clearPreview() {
        cancelAllWork()
        previewArtifact = nil
        pdfDocument = nil
        pdfData = nil
        errorMessage = nil
        compiledOnce = false
        sourceMap = nil
    }

    func presentPreflightError(_ message: String) {
        cancelAllWork()
        sourceMap = nil
        cancelDelayedError()
        errorMessage = message
    }

    func pdfDocumentForCurrentData() -> PDFDocument? {
        if let pdfDocument {
            return pdfDocument
        }
        guard let pdfData,
              let document = documentBuilder(pdfData) else {
            return nil
        }
        pdfDocument = document
        return document
    }

    /// Cancel any in-flight compilation (e.g. when document is closed).
    func cancel() {
        cancelAllWork()
    }

    private func cancelAllWork() {
        debounceTask?.cancel()
        debounceTask = nil
        activeTask?.cancel()
        activeTask = nil
        cancelDelayedError()
        scheduledRequest = nil
        pendingRequest = nil
        compileGeneration &+= 1
        refreshCompileQueuedState()
        isCompiling = false
    }

    private func enqueue(_ request: TypstCompileRequest, mode: TypstCompileMode) {
        switch mode {
        case .debounced:
            scheduledRequest = request
            refreshCompileQueuedState()
            debounceTask?.cancel()
            let sleep = self.sleep
            debounceTask = Task { [weak self] in
                do {
                    try await sleep(Self.compileDelay)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                self?.activateScheduledRequest(generation: request.generation)
            }
        case .immediate:
            debounceTask?.cancel()
            debounceTask = nil
            scheduledRequest = nil
            pendingRequest = request
            refreshCompileQueuedState()
            startNextCompileIfNeeded()
        }
    }

    private func activateScheduledRequest(generation: UInt64) {
        guard scheduledRequest?.generation == generation else { return }
        pendingRequest = scheduledRequest
        scheduledRequest = nil
        debounceTask = nil
        refreshCompileQueuedState()
        startNextCompileIfNeeded()
    }

    private func startNextCompileIfNeeded() {
        guard activeTask == nil, let request = pendingRequest else { return }

        pendingRequest = nil
        refreshCompileQueuedState()
        isCompiling = true

        let compileWorker = self.compileWorker
        let documentBuilder = self.documentBuilder
        let previewCacheStore = self.previewCacheStore
        let typstVersionProvider = self.typstVersionProvider
        let packageCacheDirectory = self.packageCacheDirectory
        let previewPackagePrefetcher = self.previewPackagePrefetcher
        let priority = Self.taskPriority(for: request.mode)
        let packageSpecs = Self.uncachedPreviewPackageSpecs(
            forSource: request.source,
            packageCacheDirectory: packageCacheDirectory
        )
        activeTask = Task { [weak self] in
            if !packageSpecs.isEmpty {
                let preflightTask = Task.detached(priority: priority) {
                    previewPackagePrefetcher(packageSpecs)
                }
                let preflightResult = await preflightTask.value
                guard !Task.isCancelled else { return }

                if case .failure(let error) = preflightResult {
                    self?.finishCompilation(.failure(error), generation: request.generation, request: request)
                    return
                }
            }

            let compilationTask = Task.detached(priority: priority) {
                Self.runCompilation(
                    request: request,
                    compileWorker: compileWorker,
                    documentBuilder: documentBuilder,
                    previewCacheStore: previewCacheStore,
                    typstVersionProvider: typstVersionProvider
                )
            }

            let timeout = packageSpecs.isEmpty
                ? Self.timeout(forSource: request.source, packageCacheDirectory: packageCacheDirectory)
                : Self.compileTimeout
            let workerResult: TypstWorkerResult
            do {
                workerResult = try await withTaskCancellationHandler(operation: {
                    try await withThrowingTaskGroup(of: TypstWorkerResult.self) { group in
                        group.addTask { await compilationTask.value }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            throw TypstCompileTimeoutError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }, onCancel: {
                    compilationTask.cancel()
                })
            } catch is TypstCompileTimeoutError {
                compilationTask.cancel()
                Self.logger.error("Compilation timed out after \(timeout)")
                workerResult = .failure(.compilationFailed(L10n.tr("error.typst.compilation_timeout")))
            } catch is CancellationError {
                compilationTask.cancel()
                return
            } catch {
                compilationTask.cancel()
                Self.logger.error("Compilation failed unexpectedly: \(error.localizedDescription, privacy: .public)")
                workerResult = .failure(.compilationFailed(error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            self?.finishCompilation(workerResult, generation: request.generation, request: request)
        }
    }

    private func finishCompilation(_ result: TypstWorkerResult, generation: UInt64, request: TypstCompileRequest? = nil) {
        activeTask = nil

        if generation == compileGeneration {
            let applyInterval = Self.signposter.beginInterval("typst.preview_apply")
            switch result {
            case .success(let artifact, let loadedFromCache):
                cancelDelayedError()
                previewArtifact = artifact
                pdfDocument = nil
                pdfData = artifact.pdfData
                sourceMap = artifact.sourceMap
                errorMessage = nil
                compiledOnce = true
                // Cached SVG/PDF artifacts do not carry a source map. Refresh
                // once from the compiler so editor↔preview sync and outline
                // navigation can use the latest mappings without looping
                // forever when a regular compile also returns no source map.
                if loadedFromCache, artifact.sourceMap == nil, request?.mode == .debounced, let request {
                    compile(
                        source: request.source,
                        fontPaths: request.fontPaths,
                        rootDir: request.rootDir,
                        mode: .debounced,
                        previewCachePolicy: .bypassCache,
                        previewCacheDescriptor: request.previewCacheDescriptor
                    )
                }
            case .failure(let error):
                // Keep the last successful PDF visible; only update the error banner.
                if request?.mode == .debounced {
                    scheduleDelayedError(error.localizedDescription, generation: generation)
                } else {
                    cancelDelayedError()
                    errorMessage = error.localizedDescription
                }
            }
            Self.signposter.endInterval("typst.preview_apply", applyInterval)
        }

        if pendingRequest != nil {
            startNextCompileIfNeeded()
        } else {
            refreshCompileQueuedState()
            isCompiling = false
        }
    }

    private func refreshCompileQueuedState() {
        isCompileQueued = scheduledRequest != nil || pendingRequest != nil
    }

    private func scheduleDelayedError(_ message: String, generation: UInt64) {
        cancelDelayedError()
        let sleep = self.sleep
        delayedErrorTask = Task { [weak self] in
            do {
                try await sleep(Self.errorVisibilityDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.applyDelayedError(message, generation: generation)
        }
    }

    private func applyDelayedError(_ message: String, generation: UInt64) {
        guard generation == compileGeneration else { return }
        errorMessage = message
        delayedErrorTask = nil
    }

    private func cancelDelayedError() {
        delayedErrorTask?.cancel()
        delayedErrorTask = nil
    }

    nonisolated static func timeout(
        forSource source: String,
        packageCacheDirectory: URL? = TypstBridge.packageCacheDirectoryURL
    ) -> Duration {
        let references = previewPackageReferences(in: source)
        guard !references.isEmpty, let packageCacheDirectory else {
            return compileTimeout
        }

        for reference in references {
            let packageDirectory = packageCacheDirectory
                .appendingPathComponent("preview", isDirectory: true)
                .appendingPathComponent(reference.name, isDirectory: true)
                .appendingPathComponent(reference.version, isDirectory: true)
            if !FileManager.default.fileExists(atPath: packageDirectory.path) {
                return uncachedPreviewPackageCompileTimeout
            }
        }

        return compileTimeout
    }

    nonisolated static func uncachedPreviewPackageSpecs(
        forSource source: String,
        packageCacheDirectory: URL? = TypstBridge.packageCacheDirectoryURL
    ) -> [String] {
        let references = previewPackageReferences(in: source)
        guard !references.isEmpty, let packageCacheDirectory else {
            return []
        }

        return references
            .filter { reference in
                let packageDirectory = packageCacheDirectory
                    .appendingPathComponent("preview", isDirectory: true)
                    .appendingPathComponent(reference.name, isDirectory: true)
                    .appendingPathComponent(reference.version, isDirectory: true)
                return !FileManager.default.fileExists(atPath: packageDirectory.path)
            }
            .map { $0.spec }
            .sorted()
    }

    nonisolated private static func previewPackageReferences(in source: String) -> [PreviewPackageReference] {
        let pattern = #"@preview/([A-Za-z0-9_.-]+):([A-Za-z0-9_.+\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)
        var references: [PreviewPackageReference] = []
        var seenSpecs = Set<String>()

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let versionRange = Range(match.range(at: 2), in: source) else {
                continue
            }
            let name = String(source[nameRange])
            let version = String(source[versionRange])
            let reference: PreviewPackageReference = (
                name: name,
                version: version,
                spec: "@preview/\(name):\(version)"
            )
            if seenSpecs.insert(reference.spec).inserted {
                references.append(reference)
            }
        }

        return references
    }

    nonisolated private static func runCompilation(
        request: TypstCompileRequest,
        compileWorker: TypstCompileWorker,
        documentBuilder: TypstDocumentBuilder,
        previewCacheStore: CompiledPreviewCacheStore,
        typstVersionProvider: @escaping @Sendable () -> String?
    ) -> TypstWorkerResult {
        let materializedFontPaths = CoreTextFontMaterializer.materializePlannedFonts(in: request.fontPaths)
        let typstVersion = typstVersionProvider()
        let cacheInput = request.previewCacheDescriptor.map {
            CompiledPreviewCacheInput(
                descriptor: $0,
                source: request.source,
                fontPaths: materializedFontPaths,
                rootDir: request.rootDir,
                typstVersion: typstVersion
            )
        }
        let previewSessionKey = previewSessionKey(
            for: request,
            materializedFontPaths: materializedFontPaths,
            typstVersion: typstVersion
        )
        _ = documentBuilder

        switch request.previewCachePolicy {
        case .useCacheIfValid:
            if let cacheInput,
               let cachedResult = loadCachedPreview(
                using: previewCacheStore,
                cacheInput: cacheInput
               ) {
                return cachedResult
            }
        case .bypassCache:
            break
        }

        let compileInterval = signposter.beginInterval("typst.compile")
        let result = compileWorker(request.source, materializedFontPaths, request.rootDir, previewSessionKey)
        signposter.endInterval("typst.compile", compileInterval)

        switch result {
        case .success(let artifact):
            if let cacheInput, artifact.pdfData != nil {
                do {
                    try previewCacheStore.save(artifact: artifact, for: cacheInput)
                } catch {
                    logger.error("Failed to store compiled preview cache: \(error.localizedDescription, privacy: .public)")
                }
            }
            return .success(artifact, loadedFromCache: false)
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated private static func loadCachedPreview(
        using previewCacheStore: CompiledPreviewCacheStore,
        cacheInput: CompiledPreviewCacheInput
    ) -> TypstWorkerResult? {
        do {
            guard let cachedArtifact = try previewCacheStore.loadArtifactIfValid(for: cacheInput) else {
                return nil
            }
            return .success(cachedArtifact, loadedFromCache: true)
        } catch {
            logger.error("Failed to load compiled preview cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func previewSessionKey(
        for request: TypstCompileRequest,
        materializedFontPaths: [String],
        typstVersion: String?
    ) -> String? {
        guard case .debounced = request.mode,
              let descriptor = request.previewCacheDescriptor else {
            return nil
        }

        let fontKey = materializedFontPaths.joined(separator: "\u{1F}")
        let localPackageRoot = TypstBridge.localPackagesDirectoryURL?.standardizedFileURL.path ?? ""
        return [
            descriptor.projectID,
            descriptor.entryFileName,
            request.rootDir ?? "",
            localPackageRoot,
            typstVersion ?? "",
            fontKey
        ].joined(separator: "\u{1E}")
    }
}
