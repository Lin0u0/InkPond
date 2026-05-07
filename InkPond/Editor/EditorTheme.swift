//
//  EditorTheme.swift
//  InkPond
//

import UIKit

struct EditorTheme {
    let id: String
    let background: UIColor
    let gutterBackground: UIColor
    let gutterForeground: UIColor
    let text: UIColor
    let heading: UIColor
    let functionColor: UIColor
    let keyword: UIColor
    let bool: UIColor
    let string: UIColor
    let math: UIColor
    let code: UIColor
    let label: UIColor
    let comment: UIColor
    let number: UIColor
    let markup: UIColor
    let rainbow: [UIColor]

    // MARK: - Mocha (forced dark)

    static let mocha = EditorTheme(
        id: "mocha",
        background:        UIColor(hex: "#1E1E2E"),
        gutterBackground:  UIColor(hex: "#181825"),
        gutterForeground:  UIColor(hex: "#585B70"),
        text:              UIColor(hex: "#CDD6F4"),
        heading:           UIColor(hex: "#89B4FA"),
        functionColor:     UIColor(hex: "#CBA6F7"),
        keyword:           UIColor(hex: "#F38BA8"),
        bool:              UIColor(hex: "#F9E2AF"),
        string:            UIColor(hex: "#A6E3A1"),
        math:              UIColor(hex: "#FAB387"),
        code:              UIColor(hex: "#74C7EC"),
        label:             UIColor(hex: "#94E2D5"),
        comment:           UIColor(hex: "#6C7086"),
        number:            UIColor(hex: "#FAB387"),
        markup:            UIColor(hex: "#F5C2E7"),
        rainbow: [
            UIColor(hex: "#CBA6F7"),
            UIColor(hex: "#89B4FA"),
            UIColor(hex: "#A6E3A1"),
            UIColor(hex: "#FAB387"),
            UIColor(hex: "#F5C2E7"),
            UIColor(hex: "#F9E2AF"),
        ],
    )

    // MARK: - Latte (forced light)

    static let latte = EditorTheme(
        id: "latte",
        background:        UIColor(hex: "#EFF1F5"),
        gutterBackground:  UIColor(hex: "#E6E9EF"),
        gutterForeground:  UIColor(hex: "#9CA0B0"),
        text:              UIColor(hex: "#4C4F69"),
        heading:           UIColor(hex: "#1E66F5"),
        functionColor:     UIColor(hex: "#8839EF"),
        keyword:           UIColor(hex: "#D20F39"),
        bool:              UIColor(hex: "#DF8E1D"),
        string:            UIColor(hex: "#40A02B"),
        math:              UIColor(hex: "#FE640B"),
        code:              UIColor(hex: "#209FB5"),
        label:             UIColor(hex: "#179299"),
        comment:           UIColor(hex: "#9CA0B0"),
        number:            UIColor(hex: "#FE640B"),
        markup:            UIColor(hex: "#EA76CB"),
        rainbow: [
            UIColor(hex: "#8839EF"),
            UIColor(hex: "#1E66F5"),
            UIColor(hex: "#40A02B"),
            UIColor(hex: "#FE640B"),
            UIColor(hex: "#EA76CB"),
            UIColor(hex: "#DF8E1D"),
        ],
    )

    // MARK: - System (adaptive: Latte in light, Mocha in dark)

    static let system: EditorTheme = {
        func a(_ dark: String, _ light: String) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        }
        return EditorTheme(
            id: "system",
            background:        a("#1E1E2E", "#EFF1F5"),
            gutterBackground:  a("#181825", "#E6E9EF"),
            gutterForeground:  a("#585B70", "#9CA0B0"),
            text:              a("#CDD6F4", "#4C4F69"),
            heading:           a("#89B4FA", "#1E66F5"),
            functionColor:     a("#CBA6F7", "#8839EF"),
            keyword:           a("#F38BA8", "#D20F39"),
            bool:              a("#F9E2AF", "#DF8E1D"),
            string:            a("#A6E3A1", "#40A02B"),
            math:              a("#FAB387", "#FE640B"),
            code:              a("#74C7EC", "#209FB5"),
            label:             a("#94E2D5", "#179299"),
            comment:           a("#6C7086", "#9CA0B0"),
            number:            a("#FAB387", "#FE640B"),
            markup:            a("#F5C2E7", "#EA76CB"),
            rainbow: [
                a("#CBA6F7", "#8839EF"),
                a("#89B4FA", "#1E66F5"),
                a("#A6E3A1", "#40A02B"),
                a("#FAB387", "#FE640B"),
                a("#F5C2E7", "#EA76CB"),
                a("#F9E2AF", "#DF8E1D"),
            ],
        )
    }()
}

// MARK: - UIColor hex initializer

extension UIColor {
    nonisolated convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.hasPrefix("#") ? String(s.dropFirst()) : s
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red:   CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >>  8) / 255.0,
            blue:  CGFloat( rgb & 0x0000FF)         / 255.0,
            alpha: 1.0
        )
    }
}
