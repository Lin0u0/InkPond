import Foundation

@Observable
class ProjectTreeNode: Identifiable, Hashable {
    static func == (lhs: ProjectTreeNode, rhs: ProjectTreeNode) -> Bool {lhs.relativePath == rhs.relativePath}
    func hash(into hasher: inout Hasher){
        hasher.combine(relativePath.hash)
    }
    
    let relativePath: String
    let displayName: String
    let kind: FileKind
    let children: [ProjectTreeNode]
    let parent: ProjectTreeNode?
    let project: InkPondProject
    
    init(relativePath: String, displayName: String, kind: FileKind, children: [ProjectTreeNode], parent: ProjectTreeNode?, project: InkPondProject){
        self.relativePath = relativePath
        self.displayName = displayName
        self.kind = kind
        self.children = children
        self.parent = nil
        self.project = project
    }
    
    var id: String { relativePath }
    var accessibilityLabel: String { kind.displayName + ", " + displayName}
    
    var isEntryFile: Bool {relativePath == project.entryFileName}
    func makeEntryFile(){
        project.entryFileName = relativePath
    }
    func delete(){
        
    }
    func rename(newName:String){
        
    }
    func move(target:String){
        
    }
}
