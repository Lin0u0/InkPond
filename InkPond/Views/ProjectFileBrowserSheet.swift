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
    var refreshLinkedFolder: (() -> Void)? = nil
    var isRefreshingLinkedFolder = false
    var linkedFolderProgress: LinkedFolderLoadProgress?
    var cancelLinkedFolderRefresh: (() -> Void)? = nil
    var refreshToken: UUID? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectFileTreeView(
                document: document,
                activePath: activePath,
                openNode: openNode,
                setEntryFile: setEntryFile,
                onNodeDeleted: onNodeDeleted,
                refreshLinkedFolder: refreshLinkedFolder,
                isRefreshingLinkedFolder: isRefreshingLinkedFolder,
                closeAfterOpen: true,
                refreshToken: refreshToken
            )
            .navigationTitle(L10n.tr("Project Files"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let linkedFolderProgress {
                    LinkedFolderLoadProgressView(
                        title: document.title,
                        progress: linkedFolderProgress
                    ) {
                        cancelLinkedFolderRefresh?()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
