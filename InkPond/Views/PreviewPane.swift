//
//  PreviewPane.swift
//  InkPond
//
//  Shows the compiled SVG preview, a compilation error banner, or a placeholder
//  when the Typst compiler library hasn't been linked yet.
//

import SwiftUI
import NaturalLanguage
import WebKit

private struct CompilationErrorPresentation {
    let summary: String
    let detail: String
    let location: String?
}

struct PreviewStatistics {
    let pageCount: Int
    let wordCount: Int
    let characterCount: Int
}

private struct PreviewCompileInputSignature: Equatable {
    let source: String
    let fontPaths: [String]
    let preflightError: String?
    let rootDir: String?
    let previewCacheDescriptor: CompiledPreviewCacheDescriptor?
    let compileToken: UUID
    let requiresExternalFolderLink: Bool
}

private struct PreviewStatisticItem: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private extension Character {
    nonisolated var countsTowardPreviewCharacter: Bool {
        !unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

private extension View {
    @ViewBuilder
    func compilationErrorSurface(cornerRadius: CGFloat = 18) -> some View {
        self
            .systemFloatingSurface(cornerRadius: cornerRadius)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            }
    }
}

// MARK: - Shared preview overlays

private final class PreviewSyncMarkerView: UIView {
    private let pillView = UIView()
    private var fadeWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0

        pillView.backgroundColor = UIColor.tintColor.withAlphaComponent(0.8)
        pillView.layer.cornerRadius = 1.5
        addSubview(pillView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(at point: CGPoint) {
        let clampedY = min(max(point.y, 12), bounds.height - 12)
        let pillHeight: CGFloat = 24
        let pillWidth: CGFloat = 4

        pillView.frame = CGRect(
            x: 3,
            y: clampedY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )

        // Cancel any pending fade-out and stop in-flight animations.
        fadeWorkItem?.cancel()
        layer.removeAllAnimations()
        pillView.layer.removeAllAnimations()

        // Brief scale-in entrance
        pillView.transform = CGAffineTransform(scaleX: 1, y: 0.4)
        alpha = 1

        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: []) {
            self.pillView.transform = .identity
        }

        // Schedule fade-out via a cancellable work item so a rapid
        // follow-up call to show(at:) can prevent the stale fade.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseIn]) {
                self.alpha = 0
            }
        }
        fadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - SVG wrapper

final class SVGPreviewContainerView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let syncMarkerView = PreviewSyncMarkerView()
    private var pageView: WKWebView?
    private var pendingPageView: WKWebView?
    private var pageFrames: [CGRect] = []
    private var pages: [TypstPreviewPage] = []
    private var pendingPages: [TypstPreviewPage]?
    private var pendingLoadID: UUID?
    private weak var horizontalPanRecognizer: UIPanGestureRecognizer?
    private var horizontalPanStartLocation: CGPoint?
    private var isLoadingPages = false
    private let reservedNavigationEdgeWidth: CGFloat = 44
    private let pageGap: CGFloat = 12
    private let pageMargin: CGFloat = 16
    private let visualFitZoomScale: CGFloat = 1
    private let minimumVisualZoomScale: CGFloat = 0.35
    private let maximumVisualZoomScale: CGFloat = 4
    /// Oversamples the WebKit backing view without changing preview layout or user zoom.
    private let svgBackingScale: CGFloat = 2.5
    private let reloadFadeDuration: TimeInterval = 0.12
    private let firstPaintDelay: TimeInterval = 0.08
    private let pendingLoadFallbackDelay: TimeInterval = 1.2
    private var lastLaidOutWidth: CGFloat = 0
    private var scrollGeneration: UInt = 0

    private struct PageLayout {
        let frames: [CGRect]
        let contentSize: CGSize
    }

    private var fitZoomScale: CGFloat {
        visualFitZoomScale
    }

