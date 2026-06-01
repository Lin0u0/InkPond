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

private struct SoftScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
        }
    }
}

private struct CompilationErrorPresentation {
    let summary: String
    let detail: String
    let location: String?
}

private struct PreviewStatistics {
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
    /// Incremented on each `scrollToPosition` call so stale scroll-animation
    /// completion handlers don't fire `showMarker` for an outdated position.
    private var scrollGeneration: UInt = 0
    /// When true, `reloadDocument` skips scroll restoration so that
    /// a pending `scrollToPosition` call can take priority.
    var suppressScrollRestoration = false
    var topViewportInset: CGFloat = 0 {
        didSet {
            guard oldValue != topViewportInset else { return }
            updateScrollInsetsIfNeeded()
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

    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollInsetsIfNeeded()
        alignShortDocumentToTopIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadDocument(_ document: PDFDocument, focusCoordinator: EditorFocusCoordinator?) {
        pdfView.backgroundColor = .secondarySystemBackground

        guard pdfView.document !== document else {
            focusCoordinator?.setResignSuppressed(false)
            return
        }

        let savedState = captureScrollState()

        // Prevent PDFKit from dismissing the software keyboard while it
        // tears down / rebuilds page views for the new document.
        focusCoordinator?.setResignSuppressed(true)
        pdfView.document = document

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

        DispatchQueue.main.async { [weak self, weak focusCoordinator] in
            guard let self, self.pdfView.document === document else { return }

            self.layoutIfNeeded()
            self.pdfView.layoutIfNeeded()
            self.pdfView.scaleFactor = self.clampedScaleFactor(savedState.scaleFactor)

            // Skip scroll restoration when a sync-driven scroll is pending —
            // scrollToPosition will handle positioning instead.
            if !self.suppressScrollRestoration {
                if let scrollView = self.findScrollView(in: self.pdfView) {
                    scrollView.layoutIfNeeded()
                    let clampedOffset = self.clampedContentOffset(
                        savedState.contentOffset,
                        in: scrollView
                    )
                    if scrollView.contentOffset != clampedOffset {
                        scrollView.setContentOffset(clampedOffset, animated: false)
                    }
                }
            }
            self.updateScrollInsetsIfNeeded()
            self.alignShortDocumentToTopIfNeeded()
            self.suppressScrollRestoration = false

            focusCoordinator?.setResignSuppressed(false)
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

    private func updateScrollInsetsIfNeeded(forcePinnedTop: Bool = false) {
        guard let scrollView = findScrollView(in: pdfView) else { return }

        let previousAdjustedTop = scrollView.adjustedContentInset.top
        let wasPinnedToTop = forcePinnedTop || abs(scrollView.contentOffset.y + previousAdjustedTop) < 2

        if scrollView.contentInset.top != topViewportInset {
            var insets = scrollView.contentInset
            insets.top = topViewportInset
            scrollView.contentInset = insets
        }

        if scrollView.verticalScrollIndicatorInsets.top != topViewportInset {
            var indicatorInsets = scrollView.verticalScrollIndicatorInsets
            indicatorInsets.top = topViewportInset
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
    var scrollTarget: PreviewScrollTarget?
    var onTapLocation: ((_ page: Int, _ yPoints: Float) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapLocation: onTapLocation)
    }

    func makeUIView(context: Context) -> PDFContainerView {
        focusCoordinator?.setResignSuppressed(true)
        context.coordinator.isHoldingInitialMountSuppression = true

        let container = PDFContainerView()
        let pdfView = container.pdfView
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.isAccessibilityElement = false
        container.isAccessibilityElement = true
        container.accessibilityIdentifier = "editor.preview"
        container.accessibilityLabel = L10n.a11yPreviewLabel
        container.accessibilityHint = L10n.a11yPreviewHint
        container.accessibilityValue = L10n.a11yPreviewValueReady

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        pdfView.addGestureRecognizer(tapGesture)
        context.coordinator.pdfView = pdfView

        return container
    }

    func updateUIView(_ container: PDFContainerView, context: Context) {
        context.coordinator.onTapLocation = onTapLocation
        context.coordinator.pdfView = container.pdfView
        container.topViewportInset = topViewportInset
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
            context.coordinator.lastAppliedScrollTarget = nil
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
    var onGoToError: ((_ file: String, _ line: Int, _ column: Int) -> Void)? = nil
    var onLinkExternalFolder: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .caption2) private var previewStatsCardWidth = 126
    @ScaledMetric(relativeTo: .caption2) private var previewStatsMinHeight = 34
    @ScaledMetric(relativeTo: .caption2) private var previewStatsHorizontalPadding = 8
    @ScaledMetric(relativeTo: .caption2) private var previewStatsVerticalPadding = 7
    @State private var isShowingErrorDetails = false
    @State private var isShowingStatsDetails = false
    @State private var cachedWordCount: Int = 0
    @State private var cachedCharacterCount: Int = 0
    @State private var dismissedFontWarningIDs: Set<String> = []

    private var previewStatistics: PreviewStatistics? {
        guard let pdf = compiler.pdfDocument else { return nil }
        return PreviewStatistics(
            pageCount: max(pdf.pageCount, 0),
            wordCount: cachedWordCount,
            characterCount: cachedCharacterCount
        )
    }

    private var visibleFontWarnings: [CompileFontWarning] {
        fontWarnings.filter { !dismissedFontWarningIDs.contains($0.id) }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if requiresExternalFolderLink {
                externalFolderLinkRequiredPlaceholder
                    .padding(.top, topViewportInset)
            } else if let pdf = compiler.pdfDocument {
                PDFKitView(
                    document: pdf,
                    focusCoordinator: focusCoordinator,
                    topViewportInset: 0,
                    scrollTarget: syncCoordinator?.previewScrollTarget,
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
                    }
                )
                .padding(.top, topViewportInset)
                .ignoresSafeArea(.container, edges: .bottom)
                .modifier(SoftScrollEdgeEffect())
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

            if compiler.isCompiling && !requiresExternalFolderLink {
                GeometryReader { geometry in
                    let topPadding = topViewportInset > 0
                        ? topViewportInset + 8
                        : geometry.safeAreaInsets.top + 12
                    ProgressView()
                        .padding(8)
                        .systemFloatingSurface(cornerRadius: 8)
                        .padding(.top, topPadding)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .allowsHitTesting(false)
                .zIndex(1)
            }

            if !requiresExternalFolderLink
                && (previewStatistics != nil || compiler.errorMessage != nil || !visibleFontWarnings.isEmpty) {
                bottomStatusOverlay
            }
        }
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
            .onChange(of: compiler.pdfDocument != nil) { _, hasPreview in
                guard !hasPreview else { return }
                isShowingStatsDetails = false
            }
            .onChange(of: compiler.errorMessage, initial: true) { _, newValue in
                let shouldExpand = (newValue != nil) && (compiler.pdfDocument == nil)
                guard shouldExpand != isShowingErrorDetails else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingErrorDetails = shouldExpand
                }
            }
            .onChange(of: fontWarnings) { _, newValue in
                let activeIDs = Set(newValue.map(\.id))
                dismissedFontWarningIDs.formIntersection(activeIDs)
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
        .background(Color(uiColor: .secondarySystemBackground))
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
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.a11yPreviewPlaceholderLabel)
        .accessibilityHint(L10n.a11yPreviewPlaceholderHint)
        .accessibilityValue(compiler.errorMessage == nil ? L10n.a11yPreviewValueEmpty : L10n.a11yPreviewValueError)
        .accessibilityIdentifier("editor.preview.placeholder")
    }

    private var bottomStatusOverlay: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let stats = previewStatistics {
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
        .padding(.bottom, 16)
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

private extension String {
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
