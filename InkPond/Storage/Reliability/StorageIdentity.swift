import CryptoKit
import Foundation

nonisolated struct ProjectID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString.lowercased() }

    static func deterministic(legacyLocator: String) -> ProjectID {
        let hex = SHA256.hash(data: Data(legacyLocator.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return ProjectID(rawValue: UUID(uuidString: uuidString)!)
    }
}

nonisolated struct FileID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString.lowercased() }
}

nonisolated struct RevisionID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let initial = RevisionID(rawValue: 1)

    static func < (lhs: RevisionID, rhs: RevisionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func advanced() throws -> RevisionID {
        guard rawValue < UInt64.max else {
            throw StorageIdentityError.revisionOverflow
        }
        return RevisionID(rawValue: rawValue + 1)
    }
}

nonisolated struct ContentDigest: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(data: Data) {
        self.rawValue = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var description: String { rawValue }
}

nonisolated struct DocumentSnapshot: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let fileID: FileID
    let revision: RevisionID
    let relativePath: String
    let data: Data
    let contentDigest: ContentDigest

    init(
        projectID: ProjectID,
        fileID: FileID,
        revision: RevisionID,
        relativePath: String,
        data: Data
    ) {
        self.projectID = projectID
        self.fileID = fileID
        self.revision = revision
        self.relativePath = relativePath
        self.data = data
        self.contentDigest = ContentDigest(data: data)
    }
}

nonisolated enum StorageIdentityError: Error, Equatable {
    case revisionOverflow
}