    var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?
    var onLoadingStateChange: ((Bool) -> Void)?
    var onHorizontalSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        didSet {
            horizontalPanRecognizer?.isEnabled = onHorizontalSwipe != nil
        }
    }
    var previewBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { applyPreviewBackgroundColor() }
    }
    var topViewportInset: CGFloat = 0 {
        didSet { updateScrollInsetsIfNeeded() }
    }
    var bottomViewportInset: CGFloat = 0 {
        didSet { updateScrollInsetsIfNeeded() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.isDirectionalLockEnabled = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        updateTransientZoomScaleLimits()
        scrollView.zoomScale = fitZoomScale
        scrollView.applySoftScrollEdgeEffects()
        addSubview(scrollView)
        contentView.clipsToBounds = true
        scrollView.addSubview(contentView)
        addSubview(syncMarkerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        syncMarkerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            syncMarkerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            syncMarkerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            syncMarkerView.topAnchor.constraint(equalTo: topAnchor),
            syncMarkerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)
        tapGesture.require(toFail: doubleTapGesture)

        installHorizontalSwipeRecognizer()
        applyPreviewBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPagesIfNeeded()
        updateScrollInsetsIfNeeded()
        clampContentOffsetIfNeeded()
    }

    func reloadPages(_ newPages: [TypstPreviewPage]) {
        guard pages != newPages else {
            layoutPagesIfNeeded()
            setLoadingPages(false)
            return
        }
        guard pendingPages != newPages else {
            layoutPagesIfNeeded()
            setLoadingPages(true)
            return
        }

        cancelPendingPageLoad(notify: false)
        guard !newPages.isEmpty else {
            pageView?.removeFromSuperview()
            pageView = nil
            pages = []
            pageFrames = []
            pendingPages = nil
            pendingLoadID = nil
            lastLaidOutWidth = 0
            updateTransientZoomScaleLimits()
            scrollView.setZoomScale(fitZoomScale, animated: false)
            layoutPagesIfNeeded(force: true)
            setLoadingPages(false)
            return
        }

        setLoadingPages(true)
        let loadID = UUID()
        let webView = Self.makeDocumentWebView()
        pendingLoadID = loadID
        pendingPages = newPages
        pendingPageView = webView
        webView.alpha = 0
        webView.navigationDelegate = self
        contentView.addSubview(webView)
        layoutPendingPageView()
        webView.loadHTMLString(html(forPages: newPages), baseURL: nil)
        schedulePendingPageLoadFallback(loadID: loadID)
    }

    @discardableResult
    func scrollToPosition(page: Int, yPoints: Float, xPoints: Float) -> Bool {
        layoutIfNeeded()
        layoutPagesIfNeeded()
        guard page >= 0, page < pageFrames.count else { return false }

        let pageFrame = pageFrames[page]
        let scale = scaleForPage(at: page)
        let target = CGPoint(
            x: pageFrame.minX + CGFloat(xPoints) * scale,
            y: pageFrame.minY + CGFloat(yPoints) * scale
        )
        let zoomedTarget = CGPoint(
            x: target.x * scrollView.zoomScale,
            y: target.y * scrollView.zoomScale
        )
        let desiredOffset = CGPoint(
            x: scrollView.contentOffset.x,
            y: zoomedTarget.y - scrollView.bounds.height * 0.33
        )
        let clampedOffset = clampedContentOffset(desiredOffset)
        let needsScroll = abs(scrollView.contentOffset.y - clampedOffset.y) > 2

        scrollGeneration &+= 1
        let currentGeneration = scrollGeneration
        let showMarker = { [weak self] in
            guard let self, self.scrollGeneration == currentGeneration else { return }
            let markerPoint = self.convert(target, from: self.contentView)
            self.syncMarkerView.show(at: markerPoint)
        }

        if needsScroll {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                self.scrollView.contentOffset = clampedOffset
            } completion: { _ in
                showMarker()
            }
        } else {
            showMarker()
        }
        return true
    }

    private func layoutPagesIfNeeded(
        force: Bool = false,
        resetZoomToFit: Bool = false,
        targetVisualZoomScale: CGFloat? = nil
    ) {
        let viewportWidth = max(bounds.width, 1)
        guard force
                || abs(viewportWidth - lastLaidOutWidth) > 0.5
                || pageFrames.count != pages.count else {
            if resetZoomToFit {
                scrollView.setZoomScale(fitZoomScale, animated: false)
                updateScrollContentSize()
                updateScrollInsetsIfNeeded()
                clampContentOffsetIfNeeded()
            }
            layoutPendingPageView()
            return
        }

        let savedOffset = scrollView.contentOffset
        let nextVisualZoomScale = resetZoomToFit
            ? visualFitZoomScale
            : min(max(targetVisualZoomScale ?? currentVisualZoomScale, minimumVisualZoomScale), maximumVisualZoomScale)
        let layout = pageLayout(for: pages, viewportWidth: viewportWidth)
        pageFrames = layout.frames

        contentView.frame = CGRect(origin: .zero, size: layout.contentSize)
        applyWebViewBackingLayout(to: pageView, logicalContentSize: layout.contentSize)
        lastLaidOutWidth = viewportWidth
        updateTransientZoomScaleLimits()
        scrollView.setZoomScale(nextVisualZoomScale, animated: false)
        updateScrollContentSize()
        updateScrollInsetsIfNeeded()
        layoutPendingPageView()
        scrollView.setContentOffset(clampedContentOffset(savedOffset), animated: false)
    }

    private func pageLayout(
        for pages: [TypstPreviewPage],
        viewportWidth: CGFloat? = nil
    ) -> PageLayout {
        let viewportWidth = max(viewportWidth ?? bounds.width, 1)
        let layoutWidth = max(viewportWidth, 1)
        let margin = pageMargin
        let gap = pageGap
        let availableWidth = max(layoutWidth - margin * 2, 1)
        var frames: [CGRect] = []
        frames.reserveCapacity(pages.count)
        var y = margin

        for page in pages {
            let sourceWidth = max(CGFloat(page.widthPoints), 1)
            let sourceHeight = max(CGFloat(page.heightPoints), 1)
            let width = availableWidth
            let height = max(sourceHeight * (width / sourceWidth), 1)
            let frame = CGRect(x: margin, y: y, width: width, height: height)
            frames.append(frame)
            y += height + gap
        }

        if !frames.isEmpty {
            y -= gap
        }
        y += margin

        return PageLayout(
            frames: frames,
            contentSize: CGSize(width: layoutWidth, height: max(y, bounds.height + 1))
        )
    }

    private func layoutPendingPageView() {
        guard let pendingPages, let pendingPageView else { return }
        let layout = pageLayout(for: pendingPages)
        applyWebViewBackingLayout(to: pendingPageView, logicalContentSize: layout.contentSize)
    }

    private func applyWebViewBackingLayout(to webView: WKWebView?, logicalContentSize: CGSize) {
        guard let webView else { return }
        let scale = max(svgBackingScale, 1)
        let logicalSize = CGSize(
            width: max(logicalContentSize.width, 1),
            height: max(logicalContentSize.height, 1)
        )

        webView.transform = .identity
        webView.bounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: logicalSize.width * scale,
                height: logicalSize.height * scale
            )
        )
        webView.center = CGPoint(x: logicalSize.width / 2, y: logicalSize.height / 2)
        webView.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
    }

    private func scaleForPage(at index: Int) -> CGFloat {
        guard index >= 0, index < pages.count, index < pageFrames.count else { return 1 }
        return pageFrames[index].width / max(CGFloat(pages[index].widthPoints), 1)
    }

    private func updateScrollInsetsIfNeeded() {
        let horizontalInset = centeredHorizontalContentInset()
        var insets = scrollView.contentInset
        if abs(insets.top - topViewportInset) > 0.5
            || abs(insets.bottom - bottomViewportInset) > 0.5
            || abs(insets.left - horizontalInset) > 0.5
            || abs(insets.right - horizontalInset) > 0.5 {
            insets.top = topViewportInset
            insets.bottom = bottomViewportInset
            insets.left = horizontalInset
            insets.right = horizontalInset
            scrollView.contentInset = insets
        }
        scrollView.verticalScrollIndicatorInsets.top = topViewportInset
        scrollView.verticalScrollIndicatorInsets.bottom = bottomViewportInset
    }

    private var zoomedContentSize: CGSize {
        CGSize(
            width: contentView.bounds.width * scrollView.zoomScale,
            height: contentView.bounds.height * scrollView.zoomScale
        )
    }

    private func updateScrollContentSize() {
        scrollView.contentSize = zoomedContentSize
    }

    private func centeredHorizontalContentInset() -> CGFloat {
        let visibleWidth = scrollView.bounds.width
        guard visibleWidth > 1 else { return 0 }
        let zoomedContentWidth = contentView.bounds.width * scrollView.zoomScale
        return max((visibleWidth - zoomedContentWidth) / 2, 0)
    }

    private func clampedContentOffset(_ contentOffset: CGPoint) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let contentSize = zoomedContentSize
        let maxY = max(minY, contentSize.height - scrollView.bounds.height + inset.bottom)
        return CGPoint(
            x: clampedHorizontalOffset(contentOffset.x),
            y: min(max(contentOffset.y, minY), maxY)
        )
    }

    private func clampedHorizontalOffset(_ x: CGFloat) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let contentSize = zoomedContentSize
        let maxX = max(minX, contentSize.width - scrollView.bounds.width + inset.right)
        return allowsHorizontalScroll
            ? min(max(x, minX), maxX)
            : minX
    }

    private var allowsHorizontalScroll: Bool {
        contentView.bounds.width * scrollView.zoomScale > scrollView.bounds.width + 1
    }

    private func updateTransientZoomScaleLimits() {
        scrollView.minimumZoomScale = minimumVisualZoomScale
        scrollView.maximumZoomScale = maximumVisualZoomScale
    }

    private func clampContentOffsetIfNeeded() {
        let clampedOffset = clampedContentOffset(scrollView.contentOffset)
        guard abs(scrollView.contentOffset.x - clampedOffset.x) > 0.5
                || abs(scrollView.contentOffset.y - clampedOffset.y) > 0.5 else {
            return
        }
        scrollView.setContentOffset(clampedOffset, animated: false)
    }

    private var currentVisualZoomScale: CGFloat {
        scrollView.zoomScale
    }

    private func applyPreviewBackgroundColor() {
        backgroundColor = previewBackgroundColor
        scrollView.backgroundColor = previewBackgroundColor
        contentView.backgroundColor = previewBackgroundColor
        [pageView, pendingPageView].compactMap { $0 }.forEach { webView in
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
    }

    private func completePendingPageLoad(for webView: WKWebView) {
        guard webView === pendingPageView,
              let loadID = pendingLoadID else {
            return
        }
        commitPendingPages(loadID: loadID)
    }

    private func schedulePendingPageLoadFallback(loadID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingLoadFallbackDelay) { [weak self] in
            guard let self,
                  self.pendingLoadID == loadID,
                  self.pendingPageView != nil else {
                return
            }
            self.commitPendingPages(loadID: loadID)
        }
    }

    private func commitPendingPages(loadID: UUID) {
        guard pendingLoadID == loadID,
              let nextPages = pendingPages,
              let loadedPageView = pendingPageView else {
            return
        }

        let oldPageView = pageView
        let shouldResetZoomToFit = oldPageView == nil
        let savedOffset = scrollView.contentOffset

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            pageView = loadedPageView
            pages = nextPages
            pendingPageView = nil
            pendingPages = nil
            pendingLoadID = nil
            lastLaidOutWidth = 0

            setNeedsLayout()
            layoutIfNeeded()
            layoutPagesIfNeeded(force: true, resetZoomToFit: shouldResetZoomToFit)
            scrollView.setContentOffset(clampedContentOffset(savedOffset), animated: false)

            loadedPageView.navigationDelegate = nil
            loadedPageView.alpha = 0
        }
        CATransaction.commit()

        UIView.animate(
            withDuration: oldPageView == nil ? 0 : reloadFadeDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            loadedPageView.alpha = 1
            oldPageView?.alpha = 0
        } completion: { _ in
            oldPageView?.removeFromSuperview()
            self.setLoadingPages(false)
        }
    }

    private func cancelPendingPageLoad(notify: Bool = true) {
        pendingPageView?.navigationDelegate = nil
        pendingPageView?.stopLoading()
        pendingPageView?.removeFromSuperview()
        pendingPageView = nil
        pendingPages = nil
        pendingLoadID = nil
        if notify {
            setLoadingPages(false)
        }
    }

    private func setLoadingPages(_ isLoading: Bool) {
        guard isLoadingPages != isLoading else { return }
        isLoadingPages = isLoading
        onLoadingStateChange?(isLoading)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: contentView)
        guard let pageIndex = pageFrames.firstIndex(where: { $0.contains(location) }) else {
            return
        }
        let pageFrame = pageFrames[pageIndex]
        let scale = scaleForPage(at: pageIndex)
        guard scale > 0 else { return }
        let yPoints = (location.y - pageFrame.minY) / scale
        onTapLocation?(pageIndex, Float(yPoints))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if abs(currentVisualZoomScale - visualFitZoomScale) > 0.05 {
            scrollView.setZoomScale(fitZoomScale, animated: true)
            return
        }

        let targetScale = min(maximumVisualZoomScale, 2.5)
        let center = recognizer.location(in: contentView)
        let zoomSize = CGSize(
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        let zoomRect = CGRect(
            x: center.x - zoomSize.width / 2,
            y: center.y - zoomSize.height / 2,
            width: zoomSize.width,
            height: zoomSize.height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }

    private func installHorizontalSwipeRecognizer() {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = onHorizontalSwipe != nil
        addGestureRecognizer(recognizer)
        horizontalPanRecognizer = recognizer
    }

    @objc private func handleHorizontalPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            horizontalPanStartLocation = recognizer.location(in: self)
        case .ended:
            defer { horizontalPanStartLocation = nil }
            let translation = recognizer.translation(in: self)
            guard let startLocation = horizontalPanStartLocation,
                  !allowsHorizontalScroll,
                  startLocation.x > reservedNavigationEdgeWidth,
                  translation.x >= 70,
                  abs(translation.x) > abs(translation.y) * 1.35 else {
                return
            }
            onHorizontalSwipe?(.right)
        case .cancelled, .failed:
            horizontalPanStartLocation = nil
        default:
            break
        }
    }

    private func html(forPages pages: [TypstPreviewPage]) -> String {
        let scale = max(svgBackingScale, 1)
        let margin = Self.cssPixels(pageMargin * scale)
        let gap = Self.cssPixels(pageGap * scale)
        let pageHTML = pages.map { page in
            let width = max(page.widthPoints, 1)
            let height = max(page.heightPoints, 1)
            return """
            <div class="page" style="aspect-ratio: \(Self.cssPixels(width)) / \(Self.cssPixels(height));">
            \(page.svg)
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        html, body {
          margin: 0;
          padding: 0;
          width: 100%;
          min-height: 100%;
          overflow: hidden;
          background: transparent;
        }
        body {
          box-sizing: border-box;
          padding: \(margin)px;
        }
        .page {
          width: 100%;
          margin: 0 0 \(gap)px 0;
          overflow: hidden;
          background: transparent;
        }
        .page:last-child {
          margin-bottom: 0;
        }
        .page > svg {
          display: block;
          width: 100%;
          height: 100%;
        }
        </style>
        </head>
        <body>
        \(pageHTML)
        </body>
        </html>
        """
    }

    private static func cssPixels(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func cssPixels(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private static func makeDocumentWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        return webView
    }

}

extension SVGPreviewContainerView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalPanRecognizer,
              let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let startLocation = panRecognizer.location(in: self)
        let velocity = panRecognizer.velocity(in: self)
        return !allowsHorizontalScroll
            && startLocation.x > reservedNavigationEdgeWidth
            && velocity.x > 0
            && abs(velocity.x) > abs(velocity.y) * 1.35
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension SVGPreviewContainerView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let clampedX = clampedHorizontalOffset(scrollView.contentOffset.x)
        guard abs(scrollView.contentOffset.x - clampedX) > 0.5 else { return }
        scrollView.setContentOffset(
            CGPoint(x: clampedX, y: scrollView.contentOffset.y),
            animated: false
        )
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateScrollContentSize()
        updateScrollInsetsIfNeeded()
        clampContentOffsetIfNeeded()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateScrollContentSize()
        updateScrollInsetsIfNeeded()
        clampContentOffsetIfNeeded()
    }
}

