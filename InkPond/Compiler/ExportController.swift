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

    /// Compatibility entry point. Cached bytes/PDFDocument lack snapshot
    /// provenance, so they are deliberately not reused.
    func exportPDF(
        for document: InkPondDocument,
        cachedPDFData: Data? = nil,
        cachedPDF: PDFDocument? = nil
    ) {
        guard beginExport() else { return }
        do { stage(try ExportManager.snapshotInput(for: document), kind: .pdf) }
        catch { failExport(error) }
    }

    func exportPDF(snapshot: OperationSnapshot) {
        guard beginExport() else { return }
        performPDF(snapshot: snapshot)
    }

    private func performPDF(snapshot: OperationSnapshot) {
        Task { @MainActor [weak self] in
            let result = await ExportManager.compilePDF(snapshot: snapshot)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                do {
                    let url = try await Self.temporaryPDFURL(data: data, title: snapshot.title)
                    finishExport(with: url)
                } catch { failExport(error) }
            case .failure(let error): failExport(error)
            }
        }
    }

    func exportTypSource(for document: InkPondDocument, fileName: String) {
        guard beginExport() else { return }
        do {
            stage(try ExportManager.snapshotInput(for: document, includeFonts: false,
                sourceFileName: fileName), kind: .source(fileName))
        } catch { failExport(error) }
    }

    func exportTypSource(snapshot: OperationSnapshot, fileName: String) {
        guard beginExport() else { return }
        performTypSource(snapshot: snapshot, fileName: fileName)
    }

    private func performTypSource(snapshot: OperationSnapshot, fileName: String) {
        Task { @MainActor [weak self] in
            do {
                let url = try await Task.detached {
                    try withExtendedLifetime(snapshot) {
                        try ExportManager.temporaryTypURL(snapshot: snapshot, fileName: fileName)
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                finishExport(with: url)
            } catch { self?.failExport(error) }
        }
    }

    func exportZip(for document: InkPondDocument) {
        guard beginExport() else { return }
        do { stage(try ExportManager.snapshotInput(for: document, includeFonts: false), kind: .zip) }
        catch { failExport(error) }
    }

    func exportZip(snapshot: OperationSnapshot) {
        guard beginExport() else { return }
        performZip(snapshot: snapshot)
    }

    private func performZip(snapshot: OperationSnapshot) {
        Task { @MainActor [weak self] in
            do {
                let url = try await Task.detached { try ExportManager.zipProject(snapshot: snapshot) }.value
                guard let self, !Task.isCancelled else { return }
                finishExport(with: url)
            } catch { self?.failExport(error) }
        }
    }

    private enum ExportKind {
        case pdf, source(String), zip
    }

    /// Input contains only copied values; no document is retained across await.
    /// The private performers do not re-enter beginExport after staging.
    private func stage(_ input: OperationSnapshotInput, kind: ExportKind) {
        Task { @MainActor [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try OperationSnapshot.capture(input)
                }.value
                guard let self, !Task.isCancelled else { return }
                switch kind {
                case .pdf: performPDF(snapshot: snapshot)
                case .source(let fileName): performTypSource(snapshot: snapshot, fileName: fileName)
                case .zip: performZip(snapshot: snapshot)
                }
            } catch { self?.failExport(error) }
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
