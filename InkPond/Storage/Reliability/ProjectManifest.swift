import Foundation

nonisolated struct ProjectFileRecord: Codable, Equatable, Sendable {
    let fileID: FileID
    let relativePath: String
    let revision: RevisionID
    let contentDigest: ContentDigest

    init(snapshot: DocumentSnapshot) {
        self.fileID = snapshot.fileID
        self.relativePath = snapshot.relativePath
        self.revision = snapshot.revision
        self.contentDigest = snapshot.contentDigest
    }

    init(fileID: FileID, relativePath: String, revision: RevisionID, contentDigest: ContentDigest) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.revision = revision
        self.contentDigest = contentDigest
    }
}

nonisolated struct ProjectManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let projectID: ProjectID
    let displayName: String
    let entryFileID: FileID
    let files: [ProjectFileRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID
        case displayName
        case entryFileID
        case files
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectID: ProjectID,
        displayName: String,
        entryFileID: FileID,
        files: [ProjectFileRecord]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProjectManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard files.contains(where: { $0.fileID == entryFileID }) else {
            throw ProjectManifestError.entryFileMissing(entryFileID)
        }
        guard Set(files.map(\.fileID)).count == files.count else {
            throw ProjectManifestError.duplicateFileID
        }
        guard Set(files.map(\.relativePath)).count == files.count else {
            throw ProjectManifestError.duplicateRelativePath
        }
        guard files.allSatisfy({ Self.isCanonicalRelativePath($0.relativePath) }) else {
            throw ProjectManifestError.invalidRelativePath
        }

        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.displayName = displayName
        self.entryFileID = entryFileID
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(ProjectID.self, forKey: .projectID),
            displayName: container.decode(String.self, forKey: .displayName),
            entryFileID: container.decode(FileID.self, forKey: .entryFileID),
            files: container.decode([ProjectFileRecord].self, forKey: .files)
        )
    }

    func file(relativePath: String) -> ProjectFileRecord? {
        files.first { $0.relativePath == relativePath }
    }

    func file(id: FileID) -> ProjectFileRecord? {
        files.first { $0.fileID == id }
    }

    func applying(_ snapshot: DocumentSnapshot) throws -> ProjectManifest {
        guard snapshot.projectID == projectID else {
            throw ProjectManifestError.projectIdentityMismatch
        }
        var nextFiles = files
        if let index = nextFiles.firstIndex(where: { $0.fileID == snapshot.fileID }) {
            guard snapshot.revision > nextFiles[index].revision else {
                throw ProjectManifestError.nonMonotonicRevision
            }
            nextFiles[index] = ProjectFileRecord(snapshot: snapshot)
        } else {
            guard !nextFiles.contains(where: { $0.relativePath == snapshot.relativePath }) else {
                throw ProjectManifestError.duplicateRelativePath
            }
            nextFiles.append(ProjectFileRecord(snapshot: snapshot))
        }
        return try ProjectManifest(
            schemaVersion: schemaVersion,
            projectID: projectID,
            displayName: displayName,
            entryFileID: entryFileID,
            files: nextFiles
        )
    }

    private static func isCanonicalRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

nonisolated enum ProjectManifestError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case entryFileMissing(FileID)
    case duplicateFileID
    case duplicateRelativePath
    case projectIdentityMismatch
    case nonMonotonicRevision
    case invalidRelativePath
}