extension SVGPreviewContainerView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        completePendingPageLoad(for: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === pendingPageView,
              let loadID = pendingLoadID else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstPaintDelay) { [weak self, weak webView] in
            guard let self,
                  let webView,
                  webView === self.pendingPageView,
                  self.pendingLoadID == loadID else {
                return
            }
            self.commitPendingPages(loadID: loadID)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completePendingPageLoad(for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completePendingPageLoad(for: webView)
    }
}

struct SVGPreviewView: UIViewRepresentable {
    let pages: [TypstPreviewPage]
    @Binding var isRendering: Bool
    var topViewportInset: CGFloat = 0
    var bottomViewportInset: CGFloat = 0
    var scrollTarget: PreviewScrollTarget?
    var backgroundColor: UIColor = .secondarySystemBackground
    var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?
    var onCompactPreviewSwipe: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SVGPreviewContainerView {
        let container = SVGPreviewContainerView()
        container.onLoadingStateChange = loadingStateHandler
        container.previewBackgroundColor = backgroundColor
        container.isAccessibilityElement = true
        container.accessibilityIdentifier = "editor.preview"
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady
        return container
    }

    func updateUIView(_ container: SVGPreviewContainerView, context: Context) {
        container.previewBackgroundColor = backgroundColor
        container.topViewportInset = topViewportInset
        container.bottomViewportInset = bottomViewportInset
        container.onTapLocation = onTapLocation
        container.onLoadingStateChange = loadingStateHandler
        container.onHorizontalSwipe = horizontalSwipeHandler
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady
        container.reloadPages(pages)

        if let target = scrollTarget, context.coordinator.lastAppliedScrollTarget != target {
            let didApply = container.scrollToPosition(
                page: target.page,
                yPoints: target.yPoints,
                xPoints: target.xPoints
            )
            if didApply {
                context.coordinator.lastAppliedScrollTarget = target
            }
        }
    }

