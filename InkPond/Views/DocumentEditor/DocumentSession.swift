import Foundation
import Observation

actor BackgroundDocumentFileWriter {
#if DEBUG
    // Instance-scoped checkpoints surround the real registry, never a substitute writer.
    var beforeRegistry: (@Sendable (ProjectReliabilityWriteRequest) async throws -> Void)?
    var afterRegistry: (@Sendable (ProjectReliabilityWriteRequest) async -> Void)?

    func setCheckpoints(
        before: (@Sendable (ProjectReliabilityWriteRequest) async throws -> Void)? = nil,
        after: (@Sendable (ProjectReliabilityWriteRequest) async -> Void)? = nil
    ) {
        beforeRegistry = before
        afterRegistry = after
    }
#endif
    func write(_ request: ProjectReliabilityWriteRequest) async throws {
#if DEBUG
        try await beforeRegistry?(request)
#endif
        try await ProjectReliabilityWriterRegistry.shared.write(request)
#if DEBUG
        await afterRegistry?(request)
#endif
    }
}

/// Authoritative text/save state. Retained by the registry while writable, including
/// failed closes; SwiftUI only keeps an attachment reference and presentation state.
@Observable
@MainActor
final class DocumentSession {
    let document: InkPondDocument
    var commitVersion: UInt64 = 0
    var closeTask: Task<Void, Never>? {
        get { context.closeTask }
        set { context.closeTask = newValue }
    }
    var isDirty: Bool { editorText != lastPersistedText || recoveryWriteSequenceFloor != nil }
#if DEBUG
    var saveTestDebounce: (@MainActor () async throws -> Void)?
#endif
    let currentFileName: String
    private(set) var editRevision: UInt64 = 0
    var editorText: String = "" {
        didSet { if oldValue != editorText { editRevision &+= 1 } }
    }
    var lastPersistedText: String = ""
    var saveTask: Task<Void, Never>?
    var saveGeneration: UInt64 = 0
    var savesInFlight = 0
    var recoveryWriteSequenceFloor: UInt64?
    var saveAuthority: UUID {
        get { context.saveAuthority }
        set { context.saveAuthority = newValue }
    }
    var reliabilityWriteAuthority: ProjectReliabilityWriteAuthority {
        get { context.reliabilityWriteAuthority }
        set { context.reliabilityWriteAuthority = newValue }
    }
    var lastSaveReceipt: EditorSaveReceipt?
    var activeSaveGeneration: UInt64?
    var backgroundFileWriter = BackgroundDocumentFileWriter()
    var projectWritableLease: ProjectWritableLease? {
        get { context.projectWritableLease }
        set { context.projectWritableLease = newValue }
    }
    var projectAccessResolved: Bool {
        get { context.projectAccessResolved }
        set { context.projectAccessResolved = newValue }
    }
    var projectLifecycleGeneration: UUID {
        get { context.projectLifecycleGeneration }
        set { context.projectLifecycleGeneration = newValue }
    }
    var conflictMonitor = FileConflictMonitor()
    var showingConflictWarning = false
    var conflictFileName: String = ""
    var fileSaveError: String?
    var fileLoadToken = UUID()
    var isLoadingFileContent = false

    let context: ProjectSaveContext
    init(document: InkPondDocument, fileName: String = "", context: ProjectSaveContext? = nil) {
        self.document = document
        self.currentFileName = fileName
        self.context = context ?? ProjectSaveContext(document: document)
    }


