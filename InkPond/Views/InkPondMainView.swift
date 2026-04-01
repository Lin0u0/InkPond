import SwiftUI
import SwiftData
import UIKit

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

struct InkPondMainView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(StorageManager.self) private var storageManager
    @State private var selectedDocument: InkPondProject?
    @State private var themeManager = ThemeManager()
    @State private var appFontLibrary = AppFontLibrary()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText: String = ""
    @State private var didSeedUITestDocument = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding || shouldSkipOnboardingForUITests {
            mainContent
        } else {
            OnboardingView {
                withAnimation { hasCompletedOnboarding = true }
            }
        }
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
                    document: document)
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
        .preferredColorScheme(colorScheme)
        .environment(themeManager)
        .environment(appFontLibrary)
        .task {
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
            seedUITestDocumentIfNeeded()
        }
        .onChange(of: storageManager.mode) { _, _ in
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

    @MainActor
    private func seedUITestDocumentIfNeeded() {
        guard shouldSeedUITestDocument, !didSeedUITestDocument else { return }
        didSeedUITestDocument = true

        let descriptor = FetchDescriptor<InkPondProject>(
            sortBy: [SortDescriptor(\InkPondProject.createdAt, order: .forward)]
        )
        let existingDocuments = (try? modelContext.fetch(descriptor)) ?? []

        if let existingSeed = existingDocuments.first(where: { $0.title == L10n.uiTestSampleDocumentTitle }) {
            selectedDocument = existingSeed
            return
        }

        let document = InkPondProject(title: L10n.uiTestSampleDocumentTitle, content: "")
        document.projectID = ProjectFileManager.uniqueFolderName(for: document.title)

        do {
            try ProjectFileManager.createInitialProject(for: document)
            try ProjectFileManager.writeTypFile(
                named: document.entryFileName,
                content: "= \(L10n.uiTestSampleDocumentTitle)\n\nHello, InkPond UI tests.",
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
    InkPondMainView()
        .modelContainer(for: InkPondProject.self, inMemory: true)
}
