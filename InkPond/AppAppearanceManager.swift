//
//  AppAppearanceManager.swift
//  InkPond
//

import Foundation
import Observation
import SwiftUI
import UIKit

enum AppAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            .unspecified
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

@Observable
final class AppAppearanceManager {
    private static let defaultsKey = "appAppearanceMode"
    private let defaults: UserDefaults

    var mode: String {
        didSet { defaults.set(mode, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.defaultsKey) ?? AppAppearanceMode.system.rawValue
    }

    var currentMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: mode) ?? .system
    }

    var colorScheme: ColorScheme? { currentMode.colorScheme }
    var userInterfaceStyle: UIUserInterfaceStyle { currentMode.userInterfaceStyle }
}
