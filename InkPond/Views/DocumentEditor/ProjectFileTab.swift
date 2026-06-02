//
//  ProjectFileTab.swift
//  InkPond
//

import Foundation

struct ProjectFileTab: Identifiable, Hashable {
    let relativePath: String
    let displayName: String
    let kind: FileKind

    var id: String { relativePath }
}

