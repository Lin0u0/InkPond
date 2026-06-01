//
//  InkPondApp.swift
//  InkPond
//
//  Created by Lin Qidi on 2026/3/2.
//

import SwiftUI
import SwiftData
import UIKit
import os

final class InkPondAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            ExternalOpenURLRouter.open(url)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard ExternalTypFileImporter.canImport(url) else { return false }
        ExternalOpenURLRouter.open(url)
        return true
    }
}

@main
struct InkPondApp: App {
    @UIApplicationDelegateAdaptor(InkPondAppDelegate.self) private var appDelegate
    @State private var storageManager: StorageManager
    @State private var modelContainer: ModelContainer?
    @State private var snippetStore = SnippetStore()

    init() {
        let manager = StorageManager()
        ProjectFileManager.storageManager = manager
        _storageManager = State(initialValue: manager)
        _modelContainer = State(initialValue: Self.makeModelContainer(using: manager.mode))
    }

    private static func makeModelContainer(using mode: StorageMode) -> ModelContainer? {
        let processInfo = ProcessInfo.processInfo
        let useInMemoryStore = processInfo.arguments.contains("UITEST_IN_MEMORY_STORE")
            || processInfo.environment["UITEST_IN_MEMORY_STORE"] == "1"
        let schema = Schema([
            InkPondDocument.self,
        ])

        let modelConfiguration: ModelConfiguration
        if useInMemoryStore {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: mode == .iCloud ? .automatic : .none
            )
        }

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "InkPond", category: "DataStore")
                .error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var body: some Scene {
        let currentStorageMode = storageManager.mode
        WindowGroup {
            Group {
                if let container = modelContainer {
                    ContentView()
                        .modelContainer(container)
                        .environment(snippetStore)
                        .environment(storageManager)
                } else {
                    DataStoreErrorView()
                }
            }
            .task {
                ExportManager.cleanupTemporaryExports()
                FontManager.pruneRegistrationCache()
                await Task.detached(priority: .utility) {
                    CoreTextFontMaterializer.prunePersistentCache()
                }.value
            }
            .onChange(of: currentStorageMode) { _, newMode in
                ProjectFileManager.storageManager = storageManager
                modelContainer = Self.makeModelContainer(using: newMode)
            }
        }
    }
}

/// Shown when the SwiftData store cannot be opened.
private struct DataStoreErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L10n.tr("error.datastore.title"))
                .font(.title2.bold())
            Text(L10n.tr("error.datastore.message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
