//
//  ExternalTypFileImporter.swift
//  InkPond
//

import Foundation

enum ExternalTypFileImporter {
    static func canImport(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare("typ") == .orderedSame
    }

    static func importFile(from url: URL) throws -> InkPondDocument {
        guard canImport(url) else {
            throw InkPondFileError.invalidFileName(url.lastPathComponent)
        }

        let fileName = url.lastPathComponent
        try ProjectFileManager.validateFileName(fileName)

        let title = documentTitle(from: url)
        let document = InkPondDocument(title: title, content: "")
        document.projectID = ProjectFileManager.uniqueFolderName(for: title)

        do {
            try ProjectFileManager.createProjectRoot(for: document)
            try ProjectFileManager.createDefaultAssetDirectories(for: document)

            let importedPath = try ProjectFileManager.importFile(from: url, to: "", for: document)
            document.entryFileName = importedPath
            document.lastEditedFileName = importedPath
            document.lastCursorLocation = 0
            document.requiresInitialEntrySelection = false
            document.requiresImportConfiguration = false
            document.importEntryFileOptions = []
            document.importImageDirectoryOptions = []
            document.importFontDirectoryOptions = []
            document.modifiedAt = Date()
            return document
        } catch {
            try? ProjectFileManager.deleteProjectDirectory(for: document)
            throw error
        }
    }

    private static func documentTitle(from url: URL) -> String {
        let title = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.untitledBase : title
    }
}
