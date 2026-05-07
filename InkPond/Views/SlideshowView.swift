//
//  SlideshowView.swift
//  InkPond
//
//  Full-screen PDF slideshow: one page at a time, swipe or arrow buttons to navigate.
//

import SwiftUI
import PDFKit

private final class SlideshowPDFView: PDFView {
    override var canBecomeFirstResponder: Bool { false }
}

private final class SlideshowPDFContainerView: UIView {
    let pdfView = SlideshowPDFView()
    var page: PDFPage? {
        didSet { updatePageLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(pdfView)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .black
        pdfView.isUserInteractionEnabled = false
        pdfView.autoScales = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePageLayout()
    }

    private func updatePageLayout() {
        guard let page else { return }

        let pageBounds = page.bounds(for: .mediaBox)
        let availableWidth = max(bounds.width, 1)
        let availableHeight = max(bounds.height, 1)
        let widthScale = availableWidth / max(pageBounds.width, 1)
        let heightScale = availableHeight / max(pageBounds.height, 1)
        let fittedScale = min(widthScale, heightScale)

        pdfView.minScaleFactor = fittedScale
        pdfView.maxScaleFactor = fittedScale
        pdfView.scaleFactor = fittedScale
        pdfView.go(to: page)
        DispatchQueue.main.async { [weak self] in
            self?.centerRenderedPageIfNeeded()
        }
    }

    private func centerRenderedPageIfNeeded() {
        guard let scrollView = findScrollView(in: pdfView) else { return }

        scrollView.layoutIfNeeded()

        let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        let insets = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )

        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
        }

        if scrollView.verticalScrollIndicatorInsets != insets {
            scrollView.verticalScrollIndicatorInsets = insets
        }

        if scrollView.horizontalScrollIndicatorInsets != insets {
            scrollView.horizontalScrollIndicatorInsets = insets
        }

        let centeredOffset = CGPoint(x: -horizontalInset, y: -verticalInset)
        if scrollView.contentOffset != centeredOffset {
            scrollView.setContentOffset(centeredOffset, animated: false)
        }
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Slideshow

struct SlideshowView: View {
    let document: PDFDocument
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var showControls: Bool = true

    private var pageCount: Int { document.pageCount }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PDFSlideView(document: document, pageIndex: currentPage)
                .contentShape(Rectangle())
                .gesture(slideGesture)
                .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: Controls overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                }
                .glassButtonStyleIfAvailable()

                Spacer()

                Text(verbatim: "\(currentPage + 1) / \(pageCount)")
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

            // ── Bottom bar ───────────────────────────────────────────
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

// MARK: - Per-page renderer

struct PDFSlideView: View {
    let document: PDFDocument
    let pageIndex: Int

    var body: some View {
        PDFSinglePageView(document: document, pageIndex: pageIndex)
            .ignoresSafeArea()
    }
}

private struct PDFSinglePageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeUIView(context: Context) -> SlideshowPDFContainerView {
        let container = SlideshowPDFContainerView()
        container.pdfView.document = document
        return container
    }

    func updateUIView(_ container: SlideshowPDFContainerView, context: Context) {
        if container.pdfView.document !== document {
            container.pdfView.document = document
        }

        container.page = document.page(at: pageIndex)
    }
}
