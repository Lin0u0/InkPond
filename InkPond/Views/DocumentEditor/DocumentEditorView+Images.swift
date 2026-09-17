//
//  DocumentEditorView+Images.swift
//  InkPond
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private enum ImageImportError: LocalizedError {
    case loadDataFailed
    case processFailed

    var errorDescription: String? {
        switch self {
        case .loadDataFailed:
            return L10n.tr("error.image.load_data_failed")
        case .processFailed:
            return L10n.tr("error.image.process_failed")
        }
    }
}

extension DocumentEditorView {
    func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        guard activeTabIsTextEditable, projectWritableLease != nil else { return false }
        guard let destination = captureAssetDestination(at: currentInsertionRange(), for: currentFileName) else { return false }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let suggestedName = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else {
                    Task { @MainActor in
                    guard destination.isValid, documentSession === destination.session else { return }
                    imageImportError = L10n.tr("error.image.load_data_failed")
                }
                    return
                }
                Task { @MainActor in
                    importImage(
                        from: .rawData(data, suggestedFileName: suggestedName),
                        destination: destination
                    )
                }
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
                Task { @MainActor in
                    guard destination.isValid, documentSession === destination.session else { return }
                    imageImportError = L10n.tr("error.image.load_data_failed")
                }
                return
            }
            Task { @MainActor in
                importImage(from: .fileURL(fileURL), destination: destination)
            }
        }
        return true
    }

    func handleImageSelection(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        let destination = photoPickerDestination
        photoPickerDestination = nil
        selectedPhotoItems = []
        guard let destination, destination.isValid else { return }
        importImage(from: .photoItem(item), destination: destination)
    }

    func captureAssetDestination(at range: NSRange, for path: String) -> EditorAssetDestination? {
        guard activeTabIsTextEditable, activeTabPath == path, hasSessionAttachment else { return nil }
        return EditorAssetDestination(session: documentSession, attachmentID: sessionAttachment.id, selection: range)
    }

    func importImage(from source: ImageImportSource, anchorRange: NSRange, targetFileName: String) {
        guard let destination = captureAssetDestination(at: anchorRange, for: targetFileName) else { return }
        importImage(from: source, destination: destination)
    }

    @discardableResult
    func importImage(from source: ImageImportSource, destination: EditorAssetDestination) -> Task<Void, Never> {
        Task { await performAssetImport(sources: [source], destination: destination) }
    }

    func handleRichPaste(
        _ fragments: [TypstTextView.PasteFragment],
        anchorRange: NSRange,
        targetFileName: String
    ) {
        guard let destination = captureAssetDestination(at: anchorRange, for: targetFileName) else { return }
        handleRichPaste(fragments, destination: destination)
    }

    @discardableResult
    func handleRichPaste(_ fragments: [TypstTextView.PasteFragment], destination: EditorAssetDestination) -> Task<Void, Never> {
        Task { await performRichPaste(fragments, destination: destination) }
    }

    func performAssetImport(sources: [ImageImportSource], destination: EditorAssetDestination) async {
        let transaction = EditorAssetTransaction(destination: destination)
        do {
            for source in sources { try await stageImage(source, in: transaction) }
            try transaction.commit()
            assetImportDidCommit(transaction)
        } catch is CancellationError {
            // Stale/cancelled operations are not successful imports or user errors.
        } catch {
            if destination.isValid, !Task.isCancelled, documentSession === destination.session { imageImportError = error.localizedDescription }
        }
    }

    func performRichPaste(_ fragments: [TypstTextView.PasteFragment], destination: EditorAssetDestination) async {
        let transaction = EditorAssetTransaction(destination: destination)
        do {
            for fragment in fragments {
                switch fragment {
                case .text(let text): transaction.append(text: text)
                case .imageData(let data, let name):
                    try await stageImage(.rawData(data, suggestedFileName: name), in: transaction)
                case .imageRemoteURL(let url, let name):
                    try await stageImage(.remoteURL(url, suggestedFileName: name), in: transaction)
                }
            }
            try transaction.commit()
            assetImportDidCommit(transaction)
        } catch is CancellationError {
        } catch {
            if destination.isValid, !Task.isCancelled, documentSession === destination.session { imageImportError = error.localizedDescription }
        }
    }

    func stageImage(_ source: ImageImportSource, in transaction: EditorAssetTransaction) async throws {
        try Task.checkCancellation()
        guard transaction.destination.isValid else { throw CancellationError() }
        let raw: Data
#if DEBUG
        if let load = transaction.destination.loadDataForTesting {
            raw = try await load(source)
        } else {
            raw = try await loadImageData(from: source)
        }
#else
        raw = try await loadImageData(from: source)
#endif
        try Task.checkCancellation()
        guard transaction.destination.isValid else { throw CancellationError() }
        let normalized = try normalizeImageData(raw)
        let path = transaction.append(data: normalized.data, extension: normalized.fileExtension)
        transaction.append(text: normalizeTypstQuotes(String(format: transaction.destination.template, path)))
    }

    func assetImportDidCommit(_ transaction: EditorAssetTransaction) {
        guard hasSessionAttachment, documentSession === transaction.destination.session,
              let first = transaction.paths.first else { return }
        refreshImageFiles()
        showImageImportToast(transaction.paths.count == 1
            ? L10n.imageInserted(path: first) : L10n.imagesInserted(count: transaction.paths.count))
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
                throw ImageImportError.loadDataFailed
            }
            return data
        case .fileURL(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                throw ImageImportError.loadDataFailed
            }
            return data
        case .remoteURL(let url, _):
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw ImageImportError.loadDataFailed
            }
            guard !data.isEmpty else {
                throw ImageImportError.loadDataFailed
            }
            return data
        }
    }

    func normalizeImageData(_ data: Data) throws -> (data: Data, fileExtension: String) {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            throw ImageImportError.processFailed
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
                throw ImageImportError.processFailed
            }
            return (pngData, "png")
        }

        guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
            throw ImageImportError.processFailed
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
        if activeTabIsTextEditable, insertionRequest == nil, activeTabPath == targetFileName {
            insertionRequest = request
        } else {
            pendingInsertionQueue.append(request)
        }
    }

    @MainActor
    func pumpPendingInsertionsIfNeeded() {
        guard activeTabIsTextEditable, insertionRequest == nil else { return }
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
