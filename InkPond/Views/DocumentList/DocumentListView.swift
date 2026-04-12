//
//  DocumentListView.swift
//  InkPond
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DocumentListView: View {
    enum SortField: String, CaseIterable, Identifiable {
        case title
        case modifiedAt
        case createdAt

        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: L10n.tr("sort.field.title")
            case .modifiedAt: L10n.tr("sort.field.modified")
            case .createdAt: L10n.tr("sort.field.created")
            }
        }
    }

    enum SortDirection: String, CaseIterable, Identifiable {
        case ascending
        case descending

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ascending: L10n.tr("sort.direction.ascending")
            case .descending: L10n.tr("sort.direction.descending")
            }
        }

        func orders(_ comparison: ComparisonResult) -> Bool {
            switch self {
            case .ascending:
                comparison == .orderedAscending
            case .descending:
                comparison == .orderedDescending
            }
        }
    }

    @Environment(StorageManager.self) var storageManager
    @Environment(\.modelContext) var modelContext
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.scenePhase) var scenePhase
    @Query(sort: \InkPondDocument.modifiedAt, order: .reverse) var documents: [InkPondDocument]

    @Binding var selectedDocument: InkPondDocument?
    @Binding var searchText: String

    @State var renamingDocument: InkPondDocument?
    @State var newTitle: String = ""
    @State var exporter = ExportController()
    @State var documentToDelete: InkPondDocument?
    @State var showingSettings = false
    @State var projectActionError: String? = nil
    @State var zipImportError: String? = nil
    @State var monitor = DirectoryMonitor()
    @State var syncTask: Task<Void, Never>?
    @State var monitorRestartTask: Task<Void, Never>?
    @State var needsFilesystemSync = false
    @State var sortField: SortField = .modifiedAt
    @State var sortDirection: SortDirection = .descending
    @State var showingSortPopover = false
    @State var showingFolderImporter = false

    let rowDateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var deduplicatedDocuments: [InkPondDocument] {
        Dictionary(grouping: documents, by: \.projectID)
            .values
            .map(preferredDocumentForDuplicateGroup)
    }

    var filteredDocuments: [InkPondDocument] {
        guard !searchText.isEmpty else { return deduplicatedDocuments }
        return deduplicatedDocuments.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var sortedDocuments: [InkPondDocument] {
        filteredDocuments.sorted(by: areDocumentsOrdered)
    }

    var isShowingSearchEmptyState: Bool {
        !searchText.isEmpty && sortedDocuments.isEmpty
    }

    var isShowingLibraryEmptyState: Bool {
        deduplicatedDocuments.isEmpty && searchText.isEmpty
    }

    var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        baseContent
            .modifier(DocumentListAlertsModifier(
                exporter: $exporter,
                renamingDocument: $renamingDocument,
                newTitle: $newTitle,
                documentToDelete: $documentToDelete,
                projectActionError: $projectActionError,
                zipImportError: $zipImportError,
                showingSettings: $showingSettings,
                showingFolderImporter: $showingFolderImporter,
                linkExternalFolder: linkExternalFolder(from:),
                importZip: importZip(from:),
                selectedDocument: $selectedDocument,
                scenePhase: scenePhase,
                scheduleFilesystemSync: scheduleFilesystemSync
            ))
            .modifier(DocumentListStateChangeModifier(
                exporter: $exporter,
                projectActionError: $projectActionError,
                zipImportError: $zipImportError,
                selectedDocument: $selectedDocument
            ))
    }

    private var baseContent: some View {
        documentList
            .searchable(text: $searchText, prompt: "Search")
            .navigationTitle(L10n.appName)
            .toolbar { if isIPad { iPadToolbar } else { iPhoneToolbar } }
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
    }
}

private struct DocumentListAlertsModifier: ViewModifier {
    @Binding var exporter: ExportController
    @Binding var renamingDocument: InkPondDocument?
    @Binding var newTitle: String
    @Binding var documentToDelete: InkPondDocument?
    @Binding var projectActionError: String?
    @Binding var zipImportError: String?
    @Binding var showingSettings: Bool
    @Binding var showingFolderImporter: Bool

    @Environment(\.modelContext) var modelContext
    let linkExternalFolder: (URL) -> Void
    let importZip: (URL) -> Void
    @Binding var selectedDocument: InkPondDocument?
    let scenePhase: ScenePhase
    let scheduleFilesystemSync: (Duration) -> Void

    // Break up complex bindings to avoid type-checker timeouts
    private var isExportErrorPresented: Binding<Bool> {
        Binding(
            get: { exporter.exportError != nil },
            set: { if !$0 { exporter.exportError = nil } }
        )
    }

