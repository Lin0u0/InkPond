//
//  ContentView.swift
//  InkPond
//
//  Created by Lin Qidi on 2026/3/2.
//

import SwiftUI
import SwiftData
import UIKit

/// Sets the title of the UIWindowScene that contains this view.
/// This controls the name shown in the iPadOS app switcher and window labels.
private struct SceneTitleSetter: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            uiView.window?.windowScene?.title = title
        }
    }
}

private final class WindowUserInterfaceStyleSetterView: UIView {
    var style: UIUserInterfaceStyle = .unspecified {
        didSet { applyStyle() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyStyle()
    }

    private func applyStyle() {
        guard let window else { return }
        if let scene = window.windowScene {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        } else {
            window.overrideUserInterfaceStyle = style
        }
    }
}

private struct WindowUserInterfaceStyleSetter: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> WindowUserInterfaceStyleSetterView {
        let view = WindowUserInterfaceStyleSetterView()
        view.isHidden = true
        view.style = style
        return view
    }

    func updateUIView(_ uiView: WindowUserInterfaceStyleSetterView, context: Context) {
        uiView.style = style
    }
}

struct ExternalTypFileOpenRequest: Equatable {
    let id = UUID()
    let projectID: String
    let fileName: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(StorageManager.self) private var storageManager
    @State private var selectedDocument: InkPondDocument?
    @State private var themeManager = ThemeManager()
    @State private var editorFontSettings = EditorFontSettings()
    @State private var appAppearanceManager = AppAppearanceManager()
    @State private var appFontLibrary = AppFontLibrary()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText: String = ""
    @State private var didSeedUITestDocument = false
    @State private var externalOpenError: String?
    @State private var externalOpenRequest: ExternalTypFileOpenRequest?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if hasCompletedOnboarding || shouldSkipOnboardingForUITests {
                mainContent
            } else {
                onboardingContent
            }
        }
        .background(WindowUserInterfaceStyleSetter(style: appAppearanceManager.userInterfaceStyle))
        .onOpenURL(perform: handleExternalOpenURL)
        .alert(L10n.tr("Import Error"), isPresented: Binding(
            get: { externalOpenError != nil },
            set: { if !$0 { externalOpenError = nil } }
        )) {
            Button(L10n.tr("OK")) { externalOpenError = nil }
        } message: {
            Text(externalOpenError ?? "")
        }
    }

    private var onboardingContent: some View {
        OnboardingView {
            withAnimation { hasCompletedOnboarding = true }
        }
        .environment(appAppearanceManager)
    }

    private var shouldSkipOnboardingForUITests: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("UITEST_SKIP_ONBOARDING")
            || processInfo.environment["UITEST_SKIP_ONBOARDING"] == "1"
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DocumentListView(selectedDocument: $selectedDocument, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 320, ideal: 340)
        } detail: {
            if let document = selectedDocument {
                DocumentEditorView(
                    document: document,
                    isSidebarVisible: columnVisibility != .detailOnly,
                    externalOpenRequest: externalOpenRequest
                )
                    .id(document.persistentModelID)
            } else {
                ContentUnavailableView(
                    "No Document Selected",
                    systemImage: "doc.text",
                    description: Text("Select a document from the list or create a new one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            }
        }
        .background(SceneTitleSetter(title: selectedDocument?.title ?? L10n.appName))
        .environment(appAppearanceManager)
        .environment(themeManager)
        .environment(editorFontSettings)
        .environment(appFontLibrary)
        .task {
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
            seedUITestDocumentIfNeeded()
        }
        .onChange(of: storageManager.mode) { _, _ in
            selectedDocument = nil
            appFontLibrary.stopMonitoring()
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
        }
        .onChange(of: storageManager.syncFontsInICloud) { _, _ in
            appFontLibrary.stopMonitoring()
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
        }
        .onChange(of: storageManager.syncPackagesInICloud) { _, _ in
            try? LocalPackageStore().ensureRootDirectory()
        }
        .onDisappear {
            appFontLibrary.stopMonitoring()
        }
    }

    private var shouldSeedUITestDocument: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("UITEST_SEED_SAMPLE_DOCUMENT")
            || processInfo.environment["UITEST_SEED_SAMPLE_DOCUMENT"] == "1"
    }

    private var uiTestSampleDocumentContent: String {
        let processInfo = ProcessInfo.processInfo
        if let override = processInfo.environment["UITEST_SAMPLE_CONTENT"], !override.isEmpty {
            return override
        }
        return "= \(L10n.uiTestSampleDocumentTitle)\n\nHello, InkPond UI tests."
    }

    @MainActor
    private func handleExternalOpenURL(_ url: URL) {
        guard ExternalTypFileImporter.canImport(url) else { return }

        do {
            let document: InkPondDocument
            if let location = ExternalTypFileImporter.managedProjectLocation(for: url) {
                document = try existingOrCreateManagedProjectDocument(for: location)
                document.lastEditedFileName = location.relativeFileName
                document.lastCursorLocation = 0
                externalOpenRequest = ExternalTypFileOpenRequest(
                    projectID: location.projectID,
                    fileName: location.relativeFileName
                )
            } else {
                document = try ExternalTypFileImporter.importFile(from: url)
                modelContext.insert(document)
                externalOpenRequest = ExternalTypFileOpenRequest(
                    projectID: document.projectID,
                    fileName: document.entryFileName
                )
            }
            hasCompletedOnboarding = true
            selectedDocument = document
            InteractionFeedback.notify(.success)
            AccessibilitySupport.announce(L10n.a11yDocumentImported(document.title))
        } catch {
            let message = error.localizedDescription
            externalOpenError = message
            InteractionFeedback.notify(.error)
            AccessibilitySupport.announce(message)
        }
    }

    @MainActor
    private func existingOrCreateManagedProjectDocument(
        for location: ExternalTypFileImporter.ManagedProjectLocation
    ) throws -> InkPondDocument {
        let projectID = location.projectID
        let descriptor = FetchDescriptor<InkPondDocument>(
            predicate: #Predicate { $0.projectID == projectID }
        )
        if let existingDocument = try modelContext.fetch(descriptor).first {
            return existingDocument
        }

        let document = InkPondDocument(title: projectID, content: "")
        document.projectID = projectID

        let typFiles = ProjectFileManager.listAllTypFiles(for: document)
        if typFiles.contains(location.relativeFileName) {
            document.entryFileName = location.relativeFileName
        } else if let entryFileName = ProjectFileManager.resolveImportedEntryFile(from: typFiles).entryFileName {
            document.entryFileName = entryFileName
        }

        document.requiresInitialEntrySelection = false
        document.requiresImportConfiguration = false
        document.importEntryFileOptions = []
        document.importImageDirectoryOptions = []
        document.importFontDirectoryOptions = []
        modelContext.insert(document)
        return document
    }

    @MainActor
    private func seedUITestDocumentIfNeeded() {
        guard shouldSeedUITestDocument, !didSeedUITestDocument else { return }
        didSeedUITestDocument = true

        let descriptor = FetchDescriptor<InkPondDocument>(
            sortBy: [SortDescriptor(\InkPondDocument.createdAt, order: .forward)]
        )
        let existingDocuments = (try? modelContext.fetch(descriptor)) ?? []

        if let existingSeed = existingDocuments.first(where: { $0.title == L10n.uiTestSampleDocumentTitle }) {
            selectedDocument = existingSeed
            return
        }

        let document = InkPondDocument(title: L10n.uiTestSampleDocumentTitle, content: "")
        document.projectID = ProjectFileManager.uniqueFolderName(for: document.title)

        do {
            try ProjectFileManager.createInitialProject(for: document)
            try ProjectFileManager.writeTypFile(
                named: document.entryFileName,
                content: uiTestSampleDocumentContent,
                for: document
            )
            modelContext.insert(document)
            selectedDocument = document
        } catch {
            try? ProjectFileManager.deleteProjectDirectory(for: document)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: InkPondDocument.self, inMemory: true)
}
