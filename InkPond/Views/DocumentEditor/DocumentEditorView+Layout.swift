//
//  DocumentEditorView+Layout.swift
//  InkPond
//

import SwiftUI
import SwiftData
import PDFKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private struct HitTestShield: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {}
    }
}

private struct RegularWorkspaceMetrics {
    let totalWidth: CGFloat
    let treeWidth: CGFloat
    let treeDividerWidth: CGFloat
    let projectHeaderWidth: CGFloat
    let workspaceWidth: CGFloat
    let editorWidth: CGFloat
    let splitHandleWidth: CGFloat

    var editorStartX: CGFloat { treeWidth + treeDividerWidth }
    var previewStartX: CGFloat { editorStartX + editorWidth + splitHandleWidth }
    var previewWidth: CGFloat { max(workspaceWidth - editorWidth - splitHandleWidth, 1) }
}

private enum RegularToolbarActionLayout {
    case full
    case compact
    case minimal
}

private struct HorizontalBoundsClipShape: Shape {
    let verticalOutset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(
            CGRect(
                x: rect.minX,
                y: rect.minY - verticalOutset,
                width: rect.width,
                height: rect.height + verticalOutset * 2
            )
        )
        return path
    }
}

private struct EditorNavigationBarBackgroundModifier: ViewModifier {
    let usesCompactChrome: Bool
    let background: Color
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if usesCompactChrome {
            if #available(iOS 26.0, *) {
                content
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
            } else if #available(iOS 18.0, *) {
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

private struct ConditionalNavigationBarVisibilityModifier: ViewModifier {
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
    func clippedHorizontally(verticalOutset: CGFloat) -> some View {
        clipShape(HorizontalBoundsClipShape(verticalOutset: verticalOutset))
    }

    @ViewBuilder
    func highPriorityGestureIfEnabled<G: Gesture>(_ isEnabled: Bool, _ gesture: G) -> some View {
        if isEnabled {
            highPriorityGesture(gesture)
        } else {
            self
        }
    }

