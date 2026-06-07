//
//  ProjectFileBrowserSheet.swift
//  InkPond
//

import SwiftUI

struct ProjectFileBrowserSheet: View {
    @Bindable var document: InkPondDocument
    var activePath: String?
    var openNode: (ProjectTreeNode) -> Void
    var setEntryFile: (String) -> Bool
    var onNodeDeleted: (ProjectTreeNode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectFileTreeView(
                document: document,
                activePath: activePath,
                openNode: openNode,
                setEntryFile: setEntryFile,
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
