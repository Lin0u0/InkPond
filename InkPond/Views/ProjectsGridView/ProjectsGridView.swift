import SwiftUI

struct ProjectsGridView: View {
    @Environment(NavigationController.self) var navigationController
    @Query var projects: [InkPondProject]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(projects, id: \.id) { project in
                    Button{
                        navigationController.navigateToProject(project: project)
                    }label: {
                        ProjectGridItemView(project: project)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
    
    private var columns: [GridItem] {
        return [ GridItem(.adaptive(minimum: 160,
                                    maximum: 320),
                          spacing: 14.0) ]
    }


