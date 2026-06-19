//
//  ExportController.swift
//  InkPond
//
//  Shared export state and actions used by DocumentListView and DocumentEditorView.
//

import Foundation
import PDFKit
import Observation

enum ExportButtonPhase: Equatable {
    case idle
    case exporting
    case completed
}

@Observable
final class ExportController {
    var isExporting = false
    var exportButtonPhase: ExportButtonPhase = .idle
    var exportError: String?
    var exportURL: URL?
    private var exportCompletionTask: Task<Void, Never>?

    /// Export using already-compiled PDF bytes from the live preview.
    /// Falls back to a fresh compile if no cached data is provided.
    func exportPDF(
        for document: InkPondDocument,
        cachedPDFData: Data? = nil,
        cachedPDF: PDFDocument? = nil
    ) {
        guard beginExport() else { return }

        if let cachedPDFData {
            let title = document.title
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                do {
                    let url = try await Self.temporaryPDFURL(data: cachedPDFData, title: title)
                    finishExport(with: url)
                } catch {
                    failExport(error)
                }
            }
            return
        }

        // Keep PDFDocument compatibility for older call sites and fallback flows.
        if let pdf = cachedPDF {
            let title = document.title
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                guard let data = pdf.dataRepresentation() else {
                    failExport(CocoaError(.fileWriteUnknown))
                    return
                }
                do {
                    let url = try await Self.temporaryPDFURL(data: data, title: title)
                    finishExport(with: url)
                } catch {
                    failExport(error)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let result = await ExportManager.compilePDF(for: document)
            switch result {
            case .success(let data):
                let title = document.title
                do {
                    let url = try await Self.temporaryPDFURL(data: data, title: title)
                    finishExport(with: url)
                } catch {
                    failExport(error)
                }
            case .failure(let error):
                failExport(error)
            }
        }
    }

    func exportTypSource(for document: InkPondDocument, fileName: String) {
        guard beginExport() else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            do {
                let url = try ExportManager.temporaryTypURL(for: document, fileName: fileName)
                finishExport(with: url)
            } catch {
                failExport(error)
            }
        }
    }

    func exportZip(for document: InkPondDocument) {
        guard beginExport() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let projectDir = ProjectFileManager.projectDirectory(for: document)
            let title = document.title
            do {
                let url = try await Task.detached {
                    try ExportManager.zipProject(sourceDir: projectDir, title: title)
                }.value
                finishExport(with: url)
            } catch {
                failExport(error)
            }
        }
    }

    @discardableResult
    private func beginExport() -> Bool {
        guard !isExporting, exportButtonPhase == .idle else { return false }
        exportCompletionTask?.cancel()
        exportCompletionTask = nil
        exportError = nil
        isExporting = true
        exportButtonPhase = .exporting
        return true
    }

    private func finishExport(with url: URL) {
        exportButtonPhase = .completed
        exportCompletionTask?.cancel()
        exportCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            exportURL = url
            isExporting = false

            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            exportButtonPhase = .idle
            exportCompletionTask = nil
        }
    }

    private func failExport(_ error: Error) {
        exportCompletionTask?.cancel()
        exportCompletionTask = nil
        isExporting = false
        exportButtonPhase = .idle
        exportError = error.localizedDescription
    }

    nonisolated private static func temporaryPDFURL(data: Data, title: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try ExportManager.temporaryPDFURL(data: data, title: title)
        }.value
    }
}
