//
//  PreviewPane.swift
//  InkPond
//
//  Shows the compiled PDF, a compilation error banner, or a placeholder
//  when the Typst compiler library hasn't been linked yet.
//

import SwiftUI
import PDFKit
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

// MARK: - PDFKit wrapper

/// PDFView subclass that refuses first-responder so it never steals focus
/// from the text editor (which would dismiss the software keyboard on iPadOS).
private final class PassivePDFView: PDFView {
    override var canBecomeFirstResponder: Bool { false }
}

private struct PDFPreviewScrollState {
    let contentOffset: CGPoint
    let scaleFactor: CGFloat
}

final class PDFContainerView: UIView {
    fileprivate let pdfView = PassivePDFView()
    private let syncMarkerView = PreviewSyncMarkerView()
    var previewBackgroundColor: UIColor = .secondarySystemBackground {
        didSet { applyPreviewBackgroundColor() }
    }
    private var horizontalSwipeRecognizers: [UIGestureRecognizer] = []
    private weak var horizontalPanRecognizer: UIPanGestureRecognizer?
    private var horizontalPanStartLocation: CGPoint?
    private let reservedNavigationEdgeWidth: CGFloat = 44
    /// Incremented on each `scrollToPosition` call so stale scroll-animation
    /// completion handlers don't fire `showMarker` for an outdated position.
    private var scrollGeneration: UInt = 0
    /// When true, `reloadDocument` skips scroll restoration so that
    /// a pending `scrollToPosition` call can take priority.
    var suppressScrollRestoration = false
    var onHorizontalSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        didSet {
            horizontalSwipeRecognizers.forEach { $0.isEnabled = onHorizontalSwipe != nil }
        }
    }
    var topViewportInset: CGFloat = 0 {
        didSet {
            guard oldValue != topViewportInset else { return }
            updateScrollInsetsIfNeeded()
        }
    }
    var bottomViewportInset: CGFloat = 0 {
        didSet {
            guard oldValue != bottomViewportInset else { return }
            updateScrollInsetsIfNeeded()
            alignShortDocumentToTopIfNeeded()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(pdfView)
        addSubview(syncMarkerView)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        syncMarkerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            syncMarkerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            syncMarkerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            syncMarkerView.topAnchor.constraint(equalTo: topAnchor),
            syncMarkerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyPreviewBackgroundColor()

        installHorizontalSwipeRecognizers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollInsetsIfNeeded()
        alignShortDocumentToTopIfNeeded()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalPanRecognizer,
              let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        let startLocation = panRecognizer.location(in: pdfView)
        let velocity = panRecognizer.velocity(in: pdfView)
        return startLocation.x > reservedNavigationEdgeWidth
            && velocity.x > 0
            && abs(velocity.x) > abs(velocity.y) * 1.35
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadDocument(_ document: PDFDocument, focusCoordinator: EditorFocusCoordinator?) {
        applyPreviewBackgroundColor()

        guard pdfView.document !== document else {
            focusCoordinator?.setResignSuppressed(false)
            return
        }

        let savedState = captureScrollState()

        // Prevent PDFKit from dismissing the software keyboard while it
        // tears down / rebuilds page views for the new document.
        focusCoordinator?.setResignSuppressed(true)
        UIView.performWithoutAnimation {
            pdfView.document = document
        }

        guard let savedState else {
            // First load: let PDFView pick the initial scale automatically.
            pdfView.autoScales = true
            DispatchQueue.main.async { [weak self, weak focusCoordinator] in
                guard let self, self.pdfView.document === document else { return }
                self.layoutIfNeeded()
                self.pdfView.layoutIfNeeded()
                self.updateScrollInsetsIfNeeded(forcePinnedTop: true)
                self.alignShortDocumentToTopIfNeeded()
                DispatchQueue.main.async { [weak self, weak focusCoordinator] in
                    guard let self, self.pdfView.document === document else { return }
                    focusCoordinator?.setResignSuppressed(false)
                }
            }
            return
        }

        pdfView.autoScales = false
        pdfView.scaleFactor = savedState.scaleFactor

        // PDFKit resets its internal scroll view when the document changes.
        // Restore once synchronously so the reset position is not visible for
        // one frame, then keep the async pass below as a layout-safe correction.
        restoreScrollState(savedState)

        DispatchQueue.main.async { [weak self, weak focusCoordinator] in
            guard let self, self.pdfView.document === document else { return }

            self.restoreScrollState(savedState)
            self.updateScrollInsetsIfNeeded()
            self.alignShortDocumentToTopIfNeeded()
            self.suppressScrollRestoration = false

            focusCoordinator?.setResignSuppressed(false)
        }
    }

    private func restoreScrollState(_ savedState: PDFPreviewScrollState) {
        layoutIfNeeded()
        pdfView.layoutIfNeeded()
        pdfView.scaleFactor = clampedScaleFactor(savedState.scaleFactor)

        // Skip scroll restoration when a sync-driven scroll is pending —
        // scrollToPosition will handle positioning instead.
        guard !suppressScrollRestoration,
              let scrollView = findScrollView(in: pdfView) else {
            return
        }

        scrollView.layoutIfNeeded()
        let clampedOffset = clampedContentOffset(
            savedState.contentOffset,
            in: scrollView
        )
        if scrollView.contentOffset != clampedOffset {
            scrollView.setContentOffset(clampedOffset, animated: false)
        }
    }

    private func captureScrollState() -> PDFPreviewScrollState? {
        guard pdfView.document != nil,
              let scrollView = findScrollView(in: pdfView) else {
            return nil
        }

        return PDFPreviewScrollState(
            contentOffset: scrollView.contentOffset,
            scaleFactor: pdfView.scaleFactor
        )
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }

    private func applyPreviewBackgroundColor() {
        backgroundColor = previewBackgroundColor
        pdfView.backgroundColor = previewBackgroundColor
        if let scrollView = findScrollView(in: pdfView) {
            scrollView.backgroundColor = previewBackgroundColor
            scrollView.applySoftScrollEdgeEffects()
        }
    }

    private func updateScrollInsetsIfNeeded(forcePinnedTop: Bool = false) {
        guard let scrollView = findScrollView(in: pdfView) else { return }
        scrollView.applySoftScrollEdgeEffects()
        scrollView.alwaysBounceVertical = true

        let previousAdjustedTop = scrollView.adjustedContentInset.top
        let wasPinnedToTop = forcePinnedTop || abs(scrollView.contentOffset.y + previousAdjustedTop) < 2

        if scrollView.contentInset.top != topViewportInset
            || scrollView.contentInset.bottom != bottomViewportInset {
            var insets = scrollView.contentInset
            insets.top = topViewportInset
            insets.bottom = bottomViewportInset
            scrollView.contentInset = insets
        }

        if scrollView.verticalScrollIndicatorInsets.top != topViewportInset
            || scrollView.verticalScrollIndicatorInsets.bottom != bottomViewportInset {
            var indicatorInsets = scrollView.verticalScrollIndicatorInsets
            indicatorInsets.top = topViewportInset
            indicatorInsets.bottom = bottomViewportInset
            scrollView.verticalScrollIndicatorInsets = indicatorInsets
        }

        if wasPinnedToTop {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                animated: false
            )
        }
    }

    private func alignShortDocumentToTopIfNeeded() {
        guard let scrollView = findScrollView(in: pdfView),
              let documentView = pdfView.documentView,
              documentView.superview != nil else {
            return
        }

        scrollView.layoutIfNeeded()
        documentView.layoutIfNeeded()

        let visibleHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        let documentRectInPDFView = documentView.convert(documentView.bounds, to: pdfView)
        guard visibleHeight > 0,
              documentRectInPDFView.height > 0,
              documentRectInPDFView.height < visibleHeight else {
            return
        }

        let documentTopInPDFView = documentRectInPDFView.minY
        let targetTopInPDFView = pdfView.bounds.minY + scrollView.adjustedContentInset.top
        let verticalDelta = targetTopInPDFView - documentTopInPDFView
        guard abs(verticalDelta) > 0.5 else { return }

        var frame = documentView.frame
        frame.origin.y += verticalDelta
        documentView.frame = frame
    }

    private func clampedContentOffset(_ contentOffset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)

        return CGPoint(
            x: min(max(contentOffset.x, minX), maxX),
            y: min(max(contentOffset.y, minY), maxY)
        )
    }

    private func clampedScaleFactor(_ scaleFactor: CGFloat) -> CGFloat {
        let minScale = pdfView.minScaleFactor > 0 ? pdfView.minScaleFactor : scaleFactor
        let maxScale = pdfView.maxScaleFactor > 0 ? pdfView.maxScaleFactor : scaleFactor
        return min(max(scaleFactor, minScale), maxScale)
    }

    private func installHorizontalSwipeRecognizers() {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = onHorizontalSwipe != nil
        pdfView.addGestureRecognizer(recognizer)
        horizontalPanRecognizer = recognizer
        horizontalSwipeRecognizers.append(recognizer)
    }

    @objc private func handleHorizontalPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            horizontalPanStartLocation = recognizer.location(in: pdfView)
        case .ended:
            defer { horizontalPanStartLocation = nil }
            let translation = recognizer.translation(in: pdfView)
            guard let startLocation = horizontalPanStartLocation,
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
}

