//
//  OnboardingView.swift
//  InkPond
//

import SwiftUI
import UIKit

struct OnboardingView: View {
    @State private var currentPage = 0
    @State private var appeared = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var onComplete: () -> Void

    private let pageCount = 4
    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        ZStack {
            InkPaperBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    editorPage.tag(1)
                    previewPage.tag(2)
                    projectsPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.32), value: currentPage)

                bottomBar
                    .padding(.horizontal, isRegular ? 76 : 28)
                    .padding(.bottom, isRegular ? 36 : 22)
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                appeared = true
            }
        }
    }

    private var welcomePage: some View {
        InkOnboardingPage(appeared: appeared, isRegular: isRegular) {
            VStack(spacing: isRegular ? 34 : 26) {
                Image("AppIconDisplay")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: isRegular ? 164 : 122, height: isRegular ? 164 : 122)
                    .clipShape(RoundedRectangle(cornerRadius: isRegular ? 36 : 26, style: .continuous))
                    .shadow(color: InkPalette.ink.opacity(0.16), radius: 18, y: 8)
                .accessibilityHidden(true)

                pageText(
                    title: L10n.appName,
                    subtitle: L10n.tr("onboarding.welcome.subtitle")
                )
            }
        }
    }

    private var editorPage: some View {
        InkOnboardingPage(appeared: appeared, isRegular: isRegular) {
            VStack(spacing: isRegular ? 34 : 28) {
                InkEditorIllustration(isRegular: isRegular)
                    .frame(width: isRegular ? 500 : 300, height: isRegular ? 330 : 218)
                    .accessibilityHidden(true)

                pageText(
                    title: L10n.tr("onboarding.editor.title"),
                    subtitle: L10n.tr("onboarding.editor.subtitle")
                )
            }
        }
    }

    private var previewPage: some View {
        InkOnboardingPage(appeared: appeared, isRegular: isRegular) {
            VStack(spacing: isRegular ? 34 : 28) {
                InkPreviewIllustration(isRegular: isRegular)
                    .frame(width: isRegular ? 500 : 300, height: isRegular ? 330 : 218)
                    .accessibilityHidden(true)

                pageText(
                    title: L10n.tr("onboarding.preview.title"),
                    subtitle: L10n.tr("onboarding.preview.subtitle")
                )
            }
        }
    }

    private var projectsPage: some View {
        InkOnboardingPage(appeared: appeared, isRegular: isRegular) {
            VStack(spacing: isRegular ? 34 : 28) {
                InkProjectsIllustration(isRegular: isRegular)
                    .frame(width: isRegular ? 500 : 300, height: isRegular ? 330 : 218)
                    .accessibilityHidden(true)

                pageText(
                    title: L10n.tr("onboarding.projects.title"),
                    subtitle: L10n.tr("onboarding.projects.subtitle")
                )
            }
        }
    }

    private func pageText(title: String, subtitle: String) -> some View {
        VStack(spacing: isRegular ? 14 : 11) {
            Text(title)
                .font(.notoSerif(size: isRegular ? 42 : 32, weight: .bold))
                .foregroundStyle(InkPalette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text(subtitle)
                .font(.notoSerif(size: isRegular ? 19 : 16, weight: .regular))
                .foregroundStyle(InkPalette.softInk)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isRegular ? 80 : 26)
        .accessibilityElement(children: .combine)
    }

    private var bottomBar: some View {
        VStack(spacing: isRegular ? 22 : 18) {
            pageIndicator

            Button {
                InteractionFeedback.impact(.medium)
                if currentPage == pageCount - 1 {
                    onComplete()
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        currentPage += 1
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Text(currentPage == pageCount - 1
                         ? L10n.tr("onboarding.action.get_started")
                         : L10n.tr("Continue"))
                        .font(.notoSerif(size: isRegular ? 18 : 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: currentPage == pageCount - 1 ? "arrow.right" : "chevron.right")
                        .font(.system(size: isRegular ? 15 : 14, weight: .semibold))
                }
                .foregroundStyle(InkPalette.paper)
                .frame(maxWidth: isRegular ? 360 : .infinity)
                .padding(.vertical, isRegular ? 16 : 15)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(InkPalette.ink)
                )
                .shadow(color: InkPalette.ink.opacity(0.14), radius: 12, y: 7)
            }
            .buttonStyle(.plain)
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityLabel(currentPage == pageCount - 1
                                ? L10n.tr("onboarding.action.get_started")
                                : L10n.tr("Continue"))
            .accessibilityHint(currentPage == pageCount - 1
                               ? L10n.tr("onboarding.action.get_started.hint")
                               : L10n.tr("onboarding.continue.hint"))

            Button {
                guard currentPage < pageCount - 1 else { return }
                InteractionFeedback.selection()
                onComplete()
            } label: {
                Text(L10n.tr("Skip"))
                    .font(.notoSerif(size: 15, weight: .regular))
                    .foregroundStyle(InkPalette.faintInk)
            }
            .opacity(currentPage < pageCount - 1 ? 1 : 0)
            .allowsHitTesting(currentPage < pageCount - 1)
            .accessibilityHidden(currentPage == pageCount - 1)
            .accessibilityHint(L10n.tr("onboarding.action.get_started.hint"))
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 10) {
            ForEach(0..<pageCount, id: \.self) { index in
                InkDot()
                    .fill(index == currentPage ? InkPalette.ink : InkPalette.ink.opacity(0.20))
                    .frame(width: index == currentPage ? 25 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum InkPalette {
    static let paper = Color(red: 0.965, green: 0.948, blue: 0.908)
    static let paperWarm = Color(red: 0.988, green: 0.976, blue: 0.940)
    static let ink = Color(red: 0.085, green: 0.083, blue: 0.075)
    static let softInk = Color(red: 0.230, green: 0.226, blue: 0.205)
    static let faintInk = Color(red: 0.445, green: 0.430, blue: 0.380)
}

private extension Font {
    static func notoSerif(size: CGFloat, weight: Weight) -> Font {
        let fontName: String
        switch weight {
        case .bold:
            fontName = "NotoSerif-Bold"
        case .semibold:
            fontName = "NotoSerif-SemiBold"
        default:
            fontName = "NotoSerif-Regular"
        }

        if UIFont(name: fontName, size: size) != nil {
            return .custom(fontName, size: size)
        }

        return .system(size: size, weight: weight, design: .serif)
    }
}

private struct InkOnboardingPage<Content: View>: View {
    let appeared: Bool
    let isRegular: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: isRegular ? 54 : 34)
            content
                .scaleEffect(appeared ? 1.0 : 0.96)
                .opacity(appeared ? 1.0 : 0.0)
                .offset(y: appeared ? 0 : 12)
                .animation(.easeOut(duration: 0.5), value: appeared)
            Spacer(minLength: isRegular ? 62 : 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InkPaperBackground: View {
    var body: some View {
        ZStack {
            InkPalette.paperWarm

            LinearGradient(
                colors: [
                    Color.white.opacity(0.34),
                    InkPalette.paper.opacity(0.80),
                    InkPalette.paperWarm,
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            PaperFibers(step: 18)
                .stroke(InkPalette.ink.opacity(0.014), lineWidth: 0.55)
        }
    }
}

private struct PaperFibers: Shape {
    let step: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var y = rect.minY

        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: y + 3),
                control1: CGPoint(x: rect.midX * 0.4, y: y - 2),
                control2: CGPoint(x: rect.midX * 1.35, y: y + 5)
            )
            y += step
        }

        return path
    }
}

private struct InkDot: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

private struct InkEditorIllustration: View {
    let isRegular: Bool

    private var scale: CGFloat { isRegular ? 1.52 : 1.0 }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("#let")
                        .font(.notoSerif(size: 18 * scale, weight: .bold))
                        .foregroundStyle(InkPalette.ink)
                    Spacer()
                    Text("typst")
                        .font(.notoSerif(size: 11 * scale, weight: .regular))
                        .foregroundStyle(InkPalette.faintInk)
                }
                .padding(.horizontal, 18 * scale)
                .padding(.top, 17 * scale)

                VStack(alignment: .leading, spacing: 9 * scale) {
                    codeLine(widths: [0.26, 0.36, 0.18], active: true)
                    codeLine(widths: [0.18, 0.48], active: false)
                    codeLine(widths: [], active: false)
                    codeLine(widths: [0.34, 0.22], active: true)
                    codeLine(widths: [0.58], active: false)
                    codeLine(widths: [0.38, 0.25], active: true)
                    codeLine(widths: [0.44], active: false)
                }
                .padding(18 * scale)

                Spacer(minLength: 0)

                HStack(spacing: 8 * scale) {
                    ForEach(["#", "$", "=", "*"], id: \.self) { symbol in
                        Text(symbol)
                            .font(.notoSerif(size: 12 * scale, weight: .bold))
                            .foregroundStyle(InkPalette.ink)
                            .frame(width: 27 * scale, height: 25 * scale)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(InkPalette.ink.opacity(0.16), lineWidth: 1)
                            )
                    }
                    Spacer()
                }
                .padding(.horizontal, 18 * scale)
                .padding(.bottom, 17 * scale)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InkPalette.paper.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(InkPalette.ink.opacity(0.26), lineWidth: 1)
            )
            .shadow(color: InkPalette.ink.opacity(0.10), radius: 12, y: 8)
        }
    }

    private func codeLine(widths: [CGFloat], active: Bool) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 7 * scale) {
                ForEach(Array(widths.enumerated()), id: \.offset) { offset, width in
                    Capsule()
                        .fill(InkPalette.ink.opacity(offset == 0 && active ? 0.30 : 0.18))
                        .frame(width: max(16 * scale, proxy.size.width * width), height: 5 * scale)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6 * scale)
    }
}

