//
//  DocumentEditorView+Images.swift
//  InkPond
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

extension DocumentEditorView {
    func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        let anchorRange = currentInsertionRange()
        let targetFileName = currentFileName
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else {
                    Task { @MainActor in imageImportError = L10n.tr("error.image.load_data_failed") }
                    return
                }
                importImage(
                    from: .rawData(data, suggestedFileName: provider.suggestedName),
                    anchorRange: anchorRange,
                    targetFileName: targetFileName
                )
            }
            return true
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }

            guard let fileURL = url else {
                Task { @MainActor in imageImportError = L10n.tr("error.image.load_data_failed") }
                return
            }
            importImage(from: .fileURL(fileURL), anchorRange: anchorRange, targetFileName: targetFileName)
        }
        return true
    }

    func handleImageSelection(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        importImage(from: .photoItem(item), anchorRange: currentInsertionRange(), targetFileName: currentFileName)
        selectedPhotoItems = []
    }

    func importImage(from source: ImageImportSource, anchorRange: NSRange, targetFileName: String) {
        Task {
            do {
                let result = try await importImageAsset(from: source)
                await MainActor.run {
                    refreshImageFiles()
                    enqueueInsertion(result.reference, at: anchorRange, for: targetFileName)
                    showImageImportToast(L10n.imageInserted(path: result.relativePath))
                }
            } catch {
                await MainActor.run {
                    imageImportError = error.localizedDescription
                }
            }
        }
    }

    func handleRichPaste(
        _ fragments: [TypstTextView.PasteFragment],
        anchorRange: NSRange,
        targetFileName: String
    ) {
        Task {
            var combinedInsertion = ""
            var firstError: String?
            var insertedImages: [String] = []

            for fragment in fragments {
                switch fragment {
                case .text(let text):
                    combinedInsertion.append(text)
                case .imageData(let data, let suggestedFileName):
                    do {
                        let result = try await importImageAsset(from: .rawData(data, suggestedFileName: suggestedFileName))
                        combinedInsertion.append(result.reference)
                        insertedImages.append(result.relativePath)
                    } catch {
                        if firstError == nil {
                            firstError = error.localizedDescription
                        }
                    }
                case .imageRemoteURL(let remoteURL, let suggestedFileName):
                    do {
                        let result = try await importImageAsset(from: .remoteURL(remoteURL, suggestedFileName: suggestedFileName))
                        combinedInsertion.append(result.reference)
                        insertedImages.append(result.relativePath)
                    } catch {
                        if firstError == nil {
                            firstError = error.localizedDescription
                        }
                    }
                }
            }

            await MainActor.run {
                if !insertedImages.isEmpty {
                    refreshImageFiles()
                }
                if !combinedInsertion.isEmpty {
                    enqueueInsertion(combinedInsertion, at: anchorRange, for: targetFileName)
                }
                if let firstPath = insertedImages.first {
                    if insertedImages.count == 1 {
                        showImageImportToast(L10n.imageInserted(path: firstPath))
                    } else {
                        showImageImportToast(L10n.imagesInserted(count: insertedImages.count))
                    }
                }
                if let firstError {
                    imageImportError = firstError
                }
            }
        }
    }

    func importImageAsset(from source: ImageImportSource) async throws -> (relativePath: String, reference: String) {
        let rawData = try await loadImageData(from: source)
        let normalized = try normalizeImageData(rawData)
        let fileName = makeUniqueImageFileName(ext: normalized.fileExtension, source: source)
        let relativePath = try ProjectFileManager.saveImage(data: normalized.data, fileName: fileName, for: document)
        let reference = normalizeTypstQuotes(String(format: document.imageInsertionTemplate, relativePath))
        return (relativePath, reference)
    }

    func normalizeTypstQuotes(_ text: String) -> String {
        var normalized = text
        let quoteVariants = ["“", "”", "„", "‟", "＂", "«", "»", "「", "」", "『", "』", "〝", "〞", "‘", "’", "‚", "‛"]
        for q in quoteVariants {
            normalized = normalized.replacingOccurrences(of: q, with: "\"")
        }
        return normalized
    }

    func loadImageData(from source: ImageImportSource) async throws -> Data {
        switch source {
        case .rawData(let data, _):
            return data
        case .photoItem(let item):
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                throw NSError(domain: "InkPond.ImageImport", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.load_data_failed")])
            }
            return data
        case .fileURL(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                throw NSError(domain: "InkPond.ImageImport", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.load_data_failed")])
            }
            return data
        case .remoteURL(let url, _):
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw NSError(domain: "InkPond.ImageImport", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.load_data_failed")])
            }
            guard !data.isEmpty else {
                throw NSError(domain: "InkPond.ImageImport", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.load_data_failed")])
            }
            return data
        }
    }

    func normalizeImageData(_ data: Data) throws -> (data: Data, fileExtension: String) {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            throw NSError(domain: "InkPond.ImageImport", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.process_failed")])
        }

        let hasAlpha: Bool = {
            switch cgImage.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast:
                return true
            default:
                return false
            }
        }()

        if hasAlpha {
            guard let pngData = uiImage.pngData() else {
                throw NSError(domain: "InkPond.ImageImport", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.process_failed")])
            }
            return (pngData, "png")
        }

        guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "InkPond.ImageImport", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.image.process_failed")])
        }
        return (jpegData, "jpg")
    }

    func makeUniqueImageFileName(ext: String, source: ImageImportSource) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let preferredBase = preferredImageBaseName(from: source)
        let base = preferredBase ?? "image-\(stamp)"
        let folder = ProjectFileManager.imagesDirectory(for: document)
        let fm = FileManager.default

        var candidate = "\(base).\(ext)"
        var index = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    func preferredImageBaseName(from source: ImageImportSource) -> String? {
        let rawName: String?
        switch source {
        case .fileURL(let url):
            rawName = url.lastPathComponent
        case .rawData(_, let suggested):
            rawName = suggested
        case .remoteURL(let url, let suggested):
            rawName = suggested ?? url.lastPathComponent
        case .photoItem:
            rawName = nil
        }

        guard let rawName else { return nil }
        let base = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: disallowed).joined(separator: "-")
        let collapsed = cleaned.replacingOccurrences(of: "  ", with: " ")
        let safe = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return safe.isEmpty ? nil : String(safe.prefix(80))
    }

    @MainActor
    func enqueueInsertion(_ reference: String, at targetRange: NSRange, for targetFileName: String) {
        let request = EditorInsertionRequest(
            text: normalizeTypstQuotes(reference),
            targetRange: targetRange,
            targetFileName: targetFileName
        )
        if insertionRequest == nil, currentFileName == targetFileName {
            insertionRequest = request
        } else {
            pendingInsertionQueue.append(request)
        }
    }

    @MainActor
    func pumpPendingInsertionsIfNeeded() {
        guard insertionRequest == nil else { return }
        guard let index = pendingInsertionQueue.firstIndex(where: { $0.targetFileName == currentFileName }) else {
            return
        }
        insertionRequest = pendingInsertionQueue.remove(at: index)
    }

    func currentInsertionRange() -> NSRange {
        NSRange(location: editorViewState.selectedLocation, length: editorViewState.selectedLength)
    }

    @MainActor
    func showImageImportToast(_ message: String) {
        toastDismissTask?.cancel()
        InteractionFeedback.notify(.success)
        AccessibilitySupport.announce(message)
        withAnimation(.easeInOut(duration: 0.18)) {
            imageImportToast = message
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 0.18)) {
                imageImportToast = nil
            }
        }
    }
}
