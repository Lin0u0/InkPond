import Foundation
import Observation

/// A revocable editor attachment. A departed view can still read its buffer, but
/// cannot mutate or request writes after another editor takes the project lease.
@Observable @MainActor
final class DocumentSessionAttachment {
    let id = UUID()
    var session: DocumentSession
    var isValid: Bool { session.context.attachmentID == id }
    init(session: DocumentSession) {
        self.session = session
        session.context.attachmentID = id
    }
}

/// Project-wide write authority and close/drain boundary, not workspace state.
/// Text, revisions, receipts, debounce and conflicts belong to individual sessions.
@Observable @MainActor
final class ProjectSaveContext {
    let document: InkPondDocument
    var sessions: [String: DocumentSession] = [:]
#if DEBUG
    var beforeFinalClose: (@MainActor () async -> Void)?
#endif
    var attachmentID: UUID?
    var closeTask: Task<Void, Never>?
    var saveAuthority = UUID()
    var reliabilityWriteAuthority = ProjectReliabilityWriteAuthority()
    var projectWritableLease: ProjectWritableLease?
    var projectAccessResolved = false
    var projectLifecycleGeneration = UUID()

    init(document: InkPondDocument) { self.document = document }

    func retain(_ session: DocumentSession) {
        // The empty bootstrap buffer is replaced on the first successful load.
        sessions = sessions.filter { !$0.key.isEmpty || $0.value === session }
        sessions[session.currentFileName] = session
    }

    func transfer() {
        attachmentID = nil
        reliabilityWriteAuthority.revoke()
        reliabilityWriteAuthority = ProjectReliabilityWriteAuthority()
        saveAuthority = UUID()
        projectLifecycleGeneration = UUID()
        for session in sessions.values {
            session.saveTask?.cancel()
            session.saveTask = nil
            session.activeSaveGeneration = nil
            session.lastSaveReceipt = nil
            session.fileLoadToken = UUID()
        }
        closeTask = nil
    }

    func close(session: DocumentSession, presentation: DocumentSessionRegistry.Presentation) {
        guard closeTask == nil, let lease = projectWritableLease else { return }
        let authority = saveAuthority
        let root = ProjectFileManager.projectDirectory(for: document)
        let external = ProjectFileManager.externalSingleFileURL(for: document)
        let id = document.stableProjectID
        closeTask = Task { @MainActor [self] in
            var saved = true
            for retained in Array(sessions.values) {
                if !(await retained.flushPendingSave()) { saved = false }
                guard saveAuthority == authority else { return }
            }
            saved = saved && sessions.values.allSatisfy { !$0.isDirty }
            if saved, !session.currentFileName.isEmpty {
                do {
                    let request = try session.reliabilityWriteRequest(
                        content: session.editorText, fileName: session.currentFileName,
                        fileURL: ProjectFileManager.projectFileURL(relativePath: session.currentFileName, for: document))
                    try await ProjectReliabilityWriterRegistry.shared.reconcile(request)
                } catch {
                    session.fileSaveError = error.localizedDescription
                    saved = false
                }
            }
            guard saveAuthority == authority else { return }
            saved = saved && sessions.values.allSatisfy { !$0.isDirty }
            guard saved else {
                session.recoveryWriteSequenceFloor = session.saveGeneration
                closeTask = nil
                DocumentSessionRegistry.shared.retain(.init(session: session, lease: lease,
                    presentation: presentation), for: id)
                return
            }
            // Freeze this attachment synchronously before the final close suspends.
            // A delayed UIKit binding must not create an unretained edit during drain.
            attachmentID = nil
            reliabilityWriteAuthority.revoke()
#if DEBUG
            await beforeFinalClose?()
#endif
            await ProjectReliabilityWriterRegistry.shared.close(projectID: id, rootURL: root, externalTargetURL: external)
            guard saveAuthority == authority else { return }
            projectWritableLease = nil
            await lease.release()
            DocumentSessionRegistry.shared.release(session)
            guard saveAuthority == authority else { return }
            if BookmarkManager.hasBookmark(projectID: document.projectID) {
                BookmarkManager.stopAccessing(document.projectID)
            }
            if ExternalTypFileSessionStore.contains(projectID: document.projectID) {
                ExternalTypFileSessionStore.unregister(projectID: document.projectID)
            }
            projectAccessResolved = false
            closeTask = nil
        }
    }
}
