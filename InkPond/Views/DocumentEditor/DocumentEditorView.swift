//
//  DocumentEditorView.swift
//  InkPond
//

import SwiftUI
import SwiftData
import PhotosUI

struct DocumentEditorView: View {
    enum ImageImportSource {
        case photoItem(PhotosPickerItem)
        case rawData(Data, suggestedFileName: String?)
        case fileURL(URL)
        case remoteURL(URL, suggestedFileName: String?)
    }

    @Bindable var document: InkPondDocument
    var isSidebarVisible: Bool = false
    var externalOpenRequest: ExternalTypFileOpenRequest?
    var onCloseProject: (() -> Void)?
    var onInitialOpenFailure: ((String) -> Void)?

    @Environment(AppFontLibrary.self) var appFontLibrary
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.modelContext) var modelContext
    @Environment(ThemeManager.self) var themeManager
    @Environment(EditorFontSettings.self) var editorFontSettings

    @State var sessionAttachment: DocumentSessionAttachment
    var documentSession: DocumentSession { sessionAttachment.session }
    var hasSessionAttachment: Bool { sessionAttachment.isValid }

    @State var compiler = TypstCompiler()

    var currentFileName: String {
        get { documentSession.currentFileName }
        nonmutating set {
            guard hasSessionAttachment else { return }
            let context = documentSession.context
            // The attachment may still point at a closed tab. Matching paths do
            // not make that evicted session an owner again: reopening must obtain
            // the retained session (or a fresh one), never revive stale bindings.
            if currentFileName == newValue, context.sessions[newValue] === documentSession { return }
            let next = context.sessions[newValue] ?? DocumentSession(document: document, fileName: newValue, context: context)
            sessionAttachment.session = next
            context.retain(next)
            if next.projectWritableLease != nil { DocumentSessionRegistry.shared.retain(next) }
        }
    }
    var editorText: String {
        get { documentSession.editorText }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.editorText = newValue }
    }
    @State var entrySource: String = ""
    @State var compileToken: UUID = UUID()
    @State var linkedFolderRefreshCacheBypassToken: UUID?
    var isLoadingFileContent: Bool {
        get { documentSession.isLoadingFileContent }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.isLoadingFileContent = newValue }
    }
    var lastPersistedText: String {
        get { documentSession.lastPersistedText }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.lastPersistedText = newValue }
    }
    var saveTask: Task<Void, Never>? {
        get { documentSession.saveTask }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.saveTask = newValue }
    }
    var saveGeneration: UInt64 {
        get { documentSession.saveGeneration }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.saveGeneration = newValue }
    }
    var savesInFlight: Int {
        get { documentSession.savesInFlight }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.savesInFlight = newValue }
    }
    // Only a write captured after this floor can discharge failed-close recovery.
    var recoveryWriteSequenceFloor: UInt64? {
        get { documentSession.recoveryWriteSequenceFloor }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.recoveryWriteSequenceFloor = newValue }
    }
    var saveAuthority: UUID {
        get { documentSession.saveAuthority }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.saveAuthority = newValue }
    }
    var reliabilityWriteAuthority: ProjectReliabilityWriteAuthority {
        get { documentSession.reliabilityWriteAuthority }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.reliabilityWriteAuthority = newValue }
    }
    @State var failedCloseSubscription: UUID?
    var lastSaveReceipt: EditorSaveReceipt? {
        get { hasSessionAttachment ? documentSession.lastSaveReceipt : nil }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.lastSaveReceipt = newValue }
    }
    var activeSaveGeneration: UInt64? {
        get { documentSession.activeSaveGeneration }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.activeSaveGeneration = newValue }
    }
    var backgroundFileWriter: BackgroundDocumentFileWriter {
        get { documentSession.backgroundFileWriter }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.backgroundFileWriter = newValue }
    }
    var projectWritableLease: ProjectWritableLease? {
        get { hasSessionAttachment ? documentSession.projectWritableLease : nil }
        nonmutating set {
            guard hasSessionAttachment else { return }
            documentSession.projectWritableLease = newValue
            if newValue != nil {
                workspace.retainExternalAccess()
                DocumentSessionRegistry.shared.retain(documentSession)
            }
        }
    }
    var projectAccessResolved: Bool {
        get { documentSession.projectAccessResolved }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.projectAccessResolved = newValue }
    }
    var workspace: WorkspaceSession { documentSession.context }
    var projectLeaseTask: Task<Void, Never>? {
        get { workspace.acquisitionTask }
        nonmutating set { workspace.acquisitionTask = newValue }
    }
    var projectCloseTask: Task<Void, Never>? {
        get { documentSession.closeTask }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.closeTask = newValue }
    }
    var projectLifecycleGeneration: UUID {
        get { documentSession.projectLifecycleGeneration }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.projectLifecycleGeneration = newValue }
    }
    @State var resolvedCompileFonts: ResolvedCompileFonts = .empty
    @State var availableFontFamilies: [String] = []
    @State var fontFamilyRefreshTask: Task<Void, Never>?
    @State var fontResolutionError: String?
    var conflictMonitor: FileConflictMonitor {
        get { documentSession.conflictMonitor }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.conflictMonitor = newValue }
    }

    let editorTab:Int = 0
    let previewTab:Int = 1
    var selectedTab: Int {
        get { workspace.mode == .edit ? 0 : 1 }
        nonmutating set { guard hasSessionAttachment else { return }; workspace.mode = newValue == 0 ? .edit : .preview }
    }
    @State var pendingCompactSwipeFeedback = false
    @State var showingSlideshow = false
    @State var editorFraction: CGFloat = 0.5
    @State var showingPhotoPicker = false
    @State var photoPickerDestination: EditorAssetDestination?
    @State var showingFileBrowser = false
    @State var showingProjectSettings = false
    var showingConflictWarning: Bool {
        get { documentSession.showingConflictWarning }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.showingConflictWarning = newValue }
    }
    var conflictFileName: String {
        get { documentSession.conflictFileName }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.conflictFileName = newValue }
    }
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var insertionRequest: EditorInsertionRequest?
    var findRequested: Bool {
        get { documentSession.findRequested }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.findRequested = newValue }
    }
    @State var exporter = ExportController()
    @State var imageImportError: String?
    var fileSaveError: String? {
        get { documentSession.fileSaveError }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.fileSaveError = newValue }
    }
    @State var previewActionError: String?
    @State var isImageDropTarget = false
    @State var pendingInsertionQueue: [EditorInsertionRequest] = []
    @State var imageImportToast: String?
    @State var toastDismissTask: Task<Void, Never>?
    @State var showingImportConfiguration = false
    @State var showingZipExportWarning = false
    @State var focusCoordinator = EditorFocusCoordinator()
    @State var shouldRestoreEditorFocusAfterPreview = false
    @State var syncCoordinator = SyncCoordinator()
    var editorViewState: EditorViewState {
        get { documentSession.editorViewState }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.editorViewState = newValue }
    }
    var fileLoadToken: UUID {
        get { documentSession.fileLoadToken }
        nonmutating set { guard hasSessionAttachment else { return }; documentSession.fileLoadToken = newValue }
    }
    @State var pendingCursorJump: Int?
    @State var pendingManualCompileFeedback = false
    @State var previewStatsWordCount = 0
    @State var previewStatsCharacterCount = 0
    @State var previewStatsAreReady = false
    @State var previewStatsSourceSignature: String?
    @State var previewStatsPendingID: UUID?
    @State var previewStatsTask: Task<Void, Never>?
    @State var showingPreviewStatsDetails = false
    @State var cachedBibEntries: [TypstBibliographyEntry] = []
    @State var cachedExternalLabels: [(name: String, kind: String)] = []
    @State var cachedImageFiles: [String] = []
    @State var cachedPackageSpecs: [String] = []
    @State var referenceCompletionRefreshTask: Task<Void, Never>?
    @State var imageFileRefreshTask: Task<Void, Never>?
    @State var showingPositionRestore = false
    @State var positionRestoreDismissTask: Task<Void, Never>?
    @State var pendingPreviewSync = false
    @State var compilationErrorLines: Set<Int> = []
    @State var showingKeyboardShortcuts = false
    @State var showingOutline = false
    @State var showingSnippetBrowser = false
    @State var showingExternalFolderLinkImporter = false
    @State var showingProjectFileImporter = false
    @State var showingNewProjectFileAlert = false
    @State var newProjectFileName = ""
    @State var projectFileTreeRefreshToken = UUID()
    @State var isProjectFileTreeVisible = true
    @State var externalFolderLinkProgress: LinkedFolderLoadProgress?
    @State var externalFolderLinkProgressTitle: String?
    @State var externalFolderLinkTask: Task<Void, Never>?
    @State var externalFolderLinkGeneration = AsyncOperationGeneration()
    @State var linkedFolderRefreshCoordinator = LinkedFolderRefreshCoordinator()
    @State var positionSyncTask: Task<Void, Never>?
    var openTabs: [ProjectFileTab] {
        get { workspace.openTabs }
        nonmutating set { guard hasSessionAttachment else { return }; workspace.openTabs = newValue }
    }
    var activeTabPath: String? {
        get { workspace.activeTabPath }
        nonmutating set { guard hasSessionAttachment else { return }; workspace.activeTabPath = newValue }
    }
    @State var didRestoreProjectEditorState = false
    @State var documentOpenSessionID: String?

    var rootDir: String { ProjectFileManager.projectDirectory(for: document).path }
    
    var isEditingEntryFile: Bool { currentFileName == document.entryFileName }

    var activeProjectPath: String {
        activeTabPath ?? ""
    }

    var activeProjectTab: ProjectFileTab? {
        guard let activeTabPath else { return nil }
        return openTabs.first { $0.relativePath == activeTabPath }
    }

    var activeTabIsTextEditable: Bool {
        workspace.allowsTextCommands
    }

    var activeEditorSubtitle: String {
        activeProjectTab?.relativePath ?? ""
    }

    var previewRequiresExternalFolderLink: Bool {
        document.needsExternalFolderLinkForPreview
    }
    
    var compiledPreviewCacheDescriptor: CompiledPreviewCacheDescriptor {
        CompiledPreviewCacheDescriptor(
            projectID: document.projectID,
            documentTitle: document.title,
            entryFileName: document.entryFileName
        )
    }

    var completionFontFamilies: [String] {
        availableFontFamilies
    }

    var editorTitleForegroundColor: Color {
        switch themeManager.themeID {
        case "mocha":
            return .white
        case "latte":
            return .black
        default:
            return colorScheme == .dark ? .white : .black
        }
    }

    var appThemeTitleForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    init(
        document: InkPondDocument,
        isSidebarVisible: Bool = false,
        externalOpenRequest: ExternalTypFileOpenRequest? = nil,
        onInitialOpenFailure: ((String) -> Void)? = nil,
        onCloseProject: (() -> Void)? = nil
    ) {
        self._sessionAttachment = State(initialValue: DocumentSessionAttachment(session: DocumentSession(document: document)))
        self.document = document
        self.isSidebarVisible = isSidebarVisible
        self.externalOpenRequest = externalOpenRequest
        self.onCloseProject = onCloseProject
        self.onInitialOpenFailure = onInitialOpenFailure
    }

#if DEBUG
    // Mount @State without starting compilation, file loading, or unrelated UI effects.
    var saveTestProbe: ((DocumentEditorView) -> Void)?
    var saveTestUsesLifecycle = false
    var saveTestUsesDisappearance = false
    var saveTestDidDisappear: (() -> Void)?
    var saveTestDebounce: (@MainActor () async throws -> Void)?
#endif

    var body: some View {
#if DEBUG
        if let saveTestProbe {
            Color.clear.onAppear {
                if saveTestUsesLifecycle { openEditorOnAppear() }
                saveTestProbe(self)
            }
            .onDisappear {
                if saveTestUsesDisappearance { closeEditorOnDisappear() }
                saveTestDidDisappear?()
            }
        } else {
            editorOverlaysAndAlerts
        }
#else
        editorOverlaysAndAlerts
#endif
    }
}