private struct InkPreviewIllustration: View {
    let isRegular: Bool

    private var scale: CGFloat { isRegular ? 1.52 : 1.0 }

    var body: some View {
        ZStack {
            page(offset: CGSize(width: -18 * scale, height: 15 * scale), opacity: 0.38)
            page(offset: CGSize(width: 16 * scale, height: -12 * scale), opacity: 0.58)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(InkPalette.paperWarm)
                .frame(width: 190 * scale, height: 250 * scale)
                .overlay(
                    VStack(spacing: 9 * scale) {
                        Text("InkPond")
                            .font(.notoSerif(size: 21 * scale, weight: .bold))
                            .foregroundStyle(InkPalette.ink)

                        VStack(alignment: .leading, spacing: 7 * scale) {
                            ForEach([0.92, 0.78, 0.86, 0.62, 0.74], id: \.self) { width in
                                Capsule()
                                    .fill(InkPalette.ink.opacity(0.14))
                                    .frame(width: 132 * scale * width, height: 4 * scale)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(spacing: 5 * scale) {
                            Capsule()
                                .fill(InkPalette.ink.opacity(0.34))
                                .frame(width: 62 * scale, height: 4 * scale)
                            Capsule()
                                .fill(InkPalette.ink.opacity(0.18))
                                .frame(width: 84 * scale, height: 4 * scale)
                        }
                        .padding(.vertical, 8 * scale)

                        Spacer(minLength: 0)

                        Spacer(minLength: 0)
                    }
                    .padding(21 * scale)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(InkPalette.ink.opacity(0.20), lineWidth: 1)
                )
                .shadow(color: InkPalette.ink.opacity(0.11), radius: 12, y: 8)
        }
    }

    private func page(offset: CGSize, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(InkPalette.paper.opacity(opacity))
            .frame(width: 190 * scale, height: 250 * scale)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(InkPalette.ink.opacity(0.10), lineWidth: 1)
            )
            .offset(offset)
    }
}

private struct InkProjectsIllustration: View {
    let isRegular: Bool

