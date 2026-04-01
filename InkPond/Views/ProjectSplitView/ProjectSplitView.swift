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
            List {
                if projectRootNodes.isEmpty {
                    Text("No files")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(projectRootNodes){ childNode in
                        switch childNode.kind {
                            case .directory: FileBrowserDirectoryView(node: childNode, depth: 0)
                            default: FileBrowserFileView(node: childNode, depth: 0)
                        }
                    }
                }
            }
            .toolbar {sidebarToolbar}
            .navigationDestination(for: ProjectTreeNode.self) { node in
                Label(node.relativePath, systemImage: node.kind.symbolName)
            }
        } detail: {

        }
        .navigationTitle("Hello World")
        .navigationSubtitle("Helloooo World")
        .searchable(text: $searchString)
        .inspector(isPresented: $isInspectorVisible) {
            EmptyView()
        }
    }
    
    @ToolbarContentBuilder
    var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
            } label: {
                Text("Edit")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu{
                Button{}label:{
                    Label("Create File", systemImage: "document.badge.plus")
                }
                Button{}label:{
                    Label("Create Folder", systemImage: "folder.badge.plus")
                }
                Button{}label:{
                    Label("Import File", systemImage: "link.badge.plus")
                }
                Button{}label:{
                    Label("Import Font", systemImage: "at.badge.plus")
                }
            }label: {
                Image(systemName: "plus")
            }
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
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


