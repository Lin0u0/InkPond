import Foundation

extension InkPondDocument {
    var isExternalFolder: Bool {
        BookmarkManager.hasBookmark(projectID: projectID)
    }

    var needsExternalFolderLinkForPreview: Bool {
        requiresExternalFolderLinkForPreview && !isExternalFolder
    }
}
