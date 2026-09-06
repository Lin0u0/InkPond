import Foundation

nonisolated struct ProjectReliabilityWriteRequest: Sendable {
    let rootURL: URL
    let backendKind: ProjectStorageBackendKind
    let projectID: ProjectID
    let displayName: String
    let entryRelativePath: String
    let relativePath: String
    let data: Data
    let externalTargetURL: URL?
    let securityScopeLease: SecurityScopeLease?

    init(
        rootURL: URL,
        backendKind: ProjectStorageBackendKind,
        projectID: ProjectID,
        displayName: String,
        entryRelativePath: String,
        relativePath: String,
        data: Data,
        externalTargetURL: URL? = nil,
        securityScopeLease: SecurityScopeLease? = nil
    ) {
        self.rootURL = rootURL
        self.backendKind = backendKind
        self.projectID = projectID
        self.displayName = displayName
        self.entryRelativePath = entryRelativePath
        self.relativePath = relativePath
        self.data = data
        self.externalTargetURL = externalTargetURL
        self.securityScopeLease = securityScopeLease
    }
}

actor ProjectReliabilityWriterRegistry {
    static let shared = ProjectReliabilityWriterRegistry()
    private var contexts: [String: ProjectReliabilityWriteContext] = [:]

    func write(_ request: ProjectReliabilityWriteRequest) async throws {
        let key = Self.key(
            projectID: request.projectID,
            rootURL: request.rootURL,
            externalTargetURL: request.externalTargetURL
        )
        let context: ProjectReliabilityWriteContext
        if let existing = contexts[key] {
            context = existing
        } else {
            let created = try ProjectReliabilityWriteContext(request: request)
            contexts[key] = created
            context = created
        }
        try await context.write(
            relativePath: request.relativePath,
            data: request.data,
            displayName: request.displayName,
            entryRelativePath: request.entryRelativePath
        )
    }

    func close(projectID: ProjectID, rootURL: URL, externalTargetURL: URL? = nil) async {
        let key = Self.key(
            projectID: projectID,
            rootURL: rootURL,
            externalTargetURL: externalTargetURL
        )
        guard let context = contexts[key] else { return }
        await context.closeAndDrain()
        if contexts[key] === context {
            contexts.removeValue(forKey: key)
        }
    }

    func reconcile(_ request: ProjectReliabilityWriteRequest) async throws {
        let key = Self.key(
            projectID: request.projectID,
            rootURL: request.rootURL,
            externalTargetURL: request.externalTargetURL
        )
        let context: ProjectReliabilityWriteContext
        if let existing = contexts[key] {
            context = existing
        } else {
            let created = try ProjectReliabilityWriteContext(request: request)
            contexts[key] = created
            context = created
        }
        try await context.reconcileFileSet(
            displayName: request.displayName,
            entryRelativePath: request.entryRelativePath
        )
    }

    func remove(_ request: ProjectReliabilityWriteRequest) async throws {
        let key = Self.key(
            projectID: request.projectID,
            rootURL: request.rootURL,
            externalTargetURL: request.externalTargetURL
        )
        let context: ProjectReliabilityWriteContext
        if let existing = contexts[key] {
            context = existing
        } else {
            let created = try ProjectReliabilityWriteContext(request: request)
            contexts[key] = created
            context = created
        }
        try await context.remove(
            relativePath: request.relativePath,
            displayName: request.displayName,
            entryRelativePath: request.entryRelativePath
        )
    }

    private static func key(projectID: ProjectID, rootURL: URL, externalTargetURL: URL?) -> String {
        "\(projectID.description)|\(rootURL.standardizedFileURL.path)|\(externalTargetURL?.standardizedFileURL.path ?? "project")"
    }
}

