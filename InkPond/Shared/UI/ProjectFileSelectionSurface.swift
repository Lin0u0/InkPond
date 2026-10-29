import SwiftUI
import UIKit

/// Flat file-selection tokens shared by the tree and editor file rail only.
enum ProjectFileSelectionSurface {
    static let cornerRadius: CGFloat = 12

    static func fill(panel: UIColor, scheme: ColorScheme, primary: UIColor = .label) -> Color {
        let dark = scheme == .dark
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let background = panel.resolvedColor(with: traits)
        let resolvedPrimary = primary.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        resolvedPrimary.getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
        let fraction: CGFloat = dark ? 0.10 : 0.06
        return Color(uiColor: UIColor(red: r + (pr - r) * fraction,
                                      green: g + (pg - g) * fraction,
                                      blue: b + (pb - b) * fraction, alpha: 1))
    }
}
