//
//  SystemSurface.swift
//  InkPond
//

import SwiftUI

private struct LiquidGlassColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    var liquidGlassColorScheme: ColorScheme? {
        get { self[LiquidGlassColorSchemeKey.self] }
        set { self[LiquidGlassColorSchemeKey.self] = newValue }
    }
}

private struct LiquidGlassAppearanceModifier: ViewModifier {
    @Environment(\.liquidGlassColorScheme) private var liquidGlassColorScheme
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedColorScheme: ColorScheme {
        liquidGlassColorScheme ?? colorScheme
    }

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, resolvedColorScheme)
    }
}

private struct LockedRectLiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool

    @Environment(\.liquidGlassColorScheme) private var liquidGlassColorScheme
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedColorScheme: ColorScheme {
        liquidGlassColorScheme ?? colorScheme
    }

    private var lockedBackground: Color {
        resolvedColorScheme == .dark
            ? Color.black.opacity(0.18)
            : Color.white.opacity(0.18)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if isInteractive {
                content
                    .background(
                        lockedBackground,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                    .environment(\.colorScheme, resolvedColorScheme)
            } else {
                content
                    .background(
                        lockedBackground,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .environment(\.colorScheme, resolvedColorScheme)
            }
        } else {
            content
        }
    }
}

private struct LockedCircleLiquidGlassModifier: ViewModifier {
    let isInteractive: Bool

    @Environment(\.liquidGlassColorScheme) private var liquidGlassColorScheme
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedColorScheme: ColorScheme {
        liquidGlassColorScheme ?? colorScheme
    }

    private var lockedBackground: Color {
        resolvedColorScheme == .dark
            ? Color.black.opacity(0.18)
            : Color.white.opacity(0.18)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if isInteractive {
                content
                    .background(lockedBackground, in: Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .environment(\.colorScheme, resolvedColorScheme)
            } else {
                content
                    .background(lockedBackground, in: Circle())
                    .glassEffect(.regular, in: .circle)
                    .environment(\.colorScheme, resolvedColorScheme)
            }
        } else {
            content
        }
    }
}

extension View {
    func liquidGlassColorScheme(_ colorScheme: ColorScheme) -> some View {
        environment(\.liquidGlassColorScheme, colorScheme)
    }

    func liquidGlassAppearance() -> some View {
        modifier(LiquidGlassAppearanceModifier())
    }

    func lockedLiquidGlassRect(cornerRadius: CGFloat, isInteractive: Bool = false) -> some View {
        modifier(LockedRectLiquidGlassModifier(cornerRadius: cornerRadius, isInteractive: isInteractive))
    }

    func lockedLiquidGlassCircle(isInteractive: Bool = false) -> some View {
        modifier(LockedCircleLiquidGlassModifier(isInteractive: isInteractive))
    }

    @ViewBuilder
    func systemFloatingSurface(cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26, *) {
            self
                .lockedLiquidGlassRect(cornerRadius: cornerRadius)
        } else {
            self
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func glassButtonStyleIfAvailable() -> some View {
        if #available(iOS 26, *) {
            self
                .buttonStyle(.glass)
                .liquidGlassAppearance()
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
