//
//  DocumentEditorView+Layout.swift
//  InkPond
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// Local file-rail tokens; editor and application theme definitions are untouched.
private struct FileTabPalette {
    let rail: Color
    let selected: Color
    let text: Color
    let secondary: Color
    let separator: Color

    init(theme: EditorTheme, scheme: ColorScheme, increasedContrast: Bool) {
        let dark = scheme == .dark
        if theme.id == "system" {
            rail = Color(uiColor: UIColor(hex: dark ? "#1C1C1E" : "#F2F2F7"))
            selected = ProjectFileSelectionSurface.fill(
                panel: UIColor(hex: dark ? "#1C1C1E" : "#F2F2F7"), scheme: scheme)
            text = Color(uiColor: UIColor(hex: dark ? "#FFFFFF" : "#1C1C1E"))
            secondary = Color(uiColor: UIColor(hex: dark ? "#AEAEB2" : "#636366"))
            separator = Color(uiColor: UIColor(hex: dark ? "#38383A" : "#D1D1D6"))
        } else {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let base = theme.gutterBackground.resolvedColor(with: traits)
            let foreground = theme.text.resolvedColor(with: traits)
            func blend(_ fraction: CGFloat) -> UIColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
                base.getRed(&r, green: &g, blue: &b, alpha: &a)
                foreground.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
                return UIColor(red: r + (fr-r)*fraction, green: g + (fg-g)*fraction,
                               blue: b + (fb-b)*fraction, alpha: 1)
            }
            rail = Color(uiColor: base)
            selected = ProjectFileSelectionSurface.fill(panel: base, scheme: scheme, primary: foreground)
            text = Color(uiColor: foreground)
            // Existing primary text is the contrast-safe secondary fallback for
            // custom palettes; never attenuate it with an arbitrary opacity.
            secondary = Color(uiColor: foreground)
            separator = Color(uiColor: blend(0.15))
        }
    }
}

// Measure SwiftUI's rendered text, not a guessed line count: middle-truncated
// unbroken filenames can remain one line even with lineLimit(2).
private struct FileTabContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FileTabRailHeight: ViewModifier {
    @State private var tabHeight: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .frame(height: tabHeight + 8)
            .onPreferenceChange(FileTabContentHeightKey.self) { height in
                let measured = max(44, ceil(height + 16))
                if tabHeight != measured { tabHeight = measured }
            }
    }
}


private struct FileTabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

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


}

enum EditorToolbarLayout {
    static func isCompact(sizeClass: UserInterfaceSizeClass?, containerWidth: CGFloat) -> Bool {
        sizeClass == .compact || (containerWidth > 0 && containerWidth < 572)
    }
}

extension DocumentEditorView {
    // Follow the space offered to this editor, including narrow regular-width windows.
    var usesCompactEditorToolbar: Bool {
        EditorToolbarLayout.isCompact(sizeClass: sizeClass, containerWidth: workspaceContainerWidth)
    }

    private var isSplitWorkspace: Bool { sizeClass == .regular && workspaceContainerWidth >= 572 }
    private var isTreeFitting: Bool {
        workspaceContainerWidth >= 813
            && workspaceContainerWidth - min(max(workspaceContainerWidth * 0.22, 240), 320) - 1 >= 572
    }
    private var showsProjectFileTree: Bool { isSplitWorkspace && isTreeFitting && isProjectFileTreeVisible }
    private var isSyncEnabled: Bool { isSplitWorkspace }
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
        !isSplitWorkspace
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

