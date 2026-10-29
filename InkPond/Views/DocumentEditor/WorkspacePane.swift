// Pane preference is session state, independent of document/file identity.
enum WorkspacePane: Int {
    case editor = 0
    case preview = 1

    static func collapseSelection(lastInteraction: WorkspacePane?, currentSelection: Int) -> Int {
        lastInteraction?.rawValue ?? currentSelection
    }
}
