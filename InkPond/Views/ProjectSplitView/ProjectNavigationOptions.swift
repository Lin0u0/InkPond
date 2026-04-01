import SwiftUI

enum ProjectNavigationOptions: Equatable, Hashable, Identifiable {
    var id: String {
        switch self {
        case .projectEditor: return "Project Editor"
            case .appSettings: return "App Settings"
//            case .slideShow: return "Slide Show"
        }
    }
    
    case projectEditor(project: InkPondProject)
    case appSettings
}
