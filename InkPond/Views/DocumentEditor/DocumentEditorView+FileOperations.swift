//
//  DocumentEditorView+FileOperations.swift
//  InkPond
//

import Foundation
import SwiftUI
import SwiftData

extension DocumentEditorView {
    func prepareDocumentForEditing(allowMigration: Bool = true) async {
        let sessionID = ensureDocumentOpenSession(source: "editor_prepare")
        let interval = Diagnostics.beginInterval("document.open.prepare", category: .documentOpen)
        defer { Diagnostics.endInterval("document.open.prepare", category: .documentOpen, interval) }

        Diagnostics.record(
            .documentOpen,
            "prepare.start",
            sessionID: sessionID,
            metadata: [
                "projectHash": Diagnostics.hashIdentifier(document.projectID),
                "entryHash": Diagnostics.hashIdentifier(document.entryFileName),
                "requiresImportConfiguration": String(document.requiresImportConfiguration),
                "requiresInitialEntrySelection": String(document.requiresInitialEntrySelection)
            ]
        )

        do {
            Diagnostics.record(.documentOpen, "prepare.validate.start", sessionID: sessionID)
            try ProjectFileManager.validateDocumentCanOpen(document)
            Diagnostics.record(.documentOpen, "prepare.validate.success", sessionID: sessionID)
        } catch {
            Diagnostics.record(
                .documentOpen,
                "prepare.validate.failure",
                level: .error,
                sessionID: sessionID,
                metadata: Diagnostics.errorMetadata(error)
            )
            reportInitialOpenFailure(error.localizedDescription)
            return
        }

        if !allowMigration {
            let typFiles = ProjectFileManager.listAllTypFiles(for: document)
            let readOnlyEntry = typFiles.contains(document.entryFileName)
                ? document.entryFileName
                : ProjectFileManager.resolveImportedEntryFile(from: typFiles).entryFileName
            guard let readOnlyEntry, loadFile(named: readOnlyEntry) else {
                reportInitialOpenFailure(L10n.format("error.file.not_found", document.entryFileName))
                return
            }
            Diagnostics.record(.documentOpen, "prepare.success.read_only", sessionID: sessionID)
            return
        }

        ProjectFileManager.ensureProjectRoot(for: document)

        if document.requiresImportConfiguration || document.requiresInitialEntrySelection {
            let typFiles = ProjectFileManager.listAllTypFiles(for: document)
            let resolution = ProjectFileManager.resolveImportedEntryFile(from: typFiles)
            if let suggestedEntry = resolution.entryFileName {
                if !typFiles.contains(document.entryFileName) {
                    document.entryFileName = suggestedEntry
                }
                if resolution.requiresInitialSelection && document.importEntryFileOptions.isEmpty {
                    document.importEntryFileOptions = typFiles
                }
            }
            if !resolution.requiresInitialSelection {
                document.importEntryFileOptions = []
            }
            Diagnostics.record(
                .documentOpen,
                "prepare.import_configuration",
                sessionID: sessionID,
                metadata: [
                    "typFileCount": String(typFiles.count),
                    "requiresInitialSelection": String(resolution.requiresInitialSelection),
                    "suggestedEntryHash": resolution.entryFileName.map(Diagnostics.hashIdentifier) ?? "none"
                ]
            )
            document.requiresInitialEntrySelection = resolution.requiresInitialSelection
            applyAutomaticImportDirectories()
            document.requiresImportConfiguration = document.requiresInitialEntrySelection
                || !document.importImageDirectoryOptions.isEmpty
                || !document.importFontDirectoryOptions.isEmpty
            if document.requiresImportConfiguration {
                showingImportConfiguration = true
                currentFileName = ""
                editorText = ""
                entrySource = ""
                return
            }
        }

        Diagnostics.record(.documentOpen, "prepare.migration.start", sessionID: sessionID)
        if allowMigration {
            await migrateLegacyContentReliablyIfNeeded()
        }
        if !loadFile(named: document.entryFileName) {
            reportInitialOpenFailure(fileSaveError ?? L10n.format("error.file.not_found", document.entryFileName))
        } else {
            Diagnostics.record(.documentOpen, "prepare.success", sessionID: sessionID)
        }
    }

