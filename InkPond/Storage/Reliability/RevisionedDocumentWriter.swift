import Foundation

actor RevisionedDocumentWriter {
    private let backend: any ProjectStorageBackend
    private let journal: ProjectOperationJournal
    private var revisions: [FileID: RevisionID] = [:]
    private var loadedCommittedRevisions = false
    private let interruptAt: ProjectTransactionStage?
    private let failAt: ProjectTransactionStage?
    private let injectedFailure: ProjectStorageBackendError?

    init(
        backend: any ProjectStorageBackend,
        journal: ProjectOperationJournal,
        interruptAt: ProjectTransactionStage? = nil,
        failAt: ProjectTransactionStage? = nil,
        injectedFailure: ProjectStorageBackendError? = nil
    ) {
        self.backend = backend
        self.journal = journal
        self.interruptAt = interruptAt
        self.failAt = failAt
        self.injectedFailure = injectedFailure
    }

    func write(
        _ snapshot: DocumentSnapshot,
        progress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> UUID {
        progress?(OperationProgress(phase: .preparing, completedUnitCount: 0, totalUnitCount: 5))
        if await journal.pendingEntries().isEmpty == false {
            try await recover()
        }
        try await loadCommittedRevisionsIfNeeded()
        if let current = revisions[snapshot.fileID], snapshot.revision <= current {
            throw RevisionedDocumentWriterError.staleRevision(attempted: snapshot.revision, committed: current)
        }

        let operationID = UUID()
        let stagedPath = ".inkpond/staging/\(operationID.uuidString).stage"
        let entry = ProjectOperationJournalEntry(id: operationID, snapshot: snapshot, stagedRelativePath: stagedPath)
        try await journal.prepare(entry)
        try interruptIfRequested(.prepared)
        try failIfRequested(.prepared)
        do {
            progress?(OperationProgress(phase: .staging, completedUnitCount: 1, totalUnitCount: 5))
            try await backend.writeStaged(snapshot.data, at: stagedPath)
            try interruptIfRequested(.staged)
            try failIfRequested(.staged)
            progress?(OperationProgress(phase: .verifying, completedUnitCount: 2, totalUnitCount: 5))
            let stagedData = try await backend.read(stagedPath)
            guard ContentDigest(data: stagedData) == snapshot.contentDigest else {
                throw ProjectStorageTransactionError.verificationFailed
            }
            try interruptIfRequested(.stagedVerified)
            try failIfRequested(.stagedVerified)
            progress?(OperationProgress(phase: .applying, completedUnitCount: 3, totalUnitCount: 5))
            try await backend.replace(snapshot.relativePath, withStaged: stagedPath)
            try interruptIfRequested(.replaced)
            try failIfRequested(.replaced)
            try await journal.transition(id: operationID, to: .applied)
            try interruptIfRequested(.applied)
            try failIfRequested(.applied)
            let installedData = try await backend.read(snapshot.relativePath)
            guard ContentDigest(data: installedData) == snapshot.contentDigest else {
                throw ProjectStorageTransactionError.verificationFailed
            }
            try interruptIfRequested(.installedVerified)
            try failIfRequested(.installedVerified)
            progress?(OperationProgress(phase: .committing, completedUnitCount: 4, totalUnitCount: 5))
            try await journal.transition(id: operationID, to: .committed)
            revisions[snapshot.fileID] = snapshot.revision
            progress?(OperationProgress(phase: .completed, completedUnitCount: 5, totalUnitCount: 5))
        } catch {
            if case ProjectStorageTransactionError.interrupted = error {
                throw error
            }
            try? await backend.remove(stagedPath)
            throw error
        }
        return operationID
    }

    func recover() async throws {
        let committedByPath = Dictionary(
            grouping: await journal.committedEntries(),
            by: { $0.snapshot.relativePath }
        ).compactMapValues { entries in entries.map(\.snapshot.revision).max() }
        for entry in await journal.pendingEntries() {
            if let committed = committedByPath[entry.snapshot.relativePath], committed >= entry.snapshot.revision {
                try? await backend.remove(entry.stagedRelativePath)
                try await journal.discard(id: entry.id)
                continue
            }
            switch entry.state {
            case .prepared:
                if try await backend.exists(entry.snapshot.relativePath),
                   ContentDigest(data: try await backend.read(entry.snapshot.relativePath)) == entry.snapshot.contentDigest {
                    try await journal.transition(id: entry.id, to: .applied)
                    try await journal.transition(id: entry.id, to: .committed)
                    revisions[entry.snapshot.fileID] = entry.snapshot.revision
                } else {
                    if try await backend.exists(entry.stagedRelativePath) == false {
                        try await backend.writeStaged(entry.snapshot.data, at: entry.stagedRelativePath)
                    }
                    let staged = try await backend.read(entry.stagedRelativePath)
                    guard ContentDigest(data: staged) == entry.snapshot.contentDigest else {
                        throw ProjectStorageTransactionError.recoveryVerificationFailed(entry.id)
                    }
                    try await backend.replace(entry.snapshot.relativePath, withStaged: entry.stagedRelativePath)
                    try await journal.transition(id: entry.id, to: .applied)
                    let installed = try await backend.read(entry.snapshot.relativePath)
                    guard ContentDigest(data: installed) == entry.snapshot.contentDigest else {
                        throw ProjectStorageTransactionError.recoveryVerificationFailed(entry.id)
                    }
                    try await journal.transition(id: entry.id, to: .committed)
                    revisions[entry.snapshot.fileID] = entry.snapshot.revision
                }
            case .applied:
                let installed = try await backend.read(entry.snapshot.relativePath)
                guard ContentDigest(data: installed) == entry.snapshot.contentDigest else {
                    throw ProjectStorageTransactionError.recoveryVerificationFailed(entry.id)
                }
                try await journal.transition(id: entry.id, to: .committed)
                revisions[entry.snapshot.fileID] = entry.snapshot.revision
            case .committed:
                break
            }
        }
        loadedCommittedRevisions = false
        try await loadCommittedRevisionsIfNeeded()
    }

    func committedRevision(for fileID: FileID) async -> RevisionID? {
        try? await loadCommittedRevisionsIfNeeded()
        return revisions[fileID]
    }

    private func loadCommittedRevisionsIfNeeded() async throws {
        guard !loadedCommittedRevisions else { return }
        revisions = Dictionary(grouping: await journal.committedEntries(), by: { $0.snapshot.fileID })
            .compactMapValues { entries in entries.map(\.snapshot.revision).max() }
        loadedCommittedRevisions = true
    }

    private func interruptIfRequested(_ stage: ProjectTransactionStage) throws {
        if interruptAt == stage {
            throw ProjectStorageTransactionError.interrupted(stage)
        }
    }

    private func failIfRequested(_ stage: ProjectTransactionStage) throws {
        if failAt == stage, let injectedFailure {
            throw injectedFailure
        }
    }
}

nonisolated enum ProjectTransactionStage: String, CaseIterable, Sendable {
    case prepared
    case staged
    case stagedVerified
    case replaced
    case applied
    case installedVerified
}

nonisolated enum RevisionedDocumentWriterError: Error, Equatable {
    case staleRevision(attempted: RevisionID, committed: RevisionID)
}

nonisolated enum ProjectStorageTransactionError: Error, Equatable {
    case verificationFailed
    case recoveryVerificationFailed(UUID)
    case interrupted(ProjectTransactionStage)
}
