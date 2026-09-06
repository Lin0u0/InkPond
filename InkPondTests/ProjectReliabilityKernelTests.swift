import Foundation
import os
import Testing
@testable import InkPond

@Suite(.serialized)
struct ProjectReliabilityKernelTests {
    @Test func manifestRoundTripPreservesStableIdentityAndLatestSnapshot() throws {
        let projectID = ProjectID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let fileID = FileID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let first = DocumentSnapshot(
            projectID: projectID,
            fileID: fileID,
            revision: RevisionID(rawValue: 41),
            relativePath: "main.typ",
            data: Data("= First".utf8)
        )
        let latest = DocumentSnapshot(
            projectID: projectID,
            fileID: fileID,
            revision: try first.revision.advanced(),
            relativePath: "main.typ",
            data: Data("= Latest".utf8)
        )

        let manifest = try ProjectManifest(
            projectID: projectID,
            displayName: "Stable Project",
            entryFileID: fileID,
            files: [ProjectFileRecord(snapshot: latest)]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.projectID == projectID)
        #expect(decoded.entryFileID == fileID)
        #expect(decoded.file(relativePath: "main.typ")?.fileID == fileID)
        #expect(decoded.file(relativePath: "main.typ")?.revision == RevisionID(rawValue: 42))
        #expect(decoded.file(relativePath: "main.typ")?.contentDigest == latest.contentDigest)

        #expect(throws: ProjectManifestError.self) {
            _ = try decoded.applying(first)
        }

