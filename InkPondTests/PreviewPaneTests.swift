import Foundation
import Testing
@testable import InkPond

@Suite(.serialized)
@MainActor
struct PreviewPaneTests {
    @Test func previewPageHTMLDoesNotRetainPriorFileContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pageURL = directory.appendingPathComponent("page.svg")
        try "<svg><text>first-render</text></svg>".write(
            to: pageURL,
            atomically: true,
            encoding: .utf8
        )
        let page = TypstPreviewPage(
            svgFileURL: pageURL,
            widthPoints: 100,
            heightPoints: 100,
            id: "stable-page-id"
        )

        let firstHTML = SVGPreviewContainerView.makePageHTML(forPage: page)
        try "<svg><text>second-render</text></svg>".write(
            to: pageURL,
            atomically: true,
            encoding: .utf8
        )
        let secondHTML = SVGPreviewContainerView.makePageHTML(forPage: page)

        #expect(firstHTML.contains("first-render"))
        #expect(secondHTML.contains("second-render"))
        #expect(!secondHTML.contains("first-render"))
    }
}