extension PDFContainerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === horizontalPanRecognizer else { return true }
        guard let otherView = otherGestureRecognizer.view else { return false }
        return otherView === pdfView || otherView.isDescendant(of: pdfView)
    }
}

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

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let focusCoordinator: EditorFocusCoordinator?
    var topViewportInset: CGFloat = 0
    var bottomViewportInset: CGFloat = 0
    var scrollTarget: PreviewScrollTarget?
    var backgroundColor: UIColor = .secondarySystemBackground
    var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?
    var onCompactPreviewSwipe: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapLocation: onTapLocation)
    }

    func makeUIView(context: Context) -> PDFContainerView {
        focusCoordinator?.setResignSuppressed(true)
        context.coordinator.isHoldingInitialMountSuppression = true

        let container = PDFContainerView()
        container.previewBackgroundColor = backgroundColor
        let pdfView = container.pdfView
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.isAccessibilityElement = false
        container.isAccessibilityElement = true
        container.accessibilityIdentifier = "editor.preview"
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady
        container.onHorizontalSwipe = horizontalSwipeHandler

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        pdfView.addGestureRecognizer(tapGesture)
        context.coordinator.pdfView = pdfView

        return container
    }

    func updateUIView(_ container: PDFContainerView, context: Context) {
        context.coordinator.onTapLocation = onTapLocation
        context.coordinator.pdfView = container.pdfView
        container.previewBackgroundColor = backgroundColor
        container.onHorizontalSwipe = horizontalSwipeHandler
        container.topViewportInset = topViewportInset
        container.bottomViewportInset = bottomViewportInset
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady

        if context.coordinator.isHoldingInitialMountSuppression {
            context.coordinator.isHoldingInitialMountSuppression = false
            DispatchQueue.main.async { [weak focusCoordinator] in
                DispatchQueue.main.async {
                    focusCoordinator?.setResignSuppressed(false)
                }
            }
        }

        let documentChanged = context.coordinator.lastDocument !== document
        if documentChanged {
            context.coordinator.lastDocument = document
        }

        let hasScrollTarget = scrollTarget != nil
            && context.coordinator.lastAppliedScrollTarget != scrollTarget

        // Tell reloadDocument to skip scroll restoration when we'll scroll via sync target.
        if documentChanged && hasScrollTarget {
            container.suppressScrollRestoration = true
        }

        container.reloadDocument(document, focusCoordinator: focusCoordinator)

        if let target = scrollTarget, context.coordinator.lastAppliedScrollTarget != target {
            container.scrollToPosition(page: target.page, yPoints: target.yPoints, xPoints: target.xPoints)
            context.coordinator.lastAppliedScrollTarget = target
        }
    }

    private var horizontalSwipeHandler: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        guard let onCompactPreviewSwipe else { return nil }
        return { direction in
            guard direction.contains(.right) else { return }
            onCompactPreviewSwipe()
        }
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        weak var lastDocument: PDFDocument?
        var lastAppliedScrollTarget: PreviewScrollTarget?
        var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?
        var isHoldingInitialMountSuppression = false

        init(onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?) {
            self.onTapLocation = onTapLocation
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView, let document = pdfView.document else { return }
            let tapPoint = gesture.location(in: pdfView)

            guard let tappedPage = pdfView.page(for: tapPoint, nearest: true) else { return }
            let pagePoint = pdfView.convert(tapPoint, to: tappedPage)
            let pageIndex = document.index(for: tappedPage)

            // PDFKit Y is from bottom-left; convert to top-down.
            let pageBounds = tappedPage.bounds(for: .mediaBox)
            let yFromTop = pageBounds.height - pagePoint.y

            onTapLocation?(pageIndex, Float(yFromTop))
        }
    }
}