    private func migrateLegacyContentReliablyIfNeeded() async {
        guard !document.requiresInitialEntrySelection else { return }
        let fileURL = ProjectFileManager.entryFileURL(for: document)
        guard FileManager.default.fileExists(atPath: fileURL.path) == false else { return }
        let source = document.content
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try ProjectFileManager.createProjectRoot(for: document)
            try ProjectFileManager.createTypFile(named: document.entryFileName, for: document)
            let request = try reliabilityWriteRequest(
                content: source,
                fileName: document.entryFileName,
                fileURL: fileURL
            )
            try await backgroundFileWriter.write(request)
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

    func reportInitialOpenFailure(_ message: String) {
        Diagnostics.record(
            .documentOpen,
            "initial_open.failure",
            level: .error,
            sessionID: documentOpenSessionID
        )
        fileSaveError = message
        onInitialOpenFailure?(message)
    }

    @discardableResult
    func loadFile(named name: String) -> Bool {
        let sessionID = documentOpenSessionID ?? ensureDocumentOpenSession(source: "load_file")
        let startedAt = Date()
        let interval = Diagnostics.beginInterval("document.open.load_file", category: .documentOpen)
        Diagnostics.record(
            .documentOpen,
            "load_file.start",
            sessionID: sessionID,
            metadata: [
                "fileHash": Diagnostics.hashIdentifier(name),
                "isEntry": String(name == document.entryFileName),
                "usesCoordination": String(ProjectFileManager.useCoordination)
            ]
        )

        saveTask?.cancel()
        saveTask = nil

        // If the file is in iCloud and not yet downloaded, trigger download
        let fileURL = ProjectFileManager.typFileURL(named: name, for: document)
        if ProjectFileManager.useCoordination {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                Diagnostics.record(
                    .iCloud,
                    "download.requested",
                    sessionID: sessionID,
                    metadata: ["fileHash": Diagnostics.hashIdentifier(fileURL.standardizedFileURL.path)]
                )
            } catch {
                Diagnostics.record(
                    .iCloud,
                    "download.request_failed",
                    level: .error,
                    sessionID: sessionID,
                    metadata: Diagnostics.errorMetadata(error)
                )
            }
        }

        let text: String
        do {
            text = try ProjectFileManager.readTypFile(named: name, for: document)
        } catch {
            var metadata = Diagnostics.errorMetadata(error)
            metadata["elapsedMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            metadata["fileHash"] = Diagnostics.hashIdentifier(name)
            Diagnostics.record(
                .documentOpen,
                "load_file.failure",
                level: .error,
                sessionID: sessionID,
                metadata: metadata
            )
            Diagnostics.endInterval("document.open.load_file", category: .documentOpen, interval)
            fileSaveError = error.localizedDescription
            return false
        }

        insertionRequest = nil
        pendingCursorJump = nil
        editorViewState = EditorViewState()
        currentFileName = name
        activateTab(relativePath: name, kind: ProjectFileManager.fileKind(for: name, imageDirectoryName: document.imageDirectoryName))
        isLoadingFileContent = true
        editorText = text
        fileLoadToken = UUID()
        isLoadingFileContent = false
        lastPersistedText = text
        if name == document.entryFileName {
            entrySource = text
            _ = refreshResolvedFonts(includeAvailableFamilies: false)
        }
        compilationErrorLines = recomputeCompilationErrorLines()

        // Start monitoring the newly opened file for iCloud conflicts.
        startConflictMonitoring(for: fileURL)

        pumpPendingInsertionsIfNeeded()
        Diagnostics.record(
            .documentOpen,
            "load_file.success",
            sessionID: sessionID,
            metadata: [
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "byteCount": String(text.utf8.count),
                "fileHash": Diagnostics.hashIdentifier(name)
            ]
        )
        Diagnostics.endInterval("document.open.load_file", category: .documentOpen, interval)
        return true
    }

    func ensureDocumentOpenSession(source: String) -> String {
        if let documentOpenSessionID {
            return documentOpenSessionID
        }
        let session = Diagnostics.startSession(
            category: .documentOpen,
            metadata: [
                "source": source,
                "projectHash": Diagnostics.hashIdentifier(document.projectID),
                "entryHash": Diagnostics.hashIdentifier(document.entryFileName)
            ]
        )
        documentOpenSessionID = session.id
        return session.id
    }

    func activateTab(relativePath: String, kind: FileKind) {
        guard kind.canBecomeTab else { return }
        let tab = ProjectFileTab(
            relativePath: relativePath,
            displayName: (relativePath as NSString).lastPathComponent,
            kind: kind
        )
        if let index = openTabs.firstIndex(where: { $0.relativePath == relativePath }) {
            openTabs[index] = tab
        } else {
            openTabs.append(tab)
        }
        activeTabPath = relativePath
    }

    func restoreProjectEditorStateIfNeeded() {
        guard !didRestoreProjectEditorState else { return }
        didRestoreProjectEditorState = true

        let savedState = ProjectEditorStateStore.load(projectID: document.projectID)
        let restoredTabs = savedState.openTabPaths.compactMap(savedProjectTab(for:))
        guard !restoredTabs.isEmpty else {
            persistProjectEditorTabState()
            return
        }

        openTabs = restoredTabs

        if let activePath = savedState.activeTabPath,
           let activeTab = restoredTabs.first(where: { $0.relativePath == activePath }) {
            if activeTab.kind.isTextEditable {
                _ = loadFile(named: activePath)
            } else {
                focusCoordinator.dismissKeyboard()
                selectedTab = editorTab
                activeTabPath = activePath
            }
        } else if let currentTextTab = restoredTabs.first(where: { $0.relativePath == currentFileName }) {
            activeTabPath = currentTextTab.relativePath
        } else {
            activeTabPath = restoredTabs.first?.relativePath
        }

        persistProjectEditorTabState()
    }

    func persistProjectEditorTabState() {
        guard didRestoreProjectEditorState else { return }
        ProjectEditorStateStore.saveTabs(
            projectID: document.projectID,
            openTabPaths: openTabs.map(\.relativePath),
            activeTabPath: activeTabPath
        )
    }

    private func savedProjectTab(for relativePath: String) -> ProjectFileTab? {
        guard isSafeSavedProjectPath(relativePath) else { return nil }

        let projectDirectory = ProjectFileManager.projectDirectory(for: document).standardizedFileURL
        let url = projectDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(projectDirectory.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let kind = ProjectFileManager.fileKind(for: relativePath, imageDirectoryName: document.imageDirectoryName)
        guard kind.canBecomeTab else { return nil }
        return ProjectFileTab(
            relativePath: relativePath,
            displayName: (relativePath as NSString).lastPathComponent,
            kind: kind
        )
    }

    private func isSafeSavedProjectPath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return false }
        return !relativePath.split(separator: "/").contains("..")
    }