    func scheduleSave(content: String, for fileName: String) {
        guard fileName == currentFileName else { return }
        guard content != lastPersistedText || recoveryWriteSequenceFloor != nil || saveTask != nil || savesInFlight > 0 else {
            saveTask?.cancel()
            saveTask = nil
            activeSaveGeneration = nil
            return
        }

        let fileURL: URL
        do {
            fileURL = try ProjectFileManager.projectFileURL(relativePath: fileName, for: document)
        } catch {
            fileSaveError = error.localizedDescription
            return
        }
        let shouldRefreshPreviewAfterSave = fileName != document.entryFileName
        saveGeneration &+= 1
        let revision = saveGeneration
        activeSaveGeneration = revision
        let receipt = capturedSaveReceipt(content: content, fileName: fileName, sequence: revision)
        let request: ProjectReliabilityWriteRequest
        do {
            request = try reliabilityWriteRequest(content: content, fileName: fileName, fileURL: fileURL)
        } catch {
            fileSaveError = error.localizedDescription
            return
        }

        saveTask?.cancel()
        saveTask = Task { @MainActor [self] in
            do {
#if DEBUG
                if let saveTestDebounce {
                    try await saveTestDebounce()
                } else {
                    try await Task.sleep(for: .milliseconds(350))
                }
#else
                try await Task.sleep(for: .milliseconds(350))
#endif
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            // Check for real iCloud conflicts via NSFileVersion instead
            // of the unreliable modificationDate comparison.
            conflictMonitor.refreshConflictState()
            if conflictMonitor.hasConflict {
                self.conflictFileName = fileName
                self.showingConflictWarning = true
                return
            }

            guard !Task.isCancelled else { return }

            do {
                savesInFlight += 1
                defer { savesInFlight -= 1 }
                try await backgroundFileWriter.write(request)
                // Cancellation cannot undo a successful registry commit.
                if acknowledgeSave(receipt) {
                    self.document.modifiedAt = Date()
                    if shouldRefreshPreviewAfterSave {
                        self.commitVersion &+= 1
                    }
                }
                if self.activeSaveGeneration == revision && self.saveReceiptBelongsToLoadedFile(receipt) {
                    self.saveTask = nil
                    self.activeSaveGeneration = nil
                }
            } catch {
                if self.activeSaveGeneration == revision && self.saveReceiptBelongsToLoadedFile(receipt) {
                    self.fileSaveError = error.localizedDescription
                    self.saveTask = nil
                    self.activeSaveGeneration = nil
                }
            }
        }
    }

    @discardableResult
    func flushPendingSave() async -> Bool {
        let forceWrite = recoveryWriteSequenceFloor != nil || saveTask != nil || savesInFlight > 0
        let loadedFile = currentFileName
        let loadedToken = fileLoadToken
        saveTask?.cancel()
        saveTask = nil
        activeSaveGeneration = nil
        let committed = await persistCurrentFileImmediately(content: editorText, forceWrite: forceWrite)
        // Callers use this as permission to close, switch or export. A committed
        // older buffer is not permission to abandon text typed during the await.
        return committed && currentFileName == loadedFile && fileLoadToken == loadedToken
            && editorText == lastPersistedText && recoveryWriteSequenceFloor == nil
    }

    @discardableResult
    func persistCurrentFileImmediately(content: String, forceWrite: Bool = false) async -> Bool {
        guard !currentFileName.isEmpty else { return true }
        guard content != lastPersistedText || recoveryWriteSequenceFloor != nil || forceWrite || savesInFlight > 0 else { return true }

        let fileName = currentFileName
        let shouldRefreshPreviewAfterSave = fileName != document.entryFileName
        saveGeneration &+= 1
        let receipt = capturedSaveReceipt(content: content, fileName: fileName, sequence: saveGeneration)
        savesInFlight += 1
        defer { savesInFlight -= 1 }

        do {
            let fileURL = try ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document)
            let request = try reliabilityWriteRequest(content: content, fileName: currentFileName, fileURL: fileURL)
            try await backgroundFileWriter.write(request)
            if acknowledgeSave(receipt) {
                document.modifiedAt = Date()
                if shouldRefreshPreviewAfterSave {
                    commitVersion &+= 1
                }
            }
            return true // The captured write committed, even if its view has moved on.
        } catch {
            if saveReceiptBelongsToLoadedFile(receipt) {
                fileSaveError = error.localizedDescription
            }
            return false
        }
    }

    func capturedSaveReceipt(content: String, fileName: String, sequence: UInt64) -> EditorSaveReceipt {
        EditorSaveReceipt(projectID: document.stableProjectID, fileName: fileName,
                          lifecycle: projectLifecycleGeneration, loadToken: fileLoadToken,
                          sequence: sequence, content: content)
    }

