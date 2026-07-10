//
//  ProjectFileBrowserSheet.swift
//  InkPond
//

import SwiftUI

struct ProjectFileBrowserSheet: View {
    @Bindable var document: InkPondDocument
    var activePath: String?
    var canMutate: Bool = true
    var openNode: (ProjectTreeNode) async -> Void
    var setEntryFile: (String) async -> Bool
    var createFile: (String) async throws -> Void
    var importFile: (URL, String) async throws -> String
    var deleteNode: (ProjectTreeNode) async throws -> Void
    var onNodeDeleted: (ProjectTreeNode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectFileTreeView(
                document: document,
                activePath: activePath,
                canMutate: canMutate,
                openNode: openNode,
                setEntryFile: setEntryFile,
                createFile: createFile,
                importFile: importFile,
                deleteNode: deleteNode,
                onNodeDeleted: onNodeDeleted,
                closeAfterOpen: true
            )
            .navigationTitle(L10n.tr("Project Files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
