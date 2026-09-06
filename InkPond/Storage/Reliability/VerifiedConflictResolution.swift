import Foundation

enum VerifiedConflictResolution {
    static func commitThenDiscard(
        commit: () async throws -> Void,
        verify: () throws -> Bool,
        discardRemoteVersions: () throws -> Void
    ) async throws {
        try await commit()
        guard try verify() else { throw ProjectStorageTransactionError.verificationFailed }
        try discardRemoteVersions()
    }
}
