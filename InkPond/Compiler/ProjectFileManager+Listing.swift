//
//  ProjectFileManager+Listing.swift
//  InkPond
//

import Foundation
import os.log

extension ProjectFileManager {
    static func listProjectFiles(for document: InkPondDocument) -> ProjectFiles {
        if externalSingleFileURL(for: document) != nil {
            return ProjectFiles(typFiles: [document.entryFileName], imageFiles: [], fontFiles: [])
        }

        let fm = FileManager.default
        let projectDir = projectDirectory(for: document)

        let typFiles: [String]
        if let items = try? fm.contentsOfDirectory(atPath: projectDir.path) {
            typFiles = items
                .filter { $0.hasSuffix(".typ") }
                .sorted()
        } else {
            typFiles = []
        }

        let imageFiles: [String]
        let imagesDir = imagesDirectory(for: document)
        if let items = try? fm.contentsOfDirectory(atPath: imagesDir.path) {
            imageFiles = items.filter { !$0.hasPrefix(".") }.sorted()
        } else {
            imageFiles = []
        }

        let fontFiles: [String]
        let fontsDir = fontsDirectory(for: document)
        if let items = try? fm.contentsOfDirectory(atPath: fontsDir.path) {
            fontFiles = items.filter { !$0.hasPrefix(".") }.sorted()
        } else {
            fontFiles = []
        }

        return ProjectFiles(typFiles: typFiles, imageFiles: imageFiles, fontFiles: fontFiles)
    }

    static func listAllTypFiles(for document: InkPondDocument) -> [String] {
        if externalSingleFileURL(for: document) != nil {
            return [document.entryFileName]
        }
        return listAllTypFiles(in: projectDirectory(for: document))
    }

    nonisolated static func listAllTypFiles(in projectDirectory: URL) -> [String] {
        listAllFiles(in: projectDirectory)
            .filter { $0.hasSuffix(".typ") }
            .sorted()
    }

    nonisolated static func listAllFiles(in projectDirectory: URL) -> [String] {
        let fm = FileManager.default
        let rootURL = projectDirectory.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []

        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            let standardizedFileURL = fileURL.standardizedFileURL
            let fileComponents = standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { continue }

            let relativeComponents = fileComponents.dropFirst(rootComponents.count)
            guard !relativeComponents.isEmpty else { continue }

            let relativePath = relativeComponents.joined(separator: "/")
            files.append(relativePath)
        }

