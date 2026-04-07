import SwiftUI

struct ProjectSplitViewFileBrowser: View{
    @Environment(InkPondProject.self) var selectedProject: InkPondProject
    @Binding var projectRootNodes: [ProjectTreeNode]
    @State var selectedNodes: Set<ProjectTreeNode> = []
    @State private var editMode: EditMode = .inactive
    
    var body: some View {
        List{
            ForEach(projectRootNodes, id: \.id){ childNode in
                Group{
                    switch childNode.kind {
                    case .directory: FileBrowserDirectoryView(node: childNode, depth: 0, selected: $selectedNodes)
                    default: FileBrowserFileView(node: childNode, depth: 0, selected: $selectedNodes)
                    }
                }
            }
            .onMove(perform: move)
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(selectedProject.title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
            
            if editMode.isEditing == true {
                ToolbarItem(placement: .bottomBar) {
                    Button(selectedNodes.count == 0 ? "Select All" : "Deselect All") {
                        //TODO: move to function and add recursion
                        if selectedNodes.count == 0{
                            selectedNodes.formUnion(projectRootNodes)
                        } else{
                            selectedNodes.removeAll()
                        }
                    }
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete", role: .destructive) {
//                      TODO:move to function and add recursion
                        projectRootNodes.forEach { node in
                            if selectedNodes.contains(node){
                                deleteNodeAndChildren(node: node)
                            }
                        }
                    }
                        .tint(.red)
                }
            }
            
            if editMode.isEditing == false {
                ToolbarItem(placement: .primaryAction) {
                    Menu{
                        Button{}label:{
                            Label("Create File", systemImage: "document.badge.plus")
                        }
                        Button{}label:{
                            Label("Create Folder", systemImage: "folder.badge.plus")
                        }
                        Button{}label:{
                            Label("Import File", systemImage: "paperclip")
                        }
                    }label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationDestination(for: ProjectTreeNode.self) { node in
            Label(node.relativePath, systemImage: node.kind.symbolName)
        }
    }

    //TODO: moving files from subfolders is broken. Also add the actual file moving implementation
    func move(from source: IndexSet, to destination: Int) {
        projectRootNodes.move(fromOffsets: source, toOffset: destination)
    }
    func deleteNodeAndChildren(node: ProjectTreeNode){
        
    }
}