actor ProjectReliabilityWriteContext {
    private let backend: any ProjectStorageBackend
    private let journal: ProjectOperationJournal
    private let manifest: ProjectManifestRepository
    private var fileWriters: [String: ProjectReliabilityFileWriter] = [:]
    private var didRecover = false
    private var recoveryTask: Task<Void, Error>?
    private let transactionGate = ProjectTransactionGate()
    private var isClosing = false

    init(request: ProjectReliabilityWriteRequest) throws {
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: request.projectID)
        if let externalTargetURL = request.externalTargetURL {
            backend = try ExternalSingleFileProjectStorageBackend(
                targetFileURL: externalTargetURL,
                stagingRootURL: metadataRoot
            )
        } else {
            backend = try ProjectStorageBackendFactory.make(
                kind: request.backendKind,
                rootURL: request.rootURL,
                securityScopeLease: request.securityScopeLease
            )
        }
        journal = try ProjectOperationJournal(rootURL: metadataRoot)
        manifest = try ProjectManifestRepository(
            rootURL: request.rootURL,
            metadataRootURL: metadataRoot,
            projectID: request.projectID,
            displayName: request.displayName,
            entryRelativePath: request.entryRelativePath,
            limitsManifestToEntryFile: request.externalTargetURL != nil
        )
    }

    func write(
        relativePath: String,
        data: Data,
        displayName: String,
        entryRelativePath: String
    ) async throws {
        guard !isClosing else { throw ProjectReliabilityContextError.closing }
        try Task.checkCancellation()
        await transactionGate.acquire()
        do {
            guard !isClosing else { throw ProjectReliabilityContextError.closing }
            try Task.checkCancellation()
            try await manifest.updateConfiguration(
                displayName: displayName,
                entryRelativePath: entryRelativePath
            )
            try await writeExclusively(relativePath: relativePath, data: data)
            await transactionGate.release()
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    private func writeExclusively(relativePath: String, data: Data) async throws {
        try await recoverIfNeeded()
        let fileWriter: ProjectReliabilityFileWriter
        if let existing = fileWriters[relativePath] {
            fileWriter = existing
        } else {
            let created = ProjectReliabilityFileWriter(
                writer: RevisionedDocumentWriter(backend: backend, journal: journal),
                manifest: manifest,
                journal: journal
            )
            fileWriters[relativePath] = created
            fileWriter = created
        }
        try await fileWriter.write(relativePath: relativePath, data: data)
    }

    func reconcileFileSet(displayName: String, entryRelativePath: String) async throws {
        guard !isClosing else { throw ProjectReliabilityContextError.closing }
        await transactionGate.acquire()
        do {
            guard !isClosing else { throw ProjectReliabilityContextError.closing }
            try await recoverIfNeeded()
            try await manifest.updateConfiguration(
                displayName: displayName,
                entryRelativePath: entryRelativePath
            )
            try await manifest.reconcileFileSet()
            await transactionGate.release()
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    func remove(relativePath: String, displayName: String, entryRelativePath: String) async throws {
        guard !isClosing else { throw ProjectReliabilityContextError.closing }
        await transactionGate.acquire()
        do {
            guard !isClosing else { throw ProjectReliabilityContextError.closing }
            try await recoverIfNeeded()
            try await manifest.updateConfiguration(
                displayName: displayName,
                entryRelativePath: entryRelativePath
            )
            try await backend.remove(relativePath)
            try await manifest.reconcileFileSet()
            fileWriters.removeValue(forKey: relativePath)
            await transactionGate.release()
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    func closeAndDrain() async {
        isClosing = true
        await transactionGate.acquire()
        await transactionGate.release()
    }

    private func recoverIfNeeded() async throws {
        if let recoveryTask {
            return try await recoveryTask.value
        }
        if didRecover, await journal.pendingEntries().isEmpty { return }
        let backend = backend
        let journal = journal
        let manifest = manifest
        let task = Task {
            let recoveryWriter = RevisionedDocumentWriter(backend: backend, journal: journal)
            try await recoveryWriter.recover()
            try await manifest.reconcile(await journal.committedEntries())
            try await journal.compactCommitted()
        }
        recoveryTask = task
        do {
            try await task.value
            didRecover = true
            recoveryTask = nil
        } catch {
            didRecover = false
            recoveryTask = nil
            throw error
        }
    }
}

nonisolated enum ProjectReliabilityContextError: Error, Equatable, Sendable {
    case closing
}

nonisolated enum ProjectReliabilityPaths {
    static func privateMetadataRoot(projectID: ProjectID) throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = appSupport
            .appendingPathComponent("Reliability", isDirectory: true)
            .appendingPathComponent(projectID.description, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

actor ProjectReliabilityFileWriter {
    private let writer: RevisionedDocumentWriter
    private let manifest: ProjectManifestRepository
    private let journal: ProjectOperationJournal

    init(
        writer: RevisionedDocumentWriter,
        manifest: ProjectManifestRepository,
        journal: ProjectOperationJournal
    ) {
        self.writer = writer
        self.manifest = manifest
        self.journal = journal
    }

    func write(relativePath: String, data: Data) async throws {
        let snapshot = try await manifest.reserveSnapshot(relativePath: relativePath, data: data)
        let operationID = try await writer.write(snapshot)
        try await manifest.commit(snapshot)
        try await journal.discardCommitted(id: operationID)
    }
}
