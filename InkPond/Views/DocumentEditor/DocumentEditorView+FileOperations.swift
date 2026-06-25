//
//  DocumentEditorView+FileOperations.swift
//  InkPond
//

import Foundation
import SwiftUI
import SwiftData

extension DocumentEditorView {
    func prepareDocumentForEditing() {
        do {
            try ProjectFileManager.validateDocumentCanOpen(document)
        } catch {
            reportInitialOpenFailure(error.localizedDescription)
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

        ProjectFileManager.migrateContentIfNeeded(for: document)
        if !loadFile(named: document.entryFileName) {
            reportInitialOpenFailure(fileSaveError ?? L10n.format("error.file.not_found", document.entryFileName))
        }
    }

    func reportInitialOpenFailure(_ message: String) {
        fileSaveError = message
        onInitialOpenFailure?(message)
    }

    @discardableResult
    func loadFile(named name: String) -> Bool {
        saveTask?.cancel()
        saveTask = nil

        // If the file is in iCloud and not yet downloaded, trigger download
        let fileURL = ProjectFileManager.typFileURL(named: name, for: document)
        if ProjectFileManager.useCoordination {
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        }

        let text: String
        do {
            text = try ProjectFileManager.readTypFile(named: name, for: document)
        } catch {
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
        return true
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

    func openProjectFile(_ node: ProjectTreeNode) {
        guard node.kind.canBecomeTab else { return }
        if node.kind.isTextEditable {
            selectedTab = editorTab
            _ = openFileIfPossible(named: node.relativePath)
            return
        }

        guard flushPendingSave() else { return }
        focusCoordinator.dismissKeyboard()
        selectedTab = editorTab
        activateTab(relativePath: node.relativePath, kind: node.kind)
        InteractionFeedback.selection()
    }

    func selectProjectTab(_ tab: ProjectFileTab) {
        guard tab.relativePath != activeTabPath else { return }
        if tab.kind.isTextEditable {
            selectedTab = editorTab
            _ = openFileIfPossible(named: tab.relativePath)
            return
        }

        guard flushPendingSave() else { return }
        focusCoordinator.dismissKeyboard()
        selectedTab = editorTab
        activeTabPath = tab.relativePath
        InteractionFeedback.selection()
    }

    func closeProjectTab(_ tab: ProjectFileTab) {
        if tab.relativePath == currentFileName {
            guard flushPendingSave() else { return }
        }

        openTabs.removeAll { $0.relativePath == tab.relativePath }
        guard activeTabPath == tab.relativePath else { return }

        if let currentTextTab = openTabs.first(where: { $0.relativePath == currentFileName }) {
            activeTabPath = currentTextTab.relativePath
        } else if let nextTab = openTabs.first {
            selectProjectTab(nextTab)
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
    func setEntryProjectFile(_ relativePath: String) -> Bool {
        guard relativePath != document.entryFileName else { return true }
        guard flushPendingSave() else { return false }

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
        var name = newProjectFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !name.hasSuffix(".typ") {
            name += ".typ"
        }
        guard !name.isEmpty else { return }

        do {
            try ProjectFileManager.createTypFile(named: name, for: document)
            document.modifiedAt = Date()
            projectFileTreeRefreshToken = UUID()
            openProjectFile(ProjectTreeNode(
                relativePath: name,
                displayName: (name as NSString).lastPathComponent,
                kind: .typ,
                children: []
            ))
            InteractionFeedback.notify(.success)
        } catch {
            fileSaveError = error.localizedDescription
            InteractionFeedback.notify(.error)
        }
    }

    func handleProjectFileImportFromMenu(_ result: Result<[URL], Error>) {
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
                openProjectFile(node)
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
        guard saveTask == nil, editorText == lastPersistedText else { return }

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
        guard content != lastPersistedText else {
            saveTask?.cancel()
            saveTask = nil
            return
        }

        let fileURL = ProjectFileManager.typFileURL(named: fileName, for: document)
        let shouldRefreshPreviewAfterSave = fileName != document.entryFileName

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
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
                try await backgroundFileWriter.write(content, to: fileURL)
                guard !Task.isCancelled else { return }
                if self.currentFileName == fileName, self.editorText == content {
                    self.lastPersistedText = content
                    self.document.modifiedAt = Date()
                    if shouldRefreshPreviewAfterSave {
                        _ = self.refreshResolvedFonts(includeAvailableFamilies: false)
                        self.compileToken = UUID()
                    }
                }
                self.saveTask = nil
            } catch {
                self.fileSaveError = error.localizedDescription
                self.saveTask = nil
            }
        }
    }

    /// Resolve a conflict by keeping the local version (overwrite disk).
    func resolveConflictKeepLocal() {
        showingConflictWarning = false
        let content = editorText

        // Resolve all conflict versions in favor of current, then overwrite.
        conflictMonitor.resolveKeepingCurrent()

        do {
            try ProjectFileManager.writeTypFile(named: currentFileName, content: content, for: document)
            lastPersistedText = content
            document.modifiedAt = Date()
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

    /// Resolve a conflict by reloading the remote version from disk.
    func resolveConflictKeepRemote() {
        showingConflictWarning = false

        // Pick the most recent conflict version and replace the current file.
        // If no conflict versions remain, just resolve and reload from disk.
        if let latest = conflictMonitor.conflictVersions
            .sorted(by: { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) })
            .first {
            conflictMonitor.resolveKeepingVersion(latest)
        } else {
            conflictMonitor.resolveKeepingCurrent()
        }

        _ = loadFile(named: currentFileName)
    }

    @discardableResult
    func flushPendingSave() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        return persistCurrentFileImmediately(content: editorText)
    }

    @discardableResult
    func persistCurrentFileImmediately(content: String) -> Bool {
        guard !currentFileName.isEmpty else { return true }
        guard content != lastPersistedText else { return true }

        let shouldRefreshPreviewAfterSave = currentFileName != document.entryFileName

        do {
            try ProjectFileManager.writeTypFile(named: currentFileName, content: content, for: document)
            lastPersistedText = content
            document.modifiedAt = Date()
            if shouldRefreshPreviewAfterSave {
                _ = refreshResolvedFonts(includeAvailableFamilies: false)
                compileToken = UUID()
            }
            return true
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
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

    func restoreSavedPosition() {
        let savedFileName = document.lastEditedFileName
        if !savedFileName.isEmpty, savedFileName != currentFileName {
            guard openFileIfPossible(named: savedFileName) else { return }
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
    func handleExternalOpenRequestIfNeeded(_ request: ExternalTypFileOpenRequest?) -> Bool {
        guard let request, request.projectID == document.projectID else { return false }
        let typFiles = document.isExternalFolder
            ? [document.entryFileName]
            : ProjectFileManager.listAllTypFiles(for: document)
        guard typFiles.contains(request.fileName) else { return false }

        if currentFileName != request.fileName {
            guard openFileIfPossible(named: request.fileName) else { return false }
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

        if workspaceLayoutPolicy.usesSplitWorkspace {
            // Split workspace: both panes visible, sync preview alongside editor.
            syncPreviewToOffset(offset)
        } else if selectedTab == previewTab {
            // Compact preview tab: scroll the preview.
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
    func openFileIfPossible(named name: String) -> Bool {
        guard flushPendingSave() else { return false }
        guard loadFile(named: name) else { return false }
        InteractionFeedback.selection()
        return true
    }

    func openFile(named name: String) {
        _ = openFileIfPossible(named: name)
    }

    func compilePreviewNow() {
        guard flushPendingSave() else { return }
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

    func clearCachesAndRecompile() {
        guard flushPendingSave() else { return }
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

    func triggerZipExport() {
        if !resolvedCompileFonts.includesExternalFonts {
            guard flushPendingSave() else { return }
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
    func navigateToError(file: String, line: Int, column: Int) {
        let resolvedFile = resolveErrorFileName(file)

        // Switch to editor tab when only one pane is visible.
        if workspaceLayoutPolicy.usesCompactWorkspace {
            selectedTab = editorTab
        }

        // Open the file if it's not already open
        if resolvedFile != currentFileName {
            guard openFileIfPossible(named: resolvedFile) else { return }
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
