import Foundation
import Testing
import UIKit
import WebKit
@testable import InkPond

@Suite(.serialized)
@MainActor
struct PreviewPaneTests {
    @Test func inactivePreviewHidesNativeSubtreeAndRestoresWithoutReplacingWebView() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg'><text>preview</text></svg>".write(
            to: url, atomically: true, encoding: .utf8
        )
        let container = SVGPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        container.reloadPages([TypstPreviewPage(svgFileURL: url, widthPoints: 100, heightPoints: 100, id: "page")])
        container.layoutIfNeeded()
        let webView = try #require(webViews(in: container).first)
        let scrollView = try #require(container.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(!scrollView.isHidden)
        #expect(!container.accessibilityElementsHidden)
        #expect(!webView.accessibilityElementsHidden)
        container.setAccessibilityVisible(false)
        #expect(scrollView.isHidden)
        #expect(container.accessibilityElementsHidden)
        #expect(webView.accessibilityElementsHidden)
        container.setAccessibilityVisible(true)
        #expect(!scrollView.isHidden)
        #expect(!container.accessibilityElementsHidden)
        #expect(!webView.accessibilityElementsHidden)
        #expect(webViews(in: container).first === webView)
        container.setAccessibilityVisible(false)
        #expect(scrollView.isHidden)
        #expect(webView.accessibilityElementsHidden)
        #expect(webViews(in: container).first === webView)
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    @Test func hiddenFirstPreviewCreatesWebViewOnlyWhenShown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg'><text>preview</text></svg>".write(
            to: url, atomically: true, encoding: .utf8
        )
        let pages = [TypstPreviewPage(svgFileURL: url, widthPoints: 100, heightPoints: 100, id: "page")]
        let container = SVGPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        container.setAccessibilityVisible(false)
        container.reloadPages(pages)
        container.layoutIfNeeded()
        container.reloadPages(pages)
        #expect(webViews(in: container).isEmpty)
        #expect(container.accessibilityElementsHidden)

        container.setAccessibilityVisible(true)
        #expect(webViews(in: container).count == 1)
        let webView = try #require(webViews(in: container).first)
        #expect(!webView.accessibilityElementsHidden)
        #expect(!container.accessibilityElementsHidden)
        container.setAccessibilityVisible(true)
        container.reloadPages(pages)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(webViews(in: container).count == 1)
        #expect(webViews(in: container).first === webView)
    }

    @Test func hiddenEqualPageReloadAndLayoutPreserveLoadedViewsAndScrollState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<6).map { index in
            let url = directory.appendingPathComponent("page-\(index).svg")
            try "<svg xmlns='http://www.w3.org/2000/svg'><text>page \(index)</text></svg>".write(
                to: url, atomically: true, encoding: .utf8
            )
            return TypstPreviewPage(svgFileURL: url, widthPoints: 100, heightPoints: 200, id: "page-\(index)")
        }
        let container = SVGPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        container.reloadPages(pages)
        container.layoutIfNeeded()
        let scrollView = try #require(container.subviews.compactMap { $0 as? UIScrollView }.first)
        scrollView.setZoomScale(1.5, animated: false)
        scrollView.setContentOffset(CGPoint(x: 40, y: 500), animated: false)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        let loadedViews = webViews(in: container)
        #expect(loadedViews.count > 1)
        let identities = Set(loadedViews.map { ObjectIdentifier($0) })
        let offset = scrollView.contentOffset
        let zoom = scrollView.zoomScale
        #expect(offset.y > 0)
        #expect(zoom > 1)

        container.setAccessibilityVisible(false)
        container.reloadPages(pages)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(Set(webViews(in: container).map { ObjectIdentifier($0) }) == identities)
        #expect(scrollView.contentOffset == offset)
        #expect(scrollView.zoomScale == zoom)
        #expect(scrollView.isHidden)
        #expect(container.accessibilityElementsHidden)
        #expect(loadedViews.allSatisfy { $0.accessibilityElementsHidden })

        container.setAccessibilityVisible(true)
        #expect(Set(webViews(in: container).map { ObjectIdentifier($0) }) == identities)
        #expect(scrollView.contentOffset == offset)
        #expect(scrollView.zoomScale == zoom)
        #expect(!scrollView.isHidden)
        #expect(!container.accessibilityElementsHidden)
        #expect(loadedViews.allSatisfy { !$0.accessibilityElementsHidden })
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
