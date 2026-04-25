//
//  CompileFontModels.swift
//  InkPond
//

import Foundation

enum CompileFontSource: String, CaseIterable, Hashable, Sendable {
    case project
    case app
    case installed
    case system

    var isPackagedWithProject: Bool {
        self == .project
    }
}

struct AvailableCompileFont: Hashable, Sendable {
    let familyName: String
    let faceName: String
    let postScriptName: String
    let path: String
    let source: CompileFontSource
}

struct CompileFontWarning: Hashable, Sendable, Identifiable {
    let message: String

    var id: String { message }
}

struct ResolvedCompileFonts: Equatable, Sendable {
    static let empty = ResolvedCompileFonts(
        fontPaths: [],
        families: [],
        sourcesByFamily: [:],
        implicitFallbackFamily: nil,
        fallbackFamilies: [],
        warnings: []
    )

    let fontPaths: [String]
    let families: [String]
    let sourcesByFamily: [String: CompileFontSource]
    let implicitFallbackFamily: String?
    let fallbackFamilies: [String]
    let warnings: [CompileFontWarning]

    var includesExternalFonts: Bool {
        sourcesByFamily.values.contains { !$0.isPackagedWithProject }
    }
}

struct FontResolutionFailure: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
