//
//  EditorFontSettings.swift
//  InkPond
//

import Foundation
import Observation
import UIKit

struct EditorFontOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let familyName: String?
}

struct EditorFontFaceOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct EditorFontFamilyOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let faces: [EditorFontFaceOption]

    var defaultFaceID: String {
        faces.first?.id ?? EditorFontSettings.systemMonospacedFontID
    }
}

@Observable
final class EditorFontSettings {
    static let systemMonospacedFontID = "system.monospaced"
    static let defaultFontSize: Double = 15
    static let minimumFontSize: Double = 11
    static let maximumFontSize: Double = 28

    private static let fontIDDefaultsKey = "editorFontID"
    private static let fontSizeDefaultsKey = "editorFontSize"
    private let defaults: UserDefaults

    var fontID: String {
        didSet { defaults.set(fontID, forKey: Self.fontIDDefaultsKey) }
    }

    var fontSize: Double {
        didSet {
            let clampedSize = Self.clampedFontSize(fontSize)
            guard clampedSize == fontSize else {
                fontSize = clampedSize
                return
            }
            defaults.set(fontSize, forKey: Self.fontSizeDefaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontID = defaults.string(forKey: Self.fontIDDefaultsKey) ?? Self.systemMonospacedFontID
        let storedSize = defaults.object(forKey: Self.fontSizeDefaultsKey) as? Double
        fontSize = Self.clampedFontSize(storedSize ?? Self.defaultFontSize)
    }

    var uiFont: UIFont {
        Self.uiFont(for: fontID, size: CGFloat(fontSize))
    }

    var fontDisplayName: String {
        Self.displayName(for: fontID)
    }

    var familyDisplayName: String {
        Self.familyOption(containing: fontID)?.displayName ?? L10n.tr("System Monospaced")
    }

    var selectedFamily: EditorFontFamilyOption {
        Self.familyOption(containing: fontID) ?? Self.systemFamilyOption
    }

    static var defaultUIFont: UIFont {
        uiFont(for: systemMonospacedFontID, size: CGFloat(defaultFontSize))
    }

    static func lineSpacing(for font: UIFont) -> CGFloat {
        min(max(font.pointSize * 0.12, 1), 3.5)
    }

    static func paragraphStyle(for font: UIFont) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing(for: font)
        paragraphStyle.lineBreakMode = .byWordWrapping
        return paragraphStyle
    }

    static func lineNumberFont(for editorFont: UIFont) -> UIFont {
        let size = min(max(editorFont.pointSize * 0.73, 9), 18)
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func selectFamily(_ family: EditorFontFamilyOption) {
        guard !family.faces.contains(where: { $0.id == fontID }) else { return }
        fontID = family.defaultFaceID
    }

    static func clampedFontSize(_ fontSize: Double) -> Double {
        min(max(fontSize, minimumFontSize), maximumFontSize)
    }

    static func uiFont(for fontID: String, size: CGFloat) -> UIFont {
        if fontID == systemMonospacedFontID {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        if let font = UIFont(name: fontID, size: size) {
            return font
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func displayName(for fontID: String) -> String {
        if fontID == systemMonospacedFontID {
            return L10n.tr("System Monospaced")
        }

        if let font = UIFont(name: fontID, size: CGFloat(defaultFontSize)) {
            let familyName = font.familyName
            if let faceName = font.fontDescriptor.object(forKey: .face) as? String,
               !faceName.isEmpty,
               faceName.localizedCaseInsensitiveCompare(familyName) != .orderedSame {
                return "\(familyName) \(faceName)"
            }
            if font.fontName == familyName {
                return familyName
            }
            return "\(familyName) \(font.fontName)"
        }

        return L10n.tr("System Monospaced")
    }

    static func faceDisplayName(for fontID: String) -> String {
        if fontID == systemMonospacedFontID {
            return L10n.tr("Regular")
        }

        guard let font = UIFont(name: fontID, size: CGFloat(defaultFontSize)) else {
            return fontID
        }

        if let faceName = font.fontDescriptor.object(forKey: .face) as? String,
           !faceName.isEmpty {
            return faceName
        }

        return font.fontName
    }

    static var availableFontFamilies: [EditorFontFamilyOption] {
        let installedFamilies = UIFont.familyNames
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { familyName -> EditorFontFamilyOption? in
                let faces = UIFont.fontNames(forFamilyName: familyName)
                    .sorted { lhs, rhs in
                        let lhsDisplay = Self.faceDisplayName(for: lhs)
                        let rhsDisplay = Self.faceDisplayName(for: rhs)
                        return lhsDisplay.localizedCaseInsensitiveCompare(rhsDisplay) == .orderedAscending
                    }
                    .map { fontName in
                        EditorFontFaceOption(id: fontName, displayName: Self.faceDisplayName(for: fontName))
                    }

                guard !faces.isEmpty else { return nil }
                return EditorFontFamilyOption(id: familyName, displayName: familyName, faces: faces)
            }

        return [systemFamilyOption] + installedFamilies
    }

    static var availableFontOptions: [EditorFontOption] {
        availableFontFamilies.flatMap { family in
            family.faces.map { face in
                EditorFontOption(
                    id: face.id,
                    displayName: family.id == systemMonospacedFontID
                        ? family.displayName
                        : "\(family.displayName) \(face.displayName)",
                    familyName: family.id == systemMonospacedFontID ? nil : family.displayName
                )
            }
        }
    }

    static func familyOption(containing fontID: String) -> EditorFontFamilyOption? {
        availableFontFamilies.first { family in
            family.faces.contains { $0.id == fontID }
        }
    }

    private static var systemFamilyOption: EditorFontFamilyOption {
        EditorFontFamilyOption(
            id: systemMonospacedFontID,
            displayName: L10n.tr("System Monospaced"),
            faces: [
                EditorFontFaceOption(
                    id: systemMonospacedFontID,
                    displayName: L10n.tr("Regular")
                )
            ]
        )
    }
}
