import SwiftUI

struct ProjectsGridView: View {
    @State var router: NavigationPath = NavigationPath()
    @Binding var projects: [InkPondProject]
    @State var projectTree = [
        ProjectTreeNode(relativePath: "main.typ", displayName: "main.typ", kind: .typ, children: []),
        ProjectTreeNode(relativePath: "lib.typ", displayName: "lib.typ", kind: .typ, children: []),
        ProjectTreeNode(relativePath: "roboto.otf", displayName: "roboto.otf", kind: .font, children: []),
        ProjectTreeNode(relativePath: "typst.toml", displayName: "typst.toml", kind: .configuration, children: []),
        ProjectTreeNode(relativePath: "images/", displayName: "Images", kind: .directory, children: [
            ProjectTreeNode(relativePath: "images/test.png", displayName: "test.png", kind: .image, children: []),
            ProjectTreeNode(relativePath: "images/typist.svg", displayName: "typist.svg", kind: .vector, children:[]),
            ProjectTreeNode(relativePath: "images/figure/", displayName: "figure", kind: .directory, children: [
                    ProjectTreeNode(relativePath: "images/figure/test.png", displayName: "test.pdf", kind: .pdf, children: []),
                    ProjectTreeNode(relativePath: "images/figure/typist.svg", displayName: "typist.svg", kind: .vector, children:[]),
                    ]
                ),
            ]
        ),
        ProjectTreeNode(relativePath: "data.csv", displayName: "data.csv", kind: .table, children: []),
        ProjectTreeNode(relativePath: "citations.bib", displayName: "citations.bib", kind: .bibliography, children: []),
        ProjectTreeNode(relativePath: "thesis.pdf", displayName: "thesis.pdf", kind: .pdf, children: []),
        ProjectTreeNode(relativePath: "data.xlsx", displayName: "data.xlsx", kind: .other, children: []),
    ]

    var body: some View {
//        NavigationStack(path: $router){
//            ScrollView {
//                LazyVGrid(columns: columns) {
//                    ForEach(projects, id: \.id) { project in
//                        NavigationLink(value:project){
//                            ProjectGridItemView(project: project)
//                        }
//                        .buttonStyle(.plain)
//                    }
//                }
//            }
//            .navigationDestination(for: InkPondProject.self) { project in
                ProjectSplitView(projectRootNodes: $projectTree)
                    .environment(projects[1])
//            }
//            .navigationBarHidden(true)
//            .navigationBarBackButtonHidden(true)
//        }
    }
}
    
    private var columns: [GridItem] {
//        if forEditing {
//            return [ GridItem(.adaptive(minimum: Constants.landmarkGridItemEditingMinSize,
//                                        maximum: Constants.landmarkGridItemEditingMaxSize),
//                              spacing: Constants.landmarkGridSpacing) ]
//        }
        return [ GridItem(.adaptive(minimum: 160,
                                    maximum: 320),
                          spacing: 14.0) ]
    }
//    @MainActor static var minSize: CGFloat {
//    #if os(iOS)
//        if UIDevice.current.userInterfaceIdiom == .pad {
//            return 240.0
//        } else {
//            return 160.0
//        }
//        
//    #else
//        return 240.0
//    #endif
//    }
//    static let maxsize: CGFloat = 320.0
//}
//
//#Preview {
//    let modelData = ModelData()
//    let previewCollection = modelData.userCollections[2]
//
//    LandmarksGrid(landmarks: .constant(previewCollection.landmarks), forEditing: true)
//}