    private var horizontalSwipeHandler: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        guard let onCompactPreviewSwipe else { return nil }
        return { direction in
            guard direction.contains(.right) else { return }
            onCompactPreviewSwipe()
        }
    }

    private var loadingStateHandler: (Bool) -> Void {
        { isLoading in
            Task { @MainActor in
                isRendering = isLoading
            }
        }
    }

    final class Coordinator {
        var lastAppliedScrollTarget: PreviewScrollTarget?
    }
}

// MARK: - PreviewPane

struct PreviewPane: View {
    var compiler: TypstCompiler
    var source: String
    var compileSource: String? = nil
    var fontPaths: [String] = []
    var fontWarnings: [CompileFontWarning] = []
    var preflightError: String? = nil
    var rootDir: String?
    var previewCacheDescriptor: CompiledPreviewCacheDescriptor? = nil
    var compileToken: UUID = UUID()
    var requiresExternalFolderLink: Bool = false
    var drivesCompilation: Bool = true
    var cancelsCompilerOnDisappear: Bool = true
    var focusCoordinator: EditorFocusCoordinator? = nil
    var sourceMap: SourceMap? = nil
    var syncCoordinator: SyncCoordinator? = nil
    /// The actual entry file name — Typst FFI internally reports it as "main.typ".
    var entryFileName: String = "main.typ"
    var topViewportInset: CGFloat = 0
    var overlayTopInset: CGFloat = 0
    var overlayBottomInset: CGFloat = 0
    var onGoToError: ((_ file: String, _ line: Int, _ column: Int) -> Void)? = nil
    var onCompactPreviewSwipe: (() -> Void)? = nil
    var onLinkExternalFolder: (() -> Void)? = nil
    var showsStatisticsOverlay: Bool = true
    var showsCompilingIndicatorOverlay: Bool = true
    var backgroundColor: UIColor = .secondarySystemBackground
    @ScaledMetric(relativeTo: .caption2) private var previewStatsCardWidth = 126
    @ScaledMetric(relativeTo: .caption2) private var previewStatsMinHeight = 34
    @ScaledMetric(relativeTo: .caption2) private var previewStatsHorizontalPadding = 8
    @ScaledMetric(relativeTo: .caption2) private var previewStatsVerticalPadding = 7
    @State private var isShowingErrorDetails = false
    @State private var isShowingStatsDetails = false
    @State private var cachedWordCount: Int = 0
    @State private var cachedCharacterCount: Int = 0
    @State private var dismissedFontWarningIDs: Set<String> = []
    @State private var keyboardOverlap: CGFloat = 0
    @State private var isSVGPreviewRendering = false
    @State private var lastCompileSignature: PreviewCompileInputSignature?

