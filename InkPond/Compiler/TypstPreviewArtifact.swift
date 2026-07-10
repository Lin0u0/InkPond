//
//  TypstPreviewArtifact.swift
//  InkPond
//

import CryptoKit
import Foundation

struct TypstPreviewPage: Equatable, Sendable {
    nonisolated let id: String
    nonisolated let widthPoints: Double
    nonisolated let heightPoints: Double
    nonisolated private let inlineSVG: String?
    nonisolated private let svgFileURL: URL?

    nonisolated init(svg: String, widthPoints: Double, heightPoints: Double, id: String? = nil) {
        self.id = id ?? Self.makeID(svg: svg, widthPoints: widthPoints, heightPoints: heightPoints)
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.inlineSVG = svg
        self.svgFileURL = nil
    }

    nonisolated init(svgFileURL: URL, widthPoints: Double, heightPoints: Double, id: String) {
        self.id = id
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.inlineSVG = nil
        self.svgFileURL = svgFileURL
    }

    nonisolated var svg: String {
        (try? loadSVG()) ?? ""
    }

    nonisolated var estimatedByteCount: Int {
        inlineSVG?.utf8.count ?? 0
    }

    nonisolated func loadSVG() throws -> String {
        if let inlineSVG {
            return inlineSVG
        }
        guard let svgFileURL else { return "" }
        return try String(contentsOf: svgFileURL, encoding: .utf8)
    }

    nonisolated static func == (lhs: TypstPreviewPage, rhs: TypstPreviewPage) -> Bool {
        lhs.id == rhs.id
            && lhs.widthPoints == rhs.widthPoints
            && lhs.heightPoints == rhs.heightPoints
    }

    nonisolated private static func makeID(svg: String, widthPoints: Double, heightPoints: Double) -> String {
        var hasher = SHA256()
        if let data = svg.data(using: .utf8) {
            hasher.update(data: data)
        }
        hasher.update(data: Data("\(widthPoints)x\(heightPoints)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct TypstPreviewArtifact: Equatable, Sendable {
    nonisolated let svgPages: [TypstPreviewPage]
    nonisolated let pdfData: Data?
    nonisolated let sourceMap: SourceMap?

    nonisolated var pageCount: Int {
        svgPages.count
    }
}