    func saveReceiptBelongsToLoadedFile(_ receipt: EditorSaveReceipt) -> Bool {
        receipt.projectID == document.stableProjectID && receipt.fileName == currentFileName
            && receipt.lifecycle == projectLifecycleGeneration && receipt.loadToken == fileLoadToken
    }

    @discardableResult
    func acknowledgeSave(_ receipt: EditorSaveReceipt) -> Bool {
        guard projectWritableLease != nil, saveReceiptBelongsToLoadedFile(receipt),
              receipt.sequence >= (lastSaveReceipt?.sequence ?? 0) else { return false }
        lastSaveReceipt = receipt
        lastPersistedText = receipt.content
        if let floor = recoveryWriteSequenceFloor, receipt.sequence > floor {
            recoveryWriteSequenceFloor = nil
        }
        if recoveryWriteSequenceFloor == nil { fileSaveError = nil }
        // Recovery belongs to the whole project, not just the acknowledged file.
        if !isDirty && context.sessions.values.allSatisfy({ !$0.isDirty }) {
            EditorFailedCloseStore.shared.remove(for: document.stableProjectID, lease: projectWritableLease)
        }
        return true
    }

    func reliabilityWriteRequest(
        content: String,
        fileName: String,
        fileURL: URL
    ) throws -> ProjectReliabilityWriteRequest {
        try reliabilityWriteRequest(data: Data(content.utf8), fileName: fileName, fileURL: fileURL)
    }

    func reliabilityWriteRequest(
        data: Data,
        fileName: String,
        fileURL: URL
    ) throws -> ProjectReliabilityWriteRequest {
        if projectWritableLease == nil {
            throw ProjectWritableLeaseError.alreadyHeld(document.stableProjectID)
        }
        let externalURL = ProjectFileManager.externalSingleFileURL(for: document)
        let rootURL = externalURL?.deletingLastPathComponent() ?? ProjectFileManager.projectDirectory(for: document)
        let relativePath = externalURL?.lastPathComponent ?? fileName
        let entryRelativePath = externalURL?.lastPathComponent ?? document.entryFileName
        let backendKind = ProjectFileManager.reliabilityBackendKind(
            for: document,
            coordinatingManagedFiles: ProjectFileManager.useCoordination
        )
        guard fileURL.standardizedFileURL == rootURL.appendingPathComponent(relativePath).standardizedFileURL else {
            throw InkPondFileError.unsafePath(fileName)
        }
        return ProjectReliabilityWriteRequest(
            rootURL: rootURL,
            backendKind: backendKind,
            projectID: document.stableProjectID,
            displayName: document.title,
            entryRelativePath: entryRelativePath,
            relativePath: relativePath,
            data: data,
            externalTargetURL: externalURL,
            securityScopeLease: externalURL == nil
                ? BookmarkManager.acquireLease(projectID: document.projectID)
                : nil,
            writeAuthority: reliabilityWriteAuthority
        )
    }

    func startConflictMonitoring(for fileURL: URL) {
        let fileName = currentFileName
        conflictMonitor.onConflictDetected = { [weak self] in
            guard let self else { return }
            self.conflictFileName = fileName
            self.showingConflictWarning = true
        }
        conflictMonitor.onPresentedItemChanged = { [weak self] in
            self?.reloadPresentedFileIfSafe(named: fileName)
        }
        conflictMonitor.startMonitoring(url: fileURL)
    }

    func stopConflictMonitoring() {
        conflictMonitor.stopMonitoring()
    }

    func reloadPresentedFileIfSafe(named fileName: String) {
        guard fileName == currentFileName else { return }
        guard saveTask == nil, savesInFlight == 0, recoveryWriteSequenceFloor == nil, editorText == lastPersistedText else { return }

        conflictMonitor.refreshConflictState()
        if conflictMonitor.hasConflict {
            conflictFileName = fileName
            showingConflictWarning = true
            return
        }

        let diskText: String
        do {
            diskText = try ProjectFileManager.readTypFile(named: fileName, for: document)
        } catch {
            fileSaveError = error.localizedDescription
            return
        }
        guard diskText != editorText else { return }

        isLoadingFileContent = true
        editorText = diskText
        fileLoadToken = UUID()
        isLoadingFileContent = false
        lastPersistedText = diskText

        commitVersion &+= 1
    }

