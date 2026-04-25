//
//  DocumentEditorView.swift
//  InkPond
//

import SwiftUI
import SwiftData
import PDFKit
import PhotosUI

actor BackgroundDocumentFileWriter {
    func write(_ content: String, to url: URL) throws {
        if ProjectFileManager.useCoordination {
            try CloudFileCoordinator.writeString(content, to: url)
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct DocumentEditorView: View {
    enum ImageImportSource {
        case photoItem(PhotosPickerItem)
        case rawData(Data, suggestedFileName: String?)
        case fileURL(URL)
        case remoteURL(URL, suggestedFileName: String?)
    }

    @Bindable var document: InkPondDocument
    var isSidebarVisible: Bool = false

    @Environment(AppFontLibrary.self) var appFontLibrary
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.modelContext) var modelContext
    @Environment(ThemeManager.self) var themeManager

    @State var compiler = TypstCompiler()

    @State var currentFileName: String = ""
    @State var editorText: String = ""
    @State var entrySource: String = ""
    @State var compileToken: UUID = UUID()
    @State var isLoadingFileContent = false
    @State var lastPersistedText: String = ""
    @State var saveTask: Task<Void, Never>?
    @State var backgroundFileWriter = BackgroundDocumentFileWriter()
    @State var resolvedCompileFonts: ResolvedCompileFonts = .empty
    @State var availableFontFamilies: [String] = []
    @State var fontFamilyRefreshTask: Task<Void, Never>?
    @State var fontResolutionError: String?
    @State var conflictMonitor = FileConflictMonitor()

    let editorTab:Int = 0
    let previewTab:Int = 1
    @State var selectedTab:Int = ProcessInfo.processInfo.environment["UITEST_START_IN_PREVIEW"] == "1" ? 1 : 0
    @State var showingSlideshow = false
    @State var editorFraction: CGFloat = 0.5
    @State var showingPhotoPicker = false
    @State var showingFileBrowser = false
    @State var showingProjectSettings = false
    @State var showingConflictWarning = false
    @State var conflictFileName: String = ""
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var insertionRequest: EditorInsertionRequest?
    @State var findRequested = false
    @State var exporter = ExportController()
    @State var imageImportError: String?
    @State var fileSaveError: String?
    @State var previewActionError: String?
    @State var isImageDropTarget = false
    @State var pendingInsertionQueue: [EditorInsertionRequest] = []
    @State var imageImportToast: String?
    @State var toastDismissTask: Task<Void, Never>?
    @State var showingImportConfiguration = false
    @State var showingZipExportWarning = false
    @State var focusCoordinator = EditorFocusCoordinator()
    @State var syncCoordinator = SyncCoordinator()
    @State var editorViewState = EditorViewState()
    @State var fileLoadToken = UUID()
    @State var pendingCursorJump: Int?
    @State var pendingManualCompileFeedback = false
    @State var cachedBibEntries: [(key: String, type: String)] = []
    @State var cachedExternalLabels: [(name: String, kind: String)] = []
    @State var cachedImageFiles: [String] = []
    @State var cachedPackageSpecs: [String] = []
    @State var showingPositionRestore = false
    @State var positionRestoreDismissTask: Task<Void, Never>?
    @State var pendingPreviewSync = false
    @State var compilationErrorLines: Set<Int> = []
    @State var showingKeyboardShortcuts = false
    @State var showingOutline = false
    @State var showingSnippetBrowser = false
    @State var positionSyncTask: Task<Void, Never>?

    var rootDir: String { ProjectFileManager.projectDirectory(for: document).path }
    
    var isEditingEntryFile: Bool { currentFileName == document.entryFileName }
    
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

    init(
        document: InkPondDocument,
        isSidebarVisible: Bool = false
    ) {
        self.document = document
        self.isSidebarVisible = isSidebarVisible
    }

    var body: some View {
        editorOverlaysAndAlerts
    }
}
