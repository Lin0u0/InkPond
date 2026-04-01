//
//  ProjectFileManager+Sync.swift
//  InkPond
//

import Foundation
import os.log

extension ProjectFileManager {
    private static let reservedDocumentDirectoryNames: Set<String> = [
        "AppFonts",
        "LocalPackages"
    ]

    static func untrackedFolderNames(knownProjectIDs: Set<String>) -> [String]? {
        guard let rootURL = syncDocumentsURL else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            guard !reservedDocumentDirectoryNames.contains(name) else { return nil }
            return knownProjectIDs.contains(name) ? nil : name
        }.sorted()
    }

    static func trackedFolderNames() -> Set<String>? {
        guard let rootURL = syncDocumentsURL else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return Set(contents.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            return reservedDocumentDirectoryNames.contains(name) ? nil : name
        })
    }

    static func migrateLegacyStructure(documents: [InkPondProject]) {
        let fm = FileManager.default
        guard let rootURL = syncDocumentsURL else { return }
        let legacyRoot = rootURL.appendingPathComponent("Projects", isDirectory: true)
        guard fm.fileExists(atPath: legacyRoot.path) else { return }

        for doc in documents {
            guard UUID(uuidString: doc.projectID) != nil else { continue }
            let oldDir = legacyRoot.appendingPathComponent(doc.projectID, isDirectory: true)
            let newFolderName = uniqueFolderName(for: doc.title)
            let newDir = rootURL.appendingPathComponent(newFolderName, isDirectory: true)
            if fm.fileExists(atPath: oldDir.path) {
                do {
                    try fm.moveItem(at: oldDir, to: newDir)
                } catch {
                    os_log(.error, "ProjectFileManager: failed to migrate directory %{public}@ → %{public}@: %{public}@",
                           doc.projectID, newFolderName, error.localizedDescription)
                    continue
                }
            }
            do {
                try CompiledPreviewCacheStore().moveCache(
                    from: doc.projectID,
                    to: newFolderName,
                    documentTitle: doc.title
                )
            } catch {
                os_log(.error, "ProjectFileManager: failed to migrate cache for %{public}@: %{public}@",
                       doc.title, error.localizedDescription)
            }
            doc.projectID = newFolderName
            os_log(.info, "ProjectFileManager: migrated %{public}@ → %{public}@", doc.title, newFolderName)
        }

        if let items = try? fm.contentsOfDirectory(atPath: legacyRoot.path), items.isEmpty {
            try? fm.removeItem(at: legacyRoot)
        }
    }

    static func migrateContentIfNeeded(for document: InkPondProject) {
        guard !document.requiresInitialEntrySelection else { return }

        let entryURL = entryFileURL(for: document)
        let fm = FileManager.default

        if fm.fileExists(atPath: entryURL.path) {
            return
        }

        let source = document.content
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            if useCoordination {
                try CloudFileCoordinator.writeString(source, to: entryURL)
            } else {
                try source.write(to: entryURL, atomically: true, encoding: .utf8)
            }
            os_log(.info, "ProjectFileManager: migrated content to %{public}@ for %{public}@",
                   document.entryFileName, document.projectID)
        } catch {
            os_log(.error, "ProjectFileManager: failed to migrate content for %{public}@: %{public}@",
                   document.projectID, error.localizedDescription)
        }
    }
}