extension PDFContainerView {
    func scrollToPosition(page: Int, yPoints: Float, xPoints: Float) {
        guard let document = pdfView.document,
              page < document.pageCount,
              let pdfPage = document.page(at: page) else { return }

        // Convert top-down Y to PDFKit bottom-up coordinate.
        let pageBounds = pdfPage.bounds(for: .mediaBox)
        let pdfY = pageBounds.height - CGFloat(yPoints)
        let pdfX = CGFloat(xPoints)

        // Check if the target is already near the visible area.
        // If so, skip `go(to:)` to avoid a jarring double-scroll bounce
        // (go(to:) overshoots, then the refined animation corrects it).
        let targetInView = pdfView.convert(CGPoint(x: pdfX, y: pdfY), from: pdfPage)
        let visibleRect = pdfView.bounds.insetBy(dx: 0, dy: -pdfView.bounds.height * 0.5)
        if !visibleRect.contains(targetInView) {
            let destination = PDFDestination(page: pdfPage, at: CGPoint(x: pdfX, y: pdfY))
            pdfView.go(to: destination)
        }

        // Defer the precise positioning to let PDFKit finish its internal layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pdfView.document === document else { return }
            self.layoutIfNeeded()
            self.pdfView.layoutIfNeeded()

            guard let scrollView = self.findScrollView(in: self.pdfView) else { return }

            // Convert page-space point through scroll view to get content coordinates.
            let pointInPDFView = self.pdfView.convert(CGPoint(x: pdfX, y: pdfY), from: pdfPage)
            let pointInScrollContent = scrollView.convert(pointInPDFView, from: self.pdfView)

            // Position the target at ~1/3 from the top of the visible area.
            let anchorRatio: CGFloat = 0.33
            let desiredOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: pointInScrollContent.y - scrollView.bounds.height * anchorRatio
            )
            let clampedOffset = self.clampedContentOffset(desiredOffset, in: scrollView)
            let needsScroll = abs(scrollView.contentOffset.y - clampedOffset.y) > 2

