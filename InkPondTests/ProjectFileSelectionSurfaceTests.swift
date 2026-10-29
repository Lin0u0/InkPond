import SwiftUI
import UIKit
import XCTest
@testable import InkPond

@MainActor
final class ProjectFileSelectionSurfaceTests: XCTestCase {
    private func components(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    func testContinuousCornerRadiusToken() {
        XCTAssertEqual(ProjectFileSelectionSurface.cornerRadius, 12)
    }

    func testOpaqueSixPercentLightComposite() {
        let result = components(UIColor(ProjectFileSelectionSurface.fill(panel: .white, scheme: .light)))
        for channel in result.prefix(3) { XCTAssertEqual(channel, 0.94, accuracy: 0.0001) }
        XCTAssertEqual(result[3], 1)
    }

    func testOpaqueTenPercentDarkComposite() {
        let result = components(UIColor(ProjectFileSelectionSurface.fill(panel: .black, scheme: .dark)))
        for channel in result.prefix(3) { XCTAssertEqual(channel, 0.10, accuracy: 0.0001) }
        XCTAssertEqual(result[3], 1)
    }

    private func luminance(_ color: UIColor) -> Double {
        let rgb = components(color).prefix(3).map { value -> Double in
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    }

    func testSecondaryPathContrastAcrossFourAppearances() {
        let cases: [(UIColor, UIColor, ColorScheme)] = [
            (UIColor(hex: "#F2F2F7"), UIColor(hex: "#636366"), .light),
            (UIColor(hex: "#1C1C1E"), UIColor(hex: "#AEAEB2"), .dark),
            (EditorTheme.latte.gutterBackground, EditorTheme.latte.text, .light),
            (EditorTheme.mocha.gutterBackground, EditorTheme.mocha.text, .dark)
        ]
        for (panel, text, scheme) in cases {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let foreground = luminance(text.resolvedColor(with: traits))
            let selected = UIColor(ProjectFileSelectionSurface.fill(panel: panel, scheme: scheme))
            for background in [panel.resolvedColor(with: traits), selected] {
                let base = luminance(background)
                XCTAssertGreaterThanOrEqual((max(foreground, base) + 0.05) / (min(foreground, base) + 0.05), 4.5)
                XCTAssertEqual(components(background)[3], 1)
            }
        }
    }
}