    func openProjectFile(_ node: ProjectTreeNode) async {
        guard node.kind.canBecomeTab else { return }
        if node.kind.isTextEditable {
            selectedTab = editorTab
            _ = await openFileIfPossible(named: node.relativePath)
            return
        }

        guard await flushPendingSave() else { return }
        focusCoordinator.dismissKeyboard()
        selectedTab = editorTab
        activateTab(relativePath: node.relativePath, kind: node.kind)
        InteractionFeedback.selection()
    }

    func selectProjectTab(_ tab: ProjectFileTab) async {
        guard tab.relativePath != activeTabPath else { return }
        if tab.kind.isTextEditable {
            selectedTab = editorTab
            _ = await openFileIfPossible(named: tab.relativePath)
            return
        }

        guard await flushPendingSave() else { return }
        focusCoordinator.dismissKeyboard()
        selectedTab = editorTab
        activeTabPath = tab.relativePath
        InteractionFeedback.selection()
    }

    func closeProjectTab(_ tab: ProjectFileTab) async {
        if tab.relativePath == currentFileName {
            guard await flushPendingSave() else { return }
        }

        openTabs.removeAll { $0.relativePath == tab.relativePath }
        guard activeTabPath == tab.relativePath else { return }

        if let currentTextTab = openTabs.first(where: { $0.relativePath == currentFileName }) {
            activeTabPath = currentTextTab.relativePath
        } else if let nextTab = openTabs.first {
            await selectProjectTab(nextTab)
        } else if !currentFileName.isEmpty {
            activateTab(
                relativePath: currentFileName,
                kind: ProjectFileManager.fileKind(for: currentFileName, imageDirectoryName: document.imageDirectoryName)
            )
        } else {
            activeTabPath = nil
        }
    }

    @discardableResult
    func setEntryProjectFile(_ relativePath: String) async -> Bool {
        guard projectWritableLease != nil else { return false }
        guard relativePath != document.entryFileName else { return true }
        guard await flushPendingSave() else { return false }

        document.entryFileName = relativePath
        document.modifiedAt = Date()

        if currentFileName == relativePath {
            entrySource = editorText
        } else if let source = try? ProjectFileManager.readTypFile(named: relativePath, for: document) {
            entrySource = source
        }

        _ = refreshResolvedFonts(includeAvailableFamilies: false)
        compileToken = UUID()
        InteractionFeedback.selection()
        return true
    }

    func handleProjectFileDeleted(_ node: ProjectTreeNode) {
        openTabs.removeAll { $0.relativePath == node.relativePath }
        if node.relativePath == currentFileName {
            saveTask?.cancel()
            saveTask = nil
            stopConflictMonitoring()
            if ProjectFileManager.listAllTypFiles(for: document).contains(document.entryFileName) {
                _ = loadFile(named: document.entryFileName)
            } else {
                currentFileName = ""
                editorText = ""
                lastPersistedText = ""
            }
            return
        }

        if node.relativePath == activeTabPath {
            if let currentTextTab = openTabs.first(where: { $0.relativePath == currentFileName }) {
                activeTabPath = currentTextTab.relativePath
            } else if let firstTab = openTabs.first {
                activeTabPath = firstTab.relativePath
            } else {
                activeTabPath = currentFileName.isEmpty ? nil : currentFileName
            }
        }

        if node.kind == .font {
            handleCompileInputsChanged()
        }
    }

    func createNewProjectFileFromMenu() {
        guard projectWritableLease != nil else { return }
        var name = newProjectFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !name.hasSuffix(".typ") {
            name += ".typ"
        }
        guard !name.isEmpty else { return }

        do {
            try ProjectFileManager.createTypFile(named: name, for: document)
            document.modifiedAt = Date()
            projectFileTreeRefreshToken = UUID()
            let node = ProjectTreeNode(
                relativePath: name,
                displayName: (name as NSString).lastPathComponent,
                kind: .typ,
                children: []
            )
            Task { await openProjectFile(node) }
            InteractionFeedback.notify(.success)
        } catch {
            fileSaveError = error.localizedDescription
            InteractionFeedback.notify(.error)
        }
    }

