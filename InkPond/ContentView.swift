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

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(StorageManager.self) private var storageManager
    @State private var selectedDocument: InkPondProject?
    @State private var themeManager = ThemeManager()
    @State private var appFontLibrary = AppFontLibrary()
//#if DEBUG
    @State private var navigationController: NavigationController = NavigationController()
//#else
//    @State private var navigationController: NavigationController = NavigationController()
//#endif
    
    var body: some View {
        Group{
            switch navigationController.navigationState {
            case .projectsGridView: ProjectsGridView()
            case .projectEditor: ProjectSplitView()
            case .appSettings: SettingsView()
            case .onboarding: OnboardingView{
                    withAnimation {
                        navigationController.hasCompletedOnboarding = true
                        navigationController.navigationState = .projectsGridView
                    }
                }
            }
        }
        .background(SceneTitleSetter(title: selectedDocument?.title ?? L10n.appName))
        .environment(themeManager)
        .environment(appFontLibrary)
        .environment(navigationController)
        .preferredColorScheme(colorScheme)
        .task {
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
#if DEBUG
            seedUITestDocumentIfNeeded()
#endif
        }
        .onChange(of: AppPreferences.GetSyncState(for: .projects)) { _, _ in
            appFontLibrary.stopMonitoring()
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
            try? LocalPackageStore().ensureRootDirectory()
        }
        .onChange(of: AppPreferences.GetSyncState(for: .appFonts)) { _, _ in
            appFontLibrary.stopMonitoring()
            appFontLibrary.reload()
            appFontLibrary.startMonitoring()
        }
        .onChange(of: AppPreferences.GetSyncState(for: .localPackages)) { _, _ in
            try? LocalPackageStore().ensureRootDirectory()
        }
        .onDisappear {
            appFontLibrary.stopMonitoring()
        }
    }

#if DEBUG
    @State private var didSeedUITestDocument = false
    private var shouldSkipOnboardingForUITests: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("UITEST_SKIP_ONBOARDING")
            || processInfo.environment["UITEST_SKIP_ONBOARDING"] == "1"
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
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: InkPondProject.self, inMemory: true)
}
