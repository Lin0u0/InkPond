//
//  ProjectFileManager+Files.swift
//  InkPond
//

import Foundation
import os.log

extension ProjectFileManager {
    static func copyItemReplacingSafely(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }

        if useCoordination {
            try CloudFileCoordinator.copyItem(from: sourceURL, to: destinationURL)
        } else {
            let fm = FileManager.default
            let tempURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
                ".replace-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
            )
            defer { try? fm.removeItem(at: tempURL) }

            try fm.copyItem(at: sourceURL, to: tempURL)
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(
                    destinationURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: tempURL, to: destinationURL)
            }
        }
    }

    static func readTypFile(named name: String, for document: InkPondDocument) throws -> String {
        let url = try validatedProjectPath(relativePath: name, for: document)
        if externalSingleFileURL(for: document) != nil {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return try CloudFileCoordinator.readString(from: url)
        }
        if useCoordination {
            return try CloudFileCoordinator.readString(from: url)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func writeTypFile(named name: String, content: String, for document: InkPondDocument) throws {
        let url = try validatedProjectPath(relativePath: name, for: document)
        if externalSingleFileURL(for: document) != nil {
            try CloudFileCoordinator.writeString(content, to: url)
            return
        }
        if useCoordination {
            try CloudFileCoordinator.writeString(content, to: url)
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func createTypFile(named name: String, for document: InkPondDocument) throws {
        try validateFileName(name)
        let url = try validatedProjectPath(relativePath: name, for: document)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw InkPondFileError.fileAlreadyExists(name)
        }
        if useCoordination {
            try CloudFileCoordinator.writeString("", to: url)
        } else {
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        os_log(.info, "ProjectFileManager: created %{public}@ in %{public}@", name, document.projectID)
    }

    static func deleteTypFile(named name: String, for document: InkPondDocument) throws {
        guard name != document.entryFileName else {
            throw InkPondFileError.cannotDeleteEntryFile
        }
        let url = try validatedProjectPath(relativePath: name, for: document)
        if useCoordination {
            try CloudFileCoordinator.removeItem(at: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        os_log(.info, "ProjectFileManager: deleted %{public}@ from %{public}@", name, document.projectID)
    }

    static func deleteProjectFile(relativePath: String, for document: InkPondDocument) throws {
        let url = try validatedProjectPath(relativePath: relativePath, for: document)
        if useCoordination {
            try CloudFileCoordinator.removeItem(at: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        os_log(.info, "ProjectFileManager: deleted %{public}@", relativePath)
    }

    @discardableResult
    static func importFile(from sourceURL: URL, to subdir: String, for document: InkPondDocument) throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        ensureProjectRoot(for: document)
        let destDir = try validatedProjectPath(relativePath: subdir, for: document, allowEmpty: true)
        if useCoordination {
            try CloudFileCoordinator.createDirectory(at: destDir)
        } else {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let fileName = sourceURL.lastPathComponent
        let dest = destDir.appendingPathComponent(fileName)
        try copyItemReplacingSafely(from: sourceURL, to: dest)
        os_log(.info, "ProjectFileManager: imported %{public}@ into %{public}@/%{public}@", fileName, document.projectID, subdir)
        return subdir.isEmpty ? fileName : "\(subdir)/\(fileName)"
    }
}
