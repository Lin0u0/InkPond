//
//  ProjectFileManager+OpenValidation.swift
//  InkPond
//

import Foundation

enum DocumentOpenError: LocalizedError {
    case externalSourceMissing
    case downloadingFromICloud

    var errorDescription: String? {
        switch self {
        case .externalSourceMissing:
            L10n.tr("preview.external_link_required.missing_source")
        case .downloadingFromICloud:
            L10n.tr("icloud.error.document_downloading")
        }
    }
}

extension ProjectFileManager {
    static func validateDocumentCanOpen(_ document: InkPondDocument) throws {
        if let externalFileURL = externalSingleFileURL(for: document) {
            try validateEntryFileForOpening(
                at: externalFileURL,
                displayName: document.entryFileName,
                allowMigrationFromStoredContent: false,
                missingError: DocumentOpenError.externalSourceMissing
            )
            return
        }

        if BookmarkManager.hasBookmark(projectID: document.projectID) {
            guard let projectRoot = BookmarkManager.loadBookmark(projectID: document.projectID) else {
                throw InkPondFileError.fileNotFound(document.title)
            }
            defer { BookmarkManager.stopAccessing(document.projectID) }

            try validateProjectRootForOpening(
                at: projectRoot,
                displayName: document.title,
                allowMigrationFromStoredContent: false
            )
            guard !document.requiresImportConfiguration,
                  !document.requiresInitialEntrySelection else {
                return
            }
            let entryURL = try validatedProjectPath(
                relativePath: document.entryFileName,
                in: projectRoot
            )
            try validateEntryFileForOpening(
                at: entryURL,
                displayName: document.entryFileName,
                allowMigrationFromStoredContent: false
            )
            return
        }

        let projectRoot = documentsURL.appendingPathComponent(document.projectID, isDirectory: true)
        let canMigrateFromStoredContent = canMigrateEntryFromStoredContent(for: document)
        try validateProjectRootForOpening(
            at: projectRoot,
            displayName: document.title,
            allowMigrationFromStoredContent: canMigrateFromStoredContent
        )

        guard !document.requiresImportConfiguration,
              !document.requiresInitialEntrySelection else {
            return
        }

        let entryURL = try validatedProjectPath(
            relativePath: document.entryFileName,
            in: projectRoot
        )
        try validateEntryFileForOpening(
            at: entryURL,
            displayName: document.entryFileName,
            allowMigrationFromStoredContent: canMigrateFromStoredContent
        )
    }

    private static func canMigrateEntryFromStoredContent(for document: InkPondDocument) -> Bool {
        guard !document.requiresImportConfiguration,
              !document.requiresInitialEntrySelection else {
            return false
        }
        return !document.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validateProjectRootForOpening(
        at rootURL: URL,
        displayName: String,
        allowMigrationFromStoredContent: Bool
    ) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }
        if allowMigrationFromStoredContent {
            return
        }
        throw InkPondFileError.fileNotFound(displayName)
    }

    private static func validateEntryFileForOpening(
        at entryURL: URL,
        displayName: String,
        allowMigrationFromStoredContent: Bool,
        missingError: Error? = nil
    ) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            try validateUbiquitousItemIsReadyForOpening(entryURL)
            return
        }
        if allowMigrationFromStoredContent {
            return
        }
        if let missingError {
            throw missingError
        }
        throw InkPondFileError.fileNotFound(displayName)
    }

    private static func validateUbiquitousItemIsReadyForOpening(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current else {
            return
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw DocumentOpenError.downloadingFromICloud
    }

    private static func validatedProjectPath(relativePath: String, in rootURL: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("~") else {
            throw InkPondFileError.invalidFileName(relativePath)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw InkPondFileError.unsafePath(relativePath) }
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                throw InkPondFileError.unsafePath(relativePath)
            }
        }

        let normalized = components.map(String.init).joined(separator: "/")
        let root = rootURL.standardizedFileURL
        let target = root.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        let rootPath = root.path
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw InkPondFileError.unsafePath(relativePath)
        }
        return target
    }
}
