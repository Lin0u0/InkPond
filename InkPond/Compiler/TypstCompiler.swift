//
//  TypstCompiler.swift
//  InkPond
//
//  Debounced compile pipeline: source → Rust FFI → PDFKit document.
//

import Observation
import Foundation
import os
import PDFKit

@MainActor
@Observable
final class TypstCompiler {
    enum CompileMode {
        case debounced
        case immediate
    }

    enum PreviewCachePolicy: Sendable {
        case useCacheIfValid
        case bypassCache
    }

    typealias CompileWorker = @Sendable (String, [String], String?) -> Result<(Data, SourceMap?), TypstBridgeError>
    typealias DocumentBuilder = @Sendable (Data) -> PDFDocument?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct CompileRequest: Sendable {
        let source: String
        let fontPaths: [String]
        let rootDir: String?
        let mode: CompileMode
        let previewCachePolicy: PreviewCachePolicy
        let previewCacheDescriptor: CompiledPreviewCacheDescriptor?
        let generation: UInt64
    }

    private struct PDFDocumentBox: @unchecked Sendable {
        nonisolated(unsafe) let document: PDFDocument

        nonisolated init(document: PDFDocument) {
            self.document = document
        }
    }

    private enum WorkerResult: Sendable {
        case success(PDFDocumentBox, Data, SourceMap?, loadedFromCache: Bool)
        case failure(TypstBridgeError)
    }

    private struct CompileTimeoutError: Error {}