    private var isRenamingPresented: Binding<Bool> {
        Binding(
            get: { renamingDocument != nil },
            set: { if !$0 { renamingDocument = nil } }
        )
    }

    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )
    }

    private var isProjectErrorPresented: Binding<Bool> {
        Binding(
            get: { projectActionError != nil },
            set: { if !$0 { projectActionError = nil } }
        )
    }

    private var isImportErrorPresented: Binding<Bool> {
        Binding(
            get: { zipImportError != nil },
            set: { if !$0 { zipImportError = nil } }
        )
    }

    // Helper subviews to simplify the main body
    @ViewBuilder
    private var exportSheet: some View {
        if let url = exporter.exportURL {
            ActivityView(activityItems: [url])
        }
    }

    @ViewBuilder
    private var exportErrorAlertMessage: some View {
        Text(exporter.exportError ?? "")
    }

    @ViewBuilder
    private var projectErrorAlertMessage: some View {
        Text(projectActionError ?? "")
    }

    @ViewBuilder
    private var importErrorAlertMessage: some View {
        Text(zipImportError ?? "")
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $exporter.exportURL) { _ in exportSheet }
            .alert("Export Error", isPresented: isExportErrorPresented) {
                Button("OK") { exporter.exportError = nil }
            } message: {
                exportErrorAlertMessage
            }
            .alert("Rename Document", isPresented: isRenamingPresented) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let doc = renamingDocument {
                        if doc.isExternalFolder {
                            doc.title = newTitle
                            doc.modifiedAt = Date()
                        } else {
                            do {
                                let oldProjectID = doc.projectID
                                let newFolderName = try ProjectFileManager.renameProjectDirectory(for: doc, to: newTitle)
                                try? CompiledPreviewCacheStore().moveCache(
                                    from: oldProjectID,
                                    to: newFolderName,
                                    documentTitle: newTitle
                                )
                                doc.projectID = newFolderName
                                doc.title = newTitle
                                doc.modifiedAt = Date()
                            } catch {
                                projectActionError = error.localizedDescription
                            }
                        }
                    }
                    renamingDocument = nil
                }
                Button("Cancel", role: .cancel) { renamingDocument = nil }
            }
            .alert(documentToDelete?.isExternalFolder == true ? "Unlink Folder" : "Delete Document", isPresented: isDeletePresented) {
                Button(documentToDelete?.isExternalFolder == true ? "Unlink" : "Delete", role: .destructive) {
                    if let doc = documentToDelete {
                        do {
                            if doc.isExternalFolder {
                                BookmarkManager.removeBookmark(projectID: doc.projectID)
                            } else {
                                try ProjectFileManager.deleteProjectDirectory(for: doc)
                            }
                            try? CompiledPreviewCacheStore().remove(projectID: doc.projectID)
                            if selectedDocument == doc { selectedDocument = nil }
                            modelContext.delete(doc)
                        } catch {
                            projectActionError = error.localizedDescription
                        }
                        documentToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { documentToDelete = nil }
            } message: {
                if let doc = documentToDelete {
                    if doc.isExternalFolder {
                        Text(L10n.unlinkDocumentMessage(title: doc.title))
                    } else {
                        Text(L10n.deleteDocumentMessage(title: doc.title))
                    }
                }
            }
            .alert("Project Error", isPresented: isProjectErrorPresented) {
                Button("OK") { projectActionError = nil }
            } message: {
                projectErrorAlertMessage
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(onImport: { url in importZip(url) })
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { scheduleFilesystemSync(.milliseconds(100)) }
            }
            .onChange(of: selectedDocument?.persistentModelID) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.selection()
            }
            .alert("Import Error", isPresented: isImportErrorPresented) {
                Button("OK") { zipImportError = nil }
            } message: {
                importErrorAlertMessage
            }
            .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    linkExternalFolder(url)
                case .failure(let error):
                    zipImportError = error.localizedDescription
                }
            }
    }
}

private struct DocumentListStateChangeModifier: ViewModifier {
    @Binding var exporter: ExportController
    @Binding var projectActionError: String?
    @Binding var zipImportError: String?
    @Binding var selectedDocument: InkPondDocument?

    func body(content: Content) -> some View {
        content
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
            .onChange(of: selectedDocument?.persistentModelID) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.selection()
            }
            .onChange(of: projectActionError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
            .onChange(of: zipImportError) { _, newValue in
                guard newValue != nil else { return }
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(newValue)
            }
    }
}
