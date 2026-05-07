//
//  SystemFontCatalog.swift
//  InkPond
//

import CoreText
import Foundation
import os

struct SystemFontCatalog {
    typealias Loader = @Sendable () -> [AvailableCompileFont]

    private nonisolated static let cachedFontsLock = OSAllocatedUnfairLock<[AvailableCompileFont]?>(initialState: nil)

    private nonisolated let loader: Loader

    nonisolated init(loader: @escaping Loader = Self.liveFonts) {
        self.loader = loader
    }

    nonisolated func availableFonts() -> [AvailableCompileFont] {
        loader()
    }

    nonisolated func availableFamilyNames() -> [String] {
        Self.familyNames(from: availableFonts())
    }

    nonisolated static func invalidateCache() {
        cachedFontsLock.withLock { $0 = nil }
    }

    nonisolated static func familyNames(from fonts: [AvailableCompileFont]) -> [String] {
        var seen = Set<String>()
        var families: [String] = []

        for font in fonts {
            guard seen.insert(font.familyName).inserted else { continue }
            families.append(font.familyName)
        }

        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated private static func liveFonts() -> [AvailableCompileFont] {
        if let cachedFonts = cachedFontsLock.withLock({ $0 }) {
            return cachedFonts
        }

        let loadedFonts = loadAvailableFonts()

        return cachedFontsLock.withLock { cache in
            if let cache {
                return cache
            }
            cache = loadedFonts
            return loadedFonts
        }
    }

    nonisolated private static func loadAvailableFonts() -> [AvailableCompileFont] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return []
        }

        var seen = Set<String>()
        var fonts: [AvailableCompileFont] = []

        for descriptor in descriptors {
            guard let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else {
                continue
            }

            let faceName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String)
                ?? postScriptName
            let key = "\(familyName)\u{1F}\(postScriptName)\u{1F}\(url.path)"
            guard seen.insert(key).inserted else { continue }

            fonts.append(
                AvailableCompileFont(
                    familyName: familyName,
                    faceName: faceName,
                    postScriptName: postScriptName,
                    path: url.path,
                    source: classifySource(for: url)
                )
            )
        }

        return fonts.sorted { lhs, rhs in
            if lhs.familyName != rhs.familyName {
                return lhs.familyName.localizedCaseInsensitiveCompare(rhs.familyName) == .orderedAscending
            }
            if lhs.source != rhs.source {
                return sourcePriority(lhs.source) < sourcePriority(rhs.source)
            }
            if lhs.faceName != rhs.faceName {
                return lhs.faceName.localizedCaseInsensitiveCompare(rhs.faceName) == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    nonisolated private static func classifySource(for url: URL) -> CompileFontSource {
        let path = url.path.lowercased()

        if path.hasPrefix("/system/")
            || path.contains("/system/library/fonts")
            || path.contains("/system/library/assetsv2") {
            return .system
        }

        return .installed
    }

    nonisolated private static func sourcePriority(_ source: CompileFontSource) -> Int {
        switch source {
        case .installed:
            return 0
        case .system:
            return 1
        case .app:
            return 2
        case .project:
            return 3
        }
    }
}
