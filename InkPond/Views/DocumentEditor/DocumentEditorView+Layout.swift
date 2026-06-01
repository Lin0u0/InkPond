//
//  DocumentEditorView+Layout.swift
//  InkPond
//

import SwiftUI
import SwiftData
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

private struct SoftScrollEdgeEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
        }
    }
}

private struct ConditionalNavigationBarBackgroundModifier: ViewModifier {
    let hidesBackground: Bool

    func body(content: Content) -> some View {
        if hidesBackground {
            if #available(iOS 18.0, *) {
                content
                    .toolbarBackground(.clear, for: .navigationBar)
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            } else {
                content.toolbarBackground(.hidden, for: .navigationBar)
            }
        } else {
            content
        }
    }
}


private struct ConditionalToolbarRoleModifier: ViewModifier {
    let usesEditorRole: Bool

    func body(content: Content) -> some View {
        if usesEditorRole {
            content.toolbarRole(.editor)
        } else {
            content
        }
    }
}

private enum ExternalFolderLinkError: LocalizedError {
    case missingSource
    case folderMismatch

    var errorDescription: String? {
        switch self {
        case .missingSource:
            L10n.tr("preview.external_link_required.missing_source")
        case .folderMismatch:
            L10n.tr("preview.external_link_required.folder_mismatch")
        }
    }
}

private extension View {
    @ViewBuilder
    func navigationSubtitleCompat(_ subtitle: String) -> some View {
        if #available(iOS 26, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }

    @ViewBuilder
    func compactCircleSurface() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.systemFloatingSurface(cornerRadius: 999)
        }
    }
}

extension DocumentEditorView {
    /// Sync is only useful on iPad where both panes are visible simultaneously.
    private var isSyncEnabled: Bool { sizeClass == .regular }
    private var usesSystemCompactToolbar: Bool {
        sizeClass != .regular
    }

