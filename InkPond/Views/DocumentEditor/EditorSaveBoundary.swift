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

/// Narrow failure recovery for a disappearing editor. This is not a document-session
/// registry: only failed closes are retained, until reopened or successfully retried.
/// Like an unsaved editor buffer, this memory does not survive process termination.
@MainActor
final class EditorFailedCloseStore {
    static let shared = EditorFailedCloseStore()

    // Every retained draft requires a new write, even when text == persistedText.
    struct Draft {
        let lease: ProjectWritableLease
        let fileName: String
        let text: String
        let persistedText: String
        let entrySource: String
        let tabs: [ProjectFileTab]
        let activePath: String?
        let error: String?
        let relinquish: @MainActor () -> Void
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
        draft.relinquish()
        return draft
    }

    func remove(for projectID: ProjectID, lease: ProjectWritableLease?) {
        guard let lease, drafts[projectID]?.lease === lease else { return }
        drafts.removeValue(forKey: projectID)
    }
}
