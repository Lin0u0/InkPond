import Foundation
import Observation

/// A revocable editor attachment. A departed view can still read its buffer, but
/// cannot mutate or request writes after another editor takes the project lease.
@Observable @MainActor
final class DocumentSessionAttachment {
    let id = UUID()
    var session: DocumentSession
    var isValid: Bool { session.context.attachmentID == id }
    func acceptsTextMutation(for session: DocumentSession) -> Bool {
        isValid && self.session === session
            && session.context.sessions[session.currentFileName] === session
            && session.context.activeTextSession === session
    }

    init(session: DocumentSession) {
        self.session = session
        session.context.attachmentID = id
    }
}

/// Single workspace owner of navigation, write authority and close/drain.
/// Text, revisions, receipts, debounce and conflicts belong to individual sessions.
@Observable @MainActor
final class WorkspaceSession {
    enum Mode { case edit, preview }
    var mode: Mode = .edit
    var openTabs: [ProjectFileTab] = []
    var activeTabPath: String?
    var closeError: String?
    private static var accessOwners: [ProjectID: Set<UUID>] = [:]
    private let accessOwnerID = UUID()

    func retainExternalAccess() {
        Self.accessOwners[document.stableProjectID, default: []].insert(accessOwnerID)
    }

    func releaseExternalAccess() {
        let id = document.stableProjectID
        Self.accessOwners[id]?.remove(accessOwnerID)
        guard Self.accessOwners[id]?.isEmpty != false else { return }
        Self.accessOwners[id] = nil
        if BookmarkManager.hasBookmark(projectID: document.projectID) {
            BookmarkManager.stopAccessing(document.projectID)
        }
        ExternalTypFileSessionStore.unregister(projectID: document.projectID)
    }

    var acquisitionTask: Task<Void, Never>?
    var activeTab: ProjectFileTab? { openTabs.first { $0.relativePath == activeTabPath } }
    var activeTextSession: DocumentSession? {
        guard let tab = activeTab, tab.kind.isTextEditable else { return nil }
        return sessions[tab.relativePath]
    }
    var allowsTextCommands: Bool { activeTab?.kind.isTextEditable == true }

    func activate(relativePath: String, kind: FileKind) {
        guard kind.canBecomeTab else { return }
        let tab = ProjectFileTab(relativePath: relativePath, displayName: (relativePath as NSString).lastPathComponent, kind: kind)
        if let index = openTabs.firstIndex(where: { $0.relativePath == relativePath }) {
            openTabs[index] = tab
        } else { openTabs.append(tab) }
        activeTabPath = relativePath
    }

    /// A suspended flush may race another selection or a newer edit. Never evict
    /// a dirty/in-flight buffer, or change a selection made during that flush.
    @discardableResult
    func closeTab(_ path: String) async -> Bool {
        guard openTabs.contains(where: { $0.relativePath == path }) else { return true }
        let authority = saveAuthority
        if let target = sessions[path] {
            guard await target.flushPendingSave(), saveAuthority == authority,
                  !target.isDirty, target.savesInFlight == 0 else { return false }
            target.saveTask?.cancel()
            target.saveTask = nil
            target.stopConflictMonitoring()
            sessions.removeValue(forKey: path)
        }
        openTabs.removeAll { $0.relativePath == path }
        if activeTabPath == path { activeTabPath = openTabs.first?.relativePath }
        return true
    }

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

    /// Resolve access on the owner; cancellation after grant must return the lease.
    func acquireAccess(generation: UUID) async -> ProjectAccessLease? {
        retainExternalAccess()
        let access = await ProjectWritableLeaseCoordinator.shared.open(projectID: document.stableProjectID)
        guard !Task.isCancelled, projectLifecycleGeneration == generation else {
            if case .writable(let lease) = access { await lease.release() }
            releaseExternalAccess()
            return nil
        }
        return access
    }

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
        guard closeTask == nil else { return }
        guard let lease = projectWritableLease else {
            attachmentID = nil
            reliabilityWriteAuthority.revoke()
            sessions.removeAll()
            openTabs.removeAll()
            activeTabPath = nil
            projectAccessResolved = false
            releaseExternalAccess()
            return
        }
        closeError = nil
        let authority = saveAuthority
        let root = ProjectFileManager.projectDirectory(for: document)
        let external = ProjectFileManager.externalSingleFileURL(for: document)
        let id = document.stableProjectID
        closeTask = Task { @MainActor [self] in
            var saved = true
            for retained in Array(sessions.values) {
                if !(await retained.flushPendingSave()) {
                    saved = false
                    closeError = closeError ?? retained.fileSaveError
                }
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
            releaseExternalAccess()
            await lease.release()
            DocumentSessionRegistry.shared.release(session)
            guard saveAuthority == authority else { return }
            projectAccessResolved = false
            openTabs.removeAll()
            activeTabPath = nil
            acquisitionTask = nil
            closeTask = nil
        }
    }
}

// Compatibility is an alias, never a second owner.
typealias ProjectSaveContext = WorkspaceSession