    private static let compileDelay = Duration.milliseconds(350)
    private static let compileTimeout = Duration.seconds(30)
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InkPond",
        category: "TypstCompiler"
    )
    nonisolated private static let signposter = OSSignposter(logger: logger)

    private(set) var pdfDocument: PDFDocument?
    private(set) var pdfData: Data?
    private(set) var errorMessage: String?
    private(set) var isCompiling: Bool = false
    /// Tracks whether a compiled PDF is currently available.
    private(set) var compiledOnce: Bool = false
    /// Source map from the most recent successful compilation.
    private(set) var sourceMap: SourceMap?

    private let compileWorker: CompileWorker
    private let documentBuilder: DocumentBuilder
    private let sleep: Sleep
    private let previewCacheStore: CompiledPreviewCacheStore
    private let typstVersionProvider: @Sendable () -> String?

    private var debounceTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var scheduledRequest: CompileRequest?
    private var pendingRequest: CompileRequest?
    private var compileGeneration: UInt64 = 0

    init(
        compileWorker: @escaping CompileWorker = { source, fontPaths, rootDir in
            TypstBridge.compileWithSourceMap(source: source, fontPaths: fontPaths, rootDir: rootDir)
                .map { ($0.0, $0.1) }
        },
        documentBuilder: @escaping DocumentBuilder = { PDFDocument(data: $0) },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        previewCacheStore: CompiledPreviewCacheStore = CompiledPreviewCacheStore(),
        typstVersionProvider: @escaping @Sendable () -> String? = { TypstBridge.runtimeVersion }
    ) {
        self.compileWorker = compileWorker
        self.documentBuilder = documentBuilder
        self.sleep = sleep
        self.previewCacheStore = previewCacheStore
        self.typstVersionProvider = typstVersionProvider
    }

    nonisolated static func taskPriority(for mode: CompileMode) -> TaskPriority {
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
        mode: CompileMode = .debounced,
        previewCachePolicy: PreviewCachePolicy = .bypassCache,
        previewCacheDescriptor: CompiledPreviewCacheDescriptor? = nil
    ) {
        compileGeneration &+= 1
        // Invalidate the source map immediately so stale mappings are not used
        // while the new compilation is in flight.
        sourceMap = nil
        let request = CompileRequest(
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
        previewCachePolicy: PreviewCachePolicy = .bypassCache,
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
        pdfDocument = nil
        pdfData = nil
        errorMessage = nil
        compiledOnce = false
        sourceMap = nil
    }

    func presentPreflightError(_ message: String) {
        cancelAllWork()
        sourceMap = nil
        errorMessage = message
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
        scheduledRequest = nil
        pendingRequest = nil
        compileGeneration &+= 1
        isCompiling = false
    }

    private func enqueue(_ request: CompileRequest, mode: CompileMode) {
        switch mode {
        case .debounced:
            scheduledRequest = request
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
            startNextCompileIfNeeded()
        }
    }

    private func activateScheduledRequest(generation: UInt64) {
        guard scheduledRequest?.generation == generation else { return }
        pendingRequest = scheduledRequest
        scheduledRequest = nil
        debounceTask = nil
        startNextCompileIfNeeded()
    }

    private func startNextCompileIfNeeded() {
        guard activeTask == nil, let request = pendingRequest else { return }

        pendingRequest = nil
        isCompiling = true

        let compileWorker = self.compileWorker
        let documentBuilder = self.documentBuilder
        let previewCacheStore = self.previewCacheStore
        let typstVersionProvider = self.typstVersionProvider
        let priority = Self.taskPriority(for: request.mode)
        let timeout = Self.compileTimeout
        activeTask = Task { [weak self] in
            let compilationTask = Task.detached(priority: priority) {
                Self.runCompilation(
                    request: request,
                    compileWorker: compileWorker,
                    documentBuilder: documentBuilder,
                    previewCacheStore: previewCacheStore,
                    typstVersionProvider: typstVersionProvider
                )
            }

            let workerResult: WorkerResult
            do {
                workerResult = try await withTaskCancellationHandler(operation: {
                    try await withThrowingTaskGroup(of: WorkerResult.self) { group in
                        group.addTask { await compilationTask.value }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            throw CompileTimeoutError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }, onCancel: {
                    compilationTask.cancel()
                })
            } catch is CompileTimeoutError {
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

    private func finishCompilation(_ result: WorkerResult, generation: UInt64, request: CompileRequest? = nil) {
        activeTask = nil

        if generation == compileGeneration {
            let applyInterval = Self.signposter.beginInterval("typst.preview_apply")
            switch result {
            case .success(let box, let data, let map, let loadedFromCache):
                pdfDocument = box.document
                pdfData = data
                sourceMap = map
                errorMessage = nil
                compiledOnce = true
                // Cache hits do not carry a source map. Refresh once from the
                // compiler so editor↔preview sync and outline navigation can
                // use the latest mappings without looping forever when a
                // regular compile also returns no source map.
                if loadedFromCache, map == nil, request?.mode == .debounced, let request {
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
                errorMessage = error.localizedDescription
            }
            Self.signposter.endInterval("typst.preview_apply", applyInterval)
        }

        if pendingRequest != nil {
            startNextCompileIfNeeded()
        } else {
            isCompiling = false
        }
    }

    nonisolated private static func runCompilation(
        request: CompileRequest,
        compileWorker: CompileWorker,
        documentBuilder: DocumentBuilder,
        previewCacheStore: CompiledPreviewCacheStore,
        typstVersionProvider: @escaping @Sendable () -> String?
    ) -> WorkerResult {
        let materializedFontPaths = CoreTextFontMaterializer.materializePlannedFonts(in: request.fontPaths)
        let cacheInput = request.previewCacheDescriptor.map {
            CompiledPreviewCacheInput(
                descriptor: $0,
                source: request.source,
                fontPaths: materializedFontPaths,
                rootDir: request.rootDir,
                typstVersion: typstVersionProvider()
            )
        }

        switch request.previewCachePolicy {
        case .useCacheIfValid:
            if let cacheInput,
               let cachedResult = loadCachedPreview(
                using: previewCacheStore,
                cacheInput: cacheInput,
                documentBuilder: documentBuilder
               ) {
                return cachedResult
            }
        case .bypassCache:
            break
        }

        let compileInterval = signposter.beginInterval("typst.compile")
        let result = compileWorker(request.source, materializedFontPaths, request.rootDir)
        signposter.endInterval("typst.compile", compileInterval)

        switch result {
        case .success(let (pdfData, sourceMap)):
            let decodeInterval = signposter.beginInterval("typst.pdf_decode")
            defer { signposter.endInterval("typst.pdf_decode", decodeInterval) }

            guard let document = documentBuilder(pdfData) else {
                return .failure(.compilationFailed("Failed to decode compiled PDF."))
            }
            if let cacheInput {
                do {
                    try previewCacheStore.save(pdfData: pdfData, for: cacheInput)
                } catch {
                    logger.error("Failed to store compiled preview cache: \(error.localizedDescription, privacy: .public)")
                }
            }
            return .success(PDFDocumentBox(document: document), pdfData, sourceMap, loadedFromCache: false)
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated private static func loadCachedPreview(
        using previewCacheStore: CompiledPreviewCacheStore,
        cacheInput: CompiledPreviewCacheInput,
        documentBuilder: DocumentBuilder
    ) -> WorkerResult? {
        do {
            guard let cachedPDFData = try previewCacheStore.loadIfValid(for: cacheInput) else {
                return nil
            }
            guard let document = documentBuilder(cachedPDFData) else {
                logger.error("Failed to decode cached preview PDF for \(cacheInput.descriptor.projectID, privacy: .public)")
                return nil
            }
            return .success(PDFDocumentBox(document: document), cachedPDFData, nil, loadedFromCache: true)
        } catch {
            logger.error("Failed to load compiled preview cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
