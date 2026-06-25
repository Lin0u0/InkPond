//
//  TypstPreviewArtifact.swift
//  InkPond
//

import Foundation

struct TypstPreviewPage: Equatable, Sendable {
    nonisolated let svg: String
    nonisolated let widthPoints: Double
    nonisolated let heightPoints: Double
}

struct TypstPreviewArtifact: Equatable, Sendable {
    nonisolated let svgPages: [TypstPreviewPage]
    nonisolated let pdfData: Data?
    nonisolated let sourceMap: SourceMap?

    nonisolated var pageCount: Int {
        svgPages.count
    }
}
