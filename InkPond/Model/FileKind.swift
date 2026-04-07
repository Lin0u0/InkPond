import Foundation
enum FileKind: Hashable {
    case directory
    case typ
    case image
    case vector
    case pdf
    case table
    case bibliography
    case font
    case configuration
    case settings
    case other
    
    var symbolName: String {
        return switch self {
        case .directory: "folder"
        case .typ: "text.document"
        case .image: "photo"
        case .vector: "point.topleft.down.to.point.bottomright.curvepath"
        case .pdf: "richtext.page"
        case .table: "tablecells"
        case .bibliography: "book"
        case .font: "at"
        case .configuration: "text.viewfinder"
        case .settings: "gearshape"
        case .other: "document"
        }
    }
    
    var displayName: String {
            return switch self {
            case .directory: String(localized:"Folder")
            case .typ: String(localized:"Typst Document")
            case .image: String(localized:"Image")
            case .vector: String(localized:"Vector Graphic")
            case .pdf: String(localized:"PDF")
            case .table: String(localized:"Table Document")
            case .bibliography: String(localized:"Bibliography")
            case .font: String(localized:"Font")
            case .configuration: String(localized:"File")
            case .settings: String(localized:"Settings")
            case .other: String(localized:"File")
            }
        }
    
    var supportedFileTypes: [String] {
        return switch self{
        case .directory: []
        case .typ: ["typ"]
        case .image: ["bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"]
        case .vector: ["svg", "eps"]
        case .pdf: ["pdf"]
        case .table: ["csv","tsv"]
        case .bibliography: ["bib", "yaml", "bst", "csl"]
        case .font: ["otf", "ttf", "woff", "woff2"]
        case .configuration: ["json", "toml", "xml", "txt"]
        case .settings: []
        case .other: []
        }
    }

    static func pathToFileKind(relativePath: String) -> FileKind {
        let nsString = (relativePath as NSString)
        let fileExtension = nsString.pathExtension.lowercased()
        
        let kind : FileKind = if fileExtension.count == 0{.directory}
        else if relativePath.hasSuffix("typst.toml"){.settings}
        else if FileKind.typ.supportedFileTypes.contains(fileExtension){.typ}
        else if FileKind.image.supportedFileTypes.contains(fileExtension){.image}
        else if FileKind.vector.supportedFileTypes.contains(fileExtension){.vector}
        else if FileKind.pdf.supportedFileTypes.contains(fileExtension){.pdf}
        else if FileKind.table.supportedFileTypes.contains(fileExtension){.table}
        else if FileKind.bibliography.supportedFileTypes.contains(fileExtension){.bibliography}
        else if FileKind.font.supportedFileTypes.contains(fileExtension){.font}
        else if FileKind.configuration.supportedFileTypes.contains(fileExtension){.configuration}
        else {.other}
        
        return kind
    }
}
