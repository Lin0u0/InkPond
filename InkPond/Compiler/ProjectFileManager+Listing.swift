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
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []

        for case let fileURL as URL in enumerator {
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
        progress: (LinkedFolderLoadProgress) async -> Void
    ) async throws -> LinkedFolderLoadResult {
        try Task.checkCancellation()
        await Task.yield()

        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let rootURL = folderURL.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
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

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .ubiquitousItemDownloadingStatusKey
            ])

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

            if values?.ubiquitousItemDownloadingStatus != nil,
               values?.ubiquitousItemDownloadingStatus != .current,
               seenPendingPaths.insert(relativePath).inserted {
                try? fm.startDownloadingUbiquitousItem(at: fileURL)
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
            phase: .downloading,
            scannedFileCount: scannedFileCount,
            downloadedFileCount: downloadedFileCount,
            totalDownloadFileCount: totalDownloadFileCount
        ))

        var remainingDownloadURLs = pendingDownloadURLs
        let deadline = Date().addingTimeInterval(maxDownloadWait)
        while !remainingDownloadURLs.isEmpty {
            try Task.checkCancellation()

            var stillPending: [URL] = []
            for fileURL in remainingDownloadURLs {
                if isUbiquitousItemDownloaded(fileURL) {
                    downloadedFileCount += 1
                } else {
                    try? fm.startDownloadingUbiquitousItem(at: fileURL)
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
            guard Date() < deadline else {
                throw StorageManager.MigrationError.downloadTimeout
            }

            remainingDownloadURLs = stillPending
            try await Task.sleep(for: .milliseconds(500))
        }

        return LinkedFolderLoadResult(
            relativePaths: relativePaths.sorted(),
            scannedFileCount: scannedFileCount,
            downloadedFileCount: downloadedFileCount
        )
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
        let fontsDir = fontsDirectory(for: document)

        let imported = urls.compactMap { sourceURL -> String? in
            let fileName = sourceURL.lastPathComponent
            let destination = fontsDir.appendingPathComponent(fileName)
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
        let dest = imagesDirectory(for: document).appendingPathComponent(fileName)
        if useCoordination {
            try CloudFileCoordinator.writeData(data, to: dest)
        } else {
            try data.write(to: dest)
        }
        os_log(.info, "ProjectFileManager: saved image %{public}@", fileName)
        return imageDir.isEmpty ? fileName : "\(imageDir)/\(fileName)"
    }

    private nonisolated static func isUbiquitousItemDownloaded(_ url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else {
            return true
        }
        return status == .current
    }

    private nonisolated static func isBibliographyFilePath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".bib")
            || lowercased.hasSuffix(".yaml")
            || lowercased.hasSuffix(".yml")
    }
}
