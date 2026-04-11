//
//  ProjectFileManager+Listing.swift
//  InkPond
//

import Foundation
import os.log

extension ProjectFileManager {
    static func listProjectFiles(for document: InkPondProject) -> ProjectFiles {
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

    static func listAllTypFiles(for document: InkPondProject) -> [String] {
        listAllTypFiles(in: projectDirectory(for: document))
    }

    static func listAllTypFiles(in projectDirectory: URL) -> [String] {
        listAllFiles(in: projectDirectory)
            .filter { $0.hasSuffix(".typ") }
            .sorted()
    }

    static func listAllFiles(in projectDirectory: URL) -> [String] {
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

    static func projectTree(for document: InkPondProject) -> [ProjectTreeNode] {
        let imageDirectoryName = safeImageDirectoryName(from: document.imageDirectoryName)
        return buildProjectTree(in: projectDirectory(for: document), relativePrefix: "", imageDirectoryName: imageDirectoryName, project: document)
    }

    static func imageDirectoryCandidates(from relativePaths: [String]) -> [String] {
        relevantDirectoryCandidates(from: relativePaths, matching: FileKind.image.supportedFileTypes)
    }

    static func fontDirectoryCandidates(from relativePaths: [String]) -> [String] {
        relevantDirectoryCandidates(from: relativePaths, matching: FileKind.font.supportedFileTypes)
    }

    static func requiresImportDirectorySelection(_ directories: [String]) -> Bool {
        normalizedImportDirectoryOptions(directories).count > 1
    }

    static func defaultImportDirectory(from directories: [String]) -> String? {
        let options = normalizedImportDirectoryOptions(directories)
        guard options.count == 1 else { return nil }
        return options[0]
    }

    static func importFontFiles(from relativeDirectory: String, for document: InkPondProject) -> [String] {
        let urls = listFiles(in: relativeDirectory, for: document, matching: FileKind.font.supportedFileTypes)
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
    static func saveImage(data: Data, fileName: String, for document: InkPondProject) throws -> String {
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
}
