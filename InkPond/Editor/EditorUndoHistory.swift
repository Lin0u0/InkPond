import UIKit

/// Runtime-only find state. UIKit does not expose the navigator's selected options
/// or whether its replacement field is expanded; those are not serialized here.
struct EditorFindState {
    var query: String?
    var replacement: String?
    var isPresented = false
}

struct EditorUndoSnapshot {
    var text: String
    var selection: NSRange
}

/// A session-targeted history, never a TextKit/UIView-targeted history. Registration
/// stays disabled for UIKit, AutoPairEngine and completion commands. Only committed
/// delegate transactions may register. Full buffers intentionally favor correctness
/// over memory efficiency; each callback is one step (no typing/IME coalescing yet).
@MainActor
final class EditorUndoHistory: UndoManager {
    private final class Target {
        weak var history: EditorUndoHistory?
    }
    private let target = Target()
    private weak var session: DocumentSession?
    var attachmentID: UUID?
    var canReplay: (() -> Bool)?
    var didReplay: (() -> Void)?

    init(session: DocumentSession) {
        self.session = session
        super.init()
        target.history = self
        groupsByEvent = false
        disableUndoRegistration()
    }

    // TextKit may discard its own undo records on assignment/detachment. It must
    // not discard the session chain. Only an explicit external-reload reset may.
    override func removeAllActions() {}
    override func removeAllActions(withTarget target: Any) {}
    func resetHistory() {
        super.removeAllActions()
        // Foundation also resets the registration-disable count when clearing.
        if isUndoRegistrationEnabled { disableUndoRegistration() }
    }

    override func undo() {
        guard canReplay?() == true else { return }
        withRegistrationEnabled { super.undo() }
    }

    override func redo() {
        guard canReplay?() == true else { return }
        withRegistrationEnabled { super.redo() }
    }

    func record(before: EditorUndoSnapshot, after: EditorUndoSnapshot) {
        guard before.text != after.text else { return }
        register(before, inverse: after)
    }

    private func register(_ snapshot: EditorUndoSnapshot, inverse: EditorUndoSnapshot) {
        withRegistrationEnabled {
            // UndoManager creates the inverse group itself while replaying.
            let needsGroup = !isUndoing && !isRedoing
            if needsGroup { beginUndoGrouping() }
            registerUndo(withTarget: target) { target in
                guard let history = target.history else { return }
                history.register(inverse, inverse: snapshot)
                guard let session = history.session else { return }
                // Replay must not let TextKit register view-targeted actions into the
                // inverse group. Restore registration before Foundation closes it.
                history.disableUndoRegistration()
                defer { history.enableUndoRegistration() }
                session.editorViewState.selectedLocation = snapshot.selection.location
                session.editorViewState.selectedLength = snapshot.selection.length
                session.editorText = snapshot.text
                history.didReplay?()
            }
            if needsGroup { endUndoGrouping() }
        }
    }

    /// Foundation owns replay grouping, including opening and closing the inverse
    /// group. Keep registration enabled for that entire operation, not just for
    /// registerUndo, and balance only the disable level owned by this history.
    private func withRegistrationEnabled(_ operation: () -> Void) {
        let wasEnabled = isUndoRegistrationEnabled
        if !wasEnabled { enableUndoRegistration() }
        defer { if !wasEnabled { disableUndoRegistration() } }
        operation()
    }
}
