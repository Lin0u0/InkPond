import SwiftUI

enum NavigationOptions: Equatable, Hashable, Identifiable {
    case projectEditor
    case projectsGridView
    case appSettings
    case onboarding


    var id: String {
        return switch self {
        case .projectEditor: "Project Editor"
        case .projectsGridView: "All Projects"
        case .appSettings: "App Settings"
        case .onboarding : "Onboarding"
        }
    }
}

 @Observable
class NavigationController{
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @State var navigationState : NavigationOptions
    @State var selectedProject : InkPondProject? = nil

    init(navigationOption : NavigationOptions? = nil, selectedProject : InkPondProject? = nil) {
        _navigationState = State(initialValue: navigationOption ?? (hasCompletedOnboarding ? .projectsGridView : .onboarding))
        self.selectedProject = selectedProject
    }
    
    func navigateToProject(project: InkPondProject){
        selectedProject = project
        navigationState = .projectEditor
    }
}