    func editorPane(topViewportInset: CGFloat = 0, allowsSourceUnderlap: Bool = false) -> some View {
        // Read in the owning view's evaluation, not only the deferred geometry
        // closure, so extent changes invalidate that closure's layout proposal.
        let sourceUnderlapExtent = allowsSourceUnderlap ? sourceAccessoryUnderlap : 0
        return GeometryReader { sourceSlot in
        EditorView(
            text: $editorText,
            insertionRequest: $insertionRequest,
            findRequested: $findRequested,
            viewState: $editorViewState,
            cursorJumpOffset: $pendingCursorJump,
            fileLoadToken: fileLoadToken,
            focusCoordinator: focusCoordinator,
            commandTarget: commandTarget,
            isAccessibilityExcluded: commandPanelOwnsInteraction,
            sourceUnderlap: sourceUnderlapExtent,
            onSourceUnderlapChanged: { extent in
                sourceAccessoryUnderlap = extent
                guard KeyboardAccessoryView.geometryDiagnosticsEnabled else { return "" }
                return "stateReadback=\(sourceAccessoryUnderlap) allowsSourceUnderlap=\(allowsSourceUnderlap)"
            },
            topViewportInset: topViewportInset,
            sourceMap: isSyncEnabled && isEditingEntryFile ? compiler.sourceMap : nil,
            syncCoordinator: isSyncEnabled ? syncCoordinator : nil,
            theme: themeManager.currentTheme,
            externalChromeBackgroundColor: editorExternalChromeBackgroundUIColor,
            editorFont: editorFontSettings.uiFont,
            errorLines: compilationErrorLines,
            isEditable: projectWritableLease != nil,
            onUserInteraction: { lastInteractedWorkspacePane = .editor },
            onPhotoTapped: presentCommandPhoto,
            onSnippetTapped: presentCommandSnippets,
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
        .frame(width: sourceSlot.size.width, height: sourceSlot.size.height + sourceUnderlapExtent, alignment: .top)
        }
        .accessibilityHidden(commandPanelOwnsInteraction)
        .allowsHitTesting(!commandPanelOwnsInteraction)
        .overlay {
            EditorCommandRegionHost(panel: commandPanel,
                                    interactionEnabled: commandPanelOwnsInteraction) {
                safeEditorCommandPanel
            }
        }
        .overlay(alignment: .topLeading) {
            if KeyboardAccessoryView.geometryDiagnosticsEnabled {
                EditorCommandDiagnosticValue(value:
                    "needsPanel=\(commandGeometry?.needsPanel.description ?? "pending") canPresent=\(commandPanelCanPresent)\n"
                    + commandGeometryDiagnosticSamples.joined(separator: "\n"))
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(EditorCommandGeometryKey.self) { geometry in
            // Keyboard/search and safe pose changes reflow the existing panel;
            // only an unusable region invalidates it. Search focus must not
            // discard its own browser when the keyboard changes safe insets.
            commandGeometry = geometry
            observeCommandSessionGeometry(geometry)
            recordCommandGeometryDiagnostic(event: "geometry", geometry: geometry)
            resumePendingCommandOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            commandKeyboardTransitionInFlight = true
            recordCommandKeyboardDiagnostic(notification, phase: "willChangeFrame")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            commandKeyboardTransitionInFlight = false
            recordCommandKeyboardDiagnostic(notification, phase: "didChangeFrame")
            resumePendingCommandOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            commandKeyboardTransitionInFlight = false
            resumePendingCommandOpen()
        }
        .onChange(of: editorText) { _, source in
            if commandSessionSafety.awaitingExplicitResume { commandAnchor = nil }
            if let pending = commandPendingOpen, pending.source != source {
                closeCommandPanel(restoreFocus: false)
            }
        }
        .onChange(of: editorViewState.selectedLocation) { _, _ in
            if commandSessionSafety.awaitingExplicitResume { commandAnchor = nil }
            resumePendingCommandOpen()
        }
        .onChange(of: editorViewState.selectedLength) { _, _ in
            if commandSessionSafety.awaitingExplicitResume { commandAnchor = nil }
            resumePendingCommandOpen()
        }
        .onChange(of: fileLoadToken) { _, _ in invalidateCommandContextAfterFileChange() }
        .onChange(of: currentFileName) { _, _ in invalidateCommandContextAfterFileChange() }
        .onDisappear { closeCommandPanel(restoreFocus: false) }
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
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var editorExternalChromeBackgroundUIColor: UIColor {
        isSplitWorkspace ? regularWorkspaceChromeUIColor : .secondarySystemGroupedBackground
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
            refreshCacheBypassToken: linkedFolderRefreshCacheBypassToken,
            requiresExternalFolderLink: previewRequiresExternalFolderLink,
            drivesCompilation: false,
            // A layout transition is not a document close; keep the current preview alive.
            cancelsCompilerOnDisappear: false,
            focusCoordinator: focusCoordinator,
            sourceMap: isSyncEnabled ? compiler.sourceMap : nil,
            syncCoordinator: syncCoordinator,
            entryFileName: document.entryFileName,
            topViewportInset: topViewportInset,
            overlayTopInset: overlayTopInset,
            overlayBottomInset: overlayBottomInset,
            onGoToError: { file, line, column in
                Task { await navigateToError(file: file, line: line, column: column) }
            },
            onCompactPreviewSwipe: isSplitWorkspace ? nil : {
                if selectedTab != editorTab {
                    pendingCompactSwipeFeedback = true
                    selectedTab = editorTab
                }
            },
            onLinkExternalFolder: previewRequiresExternalFolderLink ? {
                showingExternalFolderLinkImporter = true
            } : nil,
            showsStatisticsOverlay: !isSplitWorkspace,
            showsCompilingIndicatorOverlay: !isSplitWorkspace,
            backgroundColor: isSplitWorkspace ? regularWorkspaceChromeUIColor : .secondarySystemBackground,
            isAccessibilityVisible: isSplitWorkspace || selectedTab == previewTab
        )
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            lastInteractedWorkspacePane = .preview
        })
        .environment(\.colorScheme, isSplitWorkspace ? regularWorkspaceColorScheme : colorScheme)
        .liquidGlassColorScheme(isSplitWorkspace ? regularWorkspaceColorScheme : colorScheme)
    }

    func linkExternalFolderForPreview(from folderURL: URL) async {
        guard await flushPendingSave() else { return }
        externalFolderLinkTask?.cancel()
        let operationID = beginExternalFolderLinkOperation()
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
                        guard document.projectID == projectID,
                              externalFolderLinkGeneration.isCurrent(operationID) else { return }
                        externalFolderLinkProgress = progress
                    }
                }

