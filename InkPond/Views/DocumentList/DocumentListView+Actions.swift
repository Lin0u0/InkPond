//
//  DocumentListView+Actions.swift
//  InkPond
//

import SwiftUI
import SwiftData

extension DocumentListView {
    func areDocumentsOrdered(_ lhs: InkPondDocument, _ rhs: InkPondDocument) -> Bool {
        let primaryComparison = compare(lhs, rhs, by: sortField)
        if primaryComparison != .orderedSame {
            return sortDirection.orders(primaryComparison)
        }

        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let modifiedComparison = lhs.modifiedAt.compare(rhs.modifiedAt)
        if modifiedComparison != .orderedSame {
            return modifiedComparison == .orderedDescending
        }

        return lhs.createdAt > rhs.createdAt
    }

    func compare(_ lhs: InkPondDocument, _ rhs: InkPondDocument, by field: SortField) -> ComparisonResult {
        switch field {
        case .title:
            lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        case .modifiedAt:
            lhs.modifiedAt.compare(rhs.modifiedAt)
        case .createdAt:
            lhs.createdAt.compare(rhs.createdAt)
        }
    }

    func scheduleFilesystemSync(delay: Duration = .milliseconds(300)) {
        syncTask?.cancel()
        syncTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if showingSettings {
                    needsFilesystemSync = true
                } else {
                    syncWithFilesystem()
                }
            }
        }
    }

    func syncWithFilesystem() {
        deduplicateDocumentsByProjectID()
        let knownIDs = Set(documents.map { $0.projectID })
        guard let existingFolders = ProjectFileManager.trackedFolderNames(),
              let newFolders = ProjectFileManager.untrackedFolderNames(knownProjectIDs: knownIDs) else {
            return
        }

        for document in documents where !existingFolders.contains(document.projectID) {
            if BookmarkManager.hasBookmark(projectID: document.projectID) { continue }
            try? CompiledPreviewCacheStore().remove(projectID: document.projectID)
            if selectedDocument == document {
                selectedDocument = nil
            }
            modelContext.delete(document)
        }

        for folderName in newFolders {
            let folderURL = ProjectFileManager.projectDirectory(folderName: folderName)
            let allFiles = ProjectFileManager.listAllFiles(in: folderURL)
            let doc = InkPondDocument(title: folderName, content: "")
            doc.projectID = folderName
            configureImportedDocument(doc, relativePaths: allFiles)
            modelContext.insert(doc)
        }
    }

    func deduplicateDocumentsByProjectID() {
        let groupedDocuments = Dictionary(grouping: documents, by: \.projectID)

        for (_, duplicates) in groupedDocuments where duplicates.count > 1 {
            let survivor = preferredDocumentForDuplicateGroup(duplicates)

            for duplicate in duplicates where duplicate != survivor {
                mergeDuplicateDocument(duplicate, into: survivor)
                if selectedDocument == duplicate {
                    selectedDocument = survivor
                }
                modelContext.delete(duplicate)
            }
        }
    }

    func preferredDocumentForDuplicateGroup(_ duplicates: [InkPondDocument]) -> InkPondDocument {
        duplicates.max { lhs, rhs in
            let lhsScore = duplicateRetentionScore(for: lhs)
            let rhsScore = duplicateRetentionScore(for: rhs)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt < rhs.modifiedAt
            }
            return lhs.createdAt > rhs.createdAt
        } ?? duplicates[0]
    }

    func duplicateRetentionScore(for document: InkPondDocument) -> Int {
        var score = 0
        if document.entryFileName != "main.typ" { score += 5 }
        if !document.entryFileName.isEmpty { score += 2 }
        if document.imageInsertMode != "image" { score += 4 }
        if document.imageDirectoryName != "images" { score += 4 }
        if !document.lastEditedFileName.isEmpty { score += 3 }
        if !document.fontFileNames.isEmpty { score += 2 }
        if !document.importEntryFileOptions.isEmpty { score += 1 }
        if !document.importImageDirectoryOptions.isEmpty { score += 1 }
        if !document.importFontDirectoryOptions.isEmpty { score += 1 }
        if !document.content.isEmpty { score += 1 }
        return score
    }

    func mergeDuplicateDocument(_ duplicate: InkPondDocument, into survivor: InkPondDocument) {
        if survivor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !duplicate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            survivor.title = duplicate.title
        }
        if survivor.content.isEmpty && !duplicate.content.isEmpty {
            survivor.content = duplicate.content
        }
        if shouldPreferEntryFileName(duplicate.entryFileName, over: survivor.entryFileName) {
            survivor.entryFileName = duplicate.entryFileName
        }
        if survivor.imageInsertMode == "image", duplicate.imageInsertMode != "image" {
            survivor.imageInsertMode = duplicate.imageInsertMode
        }
        if survivor.imageDirectoryName == "images", duplicate.imageDirectoryName != "images" {
            survivor.imageDirectoryName = duplicate.imageDirectoryName
        }
        if survivor.lastEditedFileName.isEmpty && !duplicate.lastEditedFileName.isEmpty {
            survivor.lastEditedFileName = duplicate.lastEditedFileName
        }
        if survivor.lastCursorLocation == 0 && duplicate.lastCursorLocation > 0 {
            survivor.lastCursorLocation = duplicate.lastCursorLocation
        }

        if duplicate.modifiedAt > survivor.modifiedAt {
            survivor.modifiedAt = duplicate.modifiedAt
        }
        if duplicate.createdAt < survivor.createdAt {
            survivor.createdAt = duplicate.createdAt
        }

        survivor.fontFileNames = Array(Set(survivor.fontFileNames + duplicate.fontFileNames)).sorted()
        survivor.requiresInitialEntrySelection = survivor.requiresInitialEntrySelection || duplicate.requiresInitialEntrySelection
        survivor.requiresImportConfiguration = survivor.requiresImportConfiguration || duplicate.requiresImportConfiguration
        survivor.importEntryFileOptions = Array(
            Set(survivor.importEntryFileOptions + duplicate.importEntryFileOptions)
        ).sorted()
        survivor.importImageDirectoryOptions = Array(
            Set(survivor.importImageDirectoryOptions + duplicate.importImageDirectoryOptions)
        ).sorted()
        survivor.importFontDirectoryOptions = Array(
            Set(survivor.importFontDirectoryOptions + duplicate.importFontDirectoryOptions)
        ).sorted()
    }

    func shouldPreferEntryFileName(_ candidate: String, over current: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if current.isEmpty { return true }
        if current == "main.typ", candidate != "main.typ" { return true }
        return false
    }

    func configureImportedDocument(_ document: InkPondDocument, relativePaths: [String]) {
        let typFiles = relativePaths.filter { $0.hasSuffix(".typ") }.sorted()
        let resolution = ProjectFileManager.resolveImportedEntryFile(from: typFiles)
        if let entryFile = resolution.entryFileName {
            document.entryFileName = entryFile
        }
        document.requiresInitialEntrySelection = resolution.requiresInitialSelection
        document.importEntryFileOptions = resolution.requiresInitialSelection ? typFiles : []

        let imageDirectoryOptions = ProjectFileManager.imageDirectoryCandidates(from: relativePaths)
        if ProjectFileManager.requiresImportDirectorySelection(imageDirectoryOptions) {
            document.importImageDirectoryOptions = imageDirectoryOptions
        } else {
            document.importImageDirectoryOptions = []
            if let autoImageDirectory = ProjectFileManager.defaultImportDirectory(from: imageDirectoryOptions) {
                document.imageDirectoryName = autoImageDirectory
            }
        }

        let fontDirectoryOptions = ProjectFileManager.fontDirectoryCandidates(from: relativePaths)
        if ProjectFileManager.requiresImportDirectorySelection(fontDirectoryOptions) {
            document.importFontDirectoryOptions = fontDirectoryOptions
        } else {
            document.importFontDirectoryOptions = []
            if let autoFontDirectory = ProjectFileManager.defaultImportDirectory(from: fontDirectoryOptions) {
                _ = ProjectFileManager.importFontFiles(from: autoFontDirectory, for: document)
            }
        }

        document.requiresImportConfiguration = document.requiresInitialEntrySelection
            || !document.importImageDirectoryOptions.isEmpty
            || !document.importFontDirectoryOptions.isEmpty
    }

    func nextAvailableTitle() -> String {
        let titles = Set(documents.map { $0.title })
        let base = L10n.untitledBase
        if !titles.contains(base) { return base }
        var i = 1
        while titles.contains(L10n.untitled(number: i)) { i += 1 }
        return L10n.untitled(number: i)
    }

    func addDocument() {
        let title = nextAvailableTitle()
        let doc = InkPondDocument(title: title, content: "")
        doc.projectID = ProjectFileManager.uniqueFolderName(for: title)
        do {
            try ProjectFileManager.createInitialProject(for: doc)
            modelContext.insert(doc)
        } catch {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
            projectActionError = error.localizedDescription
            return
        }
        selectedDocument = doc
        InteractionFeedback.notify(.success)
        AccessibilitySupport.announce(L10n.a11yDocumentCreated(title))
    }

    func importZip(from url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        let doc = InkPondDocument(title: title, content: "")
        doc.projectID = ProjectFileManager.uniqueFolderName(for: title)
        let destDir = ProjectFileManager.projectDirectory(for: doc)

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            try ProjectFileManager.createProjectRoot(for: doc)
            let extracted = try ZipImporter.extract(from: url, to: destDir)
            configureImportedDocument(doc, relativePaths: extracted)
            modelContext.insert(doc)
            selectedDocument = doc
            InteractionFeedback.notify(.success)
            AccessibilitySupport.announce(L10n.a11yDocumentImported(title))
        } catch {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
            zipImportError = error.localizedDescription
        }
    }

    func linkExternalFolder(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let title = url.lastPathComponent
        let doc = InkPondDocument(title: title, content: "")
        doc.projectID = ProjectFileManager.uniqueFolderName(for: title)

        do {
            try BookmarkManager.saveBookmark(for: url, projectID: doc.projectID)

            // Build relative paths for files in the external folder to configure import
            var allFiles: [String] = []
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegularFile {
                        let path = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                        allFiles.append(path)
                    }
                }
            }
            configureImportedDocument(doc, relativePaths: allFiles)
            modelContext.insert(doc)
            selectedDocument = doc
            InteractionFeedback.notify(.success)
            AccessibilitySupport.announce(L10n.a11yDocumentImported(title))
        } catch {
            BookmarkManager.removeBookmark(projectID: doc.projectID)
            zipImportError = error.localizedDescription
        }
    }
}
