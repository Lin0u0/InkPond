import Foundation

nonisolated struct ProjectRootMigrationRecord: Codable, Sendable {
    let schemaVersion: Int
    let sourceURL: URL
    let stagingURL: URL
    let destinationURL: URL
    let sourceDigest: ContentDigest
    var state: ProjectOperationState
}

nonisolated enum ProjectRootMigrationJournal {
    static func pendingDestinationURL(projectID: ProjectID) -> URL? {
        guard let metadataRoot = try? ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID) else { return nil }
        let journalURL = metadataRoot.appendingPathComponent("root-migration-v1.json")
        guard let data = try? Data(contentsOf: journalURL),
              let record = try? JSONDecoder().decode(ProjectRootMigrationRecord.self, from: data),
              record.schemaVersion == 1 else { return nil }
        return record.destinationURL
    }

    static func acknowledge(projectID: ProjectID, destinationURL: URL) throws {
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        let journalURL = metadataRoot.appendingPathComponent("root-migration-v1.json")
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let record = try JSONDecoder().decode(
            ProjectRootMigrationRecord.self,
            from: Data(contentsOf: journalURL)
        )
        guard record.schemaVersion == 1,
              record.state == .committed,
              record.destinationURL.standardizedFileURL == destinationURL.standardizedFileURL,
              try directoryDigest(record.destinationURL) == record.sourceDigest else {
            throw ProjectRootMigrationError.verificationFailed
        }
        try FileManager.default.removeItem(at: journalURL)
        try DurableFileSynchronization.synchronizeParent(of: journalURL)
    }

    static func migrate(sourceURL: URL, destinationURL: URL, projectID: ProjectID) throws {
        let fm = FileManager.default
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        let journalURL = metadataRoot.appendingPathComponent("root-migration-v1.json")
        var record: ProjectRootMigrationRecord
        if fm.fileExists(atPath: journalURL.path) {
            record = try JSONDecoder().decode(ProjectRootMigrationRecord.self, from: Data(contentsOf: journalURL))
            guard record.schemaVersion == 1 else { throw ProjectRootMigrationError.unsupportedSchema }
        } else {
            let stagingURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".migration-\(projectID.description)", isDirectory: true)
            record = ProjectRootMigrationRecord(
                schemaVersion: 1,
                sourceURL: sourceURL,
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                sourceDigest: try directoryDigest(sourceURL),
                state: .prepared
            )
            try persist(record, to: journalURL)
        }

        if record.state == .prepared {
            if fm.fileExists(atPath: record.destinationURL.path) == false {
                if fm.fileExists(atPath: record.stagingURL.path),
                   try directoryDigest(record.stagingURL) != record.sourceDigest {
                    try fm.removeItem(at: record.stagingURL)
                }
                if fm.fileExists(atPath: record.stagingURL.path) == false {
                    try fm.copyItem(at: record.sourceURL, to: record.stagingURL)
                }
                guard try directoryDigest(record.stagingURL) == record.sourceDigest else {
                    throw ProjectRootMigrationError.verificationFailed
                }
                try fm.moveItem(at: record.stagingURL, to: record.destinationURL)
            }
            guard try directoryDigest(record.destinationURL) == record.sourceDigest else {
                throw ProjectRootMigrationError.verificationFailed
            }
            try DurableFileSynchronization.synchronizeFileAndParent(record.destinationURL)
            record.state = .applied
            try persist(record, to: journalURL)
        }

        if record.state == .applied {
            guard try directoryDigest(record.destinationURL) == record.sourceDigest else {
                throw ProjectRootMigrationError.verificationFailed
            }
            record.state = .committed
            try persist(record, to: journalURL)
        }

        guard record.state == .committed,
              try directoryDigest(record.destinationURL) == record.sourceDigest else {
            throw ProjectRootMigrationError.verificationFailed
        }
        if fm.fileExists(atPath: record.sourceURL.path) {
            try fm.removeItem(at: record.sourceURL)
        }
        // Keep the committed mapping as a recovery pointer until a future
        // model-layer acknowledgement can prove the locator update is durable.
    }

    private static func directoryDigest(_ rootURL: URL) throws -> ContentDigest {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw ProjectRootMigrationError.verificationFailed }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        var rows: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ProjectRootMigrationError.symbolicLinkRejected }
            guard values.isRegularFile == true else { continue }
            let relativePath = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            rows.append("\(relativePath):\(ContentDigest(data: try Data(contentsOf: url)).rawValue)")
        }
        return ContentDigest(data: Data(rows.sorted().joined(separator: "\n").utf8))
    }

    private static func persist(_ record: ProjectRootMigrationRecord, to url: URL) throws {
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        try DurableFileSynchronization.synchronizeFileAndParent(url)
    }
}

nonisolated enum ProjectRootMigrationError: Error, Equatable {
    case unsupportedSchema
    case verificationFailed
    case symbolicLinkRejected
}