    @ViewBuilder
    func containerCornerOffsetWhenAvailable(enabled: Bool = true) -> some View {
        if enabled, #available(iOS 26.0, *) {
            containerCornerOffset(.horizontal, sizeToFit: true)
        } else {
            self
        }
    }

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
            self.lockedLiquidGlassCircle()
        } else {
            self.systemFloatingSurface(cornerRadius: 999)
        }
    }

    @ViewBuilder
    func regularToolbarCircleSurface() -> some View {
        if #available(iOS 26, *) {
            self.lockedLiquidGlassCircle()
        } else {
            self.systemFloatingSurface(cornerRadius: 999)
        }
    }

    @ViewBuilder
    func regularToolbarCapsuleSurface() -> some View {
        if #available(iOS 26, *) {
            self.lockedLiquidGlassRect(cornerRadius: 24)
        } else {
            self.systemFloatingSurface(cornerRadius: 24)
        }
    }

    @ViewBuilder
    func projectTabBarSurface(
        background: Color,
        border: Color,
        cornerRadius: CGFloat,
        isInteractive: Bool
    ) -> some View {
        if #available(iOS 26, *) {
            self
                .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(border.opacity(0.54), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .lockedLiquidGlassRect(cornerRadius: cornerRadius, isInteractive: isInteractive)
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
    private var regularWorkspaceTopHitHeight: CGFloat { regularWorkspaceTopBarHeight + 14 }
    private var regularToolbarControlHeight: CGFloat { 48 }
    private var regularSplitHandleWidth: CGFloat { 12 }
    private var regularTabOverlayLeadingInset: CGFloat { 6 }
    private var regularTabOverlayTrailingInset: CGFloat { 18 }
    private var regularTabOverlayEdgeFadeWidth: CGFloat { 24 }
    private var regularProjectTabSpacing: CGFloat { 5 }
    private var regularProjectTabMinimumWidth: CGFloat { 168 }
    private var regularProjectTabMaximumWidth: CGFloat { 214 }
    private var regularProjectTabTitleMaximumWidth: CGFloat { 116 }
    private var regularProjectTabSurfaceHeight: CGFloat { 44 }
    private var regularCollapsedProjectHeaderMinimumWidth: CGFloat { 272 }
    private var regularCollapsedProjectHeaderMaximumWidth: CGFloat { 312 }
    private var regularToolbarActionButtonSpacing: CGFloat { 2 }
    private var regularToolbarActionCapsuleHorizontalPadding: CGFloat { 8 }
    private var regularToolbarPreviewStatsFullEstimatedWidth: CGFloat { 134 }
    private var regularToolbarPreviewStatsCompactEstimatedWidth: CGFloat { 78 }
    private var regularToolbarMinimalActionsMaximumPreviewWidth: CGFloat { 220 }
    private var regularToolbarCompactActionsMaximumPreviewWidth: CGFloat { 280 }
    private var regularPreviewStatsCompactMinimumPreviewWidth: CGFloat { 340 }
    private var regularPreviewStatsFullMinimumPreviewWidth: CGFloat { 420 }
    private var usesSystemCompactToolbar: Bool {
        sizeClass != .regular
    }

    private var regularToolbarForegroundColor: Color {
        regularWorkspaceColorScheme == .dark ? .white : .black
    }

    private var regularToolbarSecondaryForegroundColor: Color {
        regularToolbarForegroundColor.opacity(0.62)
    }

    private var regularWorkspaceColorScheme: ColorScheme {
        colorScheme
    }

    private var regularWorkspaceChromeColor: Color {
        Color(uiColor: regularWorkspaceChromeUIColor)
    }

    @ViewBuilder
    private var regularWorkspaceTopBarBackdrop: some View {
        if #available(iOS 26, *) {
            Color.clear
        } else {
            regularWorkspaceChromeColor
        }
    }

    private var regularWorkspaceChromeUIColor: UIColor {
        if regularWorkspaceColorScheme == .dark {
            return UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        }
        return UIColor.secondarySystemGroupedBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
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
            externalChromeBackgroundColor: editorExternalChromeBackgroundUIColor,
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
                    .stroke(editorThemeTextColor.opacity(0.72), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var editorExternalChromeBackgroundUIColor: UIColor {
        sizeClass == .regular ? regularWorkspaceChromeUIColor : .secondarySystemGroupedBackground
    }

    func previewPane(
        topViewportInset: CGFloat = 0,
        overlayTopInset: CGFloat = 0,
        overlayBottomInset: CGFloat = 0
    ) -> some View {
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
            overlayTopInset: overlayTopInset,
            overlayBottomInset: overlayBottomInset,
            onGoToError: { file, line, column in
                navigateToError(file: file, line: line, column: column)
            },
            onCompactPreviewSwipe: sizeClass == .regular ? nil : {
                if selectedTab != editorTab {
                    pendingCompactSwipeFeedback = true
                    selectedTab = editorTab
                }
            },
            onLinkExternalFolder: previewRequiresExternalFolderLink ? {
                showingExternalFolderLinkImporter = true
            } : nil,
            showsStatisticsOverlay: sizeClass != .regular,
            showsCompilingIndicatorOverlay: sizeClass != .regular,
            backgroundColor: sizeClass == .regular ? regularWorkspaceChromeUIColor : .secondarySystemBackground
        )
        .environment(\.colorScheme, sizeClass == .regular ? regularWorkspaceColorScheme : colorScheme)
        .liquidGlassColorScheme(sizeClass == .regular ? regularWorkspaceColorScheme : colorScheme)
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
        appThemeTitleForegroundColor
    }

    private var compactTitleSecondaryForegroundColor: Color {
        compactTitleForegroundColor.opacity(0.68)
    }

    private var navigationEditorSubtitle: String {
        openTabs.count <= 1 ? activeEditorSubtitle : ""
    }

    func splitHandle(totalWidth: CGFloat) -> some View {
        let dragGesture = DragGesture(minimumDistance: 1, coordinateSpace: .named("splitContainer"))
            .onChanged { value in
                let raw = value.location.x / totalWidth
                withTransaction(Transaction(animation: nil)) {
                    editorFraction = min(0.8, max(0.2, raw))
                }
            }

        return ZStack {
            Rectangle()
                .fill(regularWorkspaceChromeColor)
            Rectangle()
                .fill(regularToolbarSecondaryForegroundColor.opacity(0.12))
                .frame(width: 1)
            Capsule()
                .fill(regularToolbarSecondaryForegroundColor.opacity(0.45))
                .frame(width: 4, height: 52)
        }
        .frame(width: regularSplitHandleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                InteractionFeedback.impact(.medium)
                withAnimation(.spring(duration: 0.3)) { editorFraction = 0.5 }
            }
        )
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
            if sizeClass != .regular, !usesCompactTabsInTopChrome {
                compactProjectTabBar
            }
            if activeTabIsTextEditable {
                editorPane(topViewportInset: topViewportInset)
        } else if let tab = activeProjectTab {
            ProjectFilePreviewView(
                tab: tab,
                url: try? ProjectFileManager.projectFileURL(relativePath: tab.relativePath, for: document),
                topViewportInset: topViewportInset,
                backgroundColor: regularWorkspaceChromeUIColor
            )
        } else {
            editorPane(topViewportInset: topViewportInset)
        }
        }
        .animation(.smooth(duration: 0.22, extraBounce: 0), value: openTabs.count)
    }

    @ViewBuilder
    private func projectFileTreeSidebar(topContentInset: CGFloat = 0) -> some View {
        ProjectFileTreeView(
            document: document,
            activePath: activeProjectPath,
            openNode: openProjectFile,
            setEntryFile: setEntryProjectFile,
            onNodeDeleted: handleProjectFileDeleted,
            usesNavigationToolbar: false,
            topContentInset: topContentInset,
            refreshToken: projectFileTreeRefreshToken
        )
        .environment(\.colorScheme, regularWorkspaceColorScheme)
        .liquidGlassColorScheme(regularWorkspaceColorScheme)
        .accessibilityIdentifier("project-workspace.file-tree-sidebar")
    }

    private var regularToolbarTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: regularProjectTabSpacing) {
                ForEach(openTabs) { tab in
                    projectTabButton(tab, isCompact: false)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollClipDisabled()
        .softScrollEdgeEffect(for: .horizontal)
        .frame(height: regularToolbarControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("project-workspace.tabs")
    }

    @ViewBuilder
    private var regularWorkspaceTopBar: some View {
        GeometryReader { geo in
            let metrics = regularWorkspaceMetrics(totalWidth: geo.size.width)
            regularWorkspaceTopBarContent(metrics: metrics)
                .background {
                    regularWorkspaceTopBarBackdrop
                }
                .scrollEdgeElementContainer(edge: .top)
        }
        .frame(height: regularWorkspaceTopBarHeight)
    }

    private func regularWorkspaceTopBarContent(metrics: RegularWorkspaceMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            regularWorkspaceProjectHeader
                .padding(.horizontal, 12)
                .frame(width: metrics.projectHeaderWidth, height: regularWorkspaceTopBarHeight, alignment: .leading)
                .background {
                    regularWorkspaceTopBarBackdrop
                }
                .liquidGlassColorScheme(regularWorkspaceColorScheme)
                .position(
                    x: metrics.projectHeaderWidth / 2,
                    y: regularWorkspaceTopBarHeight / 2
                )

            regularWorkspaceTabsOverlay(metrics: metrics)
                .zIndex(1)

            regularWorkspaceActionButtons(metrics: metrics)
                .padding(.horizontal, 12)
                .frame(width: metrics.previewWidth, height: regularWorkspaceTopBarHeight, alignment: .trailing)
                .background {
                    regularWorkspaceTopBarBackdrop
                }
                .liquidGlassColorScheme(regularWorkspaceColorScheme)
                .position(
                    x: metrics.previewStartX + metrics.previewWidth / 2,
                    y: regularWorkspaceTopBarHeight / 2
                )
        }
        .frame(maxWidth: .infinity, minHeight: regularWorkspaceTopBarHeight, maxHeight: regularWorkspaceTopBarHeight, alignment: .topLeading)
    }

    private var regularWorkspaceProjectHeader: some View {
        HStack(spacing: 12) {
            regularProjectFileTreeToggleButton

            if let onCloseProject {
                Button {
                    guard flushPendingSave() else { return }
                    onCloseProject()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(regularToolbarForegroundColor)
                        .frame(width: regularToolbarControlHeight, height: regularToolbarControlHeight)
                        .regularToolbarCircleSurface()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Projects"))
                .accessibilityIdentifier("editor.close-project")
            }

            regularProjectTitleMenu
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var regularProjectFileTreeToggleButton: some View {
        Button {
            InteractionFeedback.impact(.light)
            withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
                isProjectFileTreeVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.title3.weight(.semibold))
                .foregroundStyle(regularToolbarForegroundColor)
                .frame(width: regularToolbarControlHeight, height: regularToolbarControlHeight)
                .regularToolbarCircleSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isProjectFileTreeVisible ? L10n.a11yProjectFilesHideLabel : L10n.a11yProjectFilesShowLabel)
        .accessibilityValue(isProjectFileTreeVisible ? L10n.a11yStateExpanded : L10n.a11yStateCollapsed)
        .accessibilityIdentifier("project-workspace.file-tree-toggle")
    }

    private var regularProjectTitleMenu: some View {
        Menu {
            Section {
                Button {
                    InteractionFeedback.impact(.light)
                    showingProjectSettings = true
                } label: {
                    Label("Project Settings", systemImage: "gearshape")
                }
                Button {
                    newProjectFileName = ""
                    showingNewProjectFileAlert = true
                } label: {
                    Label("New .typ File", systemImage: "doc.badge.plus")
                }
                Button {
                    showingProjectFileImporter = true
                } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                }
            }
            Section {
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
        } label: {
            HStack(spacing: 5) {
                Text(document.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.72)
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(regularToolbarForegroundColor)
            .padding(.horizontal, 6)
            .frame(height: regularToolbarControlHeight)
            .frame(maxWidth: 320, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(document.title)
    }

    private func regularWorkspaceActionButtons(metrics: RegularWorkspaceMetrics) -> some View {
        let actionLayout = regularToolbarActionLayout(for: metrics.previewWidth)
        let usesCompactStats = metrics.previewWidth < regularPreviewStatsFullMinimumPreviewWidth
        let showsStats = regularShouldShowPreviewStatistics(for: metrics.previewWidth)
        return HStack(spacing: 8) {
            if showsStats {
                regularPreviewStatisticsPill(
                    toolbarPreviewStatistics,
                    usesCompactLabel: usesCompactStats,
                    includesRenderedPages: toolbarPreviewStatisticsIncludesRenderedPages
                )
            }

            regularWorkspaceButtonCapsule(layout: actionLayout)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private func regularToolbarActionLayout(for previewWidth: CGFloat) -> RegularToolbarActionLayout {
        if previewWidth < regularToolbarMinimalActionsMaximumPreviewWidth {
            return .minimal
        } else if previewWidth < regularToolbarCompactActionsMaximumPreviewWidth {
            return .compact
        } else {
            return .full
        }
    }

    private func regularWorkspaceButtonCapsule(layout: RegularToolbarActionLayout) -> some View {
        let usesFullLayout = layout == .full
        let usesMinimalLayout = layout == .minimal
        let iconSize: CGFloat = usesFullLayout ? 44 : 40
        let iconSpacing: CGFloat = usesFullLayout ? regularToolbarActionButtonSpacing : 0

        return HStack(spacing: iconSpacing) {
            if usesFullLayout {
                Button { requestFindReplaceFromToolbar() } label: {
                    regularToolbarIconLabel("magnifyingglass", size: iconSize)
                }
                .contentShape(Rectangle())
                .accessibilityLabel(L10n.tr("action.find_replace"))
                .accessibilityIdentifier("editor.search")
            }

            Button {
                InteractionFeedback.impact(.light)
                presentAfterKeyboardDismissal {
                    showingOutline = true
                }
            } label: {
                regularToolbarIconLabel("list.bullet", size: iconSize)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.tr("outline.title"))
            .accessibilityIdentifier("editor.outline")

            if !usesMinimalLayout {
                Button {
                    presentAfterKeyboardDismissal {
                        showingSlideshow = true
                    }
                } label: {
                    regularToolbarIconLabel("play.rectangle", size: iconSize)
                }
                .contentShape(Rectangle())
                .disabled(!compiler.compiledOnce)
                .accessibilityLabel(L10n.tr("Slideshow"))
            }

            if !usesMinimalLayout {
                Button(action: shareButtonAction) {
                    regularToolbarIconLabel("square.and.arrow.up", size: iconSize)
                }
                .contentShape(Rectangle())
                .accessibilityLabel(Text(shareButtonLabel))
                .accessibilityHint(L10n.a11yEditorShareHint)
                .accessibilityIdentifier("editor.share")
            }

            Menu {
                if !usesFullLayout {
                    Section {
                        Button {
                            requestFindReplaceFromToolbar()
                        } label: {
                            Label(L10n.tr("action.find_replace"), systemImage: "magnifyingglass")
                        }
                    }
                }
                if usesMinimalLayout {
                    Section {
                        Button {
                            presentAfterKeyboardDismissal {
                                showingSlideshow = true
                            }
                        } label: {
                            Label(L10n.tr("Slideshow"), systemImage: "play.rectangle")
                        }
                        .disabled(!compiler.compiledOnce)

                        Button(action: shareButtonAction) {
                            Label(shareButtonLabel, systemImage: "square.and.arrow.up")
                        }
                    }
                }
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
                regularToolbarIconLabel("ellipsis.circle", size: iconSize)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.a11yEditorMenuLabel)
            .accessibilityHint(L10n.a11yEditorMenuHint)
            .accessibilityIdentifier("editor.more-menu")
        }
        .padding(.horizontal, 4)
        .frame(height: regularToolbarControlHeight)
        .regularToolbarCapsuleSurface()
    }

    private func regularPreviewStatisticsPill(
        _ stats: PreviewStatistics?,
        usesCompactLabel: Bool = false,
        includesRenderedPages: Bool = false
    ) -> some View {
        let pillWidth = usesCompactLabel
            ? regularToolbarPreviewStatsCompactEstimatedWidth
            : regularToolbarPreviewStatsFullEstimatedWidth
        let hasStats = stats != nil
        let isCompiling = compiler.isCompiling

        return Button {
            guard hasStats else { return }
            showingPreviewStatsDetails.toggle()
        } label: {
            HStack(spacing: 5) {
                if isCompiling {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(regularToolbarForegroundColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "doc.text")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                if let stats {
                    Text(
                        usesCompactLabel
                        ? regularPreviewStatsCompactLabel(stats.wordCount)
                        : L10n.previewStatsWords(stats.wordCount)
                    )
                        .transition(.opacity)
                } else if usesCompactLabel {
                    if !isCompiling {
                        ProgressView()
                            .controlSize(.mini)
                    }
                } else {
                    if !isCompiling {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(L10n.tr("preview.stats.words.label"))
                        .foregroundStyle(regularToolbarSecondaryForegroundColor)
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(regularToolbarForegroundColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(width: pillWidth, height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPreviewStatsDetails, arrowEdge: .top) {
            if let stats {
                regularPreviewStatisticsDetails(stats, includesRenderedPages: includesRenderedPages)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.a11yPreviewLabel)
        .accessibilityValue(regularPreviewStatisticsAccessibilityValue(stats, includesRenderedPages: includesRenderedPages))
        .accessibilityHint(hasStats ? L10n.previewStatsHintCollapsed : L10n.previewStatsLoading)
        .accessibilityIdentifier("editor.preview.stats.toolbar")
        .frame(height: regularToolbarControlHeight)
        .frame(width: pillWidth)
        .regularToolbarCapsuleSurface()
        .animation(.easeInOut(duration: 0.18), value: hasStats)
        .animation(.easeInOut(duration: 0.18), value: isCompiling)
    }

    private func regularPreviewStatsCompactLabel(_ wordCount: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: wordCount), number: .decimal)
    }

    private func regularPreviewStatisticsDetails(
        _ stats: PreviewStatistics,
        includesRenderedPages: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if includesRenderedPages {
                Text(L10n.previewStatsPages(stats.pageCount))
            }
            Text(L10n.previewStatsWords(stats.wordCount))
            Text(L10n.previewStatsCharacters(stats.characterCount))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
        .frame(minWidth: 160, alignment: .leading)
    }

    private func regularPreviewStatisticsAccessibilityValue(
        _ stats: PreviewStatistics?,
        includesRenderedPages: Bool
    ) -> String {
        guard let stats else { return L10n.previewStatsLoading }
        let words = L10n.previewStatsWords(stats.wordCount)
        let characters = L10n.previewStatsCharacters(stats.characterCount)
        if includesRenderedPages {
            return L10n.previewStatsExpandedValue(
                pages: L10n.previewStatsPages(stats.pageCount),
                words: words,
                characters: characters
            )
        }
        return "\(words), \(characters)"
    }

    private func requestFindReplaceFromToolbar() {
        focusCoordinator.activateKeyboard()
        Task { @MainActor in
            await Task.yield()
            findRequested = true
        }
    }

    private func presentAfterKeyboardDismissal(_ action: @escaping @MainActor () -> Void) {
        focusCoordinator.dismissKeyboard()
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func regularToolbarIconLabel(_ systemName: String, size: CGFloat = 44) -> some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(regularToolbarForegroundColor)
            .frame(width: size, height: regularToolbarControlHeight - 4)
    }

    @ViewBuilder
    private var compactProjectTabBar: some View {
        if openTabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(openTabs) { tab in
                        projectTabButton(tab, isCompact: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                compactProjectTabBarBackdrop
            }
            .softScrollEdgeEffect(for: .horizontal)
            .clippedHorizontally(verticalOutset: 48)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .accessibilityIdentifier("project-workspace.compact-tabs")
        }
    }

    private func regularPreviewColumn(
        topViewportInset: CGFloat = 0,
        overlayTopInset: CGFloat = 0,
        overlayBottomInset: CGFloat = 0
    ) -> some View {
        previewPane(
            topViewportInset: topViewportInset,
            overlayTopInset: overlayTopInset,
            overlayBottomInset: overlayBottomInset
        )
    }

    private var usesCompactTabsInTopChrome: Bool {
        guard sizeClass != .regular else { return false }
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    @ViewBuilder
    private var compactProjectTabBarBackdrop: some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            appChromeColor
        }
    }

    private var regularWorkspaceTopFade: some View {
        Group {
            if #available(iOS 26, *) {
                Color.clear
            } else if regularWorkspaceColorScheme == .dark {
                LinearGradient(
                    stops: [
                        .init(color: regularWorkspaceChromeColor, location: 0),
                        .init(color: regularWorkspaceChromeColor.opacity(0.74), location: 0.58),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.clear
            }
        }
        .frame(height: regularWorkspaceTopBarHeight + 24)
        .allowsHitTesting(false)
    }

    private func projectTabButton(_ tab: ProjectFileTab, isCompact: Bool) -> some View {
        let isActive = tab.relativePath == activeTabPath
        let tabForeground = isCompact ? appThemeTitleForegroundColor : regularToolbarForegroundColor
        let tabSecondaryForeground = isCompact ? appThemeTitleForegroundColor.opacity(0.68) : regularToolbarSecondaryForegroundColor
        let activeForeground = tabForeground
        let activeBackground = tabForeground.opacity(isCompact ? 0.10 : 0.075)
        let inactiveBackground = tabForeground.opacity(isCompact ? 0.025 : 0.012)
        let activeBorder = tabForeground.opacity(isCompact ? 0.26 : 0.22)
        let tabSurfaceHeight: CGFloat? = isCompact ? nil : regularProjectTabSurfaceHeight
        let tabMinimumWidth: CGFloat? = (!isCompact && openTabs.count == 1) ? regularProjectTabMinimumWidth : nil
        let tabMaximumWidth: CGFloat? = isCompact || openTabs.count == 1 ? regularProjectTabMaximumWidth : nil
        let titleMaximumWidth: CGFloat? = isCompact ? nil : regularProjectTabTitleMaximumWidth
        let shouldHugContent = !isCompact && openTabs.count > 1
        let compactTapSlop: CGFloat = 10
        let closeHitSize: CGFloat = isCompact ? 44 : regularProjectTabSurfaceHeight
        return HStack(spacing: 2) {
            Button {
                selectProjectTab(tab)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tab.kind.iconName)
                        .font(.system(size: isCompact ? 11 : 12.5, weight: .semibold))
                    Text(tab.displayName)
                        .font(isCompact ? .caption.weight(isActive ? .semibold : .medium) : .callout.weight(isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: titleMaximumWidth, alignment: .leading)
                }
                .foregroundStyle(isActive ? activeForeground : tabForeground)
                .padding(.leading, isCompact ? 8 : 9)
                .padding(.vertical, isCompact ? 7 : 6)
                .frame(minHeight: isCompact ? 34 : regularProjectTabSurfaceHeight - 4)
            }
            .buttonStyle(.plain)
            .highPriorityGestureIfEnabled(
                isCompact,
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let translation = value.translation
                        guard abs(translation.width) <= compactTapSlop,
                              abs(translation.height) <= compactTapSlop else {
                            return
                        }
                        selectProjectTab(tab)
                    }
            )

            Button {
                closeProjectTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: isCompact ? 9 : 9.5, weight: .semibold))
                    .foregroundStyle(tabSecondaryForeground.opacity(isActive ? 1 : 0.72))
                    .frame(width: closeHitSize, height: closeHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGestureIfEnabled(
                isCompact,
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let translation = value.translation
                        guard abs(translation.width) <= compactTapSlop,
                              abs(translation.height) <= compactTapSlop else {
                            return
                        }
                        closeProjectTab(tab)
                    }
            )
            .accessibilityLabel(L10n.tr("Close"))
        }
        .padding(.trailing, isCompact ? 0 : 2)
        .frame(height: tabSurfaceHeight)
        .projectTabBarSurface(
            background: isActive ? activeBackground : inactiveBackground,
            border: isActive ? activeBorder : tabSecondaryForeground.opacity(0.08),
            cornerRadius: isCompact ? 9 : 14,
            isInteractive: true
        )
        .fixedSize(horizontal: shouldHugContent, vertical: false)
        .frame(
            minWidth: tabMinimumWidth,
            maxWidth: tabMaximumWidth
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? L10n.tr("a11y.state.selected") : "")
        .accessibilityIdentifier("project-workspace.tab.\(tab.relativePath)")
    }

    private var appChromeColor: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var editorThemeTextColor: Color {
        Color(uiColor: themeManager.currentTheme.text)
    }

    private var compactNavigationChromeColor: Color {
        selectedTab == editorTab ? appChromeColor : Color(uiColor: .systemBackground)
    }

    private var compactNavigationTextColor: Color {
        appThemeTitleForegroundColor
    }

    private var compactNavigationSecondaryTextColor: Color {
        appThemeTitleForegroundColor.opacity(0.68)
    }

    private var compactNavigationColorScheme: ColorScheme {
        colorScheme
    }

    @ViewBuilder
    var contentLayout: some View {
        if sizeClass == .regular {
            if #available(iOS 26, *) {
                GeometryReader { geo in
                    let overlayTopInset = geo.safeAreaInsets.top + regularWorkspaceTopBarHeight
                    let overlayBottomInset = geo.safeAreaInsets.bottom

                    regularWorkspaceContent(
                        topViewportInset: 0,
                        overlayTopInset: overlayTopInset,
                        overlayBottomInset: overlayBottomInset
                    )
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .safeAreaBar(edge: .top, spacing: 0) {
                            regularWorkspaceTopBar
                                .frame(height: regularWorkspaceTopBarHeight)
                                .containerCornerOffsetWhenAvailable()
                        }
                        .softScrollEdgeEffect(for: .top)
                        .background(regularWorkspaceChromeColor)
                        .clipped()
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 0) {
                    regularWorkspaceTopBar
                    regularWorkspaceTopBarSeparator
                    regularWorkspaceContent(topViewportInset: 0)
                }
                .background(regularWorkspaceChromeColor)
                .ignoresSafeArea(edges: .bottom)
            }
        } else {
            GeometryReader { geo in
                let topViewportInset = geo.safeAreaInsets.top
                let overlayTopInset = topViewportInset + 56
                let overlayBottomInset = geo.safeAreaInsets.bottom
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
                    workspaceEditorPane(topViewportInset: topViewportInset)
                        .ignoresSafeArea(edges: .top)
                        .softScrollEdgeEffect()
                        .opacity(selectedTab == editorTab ? 1 : 0)
                        .allowsHitTesting(selectedTab == editorTab)
                        .accessibilityHidden(selectedTab != editorTab)
                    if selectedTab == previewTab {
                        previewPane(
                            topViewportInset: topViewportInset,
                            overlayTopInset: overlayTopInset,
                            overlayBottomInset: overlayBottomInset
                        )
                            .ignoresSafeArea(edges: .top)
                            .softScrollEdgeEffect()
                            .transition(.identity)
                            .accessibilityHidden(false)
                    }
                }
                .animation(nil, value: selectedTab)
                .simultaneousGesture(compactModeSwipeGesture)
            }
        }
    }

    private func regularWorkspaceContent(
        topViewportInset: CGFloat,
        overlayTopInset: CGFloat = 0,
        overlayBottomInset: CGFloat = 0
    ) -> some View {
        GeometryReader { geo in
            let metrics = regularWorkspaceMetrics(totalWidth: geo.size.width)
            HStack(spacing: 0) {
                if isProjectFileTreeVisible {
                    projectFileTreeSidebar(topContentInset: topViewportInset)
                        .frame(width: metrics.treeWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                        .transition(.opacity)
                }
                HStack(spacing: 0) {
                    workspaceEditorPane(topViewportInset: topViewportInset)
                        .softScrollEdgeEffect()
                        .frame(width: metrics.editorWidth)
                        .clipped()
                    splitHandle(totalWidth: metrics.workspaceWidth)
                    regularPreviewColumn(
                        topViewportInset: topViewportInset,
                        overlayTopInset: overlayTopInset,
                        overlayBottomInset: overlayBottomInset
                    )
                        .softScrollEdgeEffect()
                }
                .coordinateSpace(name: "splitContainer")
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(regularWorkspaceChromeColor)
            .overlay(alignment: .topLeading) {
                if topViewportInset > 0, isProjectFileTreeVisible {
                    regularWorkspaceTopFade
                        .frame(width: metrics.treeWidth + metrics.treeDividerWidth, alignment: .leading)
                }
            }
        }
    }

    private var regularWorkspaceTopChromePlate: some View {
        regularWorkspaceTopBarBackdrop
            .frame(maxWidth: .infinity, minHeight: regularWorkspaceTopHitHeight, maxHeight: regularWorkspaceTopHitHeight, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func regularWorkspaceTabsOverlay(metrics: RegularWorkspaceMetrics) -> some View {
        if openTabs.count > 1 {
            let tabStartX = metrics.projectHeaderWidth + regularTabOverlayLeadingInset
            let tabEndX = max(
                metrics.previewStartX,
                metrics.totalWidth - regularToolbarTrailingReservedWidth(for: metrics) - regularTabOverlayTrailingInset
            )
            let tabWidth = max(tabEndX - tabStartX, 1)
            regularEditorTabOverlay
                .frame(width: tabWidth, height: regularWorkspaceTopBarHeight, alignment: .center)
                .clippedHorizontally(verticalOutset: 48)
                .position(
                    x: tabStartX + tabWidth / 2,
                    y: regularWorkspaceTopBarHeight / 2
                )
                .accessibilityIdentifier("project-workspace.tabs-overlay")
        }
    }

    private var regularEditorTabOverlay: some View {
        regularToolbarTabBar
            .padding(.horizontal, 12)
            .frame(height: regularWorkspaceTopBarHeight)
            .frame(maxWidth: .infinity, alignment: .center)
            .background {
                regularWorkspaceTopBarBackdrop
            }
            .overlay(alignment: .leading) {
                regularTabOverlayEdgeFade(isLeading: true)
            }
            .overlay(alignment: .trailing) {
                regularTabOverlayEdgeFade(isLeading: false)
            }
            .liquidGlassColorScheme(regularWorkspaceColorScheme)
    }

    private func regularTabOverlayEdgeFade(isLeading: Bool) -> some View {
        Group {
            if #available(iOS 26, *) {
                Color.clear
            } else {
                LinearGradient(
                    colors: isLeading
                        ? [regularWorkspaceChromeColor, regularWorkspaceChromeColor.opacity(0)]
                        : [regularWorkspaceChromeColor.opacity(0), regularWorkspaceChromeColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
            .frame(width: regularTabOverlayEdgeFadeWidth)
            .frame(maxHeight: regularWorkspaceTopHitHeight)
            .allowsHitTesting(false)
    }

    private func regularToolbarTrailingReservedWidth(for metrics: RegularWorkspaceMetrics) -> CGFloat {
        let actionLayout = regularToolbarActionLayout(for: metrics.previewWidth)
        let iconSize: CGFloat = actionLayout == .full ? 44 : 40
        let visibleActionCount: CGFloat
        switch actionLayout {
        case .full:
            visibleActionCount = 5
        case .compact:
            visibleActionCount = 4
        case .minimal:
            visibleActionCount = 2
        }
        let iconSpacing = actionLayout == .full ? regularToolbarActionButtonSpacing : 0
        let actionCapsuleWidth = visibleActionCount * iconSize
            + max(visibleActionCount - 1, 0) * iconSpacing
            + regularToolbarActionCapsuleHorizontalPadding
        let showsStats = regularShouldShowPreviewStatistics(for: metrics.previewWidth)
        let statsWidth: CGFloat
        if showsStats {
            statsWidth = metrics.previewWidth < regularPreviewStatsFullMinimumPreviewWidth
                ? regularToolbarPreviewStatsCompactEstimatedWidth
                : regularToolbarPreviewStatsFullEstimatedWidth
        } else {
            statsWidth = 0
        }
        let statsSpacing: CGFloat = showsStats ? 8 : 0
        return 24 + statsWidth + statsSpacing + actionCapsuleWidth
    }

    private func regularWorkspaceMetrics(totalWidth: CGFloat) -> RegularWorkspaceMetrics {
        let expandedTreeWidth = min(max(totalWidth * 0.22, 240), 320)
        let treeWidth = isProjectFileTreeVisible ? expandedTreeWidth : 0
        let treeDividerWidth: CGFloat = isProjectFileTreeVisible ? 1 : 0
        let collapsedHeaderWidth = min(
            max(totalWidth * 0.17, regularCollapsedProjectHeaderMinimumWidth),
            regularCollapsedProjectHeaderMaximumWidth
        )
        let projectHeaderWidth = collapsedHeaderWidth
        let workspaceWidth = max(totalWidth - treeWidth - treeDividerWidth, 1)
        let maximumEditorWidth = max(workspaceWidth - regularSplitHandleWidth - 1, 1)
        let minimumEditorWidth = isProjectFileTreeVisible
            ? 1
            : min(projectHeaderWidth + regularTabOverlayLeadingInset, maximumEditorWidth)
        let editorWidth = min(max(workspaceWidth * editorFraction, minimumEditorWidth), maximumEditorWidth)
        return RegularWorkspaceMetrics(
            totalWidth: totalWidth,
            treeWidth: treeWidth,
            treeDividerWidth: treeDividerWidth,
            projectHeaderWidth: projectHeaderWidth,
            workspaceWidth: workspaceWidth,
            editorWidth: editorWidth,
            splitHandleWidth: regularSplitHandleWidth
        )
    }

    @ViewBuilder
    private var regularWorkspaceTopBarSeparator: some View {
        if #available(iOS 26, *) {
            EmptyView()
        } else {
            Divider()
                .overlay(regularToolbarSecondaryForegroundColor.opacity(0.28))
        }
    }

    private var compactModeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 35, coordinateSpace: .local)
            .onEnded { value in
                guard !(selectedTab == editorTab && focusCoordinator.isTextSelectionDragActive) else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let startsAwayFromLeadingEdge = value.startLocation.x > 44
                guard abs(horizontal) >= 70, abs(horizontal) > abs(vertical) * 1.35 else { return }

                if horizontal < 0, selectedTab == editorTab, startsAwayFromLeadingEdge {
                    pendingCompactSwipeFeedback = true
                    selectedTab = previewTab
                } else if horizontal > 0, selectedTab == previewTab, startsAwayFromLeadingEdge {
                    pendingCompactSwipeFeedback = true
                    selectedTab = editorTab
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

    private func regularShouldShowPreviewStatistics(for previewWidth: CGFloat) -> Bool {
        sizeClass == .regular
            && !previewRequiresExternalFolderLink
            && previewWidth >= regularPreviewStatsCompactMinimumPreviewWidth
            && !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var toolbarPreviewStatisticsIncludesRenderedPages: Bool {
        compiler.pdfDocument != nil
    }

    private var toolbarPreviewStatistics: PreviewStatistics? {
        guard sizeClass == .regular,
              !previewRequiresExternalFolderLink,
              previewStatsAreReady,
              !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return PreviewStatistics(
            pageCount: max(compiler.pdfDocument?.pageCount ?? 0, 0),
            wordCount: previewStatsWordCount,
            characterCount: previewStatsCharacterCount
        )
    }

    private func recomputePreviewStatistics() {
        guard sizeClass == .regular else { return }
        let text = entrySource
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewStatsWordCount = 0
            previewStatsCharacterCount = 0
            previewStatsAreReady = false
            return
        }
        previewStatsAreReady = false
        Task.detached(priority: .utility) {
            let wordCount = text.previewWordCount
            let characterCount = text.previewCharacterCount
            await MainActor.run {
                guard entrySource == text else { return }
                previewStatsWordCount = wordCount
                previewStatsCharacterCount = characterCount
                previewStatsAreReady = true
            }
        }
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
                    .foregroundStyle(.primary)
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
        Menu {
            editorToolbarMenuContent
        } label: {
            HStack(alignment: .center, spacing: 4) {
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
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(compactNavigationSecondaryTextColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 176, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.title)
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
        let editorChrome = contentLayout
            .navigationTitle(document.title)
            .navigationSubtitleCompat(usesSystemCompactToolbar ? "" : navigationEditorSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConditionalToolbarRoleModifier(usesEditorRole: !usesSystemCompactToolbar))
            .modifier(EditorNavigationBarBackgroundModifier(
                usesCompactChrome: usesSystemCompactToolbar,
                background: compactNavigationChromeColor,
                colorScheme: compactNavigationColorScheme
            ))
            .modifier(ConditionalNavigationBarVisibilityModifier(hidesNavigationBar: sizeClass == .regular))
            .tint(usesSystemCompactToolbar ? compactNavigationTextColor : regularToolbarForegroundColor)
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

        let chrome: AnyView = if sizeClass == .regular {
            AnyView(compactTabsTopChrome(editorChrome.toolbar(.hidden, for: .navigationBar)))
        } else {
            AnyView(compactTabsTopChrome(editorChrome))
        }

        return chrome
    }

    @ViewBuilder
    private func compactTabsTopChrome<Content: View>(_ content: Content) -> some View {
        if sizeClass != .regular, openTabs.count > 1, #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) {
                    compactProjectTabBar
                }
                .softScrollEdgeEffect(for: .top)
        } else {
            content
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
                restoreProjectEditorStateIfNeeded()
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
                persistProjectEditorTabState()
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
            .onChange(of: entrySource, initial: true) {
                recomputePreviewStatistics()
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
            .onChange(of: openTabs) { _, _ in
                persistProjectEditorTabState()
            }
            .onChange(of: activeTabPath) { _, _ in
                persistProjectEditorTabState()
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
                if pendingCompactSwipeFeedback {
                    pendingCompactSwipeFeedback = false
                    InteractionFeedback.impact(.light)
                } else {
                    InteractionFeedback.selection()
                }
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
                } else {
                    showingPreviewStatsDetails = false
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
                OutlineView(
                    editorText: editorText,
                    projectID: document.projectID,
                    fileName: currentFileName
                ) { offset in
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
            .fileImporter(
                isPresented: $showingProjectFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleProjectFileImportFromMenu(result)
            }
            .fullScreenCover(isPresented: $showingSlideshow) {
                if let pdf = compiler.pdfDocument {
                    SlideshowView(document: pdf)
                }
            }
            .alert("New Source File", isPresented: $showingNewProjectFileAlert) {
                TextField("filename.typ", text: $newProjectFileName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Create") { createNewProjectFileFromMenu() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new .typ file.")
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
