import Foundation
import SwiftData

/// Keep the SwiftData model's underlying type name stable so existing stores
/// continue to open seamlessly after the app rename.
///
/// Data is from now on stored in typst.toml, ProjectConfiguration is from now on the model object for the typst.toml
/// Only Inkpond related editor data should still be stored in this class.
@Model
final class TypistDocument {
    // start deprecated
    
    var title: String = L10n.untitledBase
    var content: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    // Property-level defaults serve as SwiftData schema-migration fallbacks.
    var fontFileNames: [String] = []
    var projectID: String = UUID().uuidString
    var imageInsertMode: String = "image"
    var imageDirectoryName: String = "images"
    var entryFileName: String = "main.typ"
    var requiresInitialEntrySelection: Bool = false
    var requiresImportConfiguration: Bool = false
    var importEntryFileOptions: [String] = []
    var importImageDirectoryOptions: [String] = []
    var importFontDirectoryOptions: [String] = []
    
    // end deprecated

    /// Last editing position — persisted for cross-launch resume.
    var lastEditedFileName: String = ""
    var lastCursorLocation: Int = 0

    init(title: String = L10n.untitledBase, content: String = "") {
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    var imageInsertionTemplate: String {
        switch imageInsertMode {
        case "figure":
            return "#figure(image(\"%@\"), caption: [])"
        default:
            return "#image(\"%@\")"
        }
    }
    
    var isExternalFolder: Bool {
        BookmarkManager.hasBookmark(projectID: projectID)
    }
}

typealias InkPondProject = TypistDocument
