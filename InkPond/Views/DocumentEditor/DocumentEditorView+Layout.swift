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

private struct EditorNavigationBarBackgroundModifier: ViewModifier {
    let usesCompactChrome: Bool
    let background: Color
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if usesCompactChrome {
            if #available(iOS 18.0, *) {
                content
                    .toolbarBackground(background, for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
            } else {
                content
                    .toolbarBackground(background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
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

private struct RegularNavigationBarVisibilityModifier: ViewModifier {
    let hidesNavigationBar: Bool

    func body(content: Content) -> some View {
        if hidesNavigationBar {
            content.toolbar(.hidden, for: .navigationBar)
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

    @ViewBuilder
    func regularToolbarCircleSurface() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.systemFloatingSurface(cornerRadius: 999)
        }
    }

    @ViewBuilder
    func regularToolbarCapsuleSurface() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        } else {
            self.systemFloatingSurface(cornerRadius: 24)
        }
    }

    @ViewBuilder
    func projectTabBarSurface(
        background: Color,
        border: Color,
        cornerRadius: CGFloat,
        isInteractive: Bool,
        tint: Color
    ) -> some View {
        if #available(iOS 26, *) {
            self
                .background(background, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    tint.opacity(0.13),
                                    Color.white.opacity(0.04),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .glassEffect(
                    isInteractive ? .regular.interactive() : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            self
                .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
        }
    }

}

extension DocumentEditorView {
    /// Sync is only useful on iPad where both panes are visible simultaneously.
    private var isSyncEnabled: Bool { sizeClass == .regular }
    private var regularWorkspaceTopBarHeight: CGFloat { 56 }
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

    private var navigationEditorSubtitle: String {
        openTabs.isEmpty ? activeEditorSubtitle : ""
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
    func workspaceEditorPane(topViewportInset: CGFloat = 0) -> some View {
        VStack(spacing: 0) {
            if sizeClass != .regular {
                compactProjectTabBar
            }
            if activeTabIsTextEditable {
                editorPane(topViewportInset: topViewportInset)
            } else if let tab = activeProjectTab {
                ProjectFilePreviewView(
                    tab: tab,
                    url: try? ProjectFileManager.projectFileURL(relativePath: tab.relativePath, for: document)
                )
            } else {
                editorPane(topViewportInset: topViewportInset)
            }
        }
    }

    @ViewBuilder
    private var projectFileTreeSidebar: some View {
        ProjectFileTreeView(
            document: document,
            activePath: activeProjectPath,
            openNode: openProjectFile,
            setEntryFile: setEntryProjectFile,
            onNodeDeleted: handleProjectFileDeleted,
            usesNavigationToolbar: false
        )
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityIdentifier("project-workspace.file-tree-sidebar")
    }

    private var regularToolbarTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(openTabs) { tab in
                    projectTabButton(tab, isCompact: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(minWidth: 260, maxWidth: 760, minHeight: 46, maxHeight: 46, alignment: .leading)
        .accessibilityIdentifier("project-workspace.tabs")
    }

    @ViewBuilder
    private var regularWorkspaceTopBar: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 12) {
                    regularWorkspaceTopBarContent
                }
            } else {
                regularWorkspaceTopBarContent
            }
        }
        .padding(.horizontal, 12)
        .frame(height: regularWorkspaceTopBarHeight)
        .background {
            if #available(iOS 26, *) {
                Color.clear
            } else {
                Color(uiColor: .secondarySystemGroupedBackground)
            }
        }
    }

    private var regularWorkspaceTopBarContent: some View {
        HStack(spacing: 12) {
            if let onCloseProject {
                Button {
                    guard flushPendingSave() else { return }
                    onCloseProject()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .regularToolbarCircleSurface()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Projects"))
                .accessibilityIdentifier("editor.close-project")
            }

            regularProjectTitleMenu

            if !openTabs.isEmpty {
                regularToolbarTabBar
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            regularWorkspaceActionButtons
        }
    }

    private var regularProjectTitleMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 5) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down.circle.fill")
                    .font(.caption2)
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .frame(maxWidth: 230, alignment: .leading)
            .regularToolbarCapsuleSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(document.title)
    }