    func handleProjectFileImportFromMenu(_ result: Result<[URL], Error>) {
        guard projectWritableLease != nil else { return }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                fileSaveError = error.localizedDescription
                InteractionFeedback.notify(.error)
            }
            return
        }

        var firstError: Error?
        var importedNodes: [ProjectTreeNode] = []
        var importedFont = false

        for url in urls {
            let ext = url.pathExtension.lowercased()
            let subdir: String
            if ProjectFileManager.supportedImageFileExtensions.contains(ext) {
                subdir = document.imageDirectoryName
            } else if ProjectFileManager.fontFileExtensions.contains(ext) {
                subdir = "fonts"
            } else {
                subdir = ""
            }

            do {
                let importedPath = try ProjectFileManager.importFile(from: url, to: subdir, for: document)
                let kind = ProjectFileManager.fileKind(for: importedPath, imageDirectoryName: document.imageDirectoryName)
                if ProjectFileManager.fontFileExtensions.contains(ext) {
                    importedFont = true
                    let name = url.lastPathComponent
                    if !document.fontFileNames.contains(name) {
                        document.fontFileNames.append(name)
                    }
                }
                importedNodes.append(ProjectTreeNode(
                    relativePath: importedPath,
                    displayName: (importedPath as NSString).lastPathComponent,
                    kind: kind,
                    children: []
                ))
            } catch {
                firstError = firstError ?? error
            }
        }

        if !importedNodes.isEmpty {
            document.modifiedAt = Date()
            projectFileTreeRefreshToken = UUID()
            refreshReferenceCompletions()
            if importedFont {
                handleCompileInputsChanged()
            }
            if urls.count == 1, let node = importedNodes.first {
                Task { await openProjectFile(node) }
            }
            InteractionFeedback.notify(.success)
        }

        if let firstError {
            fileSaveError = firstError.localizedDescription
            InteractionFeedback.notify(.error)
        }
    }

    // MARK: - Conflict monitoring

    /// Begin monitoring a file URL for iCloud version conflicts via NSFileVersion.
    func startConflictMonitoring(for fileURL: URL) {
        let fileName = currentFileName
        conflictMonitor.onConflictDetected = {
            self.conflictFileName = fileName
            self.showingConflictWarning = true
        }
        conflictMonitor.onPresentedItemChanged = {
            self.reloadPresentedFileIfSafe(named: fileName)
        }
        conflictMonitor.startMonitoring(url: fileURL)
    }

    /// Stop monitoring the current file. Called on file switch or view disappear.
    func stopConflictMonitoring() {
        conflictMonitor.stopMonitoring()
    }

    /// Reload disk changes delivered by iCloud/Files when there is no real
    /// NSFileVersion conflict and the editor has no unsaved local text.
    func reloadPresentedFileIfSafe(named fileName: String) {
        guard fileName == currentFileName else { return }
        guard saveTask == nil, recoveryWriteSequenceFloor == nil, editorText == lastPersistedText else { return }

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

        if fileName == document.entryFileName {
            entrySource = diskText
            _ = refreshResolvedFonts(includeAvailableFamilies: false)
            compileToken = UUID()
        }
        compilationErrorLines = recomputeCompilationErrorLines()
    }

    func handleEditorTextChange(_ content: String) {
        guard !currentFileName.isEmpty else { return }
        if isEditingEntryFile {
            entrySource = content
            _ = refreshResolvedFonts(includeAvailableFamilies: false)
        }
        scheduleSave(content: content, for: currentFileName)
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
        saveTask = Task { @MainActor in
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
                        _ = self.refreshResolvedFonts(includeAvailableFamilies: false)
                        self.compileToken = UUID()
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

    /// Resolve a conflict by keeping the local version (overwrite disk).
    func resolveConflictKeepLocal() async {
        showingConflictWarning = false
        let content = editorText

        do {
            let fileURL = try ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document)
            let request = try reliabilityWriteRequest(content: content, fileName: currentFileName, fileURL: fileURL)
            try await VerifiedConflictResolution.commitThenDiscard {
                try await backgroundFileWriter.write(request)
            } verify: {
                try ProjectFileManager.readTypFile(named: currentFileName, for: document) == content
            } discardRemoteVersions: {
                try conflictMonitor.resolveKeepingCurrent()
            }
            lastPersistedText = content
            document.modifiedAt = Date()
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

    /// Resolve a conflict by reloading the remote version from disk.
    func resolveConflictKeepRemote() async {
        showingConflictWarning = false

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
                    try ProjectFileManager.readTypFile(named: currentFileName, for: document) == remoteContent
                } discardRemoteVersions: {
                    try conflictMonitor.resolveKeepingCurrent()
                }
            } catch {
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

        _ = loadFile(named: currentFileName)
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
                    _ = refreshResolvedFonts(includeAvailableFamilies: false)
                    compileToken = UUID()
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
        if recoveryWriteSequenceFloor == nil && editorText == lastPersistedText {
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

    func createProjectFileReliably(named name: String) async throws {
        let fileURL = try ProjectFileManager.projectFileURL(relativePath: name, for: document)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw InkPondFileError.fileAlreadyExists(name)
        }
        let request = try reliabilityWriteRequest(data: Data(), fileName: name, fileURL: fileURL)
        try await ProjectReliabilityWriterRegistry.shared.write(request)
    }

    func importProjectFileReliably(from sourceURL: URL, to subdir: String) async throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let fileName = sourceURL.lastPathComponent
        try ProjectFileManager.validateFileName(fileName)
        let relativePath = subdir.isEmpty ? fileName : "\(subdir)/\(fileName)"
        let fileURL = try ProjectFileManager.projectFileURL(relativePath: relativePath, for: document)
        let request = try reliabilityWriteRequest(
            data: try Data(contentsOf: sourceURL),
            fileName: relativePath,
            fileURL: fileURL
        )
        try await ProjectReliabilityWriterRegistry.shared.write(request)
        return relativePath
    }

    func deleteProjectNodeReliably(_ node: ProjectTreeNode) async throws {
        guard node.relativePath != document.entryFileName else {
            throw InkPondFileError.cannotDeleteEntryFile
        }
        if node.relativePath == currentFileName {
            saveTask?.cancel()
            saveTask = nil
            activeSaveGeneration = nil
        }
        let fileURL = try ProjectFileManager.projectFileURL(relativePath: node.relativePath, for: document)
        let request = try reliabilityWriteRequest(data: Data(), fileName: node.relativePath, fileURL: fileURL)
        try await ProjectReliabilityWriterRegistry.shared.remove(request)
    }

    func applyAutomaticImportDirectories() {
        if !ProjectFileManager.requiresImportDirectorySelection(document.importImageDirectoryOptions) {
            if let autoImageDirectory = ProjectFileManager.defaultImportDirectory(from: document.importImageDirectoryOptions) {
                document.imageDirectoryName = autoImageDirectory
            }
            document.importImageDirectoryOptions = []
        }

        if !ProjectFileManager.requiresImportDirectorySelection(document.importFontDirectoryOptions) {
            if let autoFontDirectory = ProjectFileManager.defaultImportDirectory(from: document.importFontDirectoryOptions) {
                _ = ProjectFileManager.importFontFiles(from: autoFontDirectory, for: document)
            }
            document.importFontDirectoryOptions = []
        }
    }

    func persistEditorPosition() {
        document.lastEditedFileName = currentFileName
        document.lastCursorLocation = editorViewState.selectedLocation
    }

    func scheduleEditorPositionSync(delay: Duration = .milliseconds(700)) {
        positionSyncTask?.cancel()
        positionSyncTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                persistEditorPositionIfNeeded()
            }
        }
    }

    func persistEditorPositionIfNeeded() {
        guard !currentFileName.isEmpty else { return }
        let nextFileName = currentFileName
        let nextLocation = editorViewState.selectedLocation
        guard document.lastEditedFileName != nextFileName || document.lastCursorLocation != nextLocation else {
            return
        }

        persistEditorPosition()
        try? modelContext.save()
    }

    func hasSavedPosition() -> Bool {
        document.lastCursorLocation > 0
    }

    func restoreSavedPosition() async {
        let savedFileName = document.lastEditedFileName
        if !savedFileName.isEmpty, savedFileName != currentFileName {
            guard await openFileIfPossible(named: savedFileName) else { return }
        }
        pendingCursorJump = document.lastCursorLocation

        // If the compiler already has a preview and source map (e.g. from cache),
        // defer the sync until after the cursor jump lands.  Otherwise, wait
        // for the next compilation to finish via onChange(of: compiler.previewArtifact).
        if compiler.compiledOnce, let sourceMap = compiler.sourceMap, !sourceMap.isEmpty {
            // Sync after the cursor jump is applied in the next run-loop cycle.
            Task { @MainActor in
                syncCursorToPreview(at: document.lastCursorLocation)
            }
        } else {
            pendingPreviewSync = true
        }
    }

    @discardableResult
    func handleExternalOpenRequestIfNeeded(_ request: ExternalTypFileOpenRequest?) async -> Bool {
        guard let request, request.projectID == document.projectID else { return false }
        let typFiles = document.isExternalFolder
            ? [document.entryFileName]
            : ProjectFileManager.listAllTypFiles(for: document)
        guard typFiles.contains(request.fileName) else { return false }

        if currentFileName != request.fileName {
            guard await openFileIfPossible(named: request.fileName) else { return false }
        }

        selectedTab = editorTab
        pendingCursorJump = 0
        return true
    }

    /// Immediately sync the preview to a known cursor location.
    func syncCursorToPreview(at cursorLocation: Int) {
        guard let sourceMap = compiler.sourceMap, !sourceMap.isEmpty else { return }
        guard syncCoordinator.beginSync(.editorToPreview) else { return }

        let line = lineNumber(atUTF16Offset: cursorLocation, in: editorText)

        if let target = sourceMap.pdfPosition(forLine: line) {
            syncCoordinator.previewScrollTarget = PreviewScrollTarget(
                page: target.page, yPoints: target.yPoints, xPoints: target.xPoints
            )
        }
        syncCoordinator.endSync()
    }

    func syncCursorToPreviewIfPending() {
        guard pendingPreviewSync else { return }
        pendingPreviewSync = false
        syncCursorToPreview(at: editorViewState.selectedLocation)
    }

    func handleOutlineJump(characterOffset offset: Int) {
        // Always jump the editor cursor to the heading.
        pendingCursorJump = offset

        // Sync preview only when editing the entry file — the source map
        // only covers entry-file lines, so non-entry offsets would map to
        // wrong PDF positions.
        guard isEditingEntryFile else { return }

        if sizeClass == .regular {
            // iPad: both panes visible, sync preview alongside editor.
            syncPreviewToOffset(offset)
        } else if selectedTab == previewTab {
            // iPhone preview tab: scroll the preview.
            syncPreviewToOffset(offset)
        }
    }

    private func syncPreviewToOffset(_ offset: Int) {
        guard let sourceMap = compiler.sourceMap, !sourceMap.isEmpty else { return }

        let line = lineNumber(atUTF16Offset: offset, in: editorText)

        if let target = sourceMap.pdfPosition(forLine: line) {
            syncCoordinator.previewScrollTarget = PreviewScrollTarget(
                page: target.page,
                yPoints: target.yPoints,
                xPoints: target.xPoints
            )
        }
    }

    @discardableResult
    func openFileIfPossible(named name: String) async -> Bool {
        guard await flushPendingSave() else { return false }
        guard loadFile(named: name) else { return false }
        InteractionFeedback.selection()
        return true
    }

    func openFile(named name: String) {
        Task { _ = await openFileIfPossible(named: name) }
    }

    func compilePreviewNow() async {
        guard await flushPendingSave() else { return }
        guard !previewRequiresExternalFolderLink else {
            compiler.clearPreview()
            return
        }
        _ = refreshResolvedFonts(includeAvailableFamilies: false)
        if let fontResolutionError {
            compiler.presentPreflightError(fontResolutionError)
            return
        }
        pendingManualCompileFeedback = true
        compiler.compileNow(
            source: CompileFontResolver.effectiveSource(for: entrySource, resolvedFonts: resolvedCompileFonts),
            fontPaths: resolvedCompileFonts.fontPaths,
            rootDir: rootDir,
            previewCachePolicy: .bypassCache,
            previewCacheDescriptor: compiledPreviewCacheDescriptor
        )
    }

    func clearCachesAndRecompile() async {
        guard await flushPendingSave() else { return }
        guard !previewRequiresExternalFolderLink else {
            compiler.clearPreview()
            return
        }
        _ = refreshResolvedFonts(includeAvailableFamilies: false)
        if let fontResolutionError {
            compiler.presentPreflightError(fontResolutionError)
            return
        }
        pendingManualCompileFeedback = true
        InteractionFeedback.notify(.warning)
        AccessibilitySupport.announce(L10n.a11yCacheRefreshStarted)
        let source = CompileFontResolver.effectiveSource(for: entrySource, resolvedFonts: resolvedCompileFonts)
        let fontPaths = resolvedCompileFonts.fontPaths
        let rootDirectory = rootDir

        compiler.clearPreview()

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PreviewPackageCacheStore().clearAll()
                }.value
                await MainActor.run {
                    compiler.compileNow(
                        source: source,
                        fontPaths: fontPaths,
                        rootDir: rootDirectory,
                        previewCachePolicy: .bypassCache,
                        previewCacheDescriptor: compiledPreviewCacheDescriptor
                    )
                }
            } catch {
                await MainActor.run {
                    previewActionError = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func refreshResolvedFonts(includeAvailableFamilies: Bool = true) -> Bool {
        let resolver = CompileFontResolver()
        let previousFamilies = availableFontFamilies
        if includeAvailableFamilies {
            let latestFamilies = resolver.availableFontFamilies(for: document)
            if latestFamilies != availableFontFamilies {
                availableFontFamilies = latestFamilies
            }
        }

        do {
            let latestResolvedFonts = try resolver.resolveFonts(
                for: document,
                entrySourceOverride: entrySource.isEmpty ? nil : entrySource,
                preserving: resolvedCompileFonts
            )
            if fontResolutionError != nil {
                fontResolutionError = nil
            }

            let didChange = latestResolvedFonts != resolvedCompileFonts
            if didChange {
                resolvedCompileFonts = latestResolvedFonts
            }
            return didChange || previousFamilies != availableFontFamilies
        } catch {
            let message = error.localizedDescription
            if fontResolutionError != message {
                fontResolutionError = message
            }
            return previousFamilies != availableFontFamilies
        }
    }

    func handleCompileInputsChanged() {
        scheduleAvailableFontFamilyRefresh()
        let didChange = refreshResolvedFonts(includeAvailableFamilies: false)
        guard fontResolutionError == nil else { return }
        guard didChange else { return }
        guard canTriggerPreviewActions else { return }
        compileToken = UUID()
    }

    func scheduleAvailableFontFamilyRefresh() {
        fontFamilyRefreshTask?.cancel()

        let projectFamilies = FontManager.familyNames(from: FontManager.projectFontRecords(for: document))
        let appFamilies = FontManager.familyNames(from: FontManager.appFontRecords())
        fontFamilyRefreshTask = Task { @MainActor in
            let systemFamilies = await Task.detached(priority: .utility) {
                SystemFontCatalog().availableFamilyNames()
            }.value
            guard !Task.isCancelled else { return }

            let latestFamilies = mergedFontFamilies([projectFamilies, appFamilies, systemFamilies])
            if latestFamilies != availableFontFamilies {
                availableFontFamilies = latestFamilies
            }
        }
    }

    private func mergedFontFamilies(_ buckets: [[String]]) -> [String] {
        var seen = Set<String>()
        var families: [String] = []
        for bucket in buckets {
            for family in bucket where seen.insert(family).inserted {
                families.append(family)
            }
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshReferenceCompletions() {
        let projectDir = ProjectFileManager.projectDirectory(for: document)
        let currentFileName = currentFileName
        referenceCompletionRefreshTask?.cancel()
        referenceCompletionRefreshTask = Task { @MainActor in
            let snapshot = await ProjectFileManager.referenceCompletionSnapshot(
                in: projectDir,
                currentFileName: currentFileName
            )
            guard !Task.isCancelled else { return }
            cachedBibEntries = snapshot.bibEntries
            cachedExternalLabels = snapshot.externalLabels
            cachedImageFiles = snapshot.imageFiles
        }
        refreshPackageSpecs()
    }

    func refreshPackageSpecs() {
        let store = LocalPackageStore()
        Task.detached(priority: .utility) {
            let snapshot = try? store.snapshot()
            await MainActor.run { [snapshot] in
                cachedPackageSpecs = snapshot?.entries.map { $0.spec } ?? []
            }
        }
    }

    func refreshImageFiles() {
        let projectDir = ProjectFileManager.projectDirectory(for: document)
        imageFileRefreshTask?.cancel()
        imageFileRefreshTask = Task { @MainActor in
            let imageFiles = await ProjectFileManager.imageFiles(in: projectDir)
            guard !Task.isCancelled else { return }
            cachedImageFiles = imageFiles
        }
    }

    func triggerZipExport() async {
        if !resolvedCompileFonts.includesExternalFonts {
            guard await flushPendingSave() else { return }
            exporter.exportZip(for: document)
        } else {
            showingZipExportWarning = true
        }
    }

    // MARK: - Error Navigation

    /// Map a file path from a Typst error message to the actual project file name.
    /// Typst FFI internally names the entry source "main.typ" regardless of the
    /// real file name, so we map it back to the document's entry file.
    private func resolveErrorFileName(_ path: String) -> String {
        if path == "main.typ" && document.entryFileName != "main.typ" {
            return document.entryFileName
        }
        return path
    }

    /// Recompute error lines from the current compiler error message.
    /// Call whenever `compiler.errorMessage` or `currentFileName` changes.
    func recomputeCompilationErrorLines() -> Set<Int> {
        guard let message = compiler.errorMessage else { return [] }
        var result = Set<Int>()
        let lines = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else { continue }
            let candidate = String(trimmed.dropFirst().dropLast())
            let parts = candidate.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let lineNum = Int(parts[parts.count - 2]),
                  lineNum > 0 else { continue }
            let path = parts.dropLast(2).joined(separator: ":")
            guard !path.isEmpty else { continue }
            let resolved = resolveErrorFileName(path)
            if resolved == currentFileName {
                result.insert(lineNum)
            }
        }
        return result
    }

    /// Navigate the editor to a compilation error location.
    func navigateToError(file: String, line: Int, column: Int) async {
        let resolvedFile = resolveErrorFileName(file)

        // Switch to editor tab on iPhone
        if sizeClass != .regular {
            selectedTab = editorTab
        }

        // Open the file if it's not already open
        if resolvedFile != currentFileName {
            guard await openFileIfPossible(named: resolvedFile) else { return }
        }

        // Compute UTF-16 offset from line:column
        let offset = utf16Offset(forLine: line, column: column, in: editorText)
        pendingCursorJump = offset
        InteractionFeedback.impact(.light)
    }

    func utf16Offset(forLine line: Int, column: Int, in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for i in 0..<min(line - 1, lines.count) {
            offset += (lines[i] as NSString).length + 1 // +1 for \n
        }
        if line - 1 < lines.count {
            offset += min(max(column - 1, 0), (lines[line - 1] as NSString).length)
        }
        return offset
    }

    private func lineNumber(atUTF16Offset offset: Int, in text: String) -> Int {
        let nsString = text as NSString
        let safeOffset = min(max(0, offset), nsString.length)
        var line = 1
        var searchStart = 0

        while searchStart < safeOffset {
            let searchRange = NSRange(location: searchStart, length: safeOffset - searchStart)
            let newlineRange = nsString.range(of: "\n", options: [], range: searchRange)
            guard newlineRange.location != NSNotFound else { break }
            line += 1
            searchStart = newlineRange.location + newlineRange.length
        }

        return line
    }
}

// Shared verbatim lifecycle action; tests exercise the same close task as disappearance.
extension DocumentEditorView {
    @discardableResult
    func restoreFailedCloseIfAvailable() -> Bool {
        guard let draft = EditorFailedCloseStore.shared.take(for: document.stableProjectID) else { return false }
        stopObservingFailedClose()
        saveAuthority = UUID()
        // Never reactivate the old token, even when this same State takes its draft.
        reliabilityWriteAuthority.revoke()
        reliabilityWriteAuthority = ProjectReliabilityWriteAuthority()
        projectWritableLease = draft.lease
        recoveryWriteSequenceFloor = saveGeneration
        projectAccessResolved = true
        currentFileName = draft.fileName
        editorText = draft.text
        lastPersistedText = draft.persistedText
        entrySource = draft.entrySource
        openTabs = draft.tabs
        activeTabPath = draft.activePath
        fileSaveError = draft.error
        fileLoadToken = UUID()
        lastSaveReceipt = nil
        didRestoreProjectEditorState = true
        return true
    }

    func resumeRecoveredEditorServices() {
        refreshResolvedFonts(includeAvailableFamilies: false)
        scheduleAvailableFontFamilyRefresh()
        refreshReferenceCompletions()
        if let url = try? ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document) {
            startConflictMonitoring(for: url)
        }
    }

    func stopObservingFailedClose() {
        if let id = failedCloseSubscription {
            EditorFailedCloseStore.shared.unsubscribe(for: document.stableProjectID, id: id)
            failedCloseSubscription = nil
        }
    }

    func observeFailedClose() {
        stopObservingFailedClose()
        let id = UUID()
        failedCloseSubscription = id
        EditorFailedCloseStore.shared.subscribe(for: document.stableProjectID, id: id) {
            guard failedCloseSubscription == id, projectWritableLease == nil else { return }
            // Initial read-only preparation must finish normally; never wait on
            // another view's pending close. Publication installs the awaitable
            // handoff synchronously, then restores behind that finite preparation.
            let preparation = projectLeaseTask
            projectLeaseTask = Task { @MainActor in
                await preparation?.value
                guard !Task.isCancelled, failedCloseSubscription == id,
                      projectWritableLease == nil else { return }
                if restoreFailedCloseIfAvailable() { resumeRecoveredEditorServices() }
            }
        }
    }

    func closeEditorOnDisappear() {
        stopObservingFailedClose()
        projectLeaseTask?.cancel()
        projectLeaseTask = nil
        let generation = projectLifecycleGeneration
        let leaseToRelease = projectWritableLease
        let authority = saveAuthority
        positionRestoreDismissTask?.cancel()
        positionRestoreDismissTask = nil
        positionSyncTask?.cancel()
        positionSyncTask = nil
        previewStatsTask?.cancel()
        previewStatsTask = nil
        fontFamilyRefreshTask?.cancel()
        fontFamilyRefreshTask = nil
        externalFolderLinkTask?.cancel()
        externalFolderLinkTask = nil
        externalFolderLinkGeneration = AsyncOperationGeneration()
        externalFolderLinkProgress = nil
        externalFolderLinkProgressTitle = nil
        linkedFolderRefreshCoordinator.cancel()
        persistEditorPositionIfNeeded()
        persistProjectEditorTabState()
        stopConflictMonitoring()
        focusCoordinator.clearFocusPreservation()
        compiler.cancel()
        let reliabilityRoot = ProjectFileManager.projectDirectory(for: document)
        let reliabilityProjectID = document.stableProjectID
        let legacyProjectID = document.projectID
        let reliabilityExternalTarget = ProjectFileManager.externalSingleFileURL(for: document)
        let reconciliationRequest = currentFileName.isEmpty
            ? nil
            : try? reliabilityWriteRequest(
                content: editorText,
                fileName: currentFileName,
                fileURL: ProjectFileManager.projectFileURL(relativePath: currentFileName, for: document)
            )
        if let leaseToRelease {
            projectCloseTask = Task { @MainActor in
                let saved = await flushPendingSave()
                guard saveAuthority == authority else { return }
                guard saved else {
                    recoveryWriteSequenceFloor = saveGeneration
                    projectCloseTask = nil
                    // Retain the buffer and the same lease even if SwiftUI destroys
                    // this view. Reopening takes this draft before reading disk.
                    EditorFailedCloseStore.shared.retain(.init(
                        lease: leaseToRelease, fileName: currentFileName,
                        text: editorText, persistedText: lastPersistedText,
                        entrySource: entrySource, tabs: openTabs, activePath: activeTabPath,
                        error: fileSaveError,
                        relinquish: {
                            guard saveAuthority == authority,
                                  projectWritableLease === leaseToRelease else { return }
                            // Synchronously revoke captured requests before take() can
                            // give the lease to another editor; task cancellation alone
                            // does not cover independent immediate-save tasks.
                            reliabilityWriteAuthority.revoke()
                            saveAuthority = UUID()
                            projectLifecycleGeneration = UUID()
                            projectWritableLease = nil
                            projectAccessResolved = false
                            saveTask?.cancel()
                            saveTask = nil
                            activeSaveGeneration = nil
                            lastSaveReceipt = nil
                            projectCloseTask = nil
                        }
                    ), for: reliabilityProjectID)
                    return
                }
                if let reconciliationRequest {
                    var reconciled = false
                    while !reconciled {
                        guard saveAuthority == authority else { return }
                        do {
                            try await ProjectReliabilityWriterRegistry.shared.reconcile(reconciliationRequest)
                            reconciled = true
                        } catch {
                            guard saveAuthority == authority else { return }
                            fileSaveError = error.localizedDescription
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                }
                guard saveAuthority == authority else { return }
                // Prevent delayed requests from writing through a new context after drain.
                reliabilityWriteAuthority.revoke()
                await ProjectReliabilityWriterRegistry.shared.close(
                    projectID: reliabilityProjectID,
                    rootURL: reliabilityRoot,
                    externalTargetURL: reliabilityExternalTarget
                )
                guard saveAuthority == authority else { return }
                if projectWritableLease === leaseToRelease {
                    projectWritableLease = nil
                }
                await leaseToRelease.release()
                guard saveAuthority == authority else { return }
                if BookmarkManager.hasBookmark(projectID: legacyProjectID) {
                    BookmarkManager.stopAccessing(legacyProjectID)
                }
                if ExternalTypFileSessionStore.contains(projectID: legacyProjectID) {
                    ExternalTypFileSessionStore.unregister(projectID: legacyProjectID)
                }
                if projectLifecycleGeneration == generation {
                    projectWritableLease = nil
                    projectAccessResolved = false
                }
                projectCloseTask = nil
            }
        } else {
            projectAccessResolved = false
        }
    }
}
