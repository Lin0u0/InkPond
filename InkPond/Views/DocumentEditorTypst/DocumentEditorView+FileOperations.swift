//
//  DocumentEditorView+FileOperations.swift
//  InkPond
//

import Foundation
import SwiftUI
import SwiftData

extension DocumentEditorView {
    func prepareDocumentForEditing() {
        ProjectFileManager.ensureProjectRoot(for: document)

        let typFiles = ProjectFileManager.listAllTypFiles(for: document)
        if document.requiresImportConfiguration || document.requiresInitialEntrySelection {
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
        _ = loadFile(named: document.entryFileName)
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
        isLoadingFileContent = true
        editorText = text
        fileLoadToken = UUID()
        isLoadingFileContent = false
        lastPersistedText = text
        if name == document.entryFileName {
            entrySource = text
        }
        compilationErrorLines = recomputeCompilationErrorLines()

        // Start monitoring the newly opened file for iCloud conflicts.
        startConflictMonitoring(for: fileURL)

        pumpPendingInsertionsIfNeeded()
        return true
    }

    // MARK: - Conflict monitoring

    /// Begin monitoring a file URL for iCloud version conflicts via NSFileVersion.
    func startConflictMonitoring(for fileURL: URL) {
        let fileName = currentFileName
        conflictMonitor.onConflictDetected = {
            self.conflictFileName = fileName
            self.showingConflictWarning = true
        }
        conflictMonitor.startMonitoring(url: fileURL)
    }

    /// Stop monitoring the current file. Called on file switch or view disappear.
    func stopConflictMonitoring() {
        conflictMonitor.stopMonitoring()
    }

    func handleEditorTextChange(_ content: String) {
        guard !currentFileName.isEmpty else { return }
        if isEditingEntryFile {
            entrySource = content
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
        let fileURL = ProjectFileManager.typFileURL(named: currentFileName, for: document)

        // Resolve all conflict versions in favor of current, then overwrite.
        conflictMonitor.resolveKeepingCurrent()

        do {
            if ProjectFileManager.useCoordination {
                try CloudFileCoordinator.writeString(content, to: fileURL)
            } else {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
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
        let fileURL = ProjectFileManager.typFileURL(named: currentFileName, for: document)

        do {
            if ProjectFileManager.useCoordination {
                try CloudFileCoordinator.writeString(content, to: fileURL)
            } else {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            lastPersistedText = content
            document.modifiedAt = Date()
            if shouldRefreshPreviewAfterSave {
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

        // If the compiler already has a PDF and source map (e.g. from cache),
        // defer the sync until after the cursor jump lands.  Otherwise, wait
        // for the next compilation to finish via onChange(of: compiler.pdfDocument).
        if compiler.pdfDocument != nil, let sourceMap = compiler.sourceMap, !sourceMap.isEmpty {
            // Sync after the cursor jump is applied in the next run-loop cycle.
            Task { @MainActor in
                syncCursorToPreview(at: document.lastCursorLocation)
            }
        } else {
            pendingPreviewSync = true
        }
    }

    /// Immediately sync the preview to a known cursor location.
    func syncCursorToPreview(at cursorLocation: Int) {
        guard let sourceMap = compiler.sourceMap, !sourceMap.isEmpty else { return }
        guard syncCoordinator.beginSync(.editorToPreview) else { return }

        let text = editorText as NSString
        let prefix = cursorLocation <= text.length
            ? text.substring(to: cursorLocation)
            : editorText
        let line = prefix.components(separatedBy: "\n").count

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

        let text = editorText as NSString
        let safeOffset = min(max(0, offset), text.length)
        let prefix = text.substring(to: safeOffset)
        let line = prefix.components(separatedBy: "\n").count

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
        pendingManualCompileFeedback = true
        compiler.compileNow(
            source: entrySource,
            fontPaths: compileFontPaths,
            rootDir: rootDir,
            previewCachePolicy: .bypassCache,
            previewCacheDescriptor: compiledPreviewCacheDescriptor
        )
    }

    func clearCachesAndRecompile() {
        guard flushPendingSave() else { return }
        pendingManualCompileFeedback = true
        InteractionFeedback.notify(.warning)
        AccessibilitySupport.announce(L10n.a11yCacheRefreshStarted)
        let source = entrySource
        let fontPaths = compileFontPaths
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
    func refreshCompileFontPaths() -> Bool {
        let latestPaths = FontManager.allFontPaths(for: document)
        guard latestPaths != compileFontPaths else { return false }
        compileFontPaths = latestPaths
        return true
    }

    func handleCompileInputsChanged() {
        guard refreshCompileFontPaths() else { return }
        guard canTriggerPreviewActions else { return }
        compileToken = UUID()
    }

    func refreshReferenceCompletions() {
        let projectDir = ProjectFileManager.projectDirectory(for: document)
        let fm = FileManager.default

        var bibEntries: [(key: String, type: String)] = []
        if let items = try? fm.contentsOfDirectory(atPath: projectDir.path) {
            for item in items where item.hasSuffix(".bib") {
                let url = projectDir.appendingPathComponent(item)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    bibEntries.append(contentsOf: CompletionEngine.parseBibTeX(content))
                }
            }
        }
        cachedBibEntries = bibEntries

        let engine = CompletionEngine.shared
        var labels: [(name: String, kind: String)] = []
        let typFiles = ProjectFileManager.listAllTypFiles(for: document)
        for file in typFiles where file != currentFileName {
            if let content = try? ProjectFileManager.readTypFile(named: file, for: document) {
                labels.append(contentsOf: engine.scanLabels(in: content))
            }
        }
        cachedExternalLabels = labels

        refreshImageFiles()
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
        let allFiles = ProjectFileManager.listAllFiles(in: ProjectFileManager.projectDirectory(for: document))
        let imageExtensions = ProjectFileManager.supportedImageFileExtensions
        cachedImageFiles = allFiles.filter { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return imageExtensions.contains(ext)
        }
    }

    func triggerZipExport() {
        if appFontLibrary.isEmpty {
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

        // Switch to editor tab on iPhone
        if sizeClass != .regular {
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
}
