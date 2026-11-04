import SwiftUI

/// Shares the workspace's existing fit rule with every project-files action.
enum ProjectFilesPresentation {
    static func canShowSidebar(sizeClass: UserInterfaceSizeClass?, availableWidth: CGFloat) -> Bool {
        sizeClass == .regular && availableWidth >= 813
            && availableWidth - min(max(availableWidth * 0.22, 240), 320) - 1 >= 572
    }

    static func activate(canShowSidebar: Bool, sidebarVisible: inout Bool, modalPresented: inout Bool) {
        if canShowSidebar {
            modalPresented = false
            sidebarVisible.toggle()
        } else {
            modalPresented = true
        }
    }

    static func reconcile(canShowSidebar: Bool, modalPresented: inout Bool) {
        // A wider workspace replaces the sheet, without changing the user's sidebar choice.
        if canShowSidebar { modalPresented = false }
    }
}
