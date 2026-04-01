import SwiftUI

struct FileBrowserDirectoryView: View{
    var node: ProjectTreeNode
    @State var isExpanded: Bool = false
    var depth: Int
    
    var body: some View {
        Button {
            withAnimation(.bouncy(duration:0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Label(node.displayName, systemImage: node.kind.symbolName)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(isExpanded ? .degrees(0) : .degrees(-90))
                    .frame(width: 18, height: 18, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 18)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
            } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            Button() {
            } label: {
                Label("Rename", systemImage: "pencil").labelStyle(.titleOnly)
            }
            .tint(.green)
            
        }
    
        if isExpanded{
            ForEach(node.children){ childNode in
                switch childNode.kind{
                case .directory:FileBrowserDirectoryView(node: childNode, depth: depth + 1)
                default: FileBrowserFileView(node: childNode, depth: depth + 1)
                }
            }
        }
    }
}

struct FileBrowserFileView: View{
    @Environment(InkPondProject.self) var selectedProject: InkPondProject
    var node: ProjectTreeNode
    var depth: Int
    
    var body: some View {
        NavigationLink(value: node) {
            HStack{
                Label(node.displayName, systemImage: node.kind.symbolName)
                    .lineLimit(1)
                Spacer()
                if node.relativePath == selectedProject.entryFileName {
                    Image(systemName: "eye")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
            } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            Button() {
            } label: {
                Label("Rename", systemImage: "pencil").labelStyle(.titleOnly)
            }
            .tint(.green)
            
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if(node.kind == .typ){
                Button(role:.confirm) {
                } label: {
                    Label("Watch", systemImage: "eye").labelStyle(.iconOnly)
                }
                .tint(.accentColor)   
            }
            Button() {
            } label: {
                Label("Pin", systemImage: "pin.fill").labelStyle(.iconOnly)
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button {
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            if node.kind == .typ {
                Button {
                } label: {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                }
            }

            if node.kind != .directory{
                Button {
                } label: {
                    Label("Export " + node.kind.displayName, systemImage: node.kind.symbolName)
                }
            }
            
            Divider()
            Button(role: .destructive) {
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
