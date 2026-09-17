import Foundation

/// Identity of the captured editor buffer, not a claim about an iCloud revision.
struct EditorSaveReceipt {
    let projectID: ProjectID
    let fileName: String
    let lifecycle: UUID
    let loadToken: UUID
    let sequence: UInt64
    let content: String
}

/// App-lifetime retention and exclusive failed-close handoff. Writable sessions
/// remain alive until successful close, not merely until a view disappears.
@MainActor
final class DocumentSessionRegistry {
    static let shared = DocumentSessionRegistry()

    private var contexts: [ProjectID: ProjectSaveContext] = [:]
    var retainedSessionCount: Int { contexts.values.reduce(0) { $0 + $1.sessions.count } }

    func retain(_ session: DocumentSession) {
        let id = session.document.stableProjectID
        precondition(contexts[id] == nil || contexts[id] === session.context)
        session.context.retain(session)
        contexts[id] = session.context
    }

    func flushForBackground() async {
        for context in Array(contexts.values) where context.projectWritableLease != nil {
            if let draft = drafts[context.document.stableProjectID] {
                context.close(session: draft.session, presentation: draft.presentation)
                await context.closeTask?.value
            } else {
                for session in Array(context.sessions.values) { _ = await session.flushPendingSave() }
            }
        }
    }

    func release(_ session: DocumentSession) {
        let id = session.document.stableProjectID
        if contexts[id] === session.context {
            contexts[id] = nil
            drafts[id] = nil
            session.context.sessions.removeAll()
            let callbacks = subscribers[id].map { Array($0.values) } ?? []
            for callback in callbacks { callback() }
        }
    }

    func hasRetainedSession(for projectID: ProjectID) -> Bool { contexts[projectID] != nil }

    struct Presentation {
        let entrySource: String
        let tabs: [ProjectFileTab]
        let activePath: String?
    }

    struct Draft {
        let session: DocumentSession
        let lease: ProjectWritableLease
        let presentation: Presentation
        var entrySource: String { presentation.entrySource }
        var tabs: [ProjectFileTab] { presentation.tabs }
        var activePath: String? { presentation.activePath }
        var fileName: String { session.currentFileName }
        var text: String { session.editorText }
        var persistedText: String { session.lastPersistedText }
        var error: String? { session.fileSaveError }
    }

    private var drafts: [ProjectID: Draft] = [:]
    private var subscribers: [ProjectID: [UUID: @MainActor () -> Void]] = [:]

    func subscribe(for projectID: ProjectID, id: UUID, receive: @escaping @MainActor () -> Void) {
        subscribers[projectID, default: [:]][id] = receive
    }

    func unsubscribe(for projectID: ProjectID, id: UUID) {
        subscribers[projectID]?[id] = nil
        if subscribers[projectID]?.isEmpty == true { subscribers[projectID] = nil }
    }

    func retain(_ draft: Draft, for projectID: ProjectID) {
        drafts[projectID] = draft
        let callbacks = subscribers[projectID].map { Array($0.values) } ?? []
        for callback in callbacks { callback() }
    }

    func take(for projectID: ProjectID) -> Draft? {
        guard let draft = drafts.removeValue(forKey: projectID) else { return nil }
        // Transfer the live lease without an arbitration gap. The origin may retry
        // until this point, but cannot acknowledge or close after this handoff.
        draft.session.context.transfer()
        return draft
    }

    func remove(for projectID: ProjectID, lease: ProjectWritableLease?) {
        guard let lease, drafts[projectID]?.lease === lease else { return }
        drafts.removeValue(forKey: projectID)
    }
}

// Compatibility for M2-A characterization clients and the presentation handoff.
typealias EditorFailedCloseStore = DocumentSessionRegistry