        return files.sorted()
    }

    nonisolated static func loadLinkedFolderContents(
        at folderURL: URL,
        maxDownloadWait: TimeInterval = 600,
        environment: LinkedFolderLoadEnvironment = .live,
        progress: (LinkedFolderLoadProgress) async -> Void
    ) async throws -> LinkedFolderLoadResult {
        try Task.checkCancellation()
        await Task.yield()

        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let rootURL = folderURL.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let deadline = environment.now().addingTimeInterval(maxDownloadWait)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .ubiquitousItemDownloadingStatusKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw InkPondFileError.fileNotFound(folderURL.lastPathComponent)
        }

        await progress(LinkedFolderLoadProgress(
            phase: .scanning,
            scannedFileCount: 0,
            downloadedFileCount: 0,
            totalDownloadFileCount: 0
        ))

        var relativePaths: [String] = []
        var pendingDownloadURLs: [URL] = []
        var seenPendingPaths = Set<String>()
        var scannedFileCount = 0

        while true {
            try Task.checkCancellation()
            guard environment.now() < deadline else {
                throw StorageManager.MigrationError.downloadTimeout
            }
            guard let fileURL = enumerator.nextObject() as? URL else { break }
            try Task.checkCancellation()
            guard environment.now() < deadline else {
                throw StorageManager.MigrationError.downloadTimeout
            }

            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])

            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values?.isDirectory == true {
                continue
            }
            if values?.isRegularFile == false {
                continue
            }
            if values?.isRegularFile == nil, fileURL.hasDirectoryPath {
                continue
            }

            let standardizedFileURL = fileURL.standardizedFileURL
            let fileComponents = standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { continue }

            let relativeComponents = fileComponents.dropFirst(rootComponents.count)
            guard !relativeComponents.isEmpty else { continue }

            let relativePath = relativeComponents.joined(separator: "/")
            relativePaths.append(relativePath)
            scannedFileCount += 1

            let downloadingStatus = try environment.downloadingStatus(fileURL)
            if downloadingStatus != nil,
               downloadingStatus != .current,
               seenPendingPaths.insert(relativePath).inserted {
                try environment.startDownloading(fileURL)
                pendingDownloadURLs.append(fileURL)
            }

            if scannedFileCount == 1 || scannedFileCount.isMultiple(of: 50) {
                await progress(LinkedFolderLoadProgress(
                    phase: .scanning,
                    scannedFileCount: scannedFileCount,
                    downloadedFileCount: 0,
                    totalDownloadFileCount: pendingDownloadURLs.count
                ))
            }
        }

        var downloadedFileCount = 0
        let totalDownloadFileCount = pendingDownloadURLs.count
        await progress(LinkedFolderLoadProgress(
            phase: totalDownloadFileCount == 0 ? .complete : .downloading,
            scannedFileCount: scannedFileCount,
            downloadedFileCount: downloadedFileCount,
            totalDownloadFileCount: totalDownloadFileCount
        ))

        var remainingDownloadURLs = pendingDownloadURLs
        while !remainingDownloadURLs.isEmpty {
            try Task.checkCancellation()

            var stillPending: [URL] = []
            for fileURL in remainingDownloadURLs {
                if try environment.downloadingStatus(fileURL) == .current {
                    downloadedFileCount += 1
                } else {
                    try environment.startDownloading(fileURL)
                    stillPending.append(fileURL)
                }
            }

            await progress(LinkedFolderLoadProgress(
                phase: .downloading,
                scannedFileCount: scannedFileCount,
                downloadedFileCount: downloadedFileCount,
                totalDownloadFileCount: totalDownloadFileCount
            ))

            guard !stillPending.isEmpty else { break }
            guard environment.now() < deadline else {
                throw StorageManager.MigrationError.downloadTimeout
            }

            remainingDownloadURLs = stillPending
            try await environment.sleep(.milliseconds(500))
        }

        if totalDownloadFileCount > 0 {
            await progress(LinkedFolderLoadProgress(
                phase: .complete,
                scannedFileCount: scannedFileCount,
                downloadedFileCount: downloadedFileCount,
                totalDownloadFileCount: totalDownloadFileCount
            ))
        }

        return LinkedFolderLoadResult(
            relativePaths: relativePaths.sorted(),
            scannedFileCount: scannedFileCount,
            downloadedFileCount: downloadedFileCount
        )
    }

    /// Rehydrates a linked folder and drops the compiled preview derived from
    /// its previous on-disk resources. The editor decides when to trigger the
    /// next compilation so in-memory source text can remain authoritative.
    nonisolated static func refreshLinkedFolderContents(
        at folderURL: URL,
        projectID: String,
        maxDownloadWait: TimeInterval = 120,
        previewCacheStore: CompiledPreviewCacheStore = CompiledPreviewCacheStore(),
        environment: LinkedFolderLoadEnvironment = .live,
        progress: (LinkedFolderLoadProgress) async -> Void
    ) async throws -> LinkedFolderLoadResult {
        let result = try await loadLinkedFolderContents(
            at: folderURL,
            maxDownloadWait: maxDownloadWait,
            environment: environment,
            progress: progress
        )
        try Task.checkCancellation()
        try previewCacheStore.remove(projectID: projectID)
        return result
    }

    nonisolated static func referenceCompletionSnapshot(
        in projectDirectory: URL,
        currentFileName: String
    ) async -> ProjectReferenceCompletionSnapshot {
        await Task.yield()

        let allFiles = listAllFiles(in: projectDirectory)
        let bibliographyFiles = allFiles.filter { isBibliographyFilePath($0) }
        var bibEntries: [TypstBibliographyEntry] = []
        for file in bibliographyFiles {
            let url = projectDirectory.appendingPathComponent(file)
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let entries = TypstBridge.bibliographyEntries(source: content, fileName: file) {
                bibEntries.append(contentsOf: entries)
            }
        }

        var labels: [(name: String, kind: String)] = []
        let typFiles = allFiles.filter { $0.hasSuffix(".typ") }.sorted()
        for file in typFiles where file != currentFileName {
            let url = projectDirectory.appendingPathComponent(file)
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let fileLabels = TypstBridge.labels(source: content) {
                labels.append(contentsOf: fileLabels.map { (name: $0.name, kind: $0.kind) })
            }
        }

        let imageFiles = allFiles.filter { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return supportedImageFileExtensions.contains(ext)
        }

        return ProjectReferenceCompletionSnapshot(
            bibEntries: bibEntries,
            externalLabels: labels,
            imageFiles: imageFiles
        )
    }

    nonisolated static func imageFiles(in projectDirectory: URL) async -> [String] {
        await Task.yield()
        return listAllFiles(in: projectDirectory).filter { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return supportedImageFileExtensions.contains(ext)
        }
    }

    static func projectTree(for document: InkPondDocument) -> [ProjectTreeNode] {
        if externalSingleFileURL(for: document) != nil {
            return [
                ProjectTreeNode(
                    relativePath: document.entryFileName,
                    displayName: document.entryFileName,
                    kind: .typ,
                    children: []
                )
            ]
        }

        let imageDirectoryName = safeImageDirectoryName(from: document.imageDirectoryName)
        return buildProjectTree(in: projectDirectory(for: document), relativePrefix: "", imageDirectoryName: imageDirectoryName)
    }

    static func imageDirectoryCandidates(from relativePaths: [String]) -> [String] {
        relevantDirectoryCandidates(from: relativePaths, matching: supportedImageFileExtensions)
    }

    static func fontDirectoryCandidates(from relativePaths: [String]) -> [String] {
        relevantDirectoryCandidates(from: relativePaths, matching: fontFileExtensions)
    }

    static func refreshedLinkedFolderFontFileNames(
        existing: [String],
        relativePaths: [String]
    ) -> [String] {
        let discoveredDefaultFontFileNames = relativePaths.compactMap { relativePath -> String? in
            let path = relativePath as NSString
            guard path.deletingLastPathComponent == "fonts",
                  fontFileExtensions.contains(path.pathExtension.lowercased()) else {
                return nil
            }
            return path.lastPathComponent
        }
        return Array(Set(existing + discoveredDefaultFontFileNames)).sorted()
    }

    static func requiresImportDirectorySelection(_ directories: [String]) -> Bool {
        normalizedImportDirectoryOptions(directories).count > 1
    }

    static func defaultImportDirectory(from directories: [String]) -> String? {
        let options = normalizedImportDirectoryOptions(directories)
        guard options.count == 1 else { return nil }
        return options[0]
    }

    static func importFontFiles(from relativeDirectory: String, for document: InkPondDocument) -> [String] {
        let urls = listFiles(in: relativeDirectory, for: document, matching: fontFileExtensions)
        guard !urls.isEmpty else {
            document.fontFileNames = []
            return []
        }

        ensureFontsDirectory(for: document)

        let imported = urls.compactMap { sourceURL -> String? in
            let fileName = sourceURL.lastPathComponent
            guard let destination = try? validatedProjectPath(relativePath: "fonts/\(fileName)", for: document) else {
                return nil
            }
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                do {
                    try copyItemReplacingSafely(from: sourceURL, to: destination)
                } catch {
                    return nil
                }
            }
            return fileName
        }

        let uniqueNames = Array(Set(imported)).sorted()
        document.fontFileNames = uniqueNames
        return uniqueNames
    }

    static func resolveImportedEntryFile(from typFiles: [String]) -> EntryFileResolution {
        let sortedFiles = typFiles.sorted()
        if let mainFile = sortedFiles.first(where: { ($0 as NSString).lastPathComponent == "main.typ" }) {
            return EntryFileResolution(entryFileName: mainFile, requiresInitialSelection: false)
        }
        if let firstTypFile = sortedFiles.first {
            return EntryFileResolution(entryFileName: firstTypFile, requiresInitialSelection: true)
        }
        return EntryFileResolution(entryFileName: nil, requiresInitialSelection: false)
    }

    @discardableResult
    static func saveImage(data: Data, fileName: String, for document: InkPondDocument) throws -> String {
        ensureImageDirectory(for: document)
        let imageDir = safeImageDirectoryName(from: document.imageDirectoryName)
        try validateFileName(fileName)
        let relativePath = imageDir.isEmpty ? fileName : "\(imageDir)/\(fileName)"
        let dest = try validatedProjectPath(relativePath: relativePath, for: document)
        if useCoordination {
            try CloudFileCoordinator.writeData(data, to: dest)
        } else {
            try data.write(to: dest)
        }
        os_log(.info, "ProjectFileManager: saved image %{public}@", fileName)
        return relativePath
    }

    private nonisolated static func isBibliographyFilePath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".bib")
            || lowercased.hasSuffix(".yaml")
            || lowercased.hasSuffix(".yml")
    }
}