    private var previewStatistics: PreviewStatistics? {
        guard compiler.compiledOnce else { return nil }
        return PreviewStatistics(
            pageCount: max(compiler.pageCount, 0),
            wordCount: cachedWordCount,
            characterCount: cachedCharacterCount
        )
    }

    private var hasRenderablePreview: Bool {
        compiler.previewArtifact?.svgPages.isEmpty == false
    }

    private var isPreviewLoading: Bool {
        (compiler.isPreviewUpdating || isSVGPreviewRendering)
            && !requiresExternalFolderLink
    }

    private var visibleFontWarnings: [CompileFontWarning] {
        fontWarnings.filter { !dismissedFontWarningIDs.contains($0.id) }
    }

    private var keyboardAccessoryClearance: CGFloat { 80 }
    private var minimumBottomOverlayClearance: CGFloat { 0 }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if requiresExternalFolderLink {
                externalFolderLinkRequiredPlaceholder
                    .padding(.top, topViewportInset)
            } else if let artifact = compiler.previewArtifact, !artifact.svgPages.isEmpty {
                SVGPreviewView(
                    pages: artifact.svgPages,
                    isRendering: $isSVGPreviewRendering,
                    topViewportInset: topViewportInset,
                    bottomViewportInset: previewBottomViewportInset,
                    scrollTarget: syncCoordinator?.previewScrollTarget,
                    backgroundColor: backgroundColor,
                    onTapLocation: { page, yPoints in
                        guard let syncCoordinator,
                              let sourceMap,
                              let location = sourceMap.sourceLocation(forPage: page, yPoints: yPoints),
                              syncCoordinator.beginSync(.previewToEditor) else {
                            return
                        }

                        syncCoordinator.editorScrollTarget = EditorScrollTarget(
                            line: location.line,
                            column: location.column
                        )
                    },
                    onCompactPreviewSwipe: onCompactPreviewSwipe
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .softScrollEdgeEffect()
                .accessibilityLabel(L10n.a11yPreviewLabel)
                .accessibilityHint(L10n.a11yPreviewHint)
                .accessibilityValue(
                    compiler.errorMessage == nil ? L10n.a11yPreviewValueReady : L10n.a11yPreviewValueError
                )
                .accessibilityIdentifier("editor.preview")
            } else if isPreviewLoading {
                compilingPlaceholderView
                    .padding(.top, topViewportInset)
            } else {
                placeholderView
                    .padding(.top, topViewportInset)
            }

            if showsCompilingIndicatorOverlay && isPreviewLoading {
                compilingIndicatorOverlay
            }

            if showsBottomStatusOverlay {
                statusOverlay
            }
        }
            .background(Color(uiColor: backgroundColor))
            .onChange(of: source, initial: true) {
                if drivesCompilation {
                    compileIfNeeded()
                }
                recomputeTextStatistics()
            }
            .onChange(of: compileSource) { _, _ in
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: fontPaths) {
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: preflightError, initial: true) { _, _ in
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: rootDir) {
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: compileToken) {
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: requiresExternalFolderLink, initial: true) { _, _ in
                guard drivesCompilation else { return }
                compileIfNeeded()
            }
            .onChange(of: hasRenderablePreview) { _, hasPreview in
                if !hasPreview {
                    isSVGPreviewRendering = false
                    isShowingStatsDetails = false
                }
            }
            .onChange(of: compiler.errorMessage, initial: true) { _, newValue in
                if newValue != nil {
                    isSVGPreviewRendering = false
                }
                let shouldExpand = (newValue != nil) && !hasRenderablePreview
                guard shouldExpand != isShowingErrorDetails else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingErrorDetails = shouldExpand
                }
            }
            .onChange(of: fontWarnings) { _, newValue in
                let activeIDs = Set(newValue.map(\.id))
                dismissedFontWarningIDs.formIntersection(activeIDs)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                updateKeyboardOverlap(from: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                updateKeyboardOverlap(from: notification, forcedOverlap: 0)
            }
            .onDisappear {
                focusCoordinator?.clearFocusPreservation()
                if cancelsCompilerOnDisappear {
                    compiler.cancel()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: compiler.errorMessage)
            .animation(.easeInOut(duration: 0.2), value: isShowingErrorDetails)
            .animation(.easeInOut(duration: 0.2), value: fontWarnings)
    }

    private var showsBottomStatusOverlay: Bool {
        !requiresExternalFolderLink
            && (
                (showsStatisticsOverlay && previewStatistics != nil)
                || compiler.errorMessage != nil
                || !visibleFontWarnings.isEmpty
            )
    }

    private var compilingIndicatorOverlay: some View {
        GeometryReader { geometry in
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .systemFloatingSurface(cornerRadius: 8)
                .padding(.top, topOverlayPadding(safeAreaTop: geometry.safeAreaInsets.top))
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
        .zIndex(3)
    }

    private var statusOverlay: some View {
        GeometryReader { geometry in
            bottomStatusOverlay(bottomAvoidanceInset: bottomAvoidanceInset(safeAreaBottom: geometry.safeAreaInsets.bottom))
        }
        .zIndex(2)
    }

    private func topOverlayPadding(safeAreaTop: CGFloat) -> CGFloat {
        max(overlayTopInset, safeAreaTop) + 8
    }

    private var previewBottomViewportInset: CGFloat {
        max(overlayBottomInset, keyboardAvoidanceInset, keyboardAccessoryClearance)
    }

    private func bottomAvoidanceInset(safeAreaBottom: CGFloat) -> CGFloat {
        max(safeAreaBottom, overlayBottomInset, keyboardAvoidanceInset, minimumBottomOverlayClearance)
    }

    private var keyboardAvoidanceInset: CGFloat {
        keyboardOverlap > 0 ? keyboardOverlap + keyboardAccessoryClearance : 0
    }

    private func updateKeyboardOverlap(from notification: Notification, forcedOverlap: CGFloat? = nil) {
        let nextOverlap = forcedOverlap ?? keyboardOverlap(from: notification)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25

        withAnimation(.easeInOut(duration: duration)) {
            keyboardOverlap = nextOverlap
        }
    }

    private func keyboardOverlap(from notification: Notification) -> CGFloat {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let windowFrame = activeWindowFrameInScreenCoordinates() else {
            return 0
        }

        let overlap = windowFrame.maxY - endFrame.minY
        return max(0, overlap)
    }

    private func activeWindowFrameInScreenCoordinates() -> CGRect? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            .map { $0.convert($0.bounds, to: nil) }
    }

    private func recomputeTextStatistics() {
        let text = source
        Task.detached(priority: .utility) {
            let wordCount = text.previewWordCount
            let charCount = text.previewCharacterCount
            await MainActor.run {
                cachedWordCount = wordCount
                cachedCharacterCount = charCount
            }
        }
    }

    /// Only compile when the source contains meaningful content.
    private func compileIfNeeded() {
        let effectiveCompileSource = compileSource ?? source
        let signature = PreviewCompileInputSignature(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            preflightError: preflightError,
            rootDir: rootDir,
            previewCacheDescriptor: previewCacheDescriptor,
            compileToken: compileToken,
            requiresExternalFolderLink: requiresExternalFolderLink
        )
        guard signature != lastCompileSignature else { return }
        lastCompileSignature = signature

        if requiresExternalFolderLink {
            isSVGPreviewRendering = false
            compiler.cancel()
            compiler.clearPreview()
            return
        }
        guard !effectiveCompileSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSVGPreviewRendering = false
            compiler.clearPreview()
            return
        }
        if let preflightError {
            isSVGPreviewRendering = false
            compiler.presentPreflightError(preflightError)
            return
        }
        let mode: TypstCompileMode = compiler.compiledOnce || compiler.isPreviewUpdating ? .debounced : .immediate
        compiler.compile(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            rootDir: rootDir,
            mode: mode,
            previewCachePolicy: .useCacheIfValid,
            previewCacheDescriptor: previewCacheDescriptor
        )
    }

    // MARK: Sub-views

    private var externalFolderLinkRequiredPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.tr("preview.external_link_required.title"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L10n.tr("preview.external_link_required.message"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let onLinkExternalFolder {
                Button(action: onLinkExternalFolder) {
                    Label(L10n.tr("preview.external_link_required.button"), systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("editor.preview.link-external-folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("preview.external_link_required.title"))
        .accessibilityHint(L10n.tr("preview.external_link_required.message"))
        .accessibilityIdentifier("editor.preview.external-link-required")
    }

    private var compilingPlaceholderView: some View {
        Color(uiColor: backgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Compiling…"))
        .accessibilityValue(L10n.a11yPreviewValueEmpty)
        .accessibilityIdentifier("editor.preview")
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: compiler.errorMessage == nil ? "doc.richtext" : "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(compiler.errorMessage == nil ? L10n.tr("Preview") : L10n.tr("Compilation Error"))
                .font(.title2)
                .foregroundStyle(.secondary)
            if compiler.errorMessage == nil {
                Text(L10n.tr("Start typing to see a live preview"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: backgroundColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.a11yPreviewPlaceholderLabel)
        .accessibilityHint(L10n.a11yPreviewPlaceholderHint)
        .accessibilityValue(compiler.errorMessage == nil ? L10n.a11yPreviewValueEmpty : L10n.a11yPreviewValueError)
        .accessibilityIdentifier("editor.preview")
    }

    private func bottomStatusOverlay(bottomAvoidanceInset: CGFloat) -> some View {
        let bottomPadding = bottomAvoidanceInset + 18

        return VStack(alignment: .trailing, spacing: 10) {
            if showsStatisticsOverlay, let stats = previewStatistics {
                previewStatisticsButton(stats)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = compiler.errorMessage {
                errorToast(error)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !visibleFontWarnings.isEmpty {
                fontWarningToast(visibleFontWarnings)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func previewStatisticsButton(_ stats: PreviewStatistics) -> some View {
        let pageText = L10n.previewStatsPages(stats.pageCount)
        let cardCornerRadius: CGFloat = 18
        let expandedItems = [
            PreviewStatisticItem(title: L10n.tr("preview.stats.words.label"), value: "\(stats.wordCount)"),
            PreviewStatisticItem(title: L10n.tr("preview.stats.characters.label"), value: "\(stats.characterCount)")
        ]
        let accessibilitySecondaryText = L10n.previewStatsWords(stats.wordCount)
        let accessibilityCharacterText = L10n.previewStatsCharacters(stats.characterCount)

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isShowingStatsDetails.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: isShowingStatsDetails ? 6 : 0) {
                HStack(spacing: 6) {
                    Label(pageText, systemImage: "doc.text")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 4)

                    Image(systemName: isShowingStatsDetails ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if isShowingStatsDetails {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(expandedItems) { item in
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.95)

                                Spacer(minLength: 6)

                                Text(item.value)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: 6).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                }
            }
            .frame(minHeight: previewStatsMinHeight, alignment: .leading)
            .frame(width: previewStatsCardWidth, alignment: .leading)
            .padding(.horizontal, previewStatsHorizontalPadding)
            .padding(.vertical, previewStatsVerticalPadding)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .systemFloatingSurface(cornerRadius: cardCornerRadius)
        .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.a11yPreviewLabel)
        .accessibilityValue(
            isShowingStatsDetails
                ? L10n.previewStatsExpandedValue(
                    pages: pageText,
                    words: accessibilitySecondaryText,
                    characters: accessibilityCharacterText
                )
                : pageText
        )
        .accessibilityHint(isShowingStatsDetails ? L10n.previewStatsHintExpanded : L10n.previewStatsHintCollapsed)
        .accessibilityIdentifier("editor.preview.stats")
    }

    private func errorToast(_ message: String) -> some View {
        let presentation = errorPresentation(from: message)
        let showsDetailToggle =
            presentation.detail != presentation.summary || presentation.detail.count > 140

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
                    .background(Color.red.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Compilation Error"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(presentation.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(isShowingErrorDetails ? nil : 2)

                    if let location = presentation.location {
                        Button {
                            if let parsed = firstErrorLocation(from: message) {
                                onGoToError?(parsed.file, parsed.line, parsed.column)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "scope")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(location)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if onGoToError != nil {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(onGoToError == nil)
                    }
                }

                Spacer(minLength: 8)

                if showsDetailToggle {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingErrorDetails.toggle()
                        }
                    } label: {
                        Text(isShowingErrorDetails ? L10n.tr("Hide Details") : L10n.tr("Show Details"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if isShowingErrorDetails {
                ScrollView {
                    Text(presentation.detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .softScrollEdgeEffect()
                .frame(maxHeight: 160)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .compilationErrorSurface(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format(
                "a11y.preview.error.label_format",
                L10n.tr("Compilation Error"),
                presentation.summary
            )
        )
        .accessibilityValue(presentation.location ?? "")
    }

    private func fontWarningToast(_ warnings: [CompileFontWarning]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "textformat.alt")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("warning.font_fallback.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    ForEach(warnings.prefix(3)) { warning in
                        Text(warning.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        dismissedFontWarningIDs.formUnion(warnings.map(\.id))
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel(L10n.tr("warning.font_fallback.dismiss"))
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .systemFloatingSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 14, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("warning.font_fallback.title"))
        .accessibilityValue(warnings.map(\.message).joined(separator: " "))
    }

    private func normalizedErrorMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func errorPresentation(from message: String) -> CompilationErrorPresentation {
        let normalizedMessage = normalizedErrorMessage(message)
        let lines = normalizedMessage.components(separatedBy: .newlines)

        let location = lines.compactMap(parsedLocation(from:)).first
        let summary = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && parsedLocation(from: $0) == nil }) ?? normalizedMessage

        return CompilationErrorPresentation(
            summary: summary,
            detail: normalizedMessage,
            location: location
        )
    }

    private struct ParsedErrorLocation {
        let file: String
        let line: Int
        let column: Int
        var displayText: String { "\(file):\(line):\(column)" }
    }

    private func parsedLocation(from line: String) -> String? {
        parseErrorLocation(from: line)?.displayText
    }

    private func parseErrorLocation(from line: String) -> ParsedErrorLocation? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else { return nil }
        let candidate = String(trimmed.dropFirst().dropLast())
        let parts = candidate.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let lineNum = Int(parts[parts.count - 2]),
              let column = Int(parts[parts.count - 1]),
              lineNum > 0,
              column > 0 else {
            return nil
        }

        var path = parts.dropLast(2).joined(separator: ":")
        guard !path.isEmpty else { return nil }
        // Typst FFI names the entry source "main.typ" internally — map to actual name.
        if path == "main.typ" && entryFileName != "main.typ" {
            path = entryFileName
        }
        return ParsedErrorLocation(file: path, line: lineNum, column: column)
    }

    private func firstErrorLocation(from message: String) -> ParsedErrorLocation? {
        let lines = normalizedErrorMessage(message).components(separatedBy: .newlines)
        return lines.lazy.compactMap(parseErrorLocation(from:)).first
    }
}

struct PreviewCompileDriver: View {
    var compiler: TypstCompiler
    var source: String
    var compileSource: String?
    var fontPaths: [String]
    var preflightError: String?
    var rootDir: String?
    var previewCacheDescriptor: CompiledPreviewCacheDescriptor?
    var compileToken: UUID
    var requiresExternalFolderLink: Bool = false
    @State private var lastCompileSignature: PreviewCompileInputSignature?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: source, initial: true) { _, _ in
                compileIfNeeded()
            }
            .onChange(of: compileSource) { _, _ in
                compileIfNeeded()
            }
            .onChange(of: fontPaths) {
                compileIfNeeded()
            }
            .onChange(of: preflightError, initial: true) { _, _ in
                compileIfNeeded()
            }
            .onChange(of: rootDir) {
                compileIfNeeded()
            }
            .onChange(of: compileToken) {
                compileIfNeeded()
            }
            .onChange(of: requiresExternalFolderLink, initial: true) { _, _ in
                compileIfNeeded()
            }
            .onDisappear {
                compiler.cancel()
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func compileIfNeeded() {
        let effectiveCompileSource = compileSource ?? source
        let signature = PreviewCompileInputSignature(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            preflightError: preflightError,
            rootDir: rootDir,
            previewCacheDescriptor: previewCacheDescriptor,
            compileToken: compileToken,
            requiresExternalFolderLink: requiresExternalFolderLink
        )
        guard signature != lastCompileSignature else { return }
        lastCompileSignature = signature

        if requiresExternalFolderLink {
            compiler.cancel()
            compiler.clearPreview()
            return
        }
        guard !effectiveCompileSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            compiler.clearPreview()
            return
        }
        if let preflightError {
            compiler.presentPreflightError(preflightError)
            return
        }
        let mode: TypstCompileMode = compiler.compiledOnce || compiler.isPreviewUpdating ? .debounced : .immediate
        compiler.compile(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            rootDir: rootDir,
            mode: mode,
            previewCachePolicy: .useCacheIfValid,
            previewCacheDescriptor: previewCacheDescriptor
        )
    }
}

extension String {
    nonisolated var previewWordCount: Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = self

        var count = 0
        tokenizer.enumerateTokens(in: startIndex..<endIndex) { range, _ in
            if self[range].contains(where: { !$0.isWhitespace }) {
                count += 1
            }
            return true
        }
        return count
    }

    nonisolated var previewCharacterCount: Int {
        reduce(into: 0) { count, character in
            if character.countsTowardPreviewCharacter {
                count += 1
            }
        }
    }
}
