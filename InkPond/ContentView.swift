//
//  ContentView.swift
//  InkPond
//
//  Created by Lin Qidi on 2026/3/2.
//

import SwiftUI
import SwiftData
import UIKit
import os

enum ExternalOpenURLRouter {
    private struct PendingOpen {
        let url: URL
    }

    static let notificationName = Notification.Name("ExternalOpenURLRouterDidReceiveURL")
    private nonisolated static let _lock = OSAllocatedUnfairLock<[PendingOpen]>(initialState: [])

    nonisolated static func open(_ url: URL) {
        _lock.withLock { pending in
            let normalizedURL = url.standardizedFileURL.absoluteString
            pending.removeAll { $0.url.standardizedFileURL.absoluteString == normalizedURL }
            pending.append(PendingOpen(url: url))
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notificationName, object: nil)
        }
    }

    nonisolated static func consumePendingURLs() -> [URL] {
        _lock.withLock { pending in
            let urls = pending.map(\.url)
            pending.removeAll()
            return urls
        }
    }
}

private let contentLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InkPond", category: "ContentView")

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
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(StorageManager.self) private var storageManager
    @State private var selectedDocument: InkPondDocument?
    @State private var externalFileDocument: InkPondDocument?
    @State private var themeManager = ThemeManager()
    @State private var editorFontSettings = EditorFontSettings()
    @State private var appAppearanceManager = AppAppearanceManager()
    @State private var appFontLibrary = AppFontLibrary()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText: String = ""
    @State private var didSeedUITestDocument = false
    @State private var didSeedStaleUITestDocument = false
    @State private var externalOpenError: String?
    @State private var documentOpenError: String?
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
        .onAppear(perform: handleQueuedExternalOpenURLs)
        .onOpenURL { ExternalOpenURLRouter.open($0) }
        .onReceive(NotificationCenter.default.publisher(for: ExternalOpenURLRouter.notificationName)) { _ in
            handleQueuedExternalOpenURLs()
        }
        .fullScreenCover(isPresented: externalFileEditorPresented) {
            if let document = externalFileDocument {
                externalFileEditor(document)
            }
        }
        .alert(L10n.tr("Import Error"), isPresented: Binding(
            get: { externalOpenError != nil },
            set: { if !$0 { externalOpenError = nil } }
        )) {
            Button(L10n.tr("OK")) { externalOpenError = nil }
        } message: {
            Text(externalOpenError ?? "")
        }
        .alert(L10n.tr("Project Error"), isPresented: Binding(
            get: { documentOpenError != nil },
            set: { if !$0 { documentOpenError = nil } }
        )) {
            Button(L10n.tr("OK")) { documentOpenError = nil }
        } message: {
            Text(documentOpenError ?? "")
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

    private var resolvedAppColorScheme: ColorScheme {
        appAppearanceManager.colorScheme ?? systemColorScheme
    }

    private var mainContent: some View {
        NavigationStack {
            ZStack {
                if let document = selectedDocument {
                    DocumentEditorView(
                        document: document,
                        isSidebarVisible: false,
                        externalOpenRequest: externalOpenRequest,
                        onInitialOpenFailure: { message in
                            if selectedDocument == document {
                                selectedDocument = nil
                            }
                            documentOpenError = message
                        },
                        onCloseProject: {
                            withAnimation(projectNavigationAnimation) {
                                selectedDocument = nil
                                externalOpenRequest = nil
                            }
                        }
                    )
                    .id(document.persistentModelID)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                } else {
                    ProjectHomeView(selectedDocument: documentListSelection, searchText: $searchText)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(projectNavigationAnimation, value: selectedDocument?.projectID)
        }
        .background(SceneTitleSetter(title: activeDocument?.title ?? L10n.appName))
        .environment(appAppearanceManager)
        .environment(themeManager)
        .environment(editorFontSettings)
        .environment(appFontLibrary)
        .preferredColorScheme(appAppearanceManager.colorScheme)
        .environment(\.colorScheme, resolvedAppColorScheme)
        .liquidGlassColorScheme(resolvedAppColorScheme)
        .task {
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
            seedUITestDocumentIfNeeded()
            seedStaleUITestDocumentIfNeeded()
        }
        .onChange(of: storageManager.mode) { _, _ in
            selectedDocument = nil
            externalFileDocument = nil
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

    private var activeDocument: InkPondDocument? {
        externalFileDocument ?? selectedDocument
    }

    private var projectNavigationAnimation: Animation {
        .snappy(duration: 0.28, extraBounce: 0.02)
    }

    private var documentListSelection: Binding<InkPondDocument?> {
        Binding(
            get: { selectedDocument },
            set: { newValue in
                guard let newValue else {
                    withAnimation(projectNavigationAnimation) {
                        selectedDocument = nil
                    }
                    return
                }

                do {
                    try ProjectFileManager.validateDocumentCanOpen(newValue)
                    withAnimation(projectNavigationAnimation) {
                        selectedDocument = newValue
                        externalFileDocument = nil
                    }
                } catch {
                    if selectedDocument == newValue {
                        selectedDocument = nil
                    }
                    documentOpenError = error.localizedDescription
                }
            }
        )
    }

    private var externalFileEditorPresented: Binding<Bool> {
        Binding(
            get: { externalFileDocument != nil },
            set: { isPresented in
                guard !isPresented else { return }
                if let projectID = externalFileDocument?.projectID {
                    ExternalTypFileSessionStore.unregister(projectID: projectID)
                }
                externalFileDocument = nil
                externalOpenRequest = nil
            }
        )
    }

    private func externalFileEditor(_ document: InkPondDocument) -> some View {
        NavigationStack {
            DocumentEditorView(
                document: document,
                isSidebarVisible: false,
                externalOpenRequest: externalOpenRequest,
                onInitialOpenFailure: { message in
                    if let projectID = externalFileDocument?.projectID {
                        ExternalTypFileSessionStore.unregister(projectID: projectID)
                    }
                    externalFileDocument = nil
                    externalOpenRequest = nil
                    documentOpenError = message
                }
            )
            .id("external-cover-\(document.projectID)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        externalFileEditorPresented.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.tr("Done"))
                }
            }
        }
        .environment(appAppearanceManager)
        .environment(themeManager)
        .environment(editorFontSettings)
        .environment(appFontLibrary)
        .preferredColorScheme(appAppearanceManager.colorScheme)
        .environment(\.colorScheme, resolvedAppColorScheme)
        .liquidGlassColorScheme(resolvedAppColorScheme)
    }

    private var shouldSeedUITestDocument: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("UITEST_SEED_SAMPLE_DOCUMENT")
            || processInfo.environment["UITEST_SEED_SAMPLE_DOCUMENT"] == "1"
    }

    private var shouldSeedStaleUITestDocument: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("UITEST_SEED_STALE_DOCUMENT")
            || processInfo.environment["UITEST_SEED_STALE_DOCUMENT"] == "1"
    }

    private var uiTestSampleDocumentContent: String {
        let processInfo = ProcessInfo.processInfo
        if let override = processInfo.environment["UITEST_SAMPLE_CONTENT"], !override.isEmpty {
            return override
        }
        return "= \(L10n.uiTestSampleDocumentTitle)\n\nHello, InkPond UI tests."
    }

    @MainActor
    private func handleQueuedExternalOpenURLs() {
        for url in ExternalOpenURLRouter.consumePendingURLs() {
            handleExternalOpenURL(url)
        }
    }

    @MainActor
    private func handleExternalOpenURL(_ url: URL) {
        contentLog.info("External open URL received: \(url.absoluteString, privacy: .public)")
        guard ExternalTypFileImporter.canImport(url) else {
            contentLog.info("Ignoring unsupported external URL: \(url.absoluteString, privacy: .public)")
            return
        }

        if let location = ExternalTypFileImporter.managedProjectLocation(for: url) {
            do {
                let document = try existingOrCreateManagedProjectDocument(for: location)
                document.lastEditedFileName = location.relativeFileName
                document.lastCursorLocation = 0
                externalFileDocument = nil
                externalOpenRequest = ExternalTypFileOpenRequest(
                    projectID: location.projectID,
                    fileName: location.relativeFileName
                )
                hasCompletedOnboarding = true
                selectedDocument = document
                columnVisibility = .detailOnly
                InteractionFeedback.notify(.success)
                AccessibilitySupport.announce(L10n.a11yDocumentImported(document.title))
            } catch {
                let message = error.localizedDescription
                externalOpenError = message
                InteractionFeedback.notify(.error)
                AccessibilitySupport.announce(message)
            }
            return
        }

        do {
            let document = try ExternalTypFileImporter.importFile(from: url)
            selectedDocument = nil
            externalFileDocument = document
            columnVisibility = .detailOnly
            externalOpenRequest = ExternalTypFileOpenRequest(
                projectID: document.projectID,
                fileName: document.entryFileName
            )
            hasCompletedOnboarding = true
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
            existingDocument.requiresExternalFolderLinkForPreview = false
            let typFiles = ProjectFileManager.listAllTypFiles(for: existingDocument)
            if typFiles.contains(location.relativeFileName) {
                existingDocument.entryFileName = location.relativeFileName
            }
            return existingDocument
        }

        let document = InkPondDocument(title: projectID, content: "")
        document.projectID = projectID
        document.requiresExternalFolderLinkForPreview = false

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

    @MainActor
    private func seedStaleUITestDocumentIfNeeded() {
        guard shouldSeedStaleUITestDocument, !didSeedStaleUITestDocument else { return }
        didSeedStaleUITestDocument = true

        let document = InkPondDocument(title: "Stale Test Document", content: "")
        document.projectID = "ui-test-stale-\(UUID().uuidString)"
        document.entryFileName = "main.typ"

        do {
            try ProjectFileManager.createProjectRoot(for: document)
            modelContext.insert(document)
        } catch {
            try? ProjectFileManager.deleteProjectDirectory(for: document)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: InkPondDocument.self, inMemory: true)
}