            self.scrollGeneration &+= 1
            let currentGeneration = self.scrollGeneration

            let showMarker = { [weak self] in
                guard let self, self.scrollGeneration == currentGeneration else { return }
                let updatedPoint = self.pdfView.convert(CGPoint(x: pdfX, y: pdfY), from: pdfPage)
                let markerPoint = self.convert(updatedPoint, from: self.pdfView)
                self.syncMarkerView.show(at: markerPoint)
            }

            if needsScroll {
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                    scrollView.contentOffset = clampedOffset
                } completion: { _ in
                    showMarker()
                }
            } else {
                showMarker()
            }
        }
    }

}

// MARK: - SVG wrapper

final class SVGPreviewContainerView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let syncMarkerView = PreviewSyncMarkerView()
    private var pageViews: [WKWebView] = []
    private var pendingPageViews: [WKWebView] = []
    private var pageFrames: [CGRect] = []
    private var pages: [TypstPreviewPage] = []
    private var pendingPages: [TypstPreviewPage]?
    private var pendingLoadID: UUID?
    private var pendingPageIDs: Set<ObjectIdentifier> = []
    private weak var horizontalPanRecognizer: UIPanGestureRecognizer?
    private var horizontalPanStartLocation: CGPoint?
    private let reservedNavigationEdgeWidth: CGFloat = 44
    private let pageGap: CGFloat = 12
    private let pageMargin: CGFloat = 16
    private let maximumZoomScale: CGFloat = 4
    private var lastLaidOutWidth: CGFloat = 0
    private var scrollGeneration: UInt = 0

    var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?
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
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maximumZoomScale
        scrollView.zoomScale = 1
        scrollView.applySoftScrollEdgeEffects()
        addSubview(scrollView)
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
    }

    func reloadPages(_ newPages: [TypstPreviewPage]) {
        guard pages != newPages else {
            layoutPagesIfNeeded()
            return
        }
        guard pendingPages != newPages else {
            layoutPagesIfNeeded()
            return
        }

        cancelPendingPageLoad()
        guard !newPages.isEmpty else {
            pageViews.forEach { $0.removeFromSuperview() }
            pageViews = []
            pages = []
            pageFrames = []
            pendingPages = nil
            pendingLoadID = nil
            pendingPageIDs = []
            lastLaidOutWidth = 0
            layoutPagesIfNeeded(force: true)
            return
        }

        let loadID = UUID()
        pendingLoadID = loadID
        pendingPages = newPages
        pendingPageViews = newPages.map { page in
            let webView = Self.makePageWebView()
            webView.isHidden = true
            webView.navigationDelegate = self
            contentView.addSubview(webView)
            pendingPageIDs.insert(ObjectIdentifier(webView))
            webView.loadHTMLString(Self.html(forSVG: page.svg), baseURL: nil)
            return webView
        }
    }

    func scrollToPosition(page: Int, yPoints: Float, xPoints: Float) {
        layoutIfNeeded()
        layoutPagesIfNeeded()
        guard page >= 0, page < pageFrames.count else { return }

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
    }

    private func layoutPagesIfNeeded(force: Bool = false) {
        let layoutWidth = max(bounds.width, 1)
        guard force
                || abs(layoutWidth - lastLaidOutWidth) > 0.5
                || pageFrames.count != pages.count else {
            return
        }

        let savedZoomScale = scrollView.zoomScale
        let savedOffset = scrollView.contentOffset
        if savedZoomScale != scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }

        let availableWidth = max(layoutWidth - pageMargin * 2, 1)
        var y = pageMargin
        pageFrames = []
        pageFrames.reserveCapacity(pages.count)

        for (index, page) in pages.enumerated() {
            let sourceWidth = max(CGFloat(page.widthPoints), 1)
            let sourceHeight = max(CGFloat(page.heightPoints), 1)
            let width = availableWidth
            let height = max(sourceHeight * (width / sourceWidth), 1)
            let frame = CGRect(x: pageMargin, y: y, width: width, height: height)
            pageFrames.append(frame)
            if index < pageViews.count {
                pageViews[index].frame = frame
            }
            y += height + pageGap
        }

        if !pageFrames.isEmpty {
            y -= pageGap
        }
        y += pageMargin
        contentView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: max(y, bounds.height + 1))
        scrollView.contentSize = contentView.frame.size
        lastLaidOutWidth = layoutWidth

        if savedZoomScale != scrollView.minimumZoomScale {
            scrollView.setZoomScale(min(savedZoomScale, scrollView.maximumZoomScale), animated: false)
            scrollView.setContentOffset(clampedContentOffset(savedOffset), animated: false)
        }
    }

    private func scaleForPage(at index: Int) -> CGFloat {
        guard index >= 0, index < pages.count, index < pageFrames.count else { return 1 }
        return pageFrames[index].width / max(CGFloat(pages[index].widthPoints), 1)
    }

    private func updateScrollInsetsIfNeeded() {
        if scrollView.contentInset.top != topViewportInset
            || scrollView.contentInset.bottom != bottomViewportInset {
            var insets = scrollView.contentInset
            insets.top = topViewportInset
            insets.bottom = bottomViewportInset
            scrollView.contentInset = insets
        }
        scrollView.verticalScrollIndicatorInsets.top = topViewportInset
        scrollView.verticalScrollIndicatorInsets.bottom = bottomViewportInset
    }

    private func clampedContentOffset(_ contentOffset: CGPoint) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        return CGPoint(
            x: 0,
            y: min(max(contentOffset.y, minY), maxY)
        )
    }

    private func applyPreviewBackgroundColor() {
        backgroundColor = previewBackgroundColor
        scrollView.backgroundColor = previewBackgroundColor
        contentView.backgroundColor = previewBackgroundColor
        (pageViews + pendingPageViews).forEach { webView in
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
    }

    private func completePendingPageLoad(for webView: WKWebView) {
        let pageID = ObjectIdentifier(webView)
        guard pendingPageIDs.remove(pageID) != nil,
              let loadID = pendingLoadID,
              pendingPageIDs.isEmpty else {
            return
        }
        commitPendingPages(loadID: loadID)
    }

    private func commitPendingPages(loadID: UUID) {
        guard pendingLoadID == loadID,
              let nextPages = pendingPages else {
            return
        }

        let oldPageViews = pageViews
        let loadedPageViews = pendingPageViews
        let savedOffset = scrollView.contentOffset

        pageViews = loadedPageViews
        pages = nextPages
        pendingPageViews = []
        pendingPages = nil
        pendingLoadID = nil
        pendingPageIDs = []
        lastLaidOutWidth = 0

        setNeedsLayout()
        layoutIfNeeded()
        layoutPagesIfNeeded(force: true)
        scrollView.setContentOffset(clampedContentOffset(savedOffset), animated: false)

        loadedPageViews.forEach { webView in
            webView.isHidden = false
            webView.navigationDelegate = nil
        }
        oldPageViews.forEach { $0.removeFromSuperview() }
    }

    private func cancelPendingPageLoad() {
        pendingPageViews.forEach { webView in
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        pendingPageViews = []
        pendingPages = nil
        pendingLoadID = nil
        pendingPageIDs = []
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
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.05 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(maximumZoomScale, 2.5)
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

    private static func html(forSVG svg: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
        svg { display: block; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        \(svg)
        </body>
        </html>
        """
    }

    private static func makePageWebView() -> WKWebView {
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
        return startLocation.x > reservedNavigationEdgeWidth
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
}

extension SVGPreviewContainerView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completePendingPageLoad(for: webView)
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
        container.onHorizontalSwipe = horizontalSwipeHandler
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady
        container.reloadPages(pages)

        if let target = scrollTarget, context.coordinator.lastAppliedScrollTarget != target {
            container.scrollToPosition(page: target.page, yPoints: target.yPoints, xPoints: target.xPoints)
            context.coordinator.lastAppliedScrollTarget = target
        }
    }

    private var horizontalSwipeHandler: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        guard let onCompactPreviewSwipe else { return nil }
        return { direction in
            guard direction.contains(.right) else { return }
            onCompactPreviewSwipe()
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

    private var previewStatistics: PreviewStatistics? {
        guard compiler.compiledOnce else { return nil }
        return PreviewStatistics(
            pageCount: max(compiler.pageCount, 0),
            wordCount: cachedWordCount,
            characterCount: cachedCharacterCount
        )
    }

    private var hasRenderablePreview: Bool {
        if let artifact = compiler.previewArtifact, !artifact.svgPages.isEmpty {
            return true
        }
        return compiler.pdfDocument != nil
    }

    private var visibleFontWarnings: [CompileFontWarning] {
        fontWarnings.filter { !dismissedFontWarningIDs.contains($0.id) }
    }

    private var keyboardAccessoryClearance: CGFloat { 80 }
    private var minimumBottomOverlayClearance: CGFloat { 96 }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if requiresExternalFolderLink {
                externalFolderLinkRequiredPlaceholder
                    .padding(.top, topViewportInset)
            } else if let artifact = compiler.previewArtifact, !artifact.svgPages.isEmpty {
                SVGPreviewView(
                    pages: artifact.svgPages,
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
            } else if let pdf = compiler.pdfDocument {
                PDFKitView(
                    document: pdf,
                    focusCoordinator: focusCoordinator,
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
            } else {
                placeholderView
                    .padding(.top, topViewportInset)
            }

            if showsCompilingIndicatorOverlay && compiler.isCompiling && !requiresExternalFolderLink {
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
                guard !hasPreview else { return }
                isShowingStatsDetails = false
            }
            .onChange(of: compiler.errorMessage, initial: true) { _, newValue in
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
                .padding(.trailing, 16)
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
        max(topViewportInset, overlayTopInset, safeAreaTop) + 14
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
        if requiresExternalFolderLink {
            compiler.cancel()
            compiler.clearPreview()
            return
        }
        let effectiveCompileSource = compileSource ?? source
        guard !effectiveCompileSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            compiler.clearPreview()
            return
        }
        if let preflightError {
            compiler.presentPreflightError(preflightError)
            return
        }
        compiler.compile(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            rootDir: rootDir,
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
        if requiresExternalFolderLink {
            compiler.cancel()
            compiler.clearPreview()
            return
        }
        let effectiveCompileSource = compileSource ?? source
        guard !effectiveCompileSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            compiler.clearPreview()
            return
        }
        if let preflightError {
            compiler.presentPreflightError(preflightError)
            return
        }
        compiler.compile(
            source: effectiveCompileSource,
            fontPaths: fontPaths,
            rootDir: rootDir,
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
