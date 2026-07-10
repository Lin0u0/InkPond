//
//  ProjectFileManager+Sync.swift
//  InkPond
//

import Foundation
import os.log

extension ProjectFileManager {
    struct RootMigrationAcknowledgement {
        let projectID: ProjectID
        let destinationURL: URL
    }
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

    static func migrateLegacyStructure(documents: [InkPondDocument]) -> [RootMigrationAcknowledgement] {
        let fm = FileManager.default
        guard let rootURL = syncDocumentsURL else { return [] }
        let legacyRoot = rootURL.appendingPathComponent("Projects", isDirectory: true)
        var acknowledgements: [RootMigrationAcknowledgement] = []

        for doc in documents {
            if let pendingDestination = ProjectRootMigrationJournal.pendingDestinationURL(projectID: doc.stableProjectID),
               doc.projectID == pendingDestination.lastPathComponent {
                acknowledgements.append(RootMigrationAcknowledgement(
                    projectID: doc.stableProjectID,
                    destinationURL: pendingDestination
                ))
                continue
            }
            guard UUID(uuidString: doc.projectID) != nil else { continue }
            let oldDir = legacyRoot.appendingPathComponent(doc.projectID, isDirectory: true)
            let pendingDestination = ProjectRootMigrationJournal.pendingDestinationURL(projectID: doc.stableProjectID)
            guard fm.fileExists(atPath: legacyRoot.path) || pendingDestination != nil else { continue }
            let newFolderName = pendingDestination?.lastPathComponent ?? uniqueFolderName(for: doc.title)
            let newDir = pendingDestination ?? rootURL.appendingPathComponent(newFolderName, isDirectory: true)
            if fm.fileExists(atPath: oldDir.path) || pendingDestination != nil {
                do {
                    try ProjectRootMigrationJournal.migrate(
                        sourceURL: oldDir,
                        destinationURL: newDir,
                        projectID: doc.stableProjectID
                    )
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
            acknowledgements.append(RootMigrationAcknowledgement(
                projectID: doc.stableProjectID,
                destinationURL: newDir
            ))
            os_log(.info, "ProjectFileManager: migrated %{public}@ → %{public}@", doc.title, newFolderName)
        }

        if let items = try? fm.contentsOfDirectory(atPath: legacyRoot.path), items.isEmpty {
            try? fm.removeItem(at: legacyRoot)
        }
        return acknowledgements
    }

    static func migrateContentIfNeeded(for document: InkPondDocument) {
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
