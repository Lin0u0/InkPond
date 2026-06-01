//
//  ExternalTypFileImporter.swift
//  InkPond
//

import Foundation
import os

enum ExternalTypFileSessionStore {
    private struct Entry {
        let url: URL
        let isAccessing: Bool
    }

    private nonisolated static let _lock = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    nonisolated static func register(url: URL, projectID: String) throws {
        let isAccessing = url.startAccessingSecurityScopedResource()

        _lock.withLock { state in
            if let existing = state[projectID], existing.isAccessing {
                existing.url.stopAccessingSecurityScopedResource()
            }
            state[projectID] = Entry(url: url, isAccessing: isAccessing)
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    nonisolated static func fileURL(projectID: String) -> URL? {
        _lock.withLock { $0[projectID]?.url }
    }

    nonisolated static func contains(projectID: String) -> Bool {
        fileURL(projectID: projectID) != nil
    }

    static func unregister(projectID: String) {
        _lock.withLock { state in
            guard let entry = state.removeValue(forKey: projectID) else { return }
            if entry.isAccessing {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

enum ExternalTypFileImporter {
    struct ManagedProjectLocation: Equatable {
        let projectID: String
        let relativeFileName: String
    }

    enum ImportMode: Equatable {
        case singleFile
    }

    struct ImportResult {
        let document: InkPondDocument
        let openedFileName: String
        let mode: ImportMode
    }

    static func canImport(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare("typ") == .orderedSame
    }

    static func title(for url: URL) -> String {
        documentTitle(from: url)
    }

    static func managedProjectLocation(for url: URL) -> ManagedProjectLocation? {
        guard canImport(url) else { return nil }

        let rootURL = ProjectFileManager.documentsURL.standardizedFileURL
        let fileURL = url.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let fileComponents = fileURL.pathComponents

        guard fileComponents.count >= rootComponents.count + 2,
              fileComponents.starts(with: rootComponents) else { return nil }

        let relativeComponents = Array(fileComponents[rootComponents.count...])

        let projectID = relativeComponents[0]
        let relativeFileName = relativeComponents.dropFirst().joined(separator: "/")
        guard projectID != "Inbox" else { return nil }
        guard !projectID.isEmpty, !relativeFileName.isEmpty else { return nil }

        return ManagedProjectLocation(projectID: projectID, relativeFileName: relativeFileName)
    }

    @MainActor
    static func importFile(
        from url: URL,
        preferLinkedFolder _: Bool = true
    ) async throws -> ImportResult {
        guard canImport(url) else {
            throw InkPondFileError.invalidFileName(url.lastPathComponent)
        }

        let fileName = url.lastPathComponent
        try ProjectFileManager.validateFileName(fileName)

        let title = documentTitle(from: url)
        let projectID = "external-file-\(UUID().uuidString)"
        try ExternalTypFileSessionStore.register(url: url, projectID: projectID)

        let document = makeDocument(
            title: title,
            projectID: projectID,
            entryFileName: fileName,
            requiresExternalFolderLinkForPreview: true
        )
        return ImportResult(document: document, openedFileName: fileName, mode: .singleFile)
    }

    @MainActor
    static func importFile(from url: URL) throws -> InkPondDocument {
        guard canImport(url) else {
            throw InkPondFileError.invalidFileName(url.lastPathComponent)
        }

        let fileName = url.lastPathComponent
        try ProjectFileManager.validateFileName(fileName)

        let title = documentTitle(from: url)
        let projectID = "external-file-\(UUID().uuidString)"
        try ExternalTypFileSessionStore.register(url: url, projectID: projectID)
        return makeDocument(
            title: title,
            projectID: projectID,
            entryFileName: fileName,
            requiresExternalFolderLinkForPreview: true
        )
    }

    @MainActor
    private static func makeDocument(
        title: String,
        projectID: String,
        entryFileName: String,
        requiresExternalFolderLinkForPreview: Bool
    ) -> InkPondDocument {
        let document = InkPondDocument(title: title, content: "")
        document.projectID = projectID
        document.entryFileName = entryFileName
        document.lastEditedFileName = entryFileName
        document.requiresExternalFolderLinkForPreview = requiresExternalFolderLinkForPreview
        document.lastCursorLocation = 0
        document.requiresInitialEntrySelection = false
        document.requiresImportConfiguration = false
        document.importEntryFileOptions = []
        document.importImageDirectoryOptions = []
        document.importFontDirectoryOptions = []
        document.modifiedAt = Date()
        return document
    }

    private static func documentTitle(from url: URL) -> String {
        let title = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.untitledBase : title
    }
}