    func resolveConflictKeepLocal() async {
        // Preserve the load identity through commit, verification and state installation.
        savesInFlight += 1
        defer { savesInFlight -= 1 }
        showingConflictWarning = false
        let content = editorText
        saveGeneration &+= 1
        let receipt = capturedSaveReceipt(content: content, fileName: currentFileName, sequence: saveGeneration)
        let fileName = currentFileName
        let authority = saveAuthority
        let loadToken = fileLoadToken

        do {
            let fileURL = try ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document)
            let request = try reliabilityWriteRequest(content: content, fileName: currentFileName, fileURL: fileURL)
            try await VerifiedConflictResolution.commitThenDiscard {
                try await backgroundFileWriter.write(request)
            } verify: {
                guard saveAuthority == authority, fileLoadToken == loadToken else { throw CancellationError() }
                return try ProjectFileManager.readTypFile(named: fileName, for: document) == content
            } discardRemoteVersions: {
                guard saveAuthority == authority, fileLoadToken == loadToken else { throw CancellationError() }
                try conflictMonitor.resolveKeepingCurrent()
            }
            if acknowledgeSave(receipt) { document.modifiedAt = Date() }
        } catch {
            guard saveAuthority == authority, fileLoadToken == loadToken else { return }
            fileSaveError = error.localizedDescription
        }
    }

    func resolveConflictKeepRemote() async {
        // Preserve the load identity through commit, verification and state installation.
        savesInFlight += 1
        defer { savesInFlight -= 1 }
        showingConflictWarning = false
        let originalText = editorText
        let originalToken = fileLoadToken
        let originalFile = currentFileName
        let authority = saveAuthority
        let loadToken = fileLoadToken
        saveTask?.cancel()
        saveTask = nil
        activeSaveGeneration = nil

        // Pick the most recent conflict version and replace the current file.
        // If no conflict versions remain, just resolve and reload from disk.
        if let latest = conflictMonitor.conflictVersions
            .sorted(by: { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) })
            .first {
            do {
                let remoteData = try conflictMonitor.data(for: latest)
                guard let remoteContent = String(data: remoteData, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                let fileURL = try ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document)
                let request = try reliabilityWriteRequest(
                    content: remoteContent,
                    fileName: currentFileName,
                    fileURL: fileURL
                )
                try await VerifiedConflictResolution.commitThenDiscard {
                    try await backgroundFileWriter.write(request)
                } verify: {
                    guard saveAuthority == authority, fileLoadToken == loadToken else { throw CancellationError() }
                    return try ProjectFileManager.readTypFile(named: originalFile, for: document) == remoteContent
                } discardRemoteVersions: {
                    guard saveAuthority == authority, fileLoadToken == loadToken else { throw CancellationError() }
                    try conflictMonitor.resolveKeepingCurrent()
                }
            } catch {
                guard saveAuthority == authority, fileLoadToken == loadToken else { return }
                fileSaveError = error.localizedDescription
                return
            }
        } else {
            do {
                try conflictMonitor.resolveKeepingCurrent()
            } catch {
                fileSaveError = error.localizedDescription
                return
            }
        }

        guard fileLoadToken == originalToken, currentFileName == originalFile else { return }
        do {
            let remoteText = try ProjectFileManager.readTypFile(named: originalFile, for: document)
            if editorText == originalText { editorText = remoteText }
            lastPersistedText = remoteText
            fileLoadToken = UUID()
            lastSaveReceipt = nil
            recoveryWriteSequenceFloor = nil
            fileSaveError = nil
            commitVersion &+= 1
            if isDirty { scheduleSave(content: editorText, for: originalFile) }
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

}