                try Task.checkCancellation()
                guard externalFolderLinkGeneration.isCurrent(operationID) else { return }

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
                clearExternalFolderLinkProgress(projectID: projectID, operationID: operationID)
                InteractionFeedback.notify(.success)
            } catch is CancellationError {
                clearExternalFolderLinkProgress(projectID: projectID, operationID: operationID)
            } catch let error as ExternalFolderLinkError {
                guard externalFolderLinkGeneration.isCurrent(operationID) else { return }
                clearExternalFolderLinkProgress(projectID: projectID, operationID: operationID)
                previewActionError = error.localizedDescription
                InteractionFeedback.notify(.error)
            } catch {
                guard externalFolderLinkGeneration.isCurrent(operationID) else { return }
                BookmarkManager.removeBookmark(projectID: projectID)
                clearExternalFolderLinkProgress(projectID: projectID, operationID: operationID)
                previewActionError = error.localizedDescription
                InteractionFeedback.notify(.error)
            }
        }
    }

    func refreshLinkedExternalFolder() {
        linkedFolderRefreshCoordinator.start(
            .init(projectID: document.projectID, title: document.title)
        ) { effect in
            applyLinkedFolderRefreshEffect(effect)
        }
    }

    private func applyLinkedFolderRefreshEffect(
        _ effect: LinkedFolderRefreshCoordinator.Effect
    ) {
        switch effect {
        case .cancelPreviewCompilation:
            compiler.cancel()

        case .applyWorkspaceRefresh(let workspace):
            guard document.projectID == workspace.projectID else { return }

            let refreshedEditorState = workspace.applying(
                to: LinkedFolderRefreshCoordinator.WorkspaceEditorState(
                    editorText: editorText,
                    entrySource: entrySource,
                    fontFileNames: document.fontFileNames
                )
            )
            if editorText != refreshedEditorState.editorText {
                editorText = refreshedEditorState.editorText
            }
            if entrySource != refreshedEditorState.entrySource {
                entrySource = refreshedEditorState.entrySource
            }

            if workspace.targets.contains(.fileTree) {
                projectFileTreeRefreshToken = UUID()
            }
            if workspace.targets.contains(.referenceCompletions) {
                refreshReferenceCompletions()
            }
            if workspace.targets.contains(.fonts) {
                if document.fontFileNames != refreshedEditorState.fontFileNames {
                    document.fontFileNames = refreshedEditorState.fontFileNames
                }
                scheduleAvailableFontFamilyRefresh()
                _ = refreshResolvedFonts(includeAvailableFamilies: false)
            }

            if canTriggerPreviewActions {
                pendingManualCompileFeedback = true
            }
            if workspace.compileRequest == .bypassCacheOnce {
                linkedFolderRefreshCacheBypassToken = UUID()
            }
            InteractionFeedback.notify(.success)
            AccessibilitySupport.announce(workspace.completionProgress.localizedStatusMessage)

        case .presentFailure(let projectID, let message):
            guard document.projectID == projectID else { return }
            previewActionError = message
            InteractionFeedback.notify(.error)
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

    private func clearExternalFolderLinkProgress(projectID: String, operationID: UUID) {
        guard document.projectID == projectID else { return }
        var generation = externalFolderLinkGeneration
        guard generation.finish(operationID) else { return }
        externalFolderLinkGeneration = generation
        externalFolderLinkProgress = nil
        externalFolderLinkProgressTitle = nil
        externalFolderLinkTask = nil
    }

    private func beginExternalFolderLinkOperation() -> UUID {
        var generation = externalFolderLinkGeneration
        let operationID = generation.begin()
        externalFolderLinkGeneration = generation
        return operationID
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
                let paneWidth = max(totalWidth - regularSplitHandleWidth, 560)
                let treeOffset = showsProjectFileTree ? regularWorkspaceMetrics(totalWidth: workspaceContainerWidth).treeWidth + 1 : 0
                let raw = (value.location.x - treeOffset - regularSplitHandleWidth / 2) / paneWidth
                withTransaction(Transaction(animation: nil)) {
                    editorFraction = min(1 - 280 / max(totalWidth - regularSplitHandleWidth, 560),
                                         max(280 / max(totalWidth - regularSplitHandleWidth, 560), raw))
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
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { editorFraction.isFinite ? min(max(editorFraction, 0), 1) : 0.5 },
                    set: { value in
                        let minimum = 280 / max(totalWidth - regularSplitHandleWidth, 560)
                        InteractionFeedback.selection()
                        editorFraction = min(1 - minimum, max(minimum, value))
                    }
                ),
                in: 0...1,
                step: 0.1
            )
            .accessibilityLabel(L10n.a11yEditorSplitLabel)
            .accessibilityHint(L10n.a11yEditorSplitHint + " " + splitHandleAccessibilityDescription)
            .accessibilityIdentifier("editor.split-handle")
            .accessibilityAction(named: Text(L10n.a11yEditorSplitReset)) {
                InteractionFeedback.impact(.medium)
                editorFraction = 0.5
            }
        }
    }

    @ViewBuilder
    func workspaceEditorPane(topViewportInset: CGFloat = 0, allowsSourceUnderlap: Bool = false) -> some View {
        VStack(spacing: 0) {
            if openTabs.count > 1 {
                compactProjectTabBar
            }
            if activeTabIsTextEditable {
                editorPane(topViewportInset: topViewportInset, allowsSourceUnderlap: allowsSourceUnderlap)
        } else if let tab = activeProjectTab {
            ProjectFilePreviewView(
                tab: tab,
                url: try? ProjectFileManager.projectFileURL(relativePath: tab.relativePath, for: document),
                topViewportInset: topViewportInset,
                backgroundColor: regularWorkspaceChromeUIColor
            )
        } else {
            editorPane(topViewportInset: topViewportInset, allowsSourceUnderlap: allowsSourceUnderlap)
        }
        }
        .animation(.smooth(duration: 0.22, extraBounce: 0), value: openTabs.count)
    }

    @ViewBuilder
    private func projectFileTreeSidebar(topContentInset: CGFloat = 0) -> some View {
        ProjectFileTreeView(
            document: document,
            activePath: activeProjectPath,
            canMutate: projectWritableLease != nil,
            openNode: openProjectFile,
            setEntryFile: setEntryProjectFile,
            createFile: createProjectFileReliably,
            importFile: importProjectFileReliably,
            deleteNode: deleteProjectNodeReliably,
            onNodeDeleted: handleProjectFileDeleted,
            refreshLinkedFolder: refreshLinkedExternalFolder,
            isRefreshingLinkedFolder: linkedFolderRefreshCoordinator.isRefreshing || externalFolderLinkTask != nil,
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
            HStack(spacing: 4) {
                ForEach(openTabs) { tab in
                    projectTabButton(tab, isCompact: false)
                        .background {
                            ProjectTabNativeReveal(request: projectTabRevealRequest,
                                                   isActive: tab.relativePath == activeTabPath)
                        }
                        .id(tab.relativePath)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .transaction { $0.disablesAnimations = true }
        .accessibilityIdentifier("project-workspace.tab-strip")
        .scrollClipDisabled()
        .softScrollEdgeEffect(for: .horizontal)
        .modifier(FileTabRailHeight())
        .background(fileTabPalette.rail)
        .overlay(alignment: .bottom) { fileTabPalette.separator.frame(height: 1 / max(UITraitCollection.current.displayScale, 1)).allowsHitTesting(false) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { viewport in
                Color.clear
                    .onChange(of: viewport.size, initial: true) { _, _ in
                        revealActiveProjectTab()
                    }
            }
        }
        .onChange(of: activeTabPath, initial: true) { _, _ in revealActiveProjectTab() }
        .onChange(of: openTabs) { _, _ in revealActiveProjectTab() }
        .onChange(of: dynamicTypeSize) { _, _ in revealActiveProjectTab() }
        .onChange(of: showingFileBrowser) { _, isPresented in
            if !isPresented { revealActiveProjectTab() }
        }
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
            if isTreeFitting {
                regularProjectFileTreeToggleButton
            }

            if let onCloseProject {
                Button {
                    Task {
                        guard await flushPendingSave() else { return }
                        onCloseProject()
                    }
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
            projectTitleMenuContent
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
                .disabled(!canPresentSlideshow)
                .accessibilityLabel(L10n.tr("Slideshow"))
            }

            if !usesMinimalLayout {
                Button(action: shareButtonAction) {
                    regularShareToolbarLabel(size: iconSize)
                }
                .contentShape(Rectangle())
                .disabled(exporter.exportButtonPhase != .idle)
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
                        .disabled(!canPresentSlideshow)

                        Button(action: shareButtonAction) {
                            Label(shareButtonLabel, systemImage: shareMenuSystemImage)
                        }
                        .disabled(exporter.exportButtonPhase != .idle)
                    }
                }
                Section {
                    Button {
                        Task { @MainActor in
                            await Task.yield()
                            await compilePreviewNow()
                        }
                    } label: {
                        Label(L10n.tr("Compile Now"), systemImage: "play.circle")
                    }
                    .disabled(!canTriggerPreviewActions)

                    Button {
                        Task { @MainActor in
                            await Task.yield()
                            await clearCachesAndRecompile()
                        }
                    } label: {
                        Label(L10n.tr("Recompile"), systemImage: "arrow.clockwise.circle")
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
        let isUpdatingPreview = compiler.isPreviewUpdating && !hasStats

        return Button {
            guard hasStats else { return }
            showingPreviewStatsDetails.toggle()
        } label: {
            HStack(spacing: 5) {
                if isUpdatingPreview {
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
                    if !isUpdatingPreview {
                        ProgressView()
                            .controlSize(.mini)
                    }
                } else {
                    if !isUpdatingPreview {
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
        .animation(.easeInOut(duration: 0.18), value: isUpdatingPreview)
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
    private func regularShareToolbarLabel(size: CGFloat = 44) -> some View {
        ZStack {
            regularToolbarIconLabel("square.and.arrow.up", size: size)
                .opacity(exporter.exportButtonPhase == .idle ? 1 : 0)
                .scaleEffect(exporter.exportButtonPhase == .idle ? 1 : 0.84)

            ProgressView()
                .controlSize(.small)
                .tint(regularToolbarForegroundColor)
                .frame(width: size, height: regularToolbarControlHeight - 4)
                .opacity(exporter.exportButtonPhase == .exporting ? 1 : 0)
                .scaleEffect(exporter.exportButtonPhase == .exporting ? 1 : 0.84)

            regularToolbarIconLabel("checkmark", size: size)
                .opacity(exporter.exportButtonPhase == .completed ? 1 : 0)
                .scaleEffect(exporter.exportButtonPhase == .completed ? 1 : 0.84)
        }
        .frame(width: size, height: regularToolbarControlHeight - 4)
        .animation(.easeInOut(duration: 0.18), value: exporter.exportButtonPhase)
    }

    @ViewBuilder
    private var compactProjectTabBar: some View {
        if openTabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(openTabs) { tab in
                        projectTabButton(tab, isCompact: true)
                            .background {
                                ProjectTabNativeReveal(request: projectTabRevealRequest,
                                                       isActive: tab.relativePath == activeTabPath)
                            }
                            .id(tab.relativePath)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .transaction { $0.disablesAnimations = true }
            .accessibilityIdentifier("project-workspace.tab-strip")
            .modifier(FileTabRailHeight())
            .background(fileTabPalette.rail)
            .overlay(alignment: .bottom) { fileTabPalette.separator.frame(height: 1 / max(UITraitCollection.current.displayScale, 1)).allowsHitTesting(false) }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onChange(of: geometry.size) { _, _ in
                            revealActiveProjectTab()
                        }
                }
            }
            .onChange(of: activeTabPath, initial: true) { _, _ in
                revealActiveProjectTab()
            }
            .onChange(of: openTabs) { _, _ in
                revealActiveProjectTab()
            }
            .onChange(of: showingFileBrowser) { _, isPresented in
                if !isPresented { revealActiveProjectTab() }
            }
            .onChange(of: dynamicTypeSize) { _, _ in
                revealActiveProjectTab()
            }
        }
    }

    private func revealActiveProjectTab() {
        // A request is not a two-way scroll-position binding: native scrolling
        // must not replace the selected path while the tab layout is changing.
        projectTabRevealRequest = UUID()
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
        guard !isSplitWorkspace else { return false }
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

    // Design #991: measure at semibold regardless of selection so selecting a
    // file changes only its surface and weight, never its geometry.
    private var fileTabFontTraits: UITraitCollection {
        let category: UIContentSizeCategory
        switch dynamicTypeSize {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = .large
        }
        return UITraitCollection(preferredContentSizeCategory: category)
    }

    private var fileTabPalette: FileTabPalette {
        FileTabPalette(theme: themeManager.currentTheme, scheme: colorScheme,
                       increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled)
    }

    private func projectTabButton(_ tab: ProjectFileTab, isCompact: Bool) -> some View {
        let isActive = tab.relativePath == activeTabPath
        let distinct = tab.distinctDisplayName(in: openTabs,
                                              preservingFilenameTail: dynamicTypeSize.isAccessibilitySize)
        let parent = distinct.contains("/") ? (distinct as NSString).deletingLastPathComponent : nil
        let title = parent == nil ? distinct : tab.displayName
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: fileTabFontTraits)
        let measured = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)]).width
        let captionWidth = ((parent ?? "") as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: fileTabFontTraits)]).width
        let idealWidth = min(max(max(measured, captionWidth) + 64, 144), dynamicTypeSize.isAccessibilitySize ? 320 : 240)
        let palette = fileTabPalette
        return HStack(spacing: 0) {
            Button {
                Task { await selectProjectTab(tab) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                    if let parent {
                        Text(parent)
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: FileTabContentHeightKey.self,
                                               value: geometry.size.height)
                    }
                }
                .foregroundStyle(isActive ? palette.text : palette.secondary)
                .padding(.vertical, 8)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FileTabPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(tab.relativePath)
            .accessibilityValue(isActive ? L10n.tr("a11y.state.selected") : "")
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .accessibilityIdentifier("project-workspace.tab.\(tab.relativePath)")

            Button {
                Task { await closeProjectTab(tab) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 16 : 12, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 44)
                    .frame(minHeight: 44, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FileTabPressStyle())
            .accessibilityLabel("\(L10n.tr("Close")), \(tab.relativePath)")
            .accessibilityIdentifier("project-workspace.close-tab.\(tab.relativePath)")
        }
        .containerRelativeFrame(.horizontal) { width, _ in
            min(idealWidth, max(88, width - 16))
        }
        .background(isActive ? palette.selected : .clear)
        .clipShape(RoundedRectangle(cornerRadius: ProjectFileSelectionSurface.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
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

    var contentLayout: some View {
        GeometryReader { geo in
            let split = sizeClass == .regular && geo.size.width >= 572
            let metrics = regularWorkspaceMetrics(totalWidth: geo.size.width)
            let treeWidth = split ? metrics.treeWidth + metrics.treeDividerWidth : 0
            let editorWidth = split ? metrics.editorWidth : geo.size.width
            let previewWidth = split ? metrics.previewWidth : geo.size.width
            ZStack(alignment: .topLeading) {
                PreviewCompileDriver(
                    compiler: compiler, source: entrySource,
                    compileSource: CompileFontResolver.effectiveSource(for: entrySource, resolvedFonts: resolvedCompileFonts),
                    fontPaths: resolvedCompileFonts.fontPaths, preflightError: fontResolutionError,
                    rootDir: rootDir, previewCacheDescriptor: compiledPreviewCacheDescriptor,
                    compileToken: compileToken, refreshCacheBypassToken: linkedFolderRefreshCacheBypassToken,
                    requiresExternalFolderLink: previewRequiresExternalFolderLink
                )
                workspaceEditorPane(allowsSourceUnderlap: true)
                    // Preserve pane identity/state, but exclude the inactive native subtree.
                    .accessibilityHidden(!split && selectedTab != editorTab)
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        lastInteractedWorkspacePane = .editor
                    })
                    .frame(width: editorWidth, height: geo.size.height)
                    .clippedHorizontally(verticalOutset: activeTabIsTextEditable ? sourceAccessoryUnderlap : 0)
                    .offset(x: treeWidth)
                    .opacity(split || selectedTab == editorTab ? 1 : 0)
                    .allowsHitTesting(split || selectedTab == editorTab)
                previewPane()
                    .accessibilityHidden(!split && selectedTab != previewTab)
                    .frame(width: previewWidth, height: geo.size.height)
                    .clipped()
                    .offset(x: split ? treeWidth + editorWidth + regularSplitHandleWidth : 0)
                    .opacity(split || selectedTab == previewTab ? 1 : 0)
                    .allowsHitTesting(split || selectedTab == previewTab)
                if split {
                    splitHandle(totalWidth: metrics.workspaceWidth)
                        .frame(height: geo.size.height)
                        .offset(x: treeWidth + editorWidth)
                }
                if split && metrics.treeWidth >= 240 {
                    projectFileTreeSidebar()
                        .frame(width: metrics.treeWidth, height: geo.size.height)
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: metrics.treeWidth)
                }
            }
            .coordinateSpace(name: "splitContainer")
            .onChange(of: split) { wasSplit, isSplit in
                if wasSplit && !isSplit {
                    // First-responder status can linger after a preview touch.
                    // Only real user input, not sync/compile updates, chooses the pane.
                    selectedTab = WorkspacePane.collapseSelection(
                        lastInteraction: lastInteractedWorkspacePane,
                        currentSelection: selectedTab
                    )
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, width in
                workspaceContainerWidth = width
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
                if metrics.treeWidth >= 240 {
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
                if topViewportInset > 0, metrics.treeWidth >= 240 {
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
        let expandedTreeWidth = min(min(max(totalWidth * 0.22, 240), 320), max(totalWidth - 573, 0))
        let admitsTree = sizeClass == .regular && totalWidth >= 813
            && totalWidth - min(max(totalWidth * 0.22, 240), 320) - 1 >= 572
            && isProjectFileTreeVisible
        let treeWidth = admitsTree ? expandedTreeWidth : 0
        let treeDividerWidth: CGFloat = admitsTree ? 1 : 0
        let collapsedHeaderWidth = min(
            max(totalWidth * 0.17, regularCollapsedProjectHeaderMinimumWidth),
            regularCollapsedProjectHeaderMaximumWidth
        )
        let projectHeaderWidth = collapsedHeaderWidth
        let workspaceWidth = max(totalWidth - treeWidth - treeDividerWidth, 1)
        let availablePaneWidth = max(workspaceWidth - regularSplitHandleWidth, 560)
        let minimumEditorWidth: CGFloat = 280
        let maximumEditorWidth = availablePaneWidth - 280
        let editorWidth = min(max(availablePaneWidth * editorFraction, minimumEditorWidth), maximumEditorWidth)
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
                guard !(selectedTab == editorTab && focusCoordinator.isTextSelectionInteractionActive) else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let startsAwayFromLeadingEdge = value.startLocation.x > 44
                guard abs(horizontal) >= 70, abs(horizontal) > abs(vertical) * 1.35 else { return }

                if horizontal < 0, selectedTab == editorTab, startsAwayFromLeadingEdge {
                    pendingCompactSwipeFeedback = true
                    selectedTab = previewTab
                } else if horizontal > 0, selectedTab == previewTab, !canPresentSlideshow, startsAwayFromLeadingEdge {
                    pendingCompactSwipeFeedback = true
                    selectedTab = editorTab
                }
            }
    }

    var shareButtonAction: () -> Void {
        if previewRequiresExternalFolderLink {
            return {
                Task {
                    guard await flushPendingSave() else { return }
                    exporter.exportTypSource(for: document, fileName: currentFileName)
                }
            }
        }
        if isSplitWorkspace || selectedTab == previewTab {
            return {
                Task {
                    guard await flushPendingSave() else { return }
                    if let fontResolutionError {
                        exporter.exportError = fontResolutionError
                        return
                    }
                    exporter.exportPDF(for: document)
                }
            }
        }
        return {
            Task {
                guard await flushPendingSave() else { return }
                exporter.exportTypSource(for: document, fileName: currentFileName)
            }
        }
    }

    var shareButtonLabel: String {
        if previewRequiresExternalFolderLink { return L10n.tr("Export .typ") }
        if isSplitWorkspace || selectedTab == previewTab { return L10n.tr("Share PDF") }
        return L10n.tr("Export .typ")
    }

    private var shareMenuSystemImage: String {
        switch exporter.exportButtonPhase {
        case .idle:
            "square.and.arrow.up"
        case .exporting:
            "hourglass"
        case .completed:
            "checkmark"
        }
    }

    var canTriggerPreviewActions: Bool {
        !previewRequiresExternalFolderLink
            && !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPresentSlideshow: Bool {
        compiler.previewArtifact?.svgPages.isEmpty == false
    }

    private func regularShouldShowPreviewStatistics(for previewWidth: CGFloat) -> Bool {
        isSplitWorkspace
            && !previewRequiresExternalFolderLink
            && previewWidth >= regularPreviewStatsCompactMinimumPreviewWidth
            && !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var toolbarPreviewStatisticsIncludesRenderedPages: Bool {
        compiler.compiledOnce
    }

    private var toolbarPreviewStatistics: PreviewStatistics? {
        guard isSplitWorkspace,
              !previewRequiresExternalFolderLink,
              previewStatsAreReady,
              !entrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return PreviewStatistics(
            pageCount: max(compiler.pageCount, 0),
            wordCount: previewStatsWordCount,
            characterCount: previewStatsCharacterCount
        )
    }

    private func recomputePreviewStatistics() {
        guard isSplitWorkspace else {
            previewStatsTask?.cancel()
            previewStatsTask = nil
            previewStatsPendingID = nil
            return
        }
        let text = entrySource
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewStatsTask?.cancel()
            previewStatsTask = nil
            previewStatsWordCount = 0
            previewStatsCharacterCount = 0
            previewStatsAreReady = false
            previewStatsSourceSignature = nil
            previewStatsPendingID = nil
            return
        }

        previewStatsAreReady = false
        let requestID = UUID()
        previewStatsPendingID = requestID
        previewStatsTask?.cancel()
        previewStatsTask = Task.detached(priority: .utility) {
            let statistics = PreviewTextStatisticsCache.statistics(for: text)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard previewStatsPendingID == requestID,
                      entrySource == text else { return }
                previewStatsWordCount = statistics.wordCount
                previewStatsCharacterCount = statistics.characterCount
                previewStatsSourceSignature = statistics.signature
                previewStatsPendingID = nil
                previewStatsAreReady = true
                previewStatsTask = nil
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
            Task { await restoreSavedPosition() }
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
    private var projectTitleMenuContent: some View {
        Section {
            Button {
                guard projectWritableLease != nil else { return }
                InteractionFeedback.impact(.light)
                showingProjectSettings = true
            } label: {
                Label(L10n.tr("Project Settings"), systemImage: "gearshape")
            }
            .disabled(projectWritableLease == nil)
            Button {
                newProjectFileName = ""
                showingNewProjectFileAlert = true
            } label: {
                Label(L10n.tr("New .typ File"), systemImage: "doc.badge.plus")
            }
            Button {
                showingProjectFileImporter = true
            } label: {
                Label(L10n.tr("Import File"), systemImage: "square.and.arrow.down")
            }
            if BookmarkManager.hasBookmark(projectID: document.projectID) {
                Button {
                    refreshLinkedExternalFolder()
                } label: {
                    Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(linkedFolderRefreshCoordinator.isRefreshing || externalFolderLinkTask != nil)
                .accessibilityHint(L10n.tr("a11y.project_files.refresh_linked_folder.hint"))
                .accessibilityValue(
                    linkedFolderRefreshCoordinator.presentedProgress?.localizedStatusMessage
                        ?? externalFolderLinkProgress?.localizedStatusMessage
                        ?? ""
                )
            }
        }

        Section {
            if !usesCompactEditorToolbar, !isSplitWorkspace, !previewRequiresExternalFolderLink, selectedTab == previewTab {
                Button(action: shareButtonAction) {
                    Label(shareButtonLabel, systemImage: shareMenuSystemImage)
                }
                .disabled(exporter.exportButtonPhase != .idle)
            }

            Button {
                Task {
                    guard await flushPendingSave() else { return }
                    exporter.exportTypSource(for: document, fileName: currentFileName)
                }
            } label: {
                Label(L10n.tr("Export .typ"), systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(exporter.exportButtonPhase != .idle)

            Button { Task { await triggerZipExport() } } label: {
                Label(L10n.tr("Export Project as Zip"), systemImage: "archivebox")
            }
            .disabled(exporter.exportButtonPhase != .idle)
        }
    }

    @ViewBuilder
    var editorToolbarMenuContent: some View {
        if usesCompactEditorToolbar {
            Section {
                Button {
                    InteractionFeedback.impact(.light)
                    closeCommandPanel(); showingFileBrowser = true
                } label: {
                    Label(L10n.tr("Project Files"), systemImage: "folder")
                }
                Button(action: commandMoreShareAction ?? shareButtonAction) {
                    Label(commandMoreShareLabel ?? shareButtonLabel, systemImage: shareMenuSystemImage)
                }
                .disabled(exporter.exportButtonPhase != .idle)
            }
            projectTitleMenuContent
        }
        editingCommandMenuGroups
        if !usesCompactEditorToolbar {
            Section {
                Button {
                    InteractionFeedback.impact(.light)
                    closeCommandPanel(); showingFileBrowser = true
                } label: {
                    Label(L10n.tr("Project Files"), systemImage: "folder")
                }
            }
        }

        Section {
            Button { closeCommandPanel(); findRequested = true } label: {
                Label(L10n.tr("action.find_replace"), systemImage: "magnifyingglass")
            }
            Button {
                InteractionFeedback.impact(.light)
                focusCoordinator.dismissKeyboard()
                closeCommandPanel(restoreFocus: false); showingOutline = true
            } label: {
                Label(L10n.tr("outline.title"), systemImage: "list.bullet")
            }
            Button {
                InteractionFeedback.impact(.light)
                focusCoordinator.dismissKeyboard()
                closeCommandPanel(restoreFocus: false); showingKeyboardShortcuts = true
            } label: {
                Label(L10n.tr("shortcuts.title"), systemImage: "keyboard")
            }
        }

        Section {
            Button {
                Task { @MainActor in
                    closeCommandPanel()
                    await Task.yield()
                    await compilePreviewNow()
                }
            } label: {
                Label(L10n.tr("Compile Now"), systemImage: "play.circle")
            }
            .disabled(!canTriggerPreviewActions)

            Button {
                Task { @MainActor in
                    closeCommandPanel()
                    await Task.yield()
                    await clearCachesAndRecompile()
                }
            } label: {
                Label(L10n.tr("Recompile"), systemImage: "arrow.clockwise.circle")
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

    private func compactCloseProjectButton(_ onCloseProject: @escaping () -> Void) -> some View {
        Button {
            Task {
                guard await flushPendingSave() else { return }
                onCloseProject()
            }
        } label: {
            Label(L10n.tr("Projects"), systemImage: "chevron.left")
        }
        .accessibilityLabel(L10n.tr("Projects"))
        .accessibilityIdentifier("editor.close-project")
    }

    private var systemCompactModePicker: some View {
        Menu {
            Button {
                compactTabSelection.wrappedValue = editorTab
            } label: {
                Label(L10n.tr("Editor"), systemImage: "text.quote")
            }
            Button {
                compactTabSelection.wrappedValue = previewTab
            } label: {
                Label(L10n.tr("Preview"), systemImage: "doc.richtext")
            }
        } label: {
            Label(L10n.tr("Mode"), systemImage: selectedTab == editorTab ? "text.quote" : "doc.richtext")
        }
        .accessibilityIdentifier("editor.mode-picker")
    }

    private var compactToolbarTrailingControl: some View {
        Group {
            if selectedTab == editorTab {
                editorMoreControl()
            } else {
                Button {
                    showingSlideshow = true
                } label: {
                    Label(L10n.tr("Slideshow"), systemImage: "play.rectangle")
                }
                .disabled(!canPresentSlideshow)
            }
        }
    }

    private var compactNavigationTitle: some View {
        Button { showingEditorNames = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(compactNavigationTextColor)
                if !activeEditorSubtitle.isEmpty {
                    Text(activeEditorSubtitle)
                        .font(.caption2)
                        .foregroundStyle(compactNavigationSecondaryTextColor)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(document.title + ", " + activeEditorSubtitle)
        .accessibilityHint(L10n.tr("editor.title.full_names.hint"))
        .accessibilityIdentifier("editor.document-title")
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
            .navigationTitle(document.title)
            .navigationSubtitleCompat(usesCompactEditorToolbar ? "" : navigationEditorSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if let onCloseProject {
                    ToolbarItem(placement: .topBarLeading) {
                        compactCloseProjectButton(onCloseProject)
                    }
                }
                if usesCompactEditorToolbar {
                    ToolbarItem(placement: .principal) {
                        compactNavigationTitle
                    }
                }
                if !usesCompactEditorToolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingFileBrowser = true } label: {
                            Label(L10n.tr("Project Files"), systemImage: "folder")
                        }
                        .accessibilityIdentifier("editor.project-files")
                    }
                }
                if !isSplitWorkspace {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            compactTabSelection.wrappedValue = selectedTab == editorTab ? previewTab : editorTab
                        } label: {
                            Label(L10n.tr(selectedTab == editorTab ? "Show preview" : "Show source"),
                                  systemImage: selectedTab == editorTab ? "doc.richtext" : "text.alignleft")
                        }
                        .accessibilityIdentifier("editor.mode-picker")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { findRequested = true; selectedTab = editorTab } label: {
                        Label(L10n.tr("action.find_replace"), systemImage: "magnifyingglass")
                    }
                }
                if !usesCompactEditorToolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: shareButtonAction) {
                            Label(shareButtonLabel, systemImage: shareMenuSystemImage)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    editorMoreControl(includeSlideshow: true)
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
                    canMutate: projectWritableLease != nil,
                    openNode: openProjectFile,
                    setEntryFile: setEntryProjectFile,
                    createFile: createProjectFileReliably,
                    importFile: importProjectFileReliably,
                    deleteNode: deleteProjectNodeReliably,
                    onNodeDeleted: handleProjectFileDeleted,
                    refreshLinkedFolder: refreshLinkedExternalFolder,
                    isRefreshingLinkedFolder: linkedFolderRefreshCoordinator.isRefreshing || externalFolderLinkTask != nil,
                    linkedFolderProgress: linkedFolderRefreshCoordinator.presentedProgress ?? externalFolderLinkProgress,
                    cancelLinkedFolderRefresh: {
                        if linkedFolderRefreshCoordinator.isRefreshing {
                            linkedFolderRefreshCoordinator.cancel()
                        } else {
                            externalFolderLinkTask?.cancel()
                        }
                    },
                    refreshToken: projectFileTreeRefreshToken
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
                let pendingClose = projectCloseTask
                let generation = UUID()
                projectLifecycleGeneration = generation
                if ProcessInfo.processInfo.environment["UITEST_START_IN_PREVIEW"] == "1" {
                    selectedTab = previewTab
                }
                if pendingClose == nil, projectWritableLease != nil {
                    projectAccessResolved = true
                    return
                }
                if pendingClose != nil {
                    projectWritableLease = nil
                    projectAccessResolved = false
                }
                projectLeaseTask?.cancel()
                projectLeaseTask = Task { @MainActor in
                    if let pendingClose { await pendingClose.value }
                    guard !Task.isCancelled, projectLifecycleGeneration == generation else { return }
                    let access = await ProjectWritableLeaseCoordinator.shared.open(projectID: document.stableProjectID)
                    if Task.isCancelled || projectLifecycleGeneration != generation {
                        if case .writable(let lease) = access { await lease.release() }
                        return
                    }
                    let isWritable: Bool
                    switch access {
                    case .writable(let lease):
                        projectWritableLease = lease
                        isWritable = true
                    case .readOnly:
                        projectWritableLease = nil
                        isWritable = false
                    }
                    projectAccessResolved = true
                    await prepareDocumentForEditing(allowMigration: isWritable)
                    restoreProjectEditorStateIfNeeded()
                    let handledExternalOpen = await handleExternalOpenRequestIfNeeded(externalOpenRequest)
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
            }
            .onDisappear {
                projectLeaseTask?.cancel()
                projectLeaseTask = nil
                let generation = projectLifecycleGeneration
                let leaseToRelease = projectWritableLease
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
                        _ = await flushPendingSave()
                        if let reconciliationRequest {
                            var reconciled = false
                            while !reconciled {
                                do {
                                    try await ProjectReliabilityWriterRegistry.shared.reconcile(reconciliationRequest)
                                    reconciled = true
                                } catch {
                                    fileSaveError = error.localizedDescription
                                    try? await Task.sleep(for: .seconds(1))
                                }
                            }
                        }
                        await ProjectReliabilityWriterRegistry.shared.close(
                            projectID: reliabilityProjectID,
                            rootURL: reliabilityRoot,
                            externalTargetURL: reliabilityExternalTarget
                        )
                        if projectWritableLease === leaseToRelease {
                            projectWritableLease = nil
                        }
                        await leaseToRelease.release()
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
                Task { _ = await handleExternalOpenRequestIfNeeded(externalOpenRequest) }
            }
            .onChange(of: syncCoordinator.editorScrollTarget) { _, target in
                guard let target else { return }
                if !isSplitWorkspace {
                    selectedTab = editorTab
                }
                Task {
                    if currentFileName != document.entryFileName {
                        guard await openFileIfPossible(named: document.entryFileName) else { return }
                    }
                    pendingCursorJump = utf16Offset(forLine: target.line, column: target.column, in: editorText)
                    syncCoordinator.editorScrollTarget = nil
                    InteractionFeedback.impact(.light)
                }
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
            .onChange(of: fileLoadToken) { _, _ in
                invalidateCommandContextAfterFileChange()
                insertionRequest = nil
                pendingInsertionQueue = []
            }
            .onChange(of: projectWritableLease == nil) { _, readOnly in
                if readOnly { closeCommandPanel(restoreFocus: false) }
                commandTarget.refresh()
            }
            .onChange(of: currentFileName) { _, _ in
                invalidateCommandContextAfterFileChange()
                insertionRequest = nil
                pendingInsertionQueue = []
            }
            .onChange(of: editorText) { _, _ in commandTarget.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in commandTarget.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in commandTarget.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in commandTarget.refresh() }
            .onChange(of: showingPhotoPicker) { _, showing in
                if !showing, selectedPhotoItems.isEmpty, let anchor = photoCommandAnchor {
                    if anchor.restoreFocus, commandAnchorIsCurrent(anchor) { focusCoordinator.activateKeyboard() }
                }
            }
            .onChange(of: selectedTab) { _, newTab in
                lastInteractedWorkspacePane = WorkspacePane(rawValue: newTab)
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
            .onChange(of: compiler.previewArtifact) { _, newValue in
                if newValue != nil, let sourceMap = compiler.sourceMap, !sourceMap.isEmpty {
                    syncCursorToPreviewIfPending()
                } else if newValue == nil {
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
            .safeAreaInset(edge: .bottom) {
                externalFolderLinkProgressInset
            }
            .animation(.snappy(duration: 0.25), value: externalFolderLinkProgress)
            .animation(.snappy(duration: 0.25), value: linkedFolderRefreshCoordinator.presentedProgress)
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
            .alert(document.title, isPresented: $showingEditorNames) {
                Button(L10n.tr("OK"), role: .cancel) {}
            } message: {
                Text(activeEditorSubtitle)
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
            .fileImporter(isPresented: $showingExternalFolderLinkImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    Task { await linkExternalFolderForPreview(from: url) }
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
                if let pages = compiler.previewArtifact?.svgPages, !pages.isEmpty {
                    SlideshowView(pages: pages)
                }
            }
            .alert(L10n.tr("New Source File"), isPresented: $showingNewProjectFileAlert) {
                TextField(L10n.tr("filename.typ"), text: $newProjectFileName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L10n.tr("Create")) { createNewProjectFileFromMenu() }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("Enter a name for the new .typ file."))
            }
            .alert(L10n.tr("Export Error"), isPresented: Binding(
                get: { exporter.exportError != nil },
                set: { if !$0 { exporter.exportError = nil } }
            )) {
                Button(L10n.tr("OK")) { exporter.exportError = nil }
            } message: {
                Text(exporter.exportError ?? "")
            }
            .alert(L10n.appFontsExportWarningTitle, isPresented: $showingZipExportWarning) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Continue")) {
                    Task {
                        guard await flushPendingSave() else { return }
                        exporter.exportZip(for: document)
                    }
                }
            } message: {
                Text(L10n.appFontsExportWarningMessage)
            }
            .alert(L10n.tr("Image Import Error"), isPresented: Binding(
                get: { imageImportError != nil },
                set: { if !$0 { imageImportError = nil } }
            )) {
                Button(L10n.tr("OK")) { imageImportError = nil }
            } message: {
                Text(imageImportError ?? "")
            }
            .alert(L10n.tr("File Error"), isPresented: Binding(
                get: { fileSaveError != nil },
                set: { if !$0 { fileSaveError = nil } }
            )) {
                Button(L10n.tr("OK")) { fileSaveError = nil }
            } message: {
                Text(fileSaveError ?? "")
            }
            .alert(L10n.tr("Cache Error"), isPresented: Binding(
                get: { previewActionError != nil },
                set: { if !$0 { previewActionError = nil } }
            )) {
                Button(L10n.tr("OK")) { previewActionError = nil }
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
                    Task { await resolveConflictKeepLocal() }
                }
                Button(L10n.tr("icloud.conflict.keep_remote")) {
                    Task { await resolveConflictKeepRemote() }
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
        if let progress = linkedFolderRefreshCoordinator.presentedProgress ?? externalFolderLinkProgress {
            LinkedFolderLoadProgressView(
                title: linkedFolderRefreshCoordinator.presentedTitle
                    ?? externalFolderLinkProgressTitle
                    ?? L10n.tr("preview.external_link_required.button"),
                progress: progress
            ) {
                if linkedFolderRefreshCoordinator.isRefreshing {
                    linkedFolderRefreshCoordinator.cancel()
                } else {
                    externalFolderLinkTask?.cancel()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var splitHandleEditorPercent: Int {
        let fraction = editorFraction.isFinite ? min(max(editorFraction, 0), 1) : 0.5
        return Int((fraction * 100).rounded())
    }

    private var splitHandleAccessibilityDescription: String {
        let editorPercent = splitHandleEditorPercent
        return L10n.a11yEditorSplitValue(editorPercent: editorPercent, previewPercent: 100 - editorPercent)
    }
}

// SwiftUI preferences can resolve anchors before UIScrollView commits its
// contentSize. Keep the request pending until native geometry can reveal the
// entire tab (including its separate close button), not merely a hittable sliver.
private struct ProjectTabNativeReveal: UIViewRepresentable {
    let request: UUID
    let isActive: Bool

    func makeUIView(context: Context) -> ProjectTabRevealView {
        ProjectTabRevealView()
    }

    func updateUIView(_ view: ProjectTabRevealView, context: Context) {
        view.request = isActive ? request : nil
        view.setNeedsLayout()
        view.scheduleReveal()
    }
}

private final class ProjectTabRevealView: UIView {
    var request: UUID?
    private var completedRequest: UUID?
    private weak var scrollView: UIScrollView?
    private var sizeObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var scheduled = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleReveal()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReveal()
    }

    func scheduleReveal() {
        guard request != nil, request != completedRequest, !scheduled else { return }
        scheduled = true
        // Leave the native layout callback before reading/setting scroll geometry.
        // This is not a timing retry: contentSize/bounds observation below wakes
        // the pending request when the native scroll range actually becomes ready.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.revealIfReady()
        }
    }

    private func revealIfReady() {
        guard window != nil, let request, request != completedRequest else { return }
        var ancestor = superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        guard let scroll = ancestor as? UIScrollView else { return }
        if scrollView !== scroll {
            scrollView = scroll
            sizeObservation = scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.scheduleReveal() }
            }
            boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.scheduleReveal() }
            }
        }
        let target = convert(bounds, to: scroll)
        let inset = scroll.adjustedContentInset
        let width = scroll.bounds.width - inset.left - inset.right
        guard target.width > 0, target.height > 0, width >= target.width,
              scroll.contentSize.width + 0.5 >= target.maxX else { return }
        let minimum = -inset.left
        let maximum = max(minimum, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let desired = min(max(target.midX - width / 2 - inset.left, minimum), maximum)
        scroll.setContentOffset(CGPoint(x: desired, y: scroll.contentOffset.y), animated: false)
        let visible = CGRect(x: scroll.bounds.minX + inset.left,
                             y: scroll.bounds.minY + inset.top,
                             width: width,
                             height: scroll.bounds.height - inset.top - inset.bottom)
        // Consume only a successful actual reveal. No offset-following once
        // consumed, so dragging the strip never snaps back to the selection.
        if visible.insetBy(dx: -0.5, dy: -0.5).contains(convert(bounds, to: scroll)) {
            completedRequest = request
        }
    }
}
