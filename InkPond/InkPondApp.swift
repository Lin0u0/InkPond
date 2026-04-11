//
//  InkPondApp.swift
//  InkPond
//
//  Created by Lin Qidi on 2026/3/2.
//

import SwiftUI
import SwiftData
import os

@main
struct InkPondApp: App {
    @State private var storageManager: StorageManager
    @State private var modelContainer: ModelContainer?
    @State private var containerIdentity = UUID()
    @State private var snippetStore = SnippetStore()
    
    init() {
        let manager = StorageManager()
        ProjectFileManager.storageManager = manager
        _storageManager = State(initialValue: manager)
        _modelContainer = State(initialValue: Self.makeModelContainer())
    }

    private static func makeModelContainer() -> ModelContainer? {
        let processInfo = ProcessInfo.processInfo
        let useInMemoryStore = processInfo.arguments.contains("UITEST_IN_MEMORY_STORE") || processInfo.environment["UITEST_IN_MEMORY_STORE"] == "1"
        let schema = Schema([InkPondProject.self,])

        do {
            return try ModelContainer(
                for: Schema([
                    InkPondProject.self,
                ]),
                configurations: [ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: useInMemoryStore,
                    cloudKitDatabase: useInMemoryStore ? .automatic : AppPreferences.GetSyncState(for: .projects) ? .automatic : .none
                )]
            )
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "InkPond", category: "DataStore")
                .error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = modelContainer {
                    ContentView()
                        .id(containerIdentity)
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
            }
            .onChange(of: AppPreferences.GetSyncState(for: .projects)) { _, newMode in
                modelContainer = Self.makeModelContainer()
                containerIdentity = UUID()
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