        var invalidJSON = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        invalidJSON["schemaVersion"] = 99
        let invalidData = try JSONSerialization.data(withJSONObject: invalidJSON)
        #expect(throws: ProjectManifestError.self) {
            _ = try JSONDecoder().decode(ProjectManifest.self, from: invalidData)
        }
    }

    @Test func modelIdentitySurvivesStorageLocatorRename() {
        let document = InkPondDocument(title: "Before")
        let stableID = document.stableProjectID
        document.projectID = "Renamed Folder"
        #expect(document.stableProjectID == stableID)
    }

    @Test func pathPolicyRejectsTraversalAndSymlinkAncestors() throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }

        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("final.typ"))
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("final.typ"),
            withDestinationURL: outside.appendingPathComponent("final.typ")
        )

        let policy = ProjectPathPolicy(rootURL: fixture.root)
        #expect(throws: ProjectPathPolicyError.self) { try policy.resolve("../outside.typ") }
        #expect(throws: ProjectPathPolicyError.self) { try policy.resolve("escape/stolen.typ") }
        #expect(throws: ProjectPathPolicyError.self) { try policy.resolve("final.typ") }
        #expect(try policy.resolve("chapters/one.typ").path.hasPrefix(fixture.root.path))
    }

    @Test @MainActor func publicProjectCRUDRejectsSymlinkAncestors() throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkPond-Outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("stolen.typ"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )
        try Data("entry".utf8).write(to: fixture.root.appendingPathComponent("main.typ"))
        let document = InkPondDocument(title: "Symlink CRUD")
        document.projectID = "crud-\(UUID().uuidString)"
        defer {
            BookmarkManager.stopAccessing(document.projectID)
            BookmarkManager.removeBookmark(projectID: document.projectID)
        }
        try BookmarkManager.saveBookmark(for: fixture.root, projectID: document.projectID)

        #expect(throws: InkPondFileError.self) {
            _ = try ProjectFileManager.readTypFile(named: "escape/stolen.typ", for: document)
        }
        #expect(throws: InkPondFileError.self) {
            try ProjectFileManager.writeTypFile(named: "escape/stolen.typ", content: "overwrite", for: document)
        }
        #expect(throws: InkPondFileError.self) {
            try ProjectFileManager.deleteProjectFile(relativePath: "escape/stolen.typ", for: document)
        }
        let importSource = fixture.root.appendingPathComponent("source.txt")
        try Data("import".utf8).write(to: importSource)
        #expect(throws: InkPondFileError.self) {
            _ = try ProjectFileManager.importFile(from: importSource, to: "escape", for: document)
        }
        #expect(throws: InkPondFileError.self) {
            _ = try ProjectFileManager.renameProjectDirectory(for: document, to: "Renamed linked root")
        }
        #expect(try String(contentsOf: outside.appendingPathComponent("stolen.typ"), encoding: .utf8) == "outside")
    }

    @Test func projectMutationGatePreventsDeleteFromBeingUndoneByEnteredSave() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        try Data("entry".utf8).write(to: fixture.root.appendingPathComponent("main.typ"))
        try Data("old".utf8).write(to: fixture.root.appendingPathComponent("chapter.typ"))
        let request = ProjectReliabilityWriteRequest(
            rootURL: fixture.root,
            backendKind: .local,
            projectID: ProjectID(),
            displayName: "Gate",
            entryRelativePath: "main.typ",
            relativePath: "chapter.typ",
            data: Data("entered autosave".utf8)
        )
        let context = try ProjectReliabilityWriteContext(request: request)

        let enteredSave = Task {
            try await context.write(
                relativePath: request.relativePath,
                data: request.data,
                displayName: request.displayName,
                entryRelativePath: request.entryRelativePath
            )
        }
        await Task.yield()
        enteredSave.cancel()
        try await context.remove(
            relativePath: request.relativePath,
            displayName: request.displayName,
            entryRelativePath: request.entryRelativePath
        )
        _ = try? await enteredSave.value

        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("chapter.typ").path) == false)
    }

    @Test func olderAutosaveCannotOverwriteNewerFlush() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let backend = try LocalProjectStorageBackend(rootURL: fixture.root)
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        let writer = RevisionedDocumentWriter(backend: backend, journal: journal)
        let projectID = ProjectID()
        let fileID = FileID()

        let autosave = DocumentSnapshot(projectID: projectID, fileID: fileID, revision: RevisionID(rawValue: 1), relativePath: "main.typ", data: Data("old autosave".utf8))
        let flush = DocumentSnapshot(projectID: projectID, fileID: fileID, revision: RevisionID(rawValue: 2), relativePath: "main.typ", data: Data("new flush".utf8))

        try await writer.write(flush)
        await #expect(throws: RevisionedDocumentWriterError.self) { try await writer.write(autosave) }
        #expect(try await backend.read("main.typ") == flush.data)
        #expect(await writer.committedRevision(for: fileID) == flush.revision)
    }

    @Test func failedVerificationNeverReplacesDestinationAndRecoveryIsDeterministic() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let base = try LocalProjectStorageBackend(rootURL: fixture.root)
        let backend = FaultInjectingProjectStorageBackend(base: base, fault: .corruptStagedRead)
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        let writer = RevisionedDocumentWriter(backend: backend, journal: journal)
        let initial = Data("remote version".utf8)
        try await base.writeStaged(initial, at: "seed")
        try await base.replace("main.typ", withStaged: "seed")

        let snapshot = DocumentSnapshot(projectID: ProjectID(), fileID: FileID(), revision: .initial, relativePath: "main.typ", data: Data("local version".utf8))
        await #expect(throws: ProjectStorageTransactionError.self) { try await writer.write(snapshot) }

        #expect(try await base.read("main.typ") == initial)
        let pending = try await journal.pendingEntries()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .prepared)

        let recoveryWriter = RevisionedDocumentWriter(backend: base, journal: journal)
        try await recoveryWriter.recover()
        #expect(try await base.read("main.typ") == snapshot.data)
        #expect(try await journal.pendingEntries().isEmpty)
    }

    @Test(arguments: [
        InjectedStorageFault.diskFull,
        .permissionLoss,
        .coordinationFailure,
        .failStagedWrite,
        .failReplace
    ])
    func injectedWriteFaultsPreserveExistingDestination(fault: InjectedStorageFault) async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let base = try LocalProjectStorageBackend(rootURL: fixture.root)
        let initial = Data("existing".utf8)
        try await base.writeStaged(initial, at: "seed")
        try await base.replace("main.typ", withStaged: "seed")
        let backend = FaultInjectingProjectStorageBackend(base: base, fault: fault)
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        let writer = RevisionedDocumentWriter(backend: backend, journal: journal)
        let snapshot = DocumentSnapshot(projectID: ProjectID(), fileID: FileID(), revision: .initial, relativePath: "main.typ", data: Data("replacement".utf8))

        await #expect(throws: Error.self) { try await writer.write(snapshot) }
        #expect(try await base.read("main.typ") == initial)
        let recoveryWriter = RevisionedDocumentWriter(backend: base, journal: journal)
        try await recoveryWriter.recover()
        #expect(try await journal.pendingEntries().isEmpty)
        #expect(try await base.read("main.typ") == snapshot.data)
    }

    @Test(arguments: ProjectTransactionStage.allCases)
    func restartResumesInterruptionAtEveryTransactionStage(stage: ProjectTransactionStage) async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let backend = try LocalProjectStorageBackend(rootURL: fixture.root)
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        let snapshot = DocumentSnapshot(projectID: ProjectID(), fileID: FileID(), revision: .initial, relativePath: "main.typ", data: Data("resumed".utf8))
        let interruptedWriter = RevisionedDocumentWriter(
            backend: backend,
            journal: journal,
            interruptAt: stage
        )

        await #expect(throws: ProjectStorageTransactionError.self) {
            try await interruptedWriter.write(snapshot)
        }
        let recoveryWriter = RevisionedDocumentWriter(backend: backend, journal: journal)
        try await recoveryWriter.recover()

        #expect(try await backend.read("main.typ") == snapshot.data)
        #expect(try await journal.pendingEntries().isEmpty)
        #expect(await recoveryWriter.committedRevision(for: snapshot.fileID) == snapshot.revision)
    }

    @Test func ioFaultClassesAtEveryTransactionStageRemainRecoverable() async throws {
        for fault in [
            ProjectStorageBackendError.diskFull,
            .permissionDenied,
            .coordinationFailed
        ] {
            for stage in ProjectTransactionStage.allCases {
                let fixture = try ReliabilityFixture()
                defer { fixture.remove() }
                let backend = try LocalProjectStorageBackend(rootURL: fixture.root)
                let journal = try ProjectOperationJournal(rootURL: fixture.root)
                let snapshot = DocumentSnapshot(
                    projectID: ProjectID(),
                    fileID: FileID(),
                    revision: .initial,
                    relativePath: "main.typ",
                    data: Data("\(fault)-\(stage.rawValue)".utf8)
                )
                let failing = RevisionedDocumentWriter(
                    backend: backend,
                    journal: journal,
                    failAt: stage,
                    injectedFailure: fault
                )

                await #expect(throws: ProjectStorageBackendError.self) {
                    try await failing.write(snapshot)
                }
                let recovery = RevisionedDocumentWriter(backend: backend, journal: journal)
                try await recovery.recover()
                #expect(try await backend.read("main.typ") == snapshot.data)
                #expect(try await journal.pendingEntries().isEmpty)
            }
        }
    }

    @Test func newerWriteRecoversOlderPreparedWriteBeforeCommitting() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let base = try LocalProjectStorageBackend(rootURL: fixture.root)
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        let projectID = ProjectID()
        let fileID = FileID()
        let old = DocumentSnapshot(projectID: projectID, fileID: fileID, revision: .initial, relativePath: "main.typ", data: Data("old".utf8))
        let newer = DocumentSnapshot(projectID: projectID, fileID: fileID, revision: RevisionID(rawValue: 2), relativePath: "main.typ", data: Data("newer".utf8))
        let failing = RevisionedDocumentWriter(
            backend: FaultInjectingProjectStorageBackend(base: base, fault: .diskFull),
            journal: journal
        )
        await #expect(throws: ProjectStorageBackendError.self) { try await failing.write(old) }

        let healthy = RevisionedDocumentWriter(backend: base, journal: journal)
        try await healthy.write(newer)

        #expect(try await base.read("main.typ") == newer.data)
        #expect(await healthy.committedRevision(for: fileID) == newer.revision)
        #expect(try await journal.pendingEntries().isEmpty)
    }

    @Test func operationProgressReachesCommittedCompletion() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let backend = try LocalProjectStorageBackend(rootURL: fixture.root)
        let writer = RevisionedDocumentWriter(
            backend: backend,
            journal: try ProjectOperationJournal(rootURL: fixture.root)
        )
        let phases = OSAllocatedUnfairLock<[OperationProgress.Phase]>(initialState: [])
        let snapshot = DocumentSnapshot(projectID: ProjectID(), fileID: FileID(), revision: .initial, relativePath: "main.typ", data: Data("progress".utf8))

        try await writer.write(snapshot) { progress in
            phases.withLock { $0.append(progress.phase) }
        }

        #expect(phases.withLock { $0 } == [.preparing, .staging, .verifying, .applying, .committing, .completed])
    }

    @Test func writableAndSecurityScopeLeasesBalanceOwnership() async throws {
        let coordinator = ProjectWritableLeaseCoordinator()
        let projectID = ProjectID()
        let first = try await coordinator.acquire(projectID: projectID)
        await #expect(throws: ProjectWritableLeaseError.self) {
            _ = try await coordinator.acquire(projectID: projectID)
        }
        await first.release()
        let second = try await coordinator.acquire(projectID: projectID)
        let readOnly = await coordinator.open(projectID: projectID)
        if case .readOnly = readOnly {
            // Expected while the second writer owns the project.
        } else {
            Issue.record("A second project window must open read-only")
        }
        let transferred = try await coordinator.transfer(second)
        await transferred.release()

        let counts = OSAllocatedUnfairLock(initialState: (starts: 0, stops: 0))
        var lease: SecurityScopeLease? = SecurityScopeLease(
            url: URL(fileURLWithPath: "/tmp"),
            startAccess: {
                counts.withLock { $0.starts += 1 }
                return true
            },
            stopAccess: { counts.withLock { $0.stops += 1 } }
        )
        #expect(lease != nil)
        lease?.release()
        lease?.release()
        lease = nil
        #expect(counts.withLock { $0.starts } == 1)
        #expect(counts.withLock { $0.stops } == 1)
    }

    @Test func journalRejectsUnsupportedSchemaAndInvalidTransitions() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let snapshot = DocumentSnapshot(projectID: ProjectID(), fileID: FileID(), revision: .initial, relativePath: "main.typ", data: Data("journal".utf8))
        let entry = ProjectOperationJournalEntry(snapshot: snapshot, stagedRelativePath: ".inkpond/staging/test")
        let journal = try ProjectOperationJournal(rootURL: fixture.root)
        try await journal.prepare(entry)
        await #expect(throws: ProjectOperationJournalError.self) {
            try await journal.transition(id: entry.id, to: .committed)
        }
        #expect(try await journal.pendingEntries().first?.state == .prepared)

        let journalURL = fixture.root.appendingPathComponent(".inkpond/journal-v1.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [[String: Any]])
        json[0]["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: journalURL, options: [.atomic])
        #expect(throws: ProjectOperationJournalError.self) {
            _ = try ProjectOperationJournal(rootURL: fixture.root)
        }
    }

    @Test func repeatedBookmarkProjectPathQueriesKeepOneBalancedReference() throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let projectID = "bookmark-\(UUID().uuidString)"
        defer { BookmarkManager.removeBookmark(projectID: projectID) }
        try BookmarkManager.saveBookmark(for: fixture.root, projectID: projectID)

        _ = try #require(BookmarkManager.projectPathURL(projectID: projectID))
        _ = try #require(BookmarkManager.projectPathURL(projectID: projectID))
        #expect(BookmarkManager.referenceCount(projectID: projectID) == 1)
        BookmarkManager.stopAccessing(projectID)
        #expect(BookmarkManager.referenceCount(projectID: projectID) == 0)
    }

    @Test func productionWriterRegistryPersistsManifestJournalAndFileIdentity() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        try Data("initial".utf8).write(to: fixture.root.appendingPathComponent("main.typ"))
        let projectID = ProjectID()
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        defer { try? FileManager.default.removeItem(at: metadataRoot) }
        let request = ProjectReliabilityWriteRequest(
            rootURL: fixture.root,
            backendKind: .local,
            projectID: projectID,
            displayName: "Registry",
            entryRelativePath: "main.typ",
            relativePath: "main.typ",
            data: Data("committed".utf8)
        )

        try await ProjectReliabilityWriterRegistry.shared.write(request)

        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("main.typ")) == request.data)
        let manifestData = try Data(contentsOf: metadataRoot.appendingPathComponent("project-manifest-v1.json"))
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: manifestData)
        #expect(manifest.projectID == projectID)
        #expect(manifest.file(relativePath: "main.typ")?.revision == RevisionID(rawValue: 2))
        let journal = try ProjectOperationJournal(rootURL: metadataRoot)
        #expect(try await journal.pendingEntries().isEmpty)
        #expect(try await journal.committedEntries().isEmpty)

        let imageURL = fixture.root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: imageURL)
        try await ProjectReliabilityWriterRegistry.shared.write(ProjectReliabilityWriteRequest(
            rootURL: fixture.root,
            backendKind: .local,
            projectID: projectID,
            displayName: "Registry",
            entryRelativePath: "main.typ",
            relativePath: "main.typ",
            data: Data("second".utf8)
        ))
        let refreshed = try JSONDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: metadataRoot.appendingPathComponent("project-manifest-v1.json"))
        )
        #expect(refreshed.file(relativePath: "image.png")?.fileID != nil)
    }

    @Test func rootMigrationVerifiesAndCommitsBeforeDeletingSource() throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("legacy", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("root migration".utf8).write(to: source.appendingPathComponent("main.typ"))
        let projectID = ProjectID()
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        defer { try? FileManager.default.removeItem(at: metadataRoot) }

        try ProjectRootMigrationJournal.migrate(
            sourceURL: source,
            destinationURL: destination,
            projectID: projectID
        )

        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try String(contentsOf: destination.appendingPathComponent("main.typ"), encoding: .utf8) == "root migration")
        #expect(ProjectRootMigrationJournal.pendingDestinationURL(projectID: projectID) == destination)
        try ProjectRootMigrationJournal.acknowledge(projectID: projectID, destinationURL: destination)
        #expect(ProjectRootMigrationJournal.pendingDestinationURL(projectID: projectID) == nil)
    }

    @Test @MainActor func conflictVersionsAreDiscardedOnlyAfterVerifiedCommit() async throws {
        var events: [String] = []
        await #expect(throws: ProjectStorageBackendError.self) {
            try await VerifiedConflictResolution.commitThenDiscard {
                events.append("commit")
                throw ProjectStorageBackendError.diskFull
            } verify: {
                events.append("verify")
                return true
            } discardRemoteVersions: {
                events.append("discard")
            }
        }
        #expect(events == ["commit"])

        events = []
        try await VerifiedConflictResolution.commitThenDiscard {
            events.append("commit")
        } verify: {
            events.append("verify")
            return true
        } discardRemoteVersions: {
            events.append("discard")
        }
        #expect(events == ["commit", "verify", "discard"])
    }
}

private struct ReliabilityFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkPond-Reliability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