    private var regularWorkspaceActionButtons: some View {
        HStack(spacing: 2) {
            Button { findRequested = !findRequested } label: {
                regularToolbarIconLabel("magnifyingglass")
            }
            .accessibilityLabel(L10n.tr("action.find_replace"))
            .accessibilityIdentifier("editor.search")

            Button {
                InteractionFeedback.impact(.light)
                focusCoordinator.dismissKeyboard()
                showingOutline = true
            } label: {
                regularToolbarIconLabel("list.bullet")
            }
            .accessibilityLabel(L10n.tr("outline.title"))
            .accessibilityIdentifier("editor.outline")

            Button { showingSlideshow = true } label: {
                regularToolbarIconLabel("play.rectangle")
            }
            .disabled(!compiler.compiledOnce)
            .accessibilityLabel(L10n.tr("Slideshow"))

            Button(action: shareButtonAction) {
                regularToolbarIconLabel("square.and.arrow.up")
            }
            .accessibilityLabel(Text(shareButtonLabel))
            .accessibilityHint(L10n.a11yEditorShareHint)
            .accessibilityIdentifier("editor.share")

            Menu {
                Section {
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
                regularToolbarIconLabel("ellipsis.circle")
            }
            .accessibilityLabel(L10n.a11yEditorMenuLabel)
            .accessibilityHint(L10n.a11yEditorMenuHint)
            .accessibilityIdentifier("editor.more-menu")
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
        .regularToolbarCapsuleSurface()
        .buttonStyle(.plain)
    }

    private func regularToolbarIconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var compactProjectTabBar: some View {
        if !openTabs.isEmpty {
            ZStack {
                editorThemeChromeColor
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(openTabs) { tab in
                            projectTabButton(tab, isCompact: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .accessibilityIdentifier("project-workspace.compact-tabs")
                .projectTabBarSurface(
                    background: editorThemeChromeColor.opacity(0.62),
                    border: .clear,
                    cornerRadius: 18,
                    isInteractive: true,
                    tint: editorThemeAccentColor
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .frame(height: 62)
        }
    }

    private func regularPreviewColumn(topViewportInset: CGFloat = 0) -> some View {
        previewPane(topViewportInset: topViewportInset)
            .modifier(SoftScrollEdgeEffectModifier())
    }

    private var regularEditorTopFade: some View {
        LinearGradient(
            stops: [
                .init(color: editorThemeChromeColor.opacity(0.22), location: 0),
                .init(color: editorThemeChromeColor.opacity(0.10), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: regularWorkspaceTopBarHeight + 24)
        .allowsHitTesting(false)
    }

    private func projectTabButton(_ tab: ProjectFileTab, isCompact: Bool) -> some View {
        let isActive = tab.relativePath == activeTabPath
        return HStack(spacing: 4) {
            Button {
                selectProjectTab(tab)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tab.kind.iconName)
                        .font(.system(size: isCompact ? 11 : 13, weight: .semibold))
                    Text(tab.displayName)
                        .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isActive ? editorThemeAccentColor : editorThemeTextColor)
                .padding(.leading, isCompact ? 8 : 10)
                .padding(.vertical, isCompact ? 7 : 8)
                .frame(minHeight: isCompact ? 34 : 40)
            }
            .buttonStyle(.plain)

            Button {
                closeProjectTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: isCompact ? 9 : 10, weight: .bold))
                    .foregroundStyle(editorThemeSecondaryTextColor)
                    .frame(width: isCompact ? 28 : 34, height: isCompact ? 32 : 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Close"))
        }
        .padding(.trailing, 3)
        .projectTabBarSurface(
            background: isActive ? editorThemeAccentColor.opacity(0.12) : editorThemeTextColor.opacity(0.05),
            border: isActive ? editorThemeAccentColor.opacity(0.30) : editorThemeBorderColor.opacity(0.20),
            cornerRadius: isCompact ? 9 : 13,
            isInteractive: true,
            tint: isActive ? editorThemeAccentColor : editorThemeSecondaryTextColor
        )
        .frame(maxWidth: isCompact ? 220 : 210)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project-workspace.tab.\(tab.relativePath)")
    }

    private var editorThemeChromeColor: Color {
        Color(uiColor: themeManager.currentTheme.gutterBackground)
    }

    private var editorThemeTextColor: Color {
        Color(uiColor: themeManager.currentTheme.text)
    }

    private var editorThemeSecondaryTextColor: Color {
        Color(uiColor: themeManager.currentTheme.gutterForeground)
    }

    private var editorThemeAccentColor: Color {
        Color(uiColor: themeManager.currentTheme.heading)
    }

    private var editorThemeBorderColor: Color {
        Color(uiColor: themeManager.currentTheme.gutterForeground)
    }

    private var editorThemeNavigationColorScheme: ColorScheme {
        switch themeManager.themeID {
        case "mocha":
            return .dark
        case "latte":
            return .light
        default:
            return colorScheme
        }
    }

    private var compactNavigationChromeColor: Color {
        selectedTab == editorTab ? editorThemeChromeColor : Color(uiColor: .systemBackground)
    }

    private var compactNavigationTextColor: Color {
        selectedTab == editorTab ? editorThemeTextColor : appThemeTitleForegroundColor
    }

    private var compactNavigationSecondaryTextColor: Color {
        selectedTab == editorTab ? editorThemeSecondaryTextColor : appThemeTitleForegroundColor.opacity(0.68)
    }

    private var compactNavigationColorScheme: ColorScheme {
        selectedTab == editorTab ? editorThemeNavigationColorScheme : colorScheme
    }

    @ViewBuilder
    var contentLayout: some View {
        if sizeClass == .regular {
            if #available(iOS 26, *) {
                ZStack(alignment: .top) {
                    regularWorkspaceContent(topViewportInset: regularWorkspaceTopBarHeight)
                    regularWorkspaceTopBar
                        .zIndex(1)
                }
            } else {
                VStack(spacing: 0) {
                    regularWorkspaceTopBar
                    regularWorkspaceTopBarSeparator
                    regularWorkspaceContent(topViewportInset: 0)
                }
            }
        } else {
            GeometryReader { _ in
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
                    workspaceEditorPane(topViewportInset: 0)
                        .modifier(SoftScrollEdgeEffectModifier())
                        .opacity(selectedTab == editorTab ? 1 : 0)
                        .allowsHitTesting(selectedTab == editorTab)
                        .accessibilityHidden(selectedTab != editorTab)
                    if selectedTab == previewTab {
                        previewPane(topViewportInset: 0)
                            .modifier(SoftScrollEdgeEffectModifier())
                            .transition(.identity)
                            .accessibilityHidden(false)
                    }
                }
                .animation(nil, value: selectedTab)
            }
        }
    }

    private func regularWorkspaceContent(topViewportInset: CGFloat) -> some View {
        GeometryReader { geo in
            let total = geo.size.width
            let treeWidth = min(max(total * 0.22, 240), 320)
            let workspaceWidth = max(total - treeWidth - 1, 1)
            HStack(spacing: 0) {
                projectFileTreeSidebar
                    .padding(.top, topViewportInset)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: treeWidth)
                Divider()
                HStack(spacing: 0) {
                    workspaceEditorPane(topViewportInset: topViewportInset)
                        .overlay(alignment: .top) {
                            if topViewportInset > 0 {
                                regularEditorTopFade
                            }
                        }
                        .frame(width: workspaceWidth * editorFraction)
                    splitHandle(totalWidth: workspaceWidth)
                    regularPreviewColumn(topViewportInset: 0)
                }
                .coordinateSpace(name: "splitContainer")
            }
        }
    }

    @ViewBuilder
    private var regularWorkspaceTopBarSeparator: some View {
        if #available(iOS 26, *) {
            EmptyView()
        } else {
            Divider()
                .overlay(editorThemeBorderColor.opacity(0.28))
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
            Button(action: shareButtonAction) {
                Label(shareButtonLabel, systemImage: "square.and.arrow.up")
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
            size: size,
            foregroundStyle: AnyShapeStyle(compactNavigationTextColor)
        )
    }

    private func compactCloseProjectButton(_ onCloseProject: @escaping () -> Void) -> some View {
        Button {
            guard flushPendingSave() else { return }
            onCloseProject()
        } label: {
            compactToolbarGlassLabel(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Projects"))
        .accessibilityIdentifier("editor.close-project")
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

    private var compactNavigationTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(document.title)
                .font(.headline)
                .foregroundStyle(compactNavigationTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if !navigationEditorSubtitle.isEmpty {
                Text(navigationEditorSubtitle)
                    .font(.caption2)
                    .foregroundStyle(compactNavigationSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 160, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            .navigationTitle(usesSystemCompactToolbar || !openTabs.isEmpty ? "" : document.title)
            .navigationSubtitleCompat(usesSystemCompactToolbar ? "" : navigationEditorSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConditionalToolbarRoleModifier(usesEditorRole: !usesSystemCompactToolbar))
            .modifier(RegularNavigationBarVisibilityModifier(hidesNavigationBar: !usesSystemCompactToolbar))
            .modifier(EditorNavigationBarBackgroundModifier(
                usesCompactChrome: usesSystemCompactToolbar,
                background: compactNavigationChromeColor,
                colorScheme: compactNavigationColorScheme
            ))
            .tint(usesSystemCompactToolbar ? compactNavigationTextColor : Color.accentColor)
            .toolbar {
                if let onCloseProject {
                    if usesSystemCompactToolbar {
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarLeading) {
                                compactCloseProjectButton(onCloseProject)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarLeading) {
                                compactCloseProjectButton(onCloseProject)
                            }
                        }
                    }
                }
            }
            .toolbar {
                if usesSystemCompactToolbar {
                    ToolbarItem(placement: .principal) {
                        compactNavigationTitle
                    }
                }
            }
            .toolbar {
                if sizeClass != .regular {
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
                ProjectFileBrowserSheet(
                    document: document,
                    activePath: activeProjectPath,
                    openNode: openProjectFile,
                    setEntryFile: setEntryProjectFile,
                    onNodeDeleted: handleProjectFileDeleted
                )
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
