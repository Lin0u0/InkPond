//
//  ExportController.swift
//  InkPond
//
//  Shared export state and actions used by DocumentListView and DocumentEditorView.
//

import Foundation
import PDFKit
import Observation

@Observable
final class ExportController {
    var isExporting = false
    var exportError: String?
    var exportURL: URL?

    /// Export using an already-compiled PDFDocument from the live preview.
    /// Falls back to a fresh compile if no cached document is provided.
    func exportPDF(for document: InkPondDocument, cachedPDF: PDFDocument? = nil) {
        guard !isExporting else { return }

        // If we have a cached PDF from the preview pane, write it directly — no recompile needed.
        if let pdf = cachedPDF, let data = pdf.dataRepresentation() {
            do { exportURL = try ExportManager.temporaryPDFURL(data: data, title: document.title) }
            catch { exportError = error.localizedDescription }
            return
        }

        isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ExportManager.compilePDF(for: document)
            isExporting = false
            switch result {
            case .success(let data):
                do { exportURL = try ExportManager.temporaryPDFURL(data: data, title: document.title) }
                catch { exportError = error.localizedDescription }
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }

    func exportTypSource(for document: InkPondDocument, fileName: String) {
        do { exportURL = try ExportManager.temporaryTypURL(for: document, fileName: fileName) }
        catch { exportError = error.localizedDescription }
    }

    func exportZip(for document: InkPondDocument) {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let projectDir = ProjectFileManager.projectDirectory(for: document)
            let title = document.title
            do {
                exportURL = try await Task.detached {
                    try ExportManager.zipProject(sourceDir: projectDir, title: title)
                }.value
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }
}
