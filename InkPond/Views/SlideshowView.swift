//
//  SlideshowView.swift
//  InkPond
//
//  Full-screen SVG slideshow: one page at a time, swipe or arrow buttons to navigate.
//

import SwiftUI
import WebKit

enum SlideshowSceneGeometry {
    static func matches(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        lhs.count == 3 && rhs.count == 3 && zip(lhs, rhs).allSatisfy {
            abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01
        }
    }
}

private final class SVGSlideshowContainerView: UIView, WKNavigationDelegate {
    private let webView: WKWebView
    private var pages: [TypstPreviewPage] = []
    private var currentPage = 0
    private var isLoaded = false
    private var lastLaidOutSize: CGSize = .zero
    private var boundsReportGeneration = 0
    private var geometryDisplayLink: CADisplayLink?
    private var geometryFramesRemaining = 0
    private var geometryWarmupFrames = 0
    private var stableGeometryFrames = 0
    private var lastConversionBasis: [CGPoint] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            geometryDisplayLink?.invalidate()
            geometryDisplayLink = nil
        } else if isLoaded {
            reportPageBounds()
        }
    }

    private func conversionBasis(presentation: Bool) -> [CGPoint] {
        guard let window else { return [] }
        let layer = presentation ? (webView.layer.presentation() ?? webView.layer) : webView.layer
        let target = presentation ? (window.layer.presentation() ?? window.layer) : window.layer
        let bounds = webView.bounds
        return [bounds.origin, CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY)].map { layer.convert($0, to: target) }
    }

    @objc private func sampleSceneGeometry() {
        guard window != nil else {
            geometryDisplayLink?.invalidate()
            geometryDisplayLink = nil
            return
        }
        geometryFramesRemaining -= 1
        geometryWarmupFrames -= 1
        let basis = conversionBasis(presentation: true)
        let model = conversionBasis(presentation: false)
        let unchanged = SlideshowSceneGeometry.matches(basis, lastConversionBasis)
        let settled = SlideshowSceneGeometry.matches(basis, model)
        stableGeometryFrames = unchanged && settled ? stableGeometryFrames + 1 : 0
        lastConversionBasis = basis
        if geometryWarmupFrames <= 0 && stableGeometryFrames >= 6 {
            geometryDisplayLink?.invalidate()
            geometryDisplayLink = nil
            measurePageBounds()
        } else if geometryFramesRemaining <= 0 {
            // Do not publish a mid-transition estimate as settled geometry.
            geometryDisplayLink?.invalidate()
            geometryDisplayLink = nil
        }
    }

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)

        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityIdentifier = "slideshow.deck"
        accessibilityLabel = L10n.tr("Slideshow")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .black
        webView.isUserInteractionEnabled = false

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard abs(size.width - lastLaidOutSize.width) > 0.5
                || abs(size.height - lastLaidOutSize.height) > 0.5 else {
            if isLoaded { reportPageBounds() }
            return
        }
        lastLaidOutSize = size
        updateDeckLayout()
    }

    func updatePages(_ newPages: [TypstPreviewPage]) {
        guard pages != newPages else { return }
        pages = newPages
        isLoaded = false
        lastLaidOutSize = .zero
        webView.loadHTMLString(Self.html(forPages: newPages), baseURL: nil)
    }

    func setCurrentPage(_ pageIndex: Int) {
        currentPage = min(max(pageIndex, 0), max(pages.count - 1, 0))
        accessibilityValue = "\(currentPage + 1) / \(pages.count)"
        guard isLoaded else { return }
        webView.evaluateJavaScript("window.showPage(\(currentPage));")
        reportPageBounds()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        updateDeckLayout()
        setCurrentPage(currentPage)
    }

    private func updateDeckLayout() {
        guard isLoaded else { return }
        webView.evaluateJavaScript("window.layoutPages && window.layoutPages(); window.showPage && window.showPage(\(currentPage));")
        reportPageBounds()
    }

    private func reportPageBounds() {
        boundsReportGeneration += 1 // Invalidate an in-flight pre-rotation DOM sample.
        accessibilityValue = "\(currentPage + 1) / \(pages.count); pageSceneRect=pending"
        geometryFramesRemaining = 120
        geometryWarmupFrames = 30
        stableGeometryFrames = 0
        lastConversionBasis = []
        if geometryDisplayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(sampleSceneGeometry))
            link.add(to: .main, forMode: .common)
            geometryDisplayLink = link
        }
    }

    private func measurePageBounds() {
        let basisAtRequest = conversionBasis(presentation: false)
        let index = currentPage
        boundsReportGeneration += 1
        let generation = boundsReportGeneration
        accessibilityValue = "\(index + 1) / \(pages.count); pageSceneRect=pending"
        // Await the actual CSS transform transition, then measure fractional viewport
        // coordinates. Slide-local offsets do not describe what is on screen.
        webView.callAsyncJavaScript("""
            await new Promise(resolve => requestAnimationFrame(resolve));
            const deck = document.querySelector('.deck');
            if (deck) {
                await Promise.all(deck.getAnimations().map(animation => animation.finished.catch(() => {})));
            }
            await new Promise(resolve => requestAnimationFrame(resolve));
            const page = document.querySelector('[data-page-index="\(index)"] .page');
            if (!page) return null;
            const rect = page.getBoundingClientRect();
            return [rect.x, rect.y, rect.width, rect.height];
            """, arguments: [:], in: nil, in: .page) { [weak self] result in
            let value = try? result.get()
            guard let self, self.currentPage == index, self.boundsReportGeneration == generation,
                  let values = value as? [Double], values.count == 4,
                  let window = self.window else { return }
            let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            guard self.conversionBasis(presentation: false) == basisAtRequest else {
                self.reportPageBounds()
                return
            }
            let sceneRect = self.webView.convert(rect, to: window.coordinateSpace)
            let basis = basisAtRequest.map { "[\($0.x),\($0.y)]" }.joined(separator: ",")
            self.accessibilityValue = "\(index + 1) / \(self.pages.count); pageSceneRect="
                + SlideshowUsableRegion.describe(sceneRect)
                + "; pageDOMRect=" + SlideshowUsableRegion.describe(rect)
                + "; conversionBasis=" + basis
        }
    }

    private static func html(forPages pages: [TypstPreviewPage]) -> String {
        let slideData = pages.enumerated().map { index, page in
            let width = max(page.widthPoints, 1)
            let height = max(page.heightPoints, 1)
            let metrics = "{width:\(cssPixels(width)),height:\(cssPixels(height))}"
            let slide = """
            <section class="slide" data-page-index="\(index)">
              <div class="page">
                \(page.svg)
              </div>
            </section>
            """
            return (metrics: metrics, slide: slide)
        }
        let pageMetrics = "[\(slideData.map(\.metrics).joined(separator: ","))]"
        let slides = slideData.map(\.slide).joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        html, body {
          margin: 0;
          padding: 0;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: #000;
        }
        html {
          --page: 0;
        }
        body {
          position: fixed;
          inset: 0;
        }
        .deck {
          display: flex;
          width: 100%;
          height: 100%;
          transform: translate3d(calc(var(--page) * -100%), 0, 0);
          transition: transform 220ms ease;
          will-change: transform;
        }
        .slide {
          position: relative;
          flex: 0 0 100%;
          width: 100%;
          height: 100%;
          display: flex;
          align-items: center;
          justify-content: center;
          overflow: hidden;
          background: #000;
        }
        .page {
          max-width: 100%;
          max-height: 100%;
          overflow: hidden;
          background: #fff;
        }
        .page > svg {
          display: block;
          width: 100%;
          height: 100%;
        }
        </style>
        <script>
        const pages = \(pageMetrics);
        window.layoutPages = function() {
          document.querySelectorAll(".slide").forEach(function(slide) {
            const index = Number(slide.dataset.pageIndex || 0);
            const page = pages[index];
            const pageElement = slide.querySelector(".page");
            if (!page || !pageElement) return;

            const slideBounds = slide.getBoundingClientRect();
            const slideWidth = Math.max(slideBounds.width, 1);
            const slideHeight = Math.max(slideBounds.height, 1);
            const scale = Math.min(slideWidth / page.width, slideHeight / page.height);
            pageElement.style.width = Math.max(page.width * scale, 1) + "px";
            pageElement.style.height = Math.max(page.height * scale, 1) + "px";
          });
        };
        window.showPage = function(index) {
          document.documentElement.style.setProperty("--page", index);
        };
        function installResizeObserver() {
          const deck = document.querySelector(".deck");
          if (!deck || !window.ResizeObserver || window.deckResizeObserver) return;
          window.deckResizeObserver = new ResizeObserver(window.layoutPages);
          window.deckResizeObserver.observe(deck);
        }
        window.addEventListener("resize", window.layoutPages);
        requestAnimationFrame(function() {
          window.layoutPages();
          installResizeObserver();
        });
        window.addEventListener("load", function() {
          window.layoutPages();
          installResizeObserver();
        });
        </script>
        </head>
        <body>
        <main class="deck">
        \(slides)
        </main>
        </body>
        </html>
        """
    }

    private static func cssPixels(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - Slideshow

struct SlideshowView: View {
    let pages: [TypstPreviewPage]
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var showControls: Bool = true

    private var pageCount: Int { pages.count }

    var body: some View {
        GeometryReader { proxy in
            let exclusions = activeReservedFrames(in: proxy)
            let region = SlideshowUsableRegion.pixelSafe(in: CGRect(origin: .zero, size: proxy.size), excluding: exclusions)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                ZStack {
                    if pageCount > 0 {
                        SVGSlideDeckView(pages: pages, currentPage: currentPage)
                            .contentShape(Rectangle())
                            .gesture(slideGesture)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                            }
                    }
                    if showControls {
                        controlsOverlay
                    }
                }
                .frame(width: region.width, height: region.height)
                .position(x: region.midX, y: region.midY)
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.reservedRegions")
                    .accessibilityLabel("Slideshow layout diagnostics")
                    .accessibilityValue("global(scene window): " + exclusions.map {
                        SlideshowUsableRegion.describe($0.offsetBy(dx: proxy.frame(in: .global).minX, dy: proxy.frame(in: .global).minY))
                    }.joined(separator: ";"))
            }
        }
        .onChange(of: pageCount, initial: true) { _, count in
            currentPage = min(currentPage, max(count - 1, 0))
        }
        .preferredColorScheme(.dark)
    }

    private func activeReservedFrames(in proxy: GeometryProxy) -> [CGRect] {
        // Define INKPOND_DUO_SDK only for builds using the iOS 27.1 SDK.
        // Runtime availability alone cannot protect older SDK name lookup.
        #if INKPOND_DUO_SDK
        if #available(iOS 27.1, *) {
            return (proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
                + proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed))
                .filter(\.isActive).map { region in
                    let margins = region.margins
                    return CGRect(x: region.frame.minX - margins.leading,
                                  y: region.frame.minY - margins.top,
                                  width: region.frame.width + margins.leading + margins.trailing,
                                  height: region.frame.height + margins.top + margins.bottom)
                }
        }
        #endif
        return []
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                }
                .glassButtonStyleIfAvailable()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(L10n.tr("Close"))
                .accessibilityIdentifier("slideshow.close")
                .slideshowBoundsDiagnostic()

                Spacer()

                Text(verbatim: pageCount > 0 ? "\(currentPage + 1) / \(pageCount)" : "0 / 0")
                    .foregroundStyle(.white)
                    .font(.subheadline.monospacedDigit().bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .accessibilityIdentifier("slideshow.counter")
                    .slideshowBoundsDiagnostic()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )

            Spacer()

            HStack {
                navButton(systemImage: "chevron.left", identifier: "slideshow.previous", label: L10n.tr("Previous Page"), enabled: currentPage > 0) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = max(0, currentPage - 1)
                    }
                }

                Spacer()

                navButton(systemImage: "chevron.right", identifier: "slideshow.next", label: L10n.tr("Next Page"), enabled: currentPage < pageCount - 1) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = min(pageCount - 1, currentPage + 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        .tint(.white)
    }

    @ViewBuilder
    private func navButton(systemImage: String, identifier: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
        }
        .glassButtonStyleIfAvailable()
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .slideshowBoundsDiagnostic()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    private var slideGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) else { return }

                if horizontal < -40, currentPage < pageCount - 1 {
                    currentPage += 1
                } else if horizontal > 40, currentPage > 0 {
                    currentPage -= 1
                }
            }
    }
}

private struct SVGSlideDeckView: UIViewRepresentable {
    let pages: [TypstPreviewPage]
    let currentPage: Int

    func makeUIView(context: Context) -> SVGSlideshowContainerView {
        SVGSlideshowContainerView()
    }

    func updateUIView(_ container: SVGSlideshowContainerView, context: Context) {
        container.updatePages(pages)
        container.setCurrentPage(currentPage)
    }
}

// One complete page and its overlay share a single maximal unobstructed rectangle.
// Edge enumeration handles horizontal/vertical folds, off-center folds and cameras.
enum SlideshowUsableRegion {
    static func pixelSafe(in bounds: CGRect, excluding exclusions: [CGRect]) -> CGRect {
        let region = largest(in: bounds, excluding: exclusions)
        guard !exclusions.isEmpty else { return region }
        // WebKit rounds its CSS viewport to pixels. Real breathing room prevents
        // that rounding from painting across a fractional reserved-region edge.
        let dx = min(1, region.width / 2)
        let dy = min(1, region.height / 2)
        return region.insetBy(dx: dx, dy: dy)
    }

    static func largest(in bounds: CGRect, excluding exclusions: [CGRect]) -> CGRect {
        let obstacles = exclusions.map { $0.intersection(bounds) }.filter { !$0.isNull }
        guard !obstacles.isEmpty else { return bounds }
        let xs = Set([bounds.minX, bounds.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set([bounds.minY, bounds.maxY] + obstacles.flatMap { [$0.minY, $0.maxY] }).sorted()
        var best = CGRect(origin: bounds.origin, size: .zero)
        for left in xs.indices {
            for right in xs.indices where right > left {
                for top in ys.indices {
                    for bottom in ys.indices where bottom > top {
                        let candidate = CGRect(x: xs[left], y: ys[top], width: xs[right] - xs[left], height: ys[bottom] - ys[top])
                        guard !obstacles.contains(where: {
                            let overlap = candidate.intersection($0)
                            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
                        }) else { continue }
                        if candidate.width * candidate.height > best.width * best.height {
                            best = candidate
                        }
                    }
                }
            }
        }
        return best
    }

    static func describe(_ rect: CGRect) -> String {
        String(format: "[%.2f,%.2f,%.2f,%.2f]", rect.minX, rect.minY, rect.width, rect.height)
    }
}

private struct SlideshowBoundsDiagnostic: ViewModifier {
    @State private var rect: CGRect = .zero
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in rect = frame }
            })
            .accessibilityValue("sceneRect=" + SlideshowUsableRegion.describe(rect))
    }
}

private extension View {
    func slideshowBoundsDiagnostic() -> some View { modifier(SlideshowBoundsDiagnostic()) }
}
