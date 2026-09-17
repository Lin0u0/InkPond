import Foundation
import UIKit
import Testing
@testable import InkPond

@Suite(.serialized)
@MainActor
struct PreviewPaneTests {
    @Test func previewTopInsetKeepsFirstPageBelowChromeWithoutResettingScrolledPosition() throws {
        let preview = SVGPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        preview.layoutIfNeeded()
        let scroll = try #require(preview.subviews.compactMap { $0 as? UIScrollView }.first)
        preview.topViewportInset = 170
        preview.reloadPages(Array(repeating: TypstPreviewPage(
            svg: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 595 842\"><rect width=\"595\" height=\"842\" fill=\"white\"/></svg>",
            widthPoints: 595, heightPoints: 842), count: 3))
        preview.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 1)
        #expect(scroll.adjustedContentInset.top >= 170)
        scroll.contentOffset.y = 80
        preview.topViewportInset = 190
        preview.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.y - 80) < 1)
    }

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
