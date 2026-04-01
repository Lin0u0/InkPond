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
    
    //Test stuff
    @State var project = InkPondProject(title:"Test Project", )
     @State var projectTree = [
        ProjectTreeNode(relativePath: "main.typ", displayName: "main.typ", kind: .typ, children: []),
        ProjectTreeNode(relativePath: "lib.typ", displayName: "lib.typ", kind: .typ, children: []),
        ProjectTreeNode(relativePath: "roboto.otf", displayName: "roboto.otf", kind: .font, children: []),
        ProjectTreeNode(relativePath: "typst.toml", displayName: "typst.toml", kind: .configuration, children: []),
        ProjectTreeNode(relativePath: "images/", displayName: "Images", kind: .directory, children: [
            ProjectTreeNode(relativePath: "images/test.png", displayName: "test.png", kind: .image, children: []),
            ProjectTreeNode(relativePath: "images/typist.svg", displayName: "typist.svg", kind: .vector, children:[]),
            ProjectTreeNode(relativePath: "images/figure/", displayName: "figure", kind: .directory, children: [
                    ProjectTreeNode(relativePath: "images/figure/test.png", displayName: "test.pdf", kind: .pdf, children: []),
                    ProjectTreeNode(relativePath: "images/figure/typist.svg", displayName: "typist.svg", kind: .vector, children:[]),
                    ]
                ),
            ]
        ),
        ProjectTreeNode(relativePath: "data.csv", displayName: "data.csv", kind: .table, children: []),
        ProjectTreeNode(relativePath: "citations.bib", displayName: "citations.bib", kind: .bibliography, children: []),
        ProjectTreeNode(relativePath: "thesis.pdf", displayName: "thesis.pdf", kind: .pdf, children: []),
        ProjectTreeNode(relativePath: "data.xlsx", displayName: "data.xlsx", kind: .other, children: []),
    ]

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
            InkPondProject.self,
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
            
                
//                DocumentEditorSplitView(projectRootNodes: $projectTree)
//                    .environment(project)
            
//            Group {
//                if let container = modelContainer {
//                    ContentView()
//                        .id(containerIdentity)
//                        .modelContainer(container)
//                        .environment(snippetStore)
//                        .environment(storageManager)
//                } else {
//                    DataStoreErrorView()
//                }
//            }
//            .task {
//                ExportManager.cleanupTemporaryExports()
//                FontManager.pruneRegistrationCache()
//            }
//            .onChange(of: currentStorageMode) { _, newMode in
//                ProjectFileManager.storageManager = storageManager
//                modelContainer = Self.makeModelContainer(using: newMode)
//                containerIdentity = UUID()
//            }
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