    private var compactTabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    selectedTab = newValue
                }
            }
        )
    }

    func editorPane(topViewportInset: CGFloat = 0) -> some View {
        EditorView(
            text: $editorText,
            insertionRequest: $insertionRequest,
            findRequested: $findRequested,
            viewState: $editorViewState,
            cursorJumpOffset: $pendingCursorJump,
            fileLoadToken: fileLoadToken,
            focusCoordinator: focusCoordinator,
            topViewportInset: topViewportInset,
            sourceMap: isSyncEnabled && isEditingEntryFile ? compiler.sourceMap : nil,
            syncCoordinator: isSyncEnabled ? syncCoordinator : nil,
            theme: themeManager.currentTheme,
            editorFont: editorFontSettings.uiFont,
            errorLines: compilationErrorLines,
            onPhotoTapped: { showingPhotoPicker = true },
            onSnippetTapped: { showingSnippetBrowser = true },
            onImagePasted: { pastedImageData, selectedRange in
                importImage(
                    from: .rawData(pastedImageData, suggestedFileName: nil),
                    anchorRange: selectedRange,
                    targetFileName: currentFileName
                )
            },
            onRichPaste: { fragments, selectedRange in
                handleRichPaste(
                    fragments,
                    anchorRange: selectedRange,
                    targetFileName: currentFileName
                )
            },
            fontFamilies: completionFontFamilies,
            bibEntries: cachedBibEntries,
            externalLabels: cachedExternalLabels,
            imageFiles: cachedImageFiles,
            packageSpecs: cachedPackageSpecs
        )
        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier],
                isTargeted: $isImageDropTarget,
                perform: handleImageDrop(providers:))
        .overlay {
            if isImageDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    func previewPane(topViewportInset: CGFloat = 0) -> some View {
        PreviewPane(
            compiler: compiler,
            source: entrySource,
            compileSource: CompileFontResolver.effectiveSource(for: entrySource, resolvedFonts: resolvedCompileFonts),
            fontPaths: resolvedCompileFonts.fontPaths,
            fontWarnings: resolvedCompileFonts.warnings,
            preflightError: fontResolutionError,
            rootDir: rootDir,
            previewCacheDescriptor: compiledPreviewCacheDescriptor,
            compileToken: compileToken,
            requiresExternalFolderLink: previewRequiresExternalFolderLink,
            drivesCompilation: sizeClass == .regular,
            cancelsCompilerOnDisappear: sizeClass == .regular,
            focusCoordinator: focusCoordinator,
            sourceMap: isSyncEnabled ? compiler.sourceMap : nil,
            syncCoordinator: syncCoordinator,
            entryFileName: document.entryFileName,
            topViewportInset: topViewportInset,
            onGoToError: { file, line, column in
                navigateToError(file: file, line: line, column: column)
            },
            onLinkExternalFolder: previewRequiresExternalFolderLink ? {
                showingExternalFolderLinkImporter = true
            } : nil
        )
    }

    func linkExternalFolderForPreview(from folderURL: URL) {
        guard flushPendingSave() else { return }
        externalFolderLinkTask?.cancel()
        externalFolderLinkProgressTitle = folderURL.lastPathComponent
        externalFolderLinkProgress = LinkedFolderLoadProgress(
            phase: .scanning,
            scannedFileCount: 0,
            downloadedFileCount: 0,
            totalDownloadFileCount: 0
        )

        let projectID = document.projectID
        externalFolderLinkTask = Task { @MainActor in
            do {
                let accessed = folderURL.startAccessingSecurityScopedResource()
                defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

                guard let externalFileURL = ProjectFileManager.externalSingleFileURL(for: document) else {
                    throw ExternalFolderLinkError.missingSource
                }

                guard let relativeFileName = ProjectFileManager.relativePath(of: externalFileURL, in: folderURL) else {
                    throw ExternalFolderLinkError.folderMismatch
                }

                _ = try await ProjectFileManager.loadLinkedFolderContents(at: folderURL) { progress in
                    await MainActor.run {
                        if document.projectID == projectID {
                            externalFolderLinkProgress = progress
                        }
                    }
                }

                guard !Task.isCancelled else {
                    clearExternalFolderLinkProgress(projectID: projectID)
                    return
                }

                try BookmarkManager.saveBookmark(for: folderURL, projectID: document.projectID)
                ExternalTypFileSessionStore.unregister(projectID: document.projectID)
                document.entryFileName = relativeFileName
                document.lastEditedFileName = relativeFileName
                document.lastCursorLocation = 0
                document.requiresExternalFolderLinkForPreview = false
                document.requiresInitialEntrySelection = false
                document.requiresImportConfiguration = false
                document.importEntryFileOptions = []
                document.importImageDirectoryOptions = []
                document.importFontDirectoryOptions = []
                _ = loadFile(named: relativeFileName)
                refreshReferenceCompletions()
                handleCompileInputsChanged()
                try persistLinkedExternalDocumentIfNeeded()
                clearExternalFolderLinkProgress(projectID: projectID)
                InteractionFeedback.notify(.success)
            } catch is CancellationError {
                clearExternalFolderLinkProgress(projectID: projectID)
            } catch let error as ExternalFolderLinkError {
                clearExternalFolderLinkProgress(projectID: projectID)
                previewActionError = error.localizedDescription
                InteractionFeedback.notify(.error)
            } catch {
                BookmarkManager.removeBookmark(projectID: projectID)
                clearExternalFolderLinkProgress(projectID: projectID)
                previewActionError = error.localizedDescription
                InteractionFeedback.notify(.error)
            }
        }
    }

    private func persistLinkedExternalDocumentIfNeeded() throws {
        let projectID = document.projectID
        let descriptor = FetchDescriptor<InkPondDocument>(
            predicate: #Predicate { $0.projectID == projectID }
        )
        if try modelContext.fetch(descriptor).isEmpty {
            modelContext.insert(document)
        }
        try modelContext.save()
    }

    private func clearExternalFolderLinkProgress(projectID: String) {
        guard document.projectID == projectID else { return }
        externalFolderLinkProgress = nil
        externalFolderLinkProgressTitle = nil
        externalFolderLinkTask = nil
    }

    private var editorTitleSecondaryForegroundColor: Color {
        editorTitleForegroundColor.opacity(0.68)
    }

    private var compactTitleForegroundColor: Color {
        selectedTab == previewTab ? appThemeTitleForegroundColor : editorTitleForegroundColor
    }

    private var compactTitleSecondaryForegroundColor: Color {
        compactTitleForegroundColor.opacity(0.68)
    }

    func splitHandle(totalWidth: CGFloat) -> some View {
        let dragGesture = DragGesture(minimumDistance: 1, coordinateSpace: .named("splitContainer"))
            .onChanged { value in
                let raw = value.location.x / totalWidth
                withTransaction(Transaction(animation: nil)) {
                    editorFraction = min(0.8, max(0.2, raw))
                }
            }

        return Capsule()
            .fill(Color(uiColor: .separator))
            .frame(width: 2, height: 36)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            InteractionFeedback.impact(.medium)
                            withAnimation(.spring(duration: 0.3)) { editorFraction = 0.5 }
                        }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.a11yEditorSplitLabel)
            .accessibilityHint(L10n.a11yEditorSplitHint)
            .accessibilityValue(splitHandleAccessibilityValue)
            .accessibilityIdentifier("editor.split-handle")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = 0.1
                switch direction {
                case .increment:
                    InteractionFeedback.selection()
                    editorFraction = min(0.8, editorFraction + delta)
                case .decrement:
                    InteractionFeedback.selection()
                    editorFraction = max(0.2, editorFraction - delta)
                @unknown default:
                    break
                }
            }
            .accessibilityAction(named: Text(L10n.a11yEditorSplitReset)) {
                InteractionFeedback.impact(.medium)
                editorFraction = 0.5
            }
    }

    @ViewBuilder
    var contentLayout: some View {
        if sizeClass == .regular {
            GeometryReader { geo in
                let total = geo.size.width
                let topInset = geo.safeAreaInsets.top
                HStack(spacing: 0) {
                    editorPane(topViewportInset: topInset)
                        .ignoresSafeArea(edges: .top)
                        .frame(width: total * editorFraction)
                    splitHandle(totalWidth: total)
                    previewPane()
                        .ignoresSafeArea(edges: .top)
                        .modifier(SoftScrollEdgeEffectModifier())
                }
                .coordinateSpace(name: "splitContainer")
            }
        } else {
            GeometryReader { geo in
                let topInset = geo.safeAreaInsets.top
                ZStack {
                    PreviewCompileDriver(
                        compiler: compiler,
                        source: entrySource,
                        compileSource: CompileFontResolver.effectiveSource(for: entrySource, resolvedFonts: resolvedCompileFonts),
                        fontPaths: resolvedCompileFonts.fontPaths,
                        preflightError: fontResolutionError,
                        rootDir: rootDir,
                        previewCacheDescriptor: compiledPreviewCacheDescriptor,
                        compileToken: compileToken,
                        requiresExternalFolderLink: previewRequiresExternalFolderLink
                    )
                    editorPane(topViewportInset: topInset)
                        .ignoresSafeArea(edges: .top)
                        .modifier(SoftScrollEdgeEffectModifier())
                        .opacity(selectedTab == editorTab ? 1 : 0)
                        .allowsHitTesting(selectedTab == editorTab)
                        .accessibilityHidden(selectedTab != editorTab)
                    if selectedTab == previewTab {
                        previewPane(topViewportInset: topInset)
                            .ignoresSafeArea(edges: .top)
                            .modifier(SoftScrollEdgeEffectModifier())
                            .transition(.identity)
                            .accessibilityHidden(false)
                    }
                }
                .animation(nil, value: selectedTab)
            }
        }
    }

    var shareButtonAction: () -> Void {
        if previewRequiresExternalFolderLink {
            return {
                guard flushPendingSave() else { return }
                exporter.exportTypSource(for: document, fileName: currentFileName)
            }
        }
        if sizeClass == .regular || selectedTab == previewTab {
            return {
                guard flushPendingSave() else { return }
                if let fontResolutionError {
                    exporter.exportError = fontResolutionError
                    return
                }
                exporter.exportPDF(for: document, cachedPDF: compiler.pdfDocument)
            }
        }
        return {
            guard flushPendingSave() else { return }
            exporter.exportTypSource(for: document, fileName: currentFileName)
        }
    }

    var shareButtonLabel: String {
        if previewRequiresExternalFolderLink { return L10n.tr("Export .typ") }
        if sizeClass == .regular || selectedTab == previewTab { return L10n.tr("Share PDF") }
        return L10n.tr("Export .typ")
    }

    var canTriggerPreviewActions: Bool {
        !previewRequiresExternalFolderLink
            && !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resumeBannerLabel: String {
        let fileName = document.lastEditedFileName
        if fileName.isEmpty || fileName == document.entryFileName {
            return L10n.tr("resume.banner.label")
        } else {
            return L10n.format("resume.banner.label_with_file", fileName)
        }
    }

    var resumeBanner: some View {
        Button {
            positionRestoreDismissTask?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) {
                showingPositionRestore = false
            }
            restoreSavedPosition()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.body)
                    .foregroundStyle(.tint)
                Text(resumeBannerLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .systemFloatingSurface(cornerRadius: 999)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .accessibilityLabel(resumeBannerLabel)
        .accessibilityHint(L10n.tr("resume.banner.a11y_hint"))
    }
    @ViewBuilder
    private var editorToolbarMenuContent: some View {
        Section {
            Button {
                InteractionFeedback.impact(.light)
                showingFileBrowser = true
            } label: {
                Label("Project Files", systemImage: "folder")
            }
            Button {
                InteractionFeedback.impact(.light)
                showingProjectSettings = true
            } label: {
                Label("Project Settings", systemImage: "gearshape")
            }
        }

        Section {
            Button { findRequested = true } label: {
                Label(L10n.tr("action.find_replace"), systemImage: "magnifyingglass")
            }
            Button {
                InteractionFeedback.impact(.light)
                focusCoordinator.dismissKeyboard()
                showingOutline = true
            } label: {
                Label(L10n.tr("outline.title"), systemImage: "list.bullet")
            }
            Button {
                InteractionFeedback.impact(.light)
                focusCoordinator.dismissKeyboard()
                showingKeyboardShortcuts = true
            } label: {
                Label(L10n.tr("shortcuts.title"), systemImage: "keyboard")
            }
        }

        Section {
            Button {
                Task { @MainActor in
                    await Task.yield()
                    clearCachesAndRecompile()
                }
            } label: {
                Label("Recompile", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!canTriggerPreviewActions)
        }
    }

    private func compactToolbarButtonLabel(
        systemName: String,
        font: Font = .body.weight(.semibold),
        size: CGFloat = 44,
        foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    ) -> some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .frame(width: size, height: size)
            .compactCircleSurface()
    }

    private func compactToolbarGlassLabel(
        systemName: String,
        size: CGFloat = 44
    ) -> some View {
        compactToolbarButtonLabel(
            systemName: systemName,
            font: .body.weight(.semibold),
            size: size
        )
    }

    private var systemCompactModePicker: some View {
        Picker(L10n.tr("Mode"), selection: compactTabSelection) {
            Image(systemName: "text.quote").tag(editorTab)
            Image(systemName: "document").tag(previewTab)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 100)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityIdentifier("editor.mode-picker")
    }

    private func compactToolbarTrailingWrapper<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var compactToolbarTrailingControl: some View {
        Group {
            if selectedTab == editorTab {
                compactToolbarTrailingWrapper {
                    Menu {
                        editorToolbarMenuContent
                    } label: {
                        compactToolbarGlassLabel(systemName: "ellipsis")
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityLabel(L10n.a11yEditorMenuLabel)
                .accessibilityHint(L10n.a11yEditorMenuHint)
                .accessibilityIdentifier("editor.more-menu")
            } else {
                compactToolbarTrailingWrapper {
                    Button {
                        showingSlideshow = true
                    } label: {
                        compactToolbarGlassLabel(systemName: "play.rectangle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!compiler.compiledOnce)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var compactTopBarTrailingItems: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                systemCompactModePicker
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                compactToolbarTrailingControl
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                systemCompactModePicker
            }

            ToolbarItem(placement: .topBarTrailing) {
                compactToolbarTrailingControl
            }
        }
    }

    var regularEditorChrome: some View {
        contentLayout
            .navigationTitle(usesSystemCompactToolbar ? "" : document.title)
            .navigationSubtitleCompat(usesSystemCompactToolbar ? "" : currentFileName)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConditionalToolbarRoleModifier(usesEditorRole: !usesSystemCompactToolbar))
            .modifier(ConditionalNavigationBarBackgroundModifier(hidesBackground: usesSystemCompactToolbar))
            .toolbar {
                if usesSystemCompactToolbar {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button(action: shareButtonAction) {
                                Label(shareButtonLabel, systemImage: "square.and.arrow.up")
                            }
                            if selectedTab == previewTab {
                                Button {
                                    guard flushPendingSave() else { return }
                                    exporter.exportTypSource(for: document, fileName: currentFileName)
                                } label: {
                                    Label("Export .typ", systemImage: "square.and.arrow.up.on.square")
                                }
                            }
                            Button { triggerZipExport() } label: {
                                Label("Export Project as Zip", systemImage: "archivebox")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(document.title)
                                    .font(.headline)
                                    .foregroundStyle(compactTitleForegroundColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(currentFileName)
                                    .font(.caption2)
                                    .foregroundStyle(compactTitleSecondaryForegroundColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } else {
                    ToolbarTitleMenu {
                        Button { shareButtonAction() } label: {
                            Label(L10n.tr("Share"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            guard flushPendingSave() else { return }
                            exporter.exportTypSource(for: document, fileName: currentFileName)
                        } label: {
                            Label("Export .typ", systemImage: "square.and.arrow.up.on.square")
                        }
                        Button { triggerZipExport() } label: {
                            Label("Export Project as Zip", systemImage: "archivebox")
                        }
                    }
                }
            }
            .toolbar {
                if sizeClass == .regular {
                    // --- Editor actions ---
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { findRequested = !findRequested } label: {
                            Label(L10n.tr("action.find_replace"), systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("editor.search")
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            InteractionFeedback.impact(.light)
                            focusCoordinator.dismissKeyboard()
                            showingOutline = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel(L10n.tr("outline.title"))
                        .accessibilityIdentifier("editor.outline")
                    }

                    // --- Preview actions ---
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSlideshow = true } label: {
                            Label("Slideshow", systemImage: "play.rectangle")
                        }
                        .disabled(!compiler.compiledOnce)
                    }

                    // --- Project actions ---
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: shareButtonAction) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(Text(shareButtonLabel))
                        .accessibilityHint(L10n.a11yEditorShareHint)
                        .accessibilityIdentifier("editor.share")
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section {
                                Button {
                                    InteractionFeedback.impact(.light)
                                    showingFileBrowser = true
                                } label: {
                                    Label("Project Files", systemImage: "folder")
                                }
                                Button {
                                    InteractionFeedback.impact(.light)
                                    showingProjectSettings = true
                                } label: {
                                    Label("Project Settings", systemImage: "gearshape")
                                }
                            }
                            Section {
                                Button {
                                    Task { @MainActor in
                                        await Task.yield()
                                        compilePreviewNow()
                                    }
                                } label: {
                                    Label("Compile Now", systemImage: "play.circle")
                                }
                                .disabled(!canTriggerPreviewActions)

                                Button {
                                    Task { @MainActor in
                                        await Task.yield()
                                        clearCachesAndRecompile()
                                    }
                                } label: {
                                    Label("Recompile", systemImage: "arrow.clockwise.circle")
                                }
                                .disabled(!canTriggerPreviewActions)
                            }
                            Section {
                                Button {
                                    InteractionFeedback.impact(.light)
                                    focusCoordinator.dismissKeyboard()
                                    showingKeyboardShortcuts = true
                                } label: {
                                    Label(L10n.tr("shortcuts.title"), systemImage: "keyboard")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(L10n.a11yEditorMenuLabel)
                        .accessibilityHint(L10n.a11yEditorMenuHint)
                        .accessibilityIdentifier("editor.more-menu")
                    }
                } else {
                    compactTopBarTrailingItems
                }
            }
    }

    var editorPresentation: some View {
        regularEditorChrome
            .photosPicker(isPresented: $showingPhotoPicker,
                          selection: $selectedPhotoItems,
                          maxSelectionCount: 1,
                          matching: .images)
            .onChange(of: selectedPhotoItems) { _, items in handleImageSelection(items) }
            .sheet(isPresented: $showingFileBrowser) {
                ProjectFileBrowserSheet(document: document, currentFileName: currentFileName, openFile: openFile)
            }
            .sheet(isPresented: $showingProjectSettings) {
                ProjectSettingsSheet(document: document, openFile: openFile)
            }
            .sheet(isPresented: $showingImportConfiguration) {
                InitialEntryFilePickerSheet(document: document) { selectedEntry, selectedImageDirectory, selectedFontDirectory in
                    if let selectedEntry {
                        document.entryFileName = selectedEntry
                    }
                    document.requiresInitialEntrySelection = false
                    if let selectedImageDirectory {
                        document.imageDirectoryName = selectedImageDirectory
                    } else {
                        document.imageDirectoryName = "images"
                        ProjectFileManager.ensureImageDirectory(for: document)
                    }
                    if let selectedFontDirectory {
                        _ = ProjectFileManager.importFontFiles(from: selectedFontDirectory, for: document)
                    } else {
                        ProjectFileManager.ensureFontsDirectory(for: document)
                    }
                    document.requiresImportConfiguration = false
                    document.importEntryFileOptions = []
                    document.importImageDirectoryOptions = []
                    document.importFontDirectoryOptions = []
                    showingImportConfiguration = false
                    _ = loadFile(named: document.entryFileName)
                }
            }
    }

    var editorLifecycleHandlers: some View {
        editorPresentation
            .onAppear {
                if ProcessInfo.processInfo.environment["UITEST_START_IN_PREVIEW"] == "1" {
                    selectedTab = previewTab
                }
                prepareDocumentForEditing()
                let handledExternalOpen = handleExternalOpenRequestIfNeeded(externalOpenRequest)
                refreshResolvedFonts(includeAvailableFamilies: false)
                scheduleAvailableFontFamilyRefresh()
                refreshReferenceCompletions()
                if !handledExternalOpen && hasSavedPosition() {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showingPositionRestore = true
                    }
                    positionRestoreDismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingPositionRestore = false
                        }
                    }
                }
            }
            .onDisappear {
                positionRestoreDismissTask?.cancel()
                positionRestoreDismissTask = nil
                positionSyncTask?.cancel()
                positionSyncTask = nil
                fontFamilyRefreshTask?.cancel()
                fontFamilyRefreshTask = nil
                externalFolderLinkTask?.cancel()
                externalFolderLinkTask = nil
                externalFolderLinkProgress = nil
                externalFolderLinkProgressTitle = nil
                _ = flushPendingSave()
                persistEditorPositionIfNeeded()
                stopConflictMonitoring()
                focusCoordinator.clearFocusPreservation()
                compiler.cancel()
                if ExternalTypFileSessionStore.contains(projectID: document.projectID) {
                    ExternalTypFileSessionStore.unregister(projectID: document.projectID)
                }
            }
            .onChange(of: editorText) { _, newText in
                guard !isLoadingFileContent else { return }
                handleEditorTextChange(newText)
            }
            .onChange(of: document.fontFileNames) { _, _ in
                handleCompileInputsChanged()
            }
            .onChange(of: compileToken) { _, _ in
                refreshReferenceCompletions()
            }
            .onChange(of: externalOpenRequest?.id) { _, _ in
                _ = handleExternalOpenRequestIfNeeded(externalOpenRequest)
            }
            .onChange(of: syncCoordinator.editorScrollTarget) { _, target in
                guard let target else { return }
                if sizeClass != .regular {
                    selectedTab = editorTab
                }
                if currentFileName != document.entryFileName {
                    guard openFileIfPossible(named: document.entryFileName) else { return }
                }
                pendingCursorJump = utf16Offset(forLine: target.line, column: target.column, in: editorText)
                syncCoordinator.editorScrollTarget = nil
                InteractionFeedback.impact(.light)
            }
            .onChange(of: appFontLibrary.items) { _, _ in
                handleCompileInputsChanged()
            }
            .onChange(of: currentFileName) { _, newValue in
                guard !newValue.isEmpty else { return }
                scheduleEditorPositionSync(delay: .milliseconds(150))
            }
            .onChange(of: editorViewState.selectedLocation) { _, _ in
                scheduleEditorPositionSync()
            }
    }

    var editorSheetsAndEvents: some View {
        editorLifecycleHandlers
            .onChange(of: insertionRequest) { _, newValue in
                if newValue == nil {
                    pumpPendingInsertionsIfNeeded()
                }
            }
            .onChange(of: currentFileName) { _, _ in
                pumpPendingInsertionsIfNeeded()
            }
            .onChange(of: selectedTab) { _, newTab in
                InteractionFeedback.selection()
                if newTab == editorTab {
                    let shouldRestoreFocus = shouldRestoreEditorFocusAfterPreview
                    shouldRestoreEditorFocusAfterPreview = false
                    if shouldRestoreFocus {
                        focusCoordinator.activateKeyboard()
                    }
                } else {
                    shouldRestoreEditorFocusAfterPreview = focusCoordinator.isEditorFocused
                    focusCoordinator.dismissKeyboard()
                }
            }
            .onChange(of: exporter.exportURL) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.success)
                AccessibilitySupport.announce(L10n.a11yExportReady)
            }
            .onChange(of: exporter.exportError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
            .onChange(of: imageImportError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
            .onChange(of: fileSaveError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
            .onChange(of: previewActionError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
            .onChange(of: compiler.pdfDocument) { _, newValue in
                if newValue != nil {
                    syncCursorToPreviewIfPending()
                }
                guard pendingManualCompileFeedback, newValue != nil, compiler.errorMessage == nil else { return }
                Task { @MainActor in
                    pendingManualCompileFeedback = false
                    InteractionFeedback.notify(.success)
                    AccessibilitySupport.announce(L10n.a11yCompileSuccess)
                }
            }
            .onChange(of: compiler.errorMessage) { _, newValue in
                compilationErrorLines = recomputeCompilationErrorLines()
                guard pendingManualCompileFeedback, newValue != nil else { return }
                Task { @MainActor in
                    pendingManualCompileFeedback = false
                    InteractionFeedback.notify(.error)
                    AccessibilitySupport.announce(L10n.a11yCompileFailed)
                }
            }
    }

    var editorOverlaysAndAlerts: some View {
        editorSheetsAndEvents
            .overlay {
                if exporter.isExporting {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                        ProgressView("Compiling…")
                            .padding()
                            .systemFloatingSurface(cornerRadius: 12)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                externalFolderLinkProgressInset
            }
            .animation(.snappy(duration: 0.25), value: externalFolderLinkProgress)
            .overlay(alignment: .bottom) {
                if let toast = imageImportToast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .systemFloatingSurface(cornerRadius: 999)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(toast)
                }
            }
            .sheet(item: $exporter.exportURL) { url in ActivityView(activityItems: [url]) }
            .sheet(isPresented: $showingKeyboardShortcuts) {
                NavigationStack {
                    KeyboardShortcutsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.tr("Done")) { showingKeyboardShortcuts = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingOutline) {
                OutlineView(editorText: editorText) { offset in
                    handleOutlineJump(characterOffset: offset)
                }
            }
            .sheet(isPresented: $showingSnippetBrowser) {
                SnippetBrowserSheet { snippet in
                    let (text, cursorOffset) = snippet.bodyWithCursorOffset()
                    let targetRange = NSRange(
                        location: editorViewState.selectedLocation,
                        length: editorViewState.selectedLength
                    )
                    insertionRequest = EditorInsertionRequest(
                        text: text,
                        targetRange: targetRange,
                        targetFileName: currentFileName
                    )
                    if let cursorOffset {
                        pendingCursorJump = targetRange.location + cursorOffset
                    }
                }
            }
            .fileImporter(isPresented: $showingExternalFolderLinkImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    linkExternalFolderForPreview(from: url)
                case .failure(let error):
                    previewActionError = error.localizedDescription
                    InteractionFeedback.notify(.error)
                }
            }
            .fullScreenCover(isPresented: $showingSlideshow) {
                if let pdf = compiler.pdfDocument {
                    SlideshowView(document: pdf)
                }
            }
            .alert("Export Error", isPresented: Binding(
                get: { exporter.exportError != nil },
                set: { if !$0 { exporter.exportError = nil } }
            )) {
                Button("OK") { exporter.exportError = nil }
            } message: {
                Text(exporter.exportError ?? "")
            }
            .alert(L10n.appFontsExportWarningTitle, isPresented: $showingZipExportWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") {
                    guard flushPendingSave() else { return }
                    exporter.exportZip(for: document)
                }
            } message: {
                Text(L10n.appFontsExportWarningMessage)
            }
            .alert("Image Import Error", isPresented: Binding(
                get: { imageImportError != nil },
                set: { if !$0 { imageImportError = nil } }
            )) {
                Button("OK") { imageImportError = nil }
            } message: {
                Text(imageImportError ?? "")
            }
            .alert("File Error", isPresented: Binding(
                get: { fileSaveError != nil },
                set: { if !$0 { fileSaveError = nil } }
            )) {
                Button("OK") { fileSaveError = nil }
            } message: {
                Text(fileSaveError ?? "")
            }
            .alert("Cache Error", isPresented: Binding(
                get: { previewActionError != nil },
                set: { if !$0 { previewActionError = nil } }
            )) {
                Button("OK") { previewActionError = nil }
            } message: {
                Text(previewActionError ?? "")
            }
            .overlay(alignment: .bottom) {
                if showingPositionRestore {
                    resumeBanner
                        .padding(.bottom, 48)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert(L10n.tr("icloud.conflict.title"), isPresented: $showingConflictWarning) {
                Button(L10n.tr("icloud.conflict.keep_local")) {
                    resolveConflictKeepLocal()
                }
                Button(L10n.tr("icloud.conflict.keep_remote")) {
                    resolveConflictKeepRemote()
                }
                Button(L10n.tr("Cancel"), role: .cancel) {
                    showingConflictWarning = false
                }
            } message: {
                Text(L10n.format("icloud.conflict.message", conflictFileName))
            }
    }

    @ViewBuilder
    private var externalFolderLinkProgressInset: some View {
        if let externalFolderLinkProgress {
            LinkedFolderLoadProgressView(
                title: externalFolderLinkProgressTitle ?? L10n.tr("preview.external_link_required.button"),
                progress: externalFolderLinkProgress
            ) {
                externalFolderLinkTask?.cancel()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var splitHandleAccessibilityValue: String {
        let editorPercent = Int((editorFraction * 100).rounded())
        let previewPercent = max(0, 100 - editorPercent)
        return L10n.a11yEditorSplitValue(editorPercent: editorPercent, previewPercent: previewPercent)
    }
}
