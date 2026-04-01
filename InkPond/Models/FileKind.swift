import Foundation
enum FileKind: Hashable {
    case directory
    case typ
    case image
    case vector
    case pdf
    case table
    case bibliography
    case configuration
    case font
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
        case .other: "document"
        case .configuration: "text.viewfinder"
        }
    }
    
    //TODO Localise this...
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
            case .other: String(localized:"File")
            case .configuration: String(localized:"Document")
            }
        }
    
    var supportedFileTypes: [String] {
        return switch self{
        case .directory: []
        case .typ: ["typ"]
        case .image: ["bmp", "eps", "gif", "heic", "heif", "jpg", "jpeg", "pdf", "png", "tif", "tiff", "webp"]
        case .vector: ["svg"]
        case .pdf: ["pdf"]
        case .table: ["csv","tsv"]
        case .bibliography: ["bib", "yaml"]
        case .font: ["otf", "ttf", "woff", "woff2"]
        case .other: []
        case .configuration: ["json", "toml", "xml"]
        }
    }
}