    private var scale: CGFloat { isRegular ? 1.52 : 1.0 }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12 * scale) {
                HStack {
                    Text("my-thesis")
                        .font(.notoSerif(size: 17 * scale, weight: .bold))
                        .foregroundStyle(InkPalette.ink)
                    Spacer()
                }

                Divider()
                    .overlay(InkPalette.ink.opacity(0.18))

                fileRow(icon: "doc.text", name: "main.typ", active: true)
                fileRow(icon: "doc.text", name: "chapter.typ", active: false)
                fileRow(icon: "photo", name: "figures/ink.png", active: false)
                fileRow(icon: "textformat", name: "fonts/NotoSerif.otf", active: false)
                fileRow(icon: "archivebox", name: "export.zip", active: false)
            }
            .padding(20 * scale)
            .frame(width: 244 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InkPalette.paper.opacity(0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(InkPalette.ink.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: InkPalette.ink.opacity(0.10), radius: 12, y: 8)
        }
    }

    private func fileRow(icon: String, name: String, active: Bool) -> some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: icon)
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(active ? InkPalette.ink : InkPalette.faintInk)
                .frame(width: 18 * scale)

            Text(name)
                .font(.notoSerif(size: 12 * scale, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? InkPalette.ink : InkPalette.softInk)
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3 * scale)
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
