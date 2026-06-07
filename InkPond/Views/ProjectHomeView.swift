//
//  ProjectHomeView.swift
//  InkPond
//

import SwiftUI

struct ProjectHomeView: View {
    @Binding var selectedDocument: InkPondDocument?
    @Binding var searchText: String

    var body: some View {
        DocumentListView(selectedDocument: $selectedDocument, searchText: $searchText)
            .navigationTitle(L10n.appName)
            .navigationBarTitleDisplayMode(.inline)
    }
}
