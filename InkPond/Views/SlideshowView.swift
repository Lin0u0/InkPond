//
//  SlideshowView.swift
//  InkPond
//
//  Full-screen SVG slideshow: one page at a time, swipe or arrow buttons to navigate.
//

import SwiftUI
import WebKit

private final class SVGSlideshowContainerView: UIView, WKNavigationDelegate {
    private let webView: WKWebView
    private var pages: [TypstPreviewPage] = []
    private var currentPage = 0
    private var isLoaded = false
    private var lastLaidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)

        backgroundColor = .black
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
        guard isLoaded else { return }
        webView.evaluateJavaScript("window.showPage(\(currentPage));")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        updateDeckLayout()
        setCurrentPage(currentPage)
    }

    private func updateDeckLayout() {
        guard isLoaded else { return }
        webView.evaluateJavaScript("window.layoutPages && window.layoutPages(); window.showPage && window.showPage(\(currentPage));")
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

            const slideWidth = Math.max(slide.clientWidth, 1);
            const slideHeight = Math.max(slide.clientHeight, 1);
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
        ZStack {
            Color.black.ignoresSafeArea()

            if pageCount > 0 {
                GeometryReader { proxy in
                    SVGSlideDeckView(pages: pages, currentPage: currentPage)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(slideGesture)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        }
                }
                .ignoresSafeArea()
            }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
            }
        }
        .onChange(of: pageCount, initial: true) { _, count in
            currentPage = min(currentPage, max(count - 1, 0))
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                }
                .glassButtonStyleIfAvailable()

                Spacer()

                Text(verbatim: pageCount > 0 ? "\(currentPage + 1) / \(pageCount)" : "0 / 0")
                    .foregroundStyle(.white)
                    .font(.subheadline.monospacedDigit().bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
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
                navButton(systemImage: "chevron.left", enabled: currentPage > 0) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = max(0, currentPage - 1)
                    }
                }

                Spacer()

                navButton(systemImage: "chevron.right", enabled: currentPage < pageCount - 1) {
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
    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
        }
        .glassButtonStyleIfAvailable()
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
