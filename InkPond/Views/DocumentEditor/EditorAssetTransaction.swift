import Foundation

/// Captured before provider callbacks/awaits. Retains the originating buffer, not
/// whichever buffer the SwiftUI attachment happens to display on completion.
@MainActor
struct EditorAssetDestination {
    let session: DocumentSession
    let attachmentID: UUID
    let lifecycle: UUID
    let authority: UUID
    let loadToken: UUID
    let revision: UInt64
    let selection: NSRange
    let imageDirectory: String
    let template: String
#if DEBUG
    // Per-operation suspension seam; never substitutes commit or normalization.
    var loadDataForTesting: ((DocumentEditorView.ImageImportSource) async throws -> Data)?
#endif

    init?(session: DocumentSession, attachmentID: UUID, selection: NSRange) {
        self.session = session
        self.attachmentID = attachmentID
        lifecycle = session.projectLifecycleGeneration
        authority = session.saveAuthority
        loadToken = session.fileLoadToken
        revision = session.editRevision
        self.selection = selection
        imageDirectory = ProjectFileManager.safeImageDirectoryName(from: session.document.imageDirectoryName)
        template = session.document.imageInsertionTemplate
        guard isValid else { return nil }
    }

    var isValid: Bool {
        let workspace = session.context
        let length = (session.editorText as NSString).length
        return workspace.attachmentID == attachmentID
            && workspace.sessions[session.currentFileName] === session
            && workspace.closeTask == nil
            && workspace.projectWritableLease != nil
            && session.projectLifecycleGeneration == lifecycle
            && session.saveAuthority == authority
            && session.fileLoadToken == loadToken
            && session.editRevision == revision
            && !session.isLoadingFileContent
            && selection.location != NSNotFound && selection.location >= 0
            && selection.length >= 0 && selection.location <= length
            && selection.length <= length - selection.location
    }

    func insert(_ text: String) throws {
        guard isValid, !Task.isCancelled else { throw CancellationError() }
        let before = EditorUndoSnapshot(text: session.editorText, selection: selection)
        let result = (before.text as NSString).replacingCharacters(in: selection, with: text)
        let after = EditorUndoSnapshot(text: result,
            selection: NSRange(location: selection.location + (text as NSString).length, length: 0))
        session.editorUndoHistory.record(before: before, after: after)
        session.editorText = after.text
        session.editorViewState.selectedLocation = after.selection.location
        session.editorViewState.selectedLength = 0
        session.scheduleSave(content: after.text, for: session.currentFileName)
    }
}

/// Bytes are task-owned in memory until the whole rich paste has loaded. A
/// synchronous main-actor commit installs all assets and the single undoable edit.
/// Unique names plus exclusive moves preserve pre-existing project files.
@MainActor
final class EditorAssetTransaction {
    let destination: EditorAssetDestination
    private var assets: [(path: String, data: Data)] = []
    private(set) var text = ""
    var paths: [String] { assets.map(\.path) }

    init(destination: EditorAssetDestination) { self.destination = destination }

    func append(text: String) { self.text += text }

    func append(data: Data, extension ext: String) -> String {
        let name = "image-\(UUID().uuidString).\(ext)"
        let path = destination.imageDirectory.isEmpty ? name : "\(destination.imageDirectory)/\(name)"
        assets.append((path, data))
        return path
    }

    private static func moveExclusively(from source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            do { try FileManager.default.moveItem(at: source, to: url) }
            catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }

    func commit() throws {
        try Task.checkCancellation()
        guard destination.isValid else { throw CancellationError() }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var installed: [URL] = []
        do {
            for (index, asset) in assets.enumerated() {
                let target = try ProjectFileManager.projectFileURL(relativePath: asset.path, for: destination.session.document)
                let source = staging.appendingPathComponent(String(index))
                try asset.data.write(to: source, options: .withoutOverwriting)
                if ProjectFileManager.useCoordination {
                    try CloudFileCoordinator.createDirectory(at: target.deletingLastPathComponent())
                    try Self.moveExclusively(from: source, to: target)
                } else {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: source, to: target)
                }
                installed.append(target)
            }
            try destination.insert(text)
        } catch {
            // Only successfully installed, uniquely named files belong to us.
            for url in installed {
                if ProjectFileManager.useCoordination { try? CloudFileCoordinator.removeItem(at: url) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }
}
