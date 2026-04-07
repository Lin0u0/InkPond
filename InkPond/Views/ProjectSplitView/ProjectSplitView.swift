// This should have the project files in the sidebar and depending on the selected file show the appropriate editor
import SwiftUI

struct ProjectSplitView: View{
    @Environment(InkPondProject.self) var selectedProject: InkPondProject
    @Environment(\.horizontalSizeClass) var sizeClass
    @Binding var projectRootNodes: [ProjectTreeNode]
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var searchString: String = ""
    @State private var isInspectorVisible: Bool = false
    
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            ProjectSplitViewFileBrowser(projectRootNodes:$projectRootNodes)
        } detail: {
            Text("Helloo Woorrrld")
                .navigationTitle("Detail")
        }
        .searchable(text: $searchString)
        .inspector(isPresented: $isInspectorVisible) {
            EmptyView()
        }
    }
}

#Preview {
    @Previewable @State var project = InkPondProject()
    @Previewable @State var projectTree = [
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
    
    ProjectSplitView(projectRootNodes: $projectTree)
        .environment(project)
//        .onGeometryChange(for: CGSize.self) { geometry in
//            geometry.size
//        } action: {
//            modelData.windowSize = $0
//        }
}


