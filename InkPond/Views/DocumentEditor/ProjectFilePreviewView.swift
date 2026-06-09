//
//  ProjectFilePreviewView.swift
//  InkPond
//

import PDFKit
import SwiftUI
import UIKit
import WebKit

struct ProjectFilePreviewView: View {
    let tab: ProjectFileTab
    let url: URL?
    var topViewportInset: CGFloat = 0
    var backgroundColor: UIColor

    var body: some View {
        Group {
            if let url {
                preview(for: url)
            } else {
                unavailablePreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-file-preview.\(tab.relativePath)")
    }

    @ViewBuilder
    private func preview(for url: URL) -> some View {
        switch tab.kind {
        case .image:
            ZoomableImagePreview(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        case .vector:
            ZoomableWebFilePreview(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        case .pdf:
            ZoomablePDFPreview(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        case .directory, .typ, .text, .bibliography, .data, .configuration, .font, .archive, .other:
            unavailablePreview
        }
    }

    private var unavailablePreview: some View {
        ContentUnavailableView {
            Label(L10n.tr("Preview"), systemImage: tab.kind.iconName)
        } description: {
            Text(tab.kind.localizedAccessibilityLabel)
        }
        .background(Color(uiColor: backgroundColor))
    }
}

private struct ZoomableImagePreview: UIViewRepresentable {
    let url: URL
    let topViewportInset: CGFloat
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> ZoomableImagePreviewView {
        let view = ZoomableImagePreviewView()
        view.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        return view
    }

    func updateUIView(_ uiView: ZoomableImagePreviewView, context: Context) {
        uiView.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
    }
}

private final class ZoomableImagePreviewView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var currentURL: URL?
    private var currentTopViewportInset: CGFloat = 0
    private var currentBackgroundColor: UIColor = .systemBackground
    private let defaultZoomScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(url: URL, topViewportInset: CGFloat, backgroundColor: UIColor) {
        applyBackgroundColor(backgroundColor)
        if currentURL != url {
            currentURL = url
            imageView.image = UIImage(contentsOfFile: url.path)
            if imageView.image == nil {
                imageView.image = UIImage(systemName: "photo")
            }
            resetZoom(animated: false)
        }
        if currentTopViewportInset != topViewportInset {
            currentTopViewportInset = topViewportInset
            applyInsets()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        applyInsets(resetIfAtMinimum: false)
    }

    private func setup() {
        applyBackgroundColor(currentBackgroundColor)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.applySoftScrollEdgeEffects()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit

        addSubview(scrollView)
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func applyInsets(resetIfAtMinimum: Bool = true) {
        let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((scrollView.bounds.height - currentTopViewportInset - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: currentTopViewportInset + verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        var verticalInsets = scrollView.verticalScrollIndicatorInsets
        verticalInsets.top = currentTopViewportInset
        scrollView.verticalScrollIndicatorInsets = verticalInsets
        if resetIfAtMinimum && scrollView.zoomScale == scrollView.minimumZoomScale {
            resetZoom(animated: false)
        }
    }

    @objc private func handleDoubleTap() {
        resetZoom(animated: true)
    }

    private func applyBackgroundColor(_ color: UIColor) {
        currentBackgroundColor = color
        backgroundColor = color
        scrollView.backgroundColor = color
        imageView.backgroundColor = color
    }

    private func resetZoom(animated: Bool) {
        scrollView.setZoomScale(defaultZoomScale, animated: animated)
        let targetOffset = CGPoint(
            x: -scrollView.adjustedContentInset.left,
            y: -scrollView.adjustedContentInset.top
        )
        scrollView.setContentOffset(targetOffset, animated: animated)
    }
}

private struct ZoomablePDFPreview: UIViewRepresentable {
    let url: URL
    let topViewportInset: CGFloat
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> ZoomablePDFPreviewView {
        let view = ZoomablePDFPreviewView()
        view.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        return view
    }

    func updateUIView(_ uiView: ZoomablePDFPreviewView, context: Context) {
        uiView.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
    }
}

private final class ZoomablePDFPreviewView: PDFView {
    private var currentURL: URL?
    private var currentTopViewportInset: CGFloat = 0
    private var currentBackgroundColor: UIColor = .systemBackground

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(url: URL, topViewportInset: CGFloat, backgroundColor: UIColor) {
        applyBackgroundColor(backgroundColor)
        if currentURL != url {
            currentURL = url
            document = PDFDocument(url: url)
            resetZoom(animated: false)
        }
        if currentTopViewportInset != topViewportInset {
            currentTopViewportInset = topViewportInset
            applyInsets()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScaleLimits()
        applyInsets()
    }

    private func setup() {
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        usePageViewController(false)
        autoScales = false
        applyBackgroundColor(currentBackgroundColor)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        addGestureRecognizer(doubleTap)
    }

    private func applyInsets() {
        guard let scrollView = findScrollView(in: self) else { return }
        scrollView.applySoftScrollEdgeEffects()
        scrollView.contentInset.top = currentTopViewportInset
        var verticalInsets = scrollView.verticalScrollIndicatorInsets
        verticalInsets.top = currentTopViewportInset
        scrollView.verticalScrollIndicatorInsets = verticalInsets
    }

    @objc private func handleDoubleTap() {
        resetZoom(animated: true)
    }

    private func resetZoom(animated: Bool) {
        autoScales = false
        updateScaleLimits()
        let targetScale = scaleFactorForSizeToFit
        if animated {
            UIView.animate(withDuration: 0.2) {
                self.scaleFactor = targetScale
            }
        } else {
            scaleFactor = targetScale
        }
        applyInsets()
    }

    private func updateScaleLimits() {
        let fitScale = scaleFactorForSizeToFit
        guard fitScale.isFinite, fitScale > 0 else { return }
        minScaleFactor = max(fitScale * 0.25, 0.05)
        maxScaleFactor = max(fitScale * 8, minScaleFactor + 0.5)
        if scaleFactor < minScaleFactor {
            scaleFactor = minScaleFactor
        } else if scaleFactor > maxScaleFactor {
            scaleFactor = maxScaleFactor
        }
    }

    private func applyBackgroundColor(_ color: UIColor) {
        currentBackgroundColor = color
        backgroundColor = color
        findScrollView(in: self)?.applySoftScrollEdgeEffects()
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

private struct ZoomableWebFilePreview: UIViewRepresentable {
    let url: URL
    let topViewportInset: CGFloat
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> ZoomableWebFilePreviewView {
        let view = ZoomableWebFilePreviewView()
        view.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
        return view
    }

    func updateUIView(_ uiView: ZoomableWebFilePreviewView, context: Context) {
        uiView.configure(url: url, topViewportInset: topViewportInset, backgroundColor: backgroundColor)
    }
}

private final class ZoomableWebFilePreviewView: UIView {
    private let webView: WKWebView
    private var currentURL: URL?
    private var currentTopViewportInset: CGFloat = 0
    private var currentBackgroundColor: UIColor = .systemBackground

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(coder: coder)
        setup()
    }

    func configure(url: URL, topViewportInset: CGFloat, backgroundColor: UIColor) {
        applyBackgroundColor(backgroundColor)
        if currentURL != url {
            currentURL = url
            load(url: url)
        }
        if currentTopViewportInset != topViewportInset {
            currentTopViewportInset = topViewportInset
            applyInsets()
        }
    }

    private func setup() {
        applyBackgroundColor(currentBackgroundColor)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.applySoftScrollEdgeEffects()
        webView.scrollView.minimumZoomScale = 0.25
        webView.scrollView.maximumZoomScale = 8

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        webView.scrollView.addGestureRecognizer(doubleTap)
    }

    private func load(url: URL) {
        if url.pathExtension.lowercased() == "svg",
           let data = try? Data(contentsOf: url) {
            loadImageSource(
                "data:image/svg+xml;base64,\(data.base64EncodedString())",
                baseURL: url.deletingLastPathComponent()
            )
            return
        }

        loadImageSource(escapedHTMLAttribute(url.absoluteString), baseURL: url.deletingLastPathComponent())
    }

    private func loadImageSource(_ source: String, baseURL: URL) {
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=0.25, maximum-scale=8.0, user-scalable=yes">
        <style>
        html, body {
            margin: 0;
            width: 100%;
            height: 100%;
            background: transparent;
        }
        body {
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: auto;
        }
        img {
            display: block;
            max-width: 100vw;
            max-height: 100vh;
            object-fit: contain;
        }
        </style>
        </head>
        <body><img src="\(source)" alt=""></body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func escapedHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func applyInsets() {
        webView.scrollView.applySoftScrollEdgeEffects()
        webView.scrollView.contentInset.top = currentTopViewportInset
        var verticalInsets = webView.scrollView.verticalScrollIndicatorInsets
        verticalInsets.top = currentTopViewportInset
        webView.scrollView.verticalScrollIndicatorInsets = verticalInsets
    }

    @objc private func handleDoubleTap() {
        webView.scrollView.setZoomScale(1, animated: true)
        webView.scrollView.setContentOffset(
            CGPoint(
                x: -webView.scrollView.adjustedContentInset.left,
                y: -webView.scrollView.adjustedContentInset.top
            ),
            animated: true
        )
        webView.evaluateJavaScript("window.scrollTo(0, 0);", completionHandler: nil)
    }

    private func applyBackgroundColor(_ color: UIColor) {
        currentBackgroundColor = color
        backgroundColor = color
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
    }
}
