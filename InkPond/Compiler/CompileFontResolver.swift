//
//  CompileFontResolver.swift
//  InkPond
//

import CoreGraphics
import CoreText
import Foundation

struct CompileFontResolver {
    typealias ProjectFontProvider = (InkPondDocument) -> [AvailableCompileFont]
    typealias AppFontProvider = (URL?) -> [AvailableCompileFont]
    typealias SourceReader = (InkPondDocument, String?) -> [String: String]
    typealias PreferredLanguagesProvider = () -> [String]

    private let scanner: RequiredFontFamilyScanner
    private let systemCatalog: SystemFontCatalog
    private let projectFontProvider: ProjectFontProvider
    private let appFontProvider: AppFontProvider
    private let sourceReader: SourceReader
    private let preferredLanguagesProvider: PreferredLanguagesProvider

    init(
        scanner: RequiredFontFamilyScanner = RequiredFontFamilyScanner(),
        systemCatalog: SystemFontCatalog = SystemFontCatalog(),
        projectFontProvider: @escaping ProjectFontProvider = FontManager.projectFontRecords(for:),
        appFontProvider: @escaping AppFontProvider = FontManager.appFontRecords(rootURL:),
        sourceReader: SourceReader? = nil,
        preferredLanguagesProvider: @escaping PreferredLanguagesProvider = { Locale.preferredLanguages }
    ) {
        self.scanner = scanner
        self.systemCatalog = systemCatalog
        self.projectFontProvider = projectFontProvider
        self.appFontProvider = appFontProvider
        self.sourceReader = sourceReader ?? { document, entrySourceOverride in
            Self.readProjectSources(for: document, entrySourceOverride: entrySourceOverride)
        }
        self.preferredLanguagesProvider = preferredLanguagesProvider
    }

    func availableFontFamilies(for document: InkPondDocument, appRootURL: URL? = nil) -> [String] {
        let projectFamilies = FontManager.familyNames(from: projectFontProvider(document))
        let appFamilies = FontManager.familyNames(from: appFontProvider(appRootURL))
        let systemFamilies = systemCatalog.availableFamilyNames()

        var seen = Set<String>()
        var families: [String] = []

        for bucket in [projectFamilies, appFamilies, systemFamilies] {
            for family in bucket where seen.insert(family).inserted {
                families.append(family)
            }
        }

        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func resolveFonts(
        for document: InkPondDocument,
        entrySourceOverride: String? = nil,
        appRootURL: URL? = nil,
        preserving previousFonts: ResolvedCompileFonts? = nil
    ) throws -> ResolvedCompileFonts {
        let sources = sourceReader(document, entrySourceOverride)
        let scanResult = scanner.scan(fileContents: sources)
        let projectFonts = projectFontProvider(document)
        let appFonts = appFontProvider(appRootURL)
        let systemFonts = systemCatalog.availableFonts()
        let textProfile = SourceTextProfile(fileContents: sources)
        let requiredCodepoints = collectRequiredCodepoints(from: sources)

        if scanResult.hasIncompleteExpressions, let previousFonts {
            return previousFonts
        }

        let hasDynamicFontExpressions = !scanResult.unresolvedExpressions.isEmpty

        let implicitCJKFamily: String? = textProfile.containsCJK
            ? implicitCJKFallbackFamily(from: systemFonts)
            : nil
        let emojiFallbackFamily: String? = textProfile.containsEmoji
            ? firstAvailableFamily(
                from: emojiFallbackFamilyCandidates(),
                in: systemFonts,
                requiresMaterialization: false
            )
            : nil
        let latinFallbackFamily: String? = textProfile.containsLatin
            ? firstAvailableFamily(
                from: latinFallbackFamilyCandidates(),
                in: systemFonts,
                requiresMaterialization: false
            )
            : nil

        let dynamicFontDatabase = hasDynamicFontExpressions ? projectFonts + appFonts : []

        guard !scanResult.families.isEmpty else {
            var automaticFallbacks: [String] = []
            if let emojiFallbackFamily {
                automaticFallbacks.append(emojiFallbackFamily)
            }
            if hasDynamicFontExpressions, let latinFallbackFamily {
                automaticFallbacks.append(latinFallbackFamily)
            }
            if hasDynamicFontExpressions, let implicitCJKFamily {
                automaticFallbacks.append(implicitCJKFamily)
            }
            if hasDynamicFontExpressions {
                // Do not interpret Typst variables in Swift. Register the
                // user-managed font database and let Typst evaluate the
                // original source expression.
                return try resolveRequestedFamilies(
                    [],
                    projectFonts: projectFonts,
                    appFonts: appFonts,
                    systemFonts: systemFonts,
                    implicitFallbackFamily: nil,
                    automaticFallbackFamilies: automaticFallbacks,
                    warningFamilies: automaticFallbacks,
                    additionalFonts: dynamicFontDatabase,
                    requiredCodepoints: requiredCodepoints
                )
            }
            if let implicitCJKFamily {
                automaticFallbacks.append(implicitCJKFamily)
                return try resolveRequestedFamilies(
                    [implicitCJKFamily],
                    projectFonts: projectFonts,
                    appFonts: appFonts,
                    systemFonts: systemFonts,
                    implicitFallbackFamily: implicitCJKFamily,
                    automaticFallbackFamilies: automaticFallbacks,
                    warningFamilies: automaticFallbacks,
                    requiredCodepoints: requiredCodepoints
                )
            }
            if !automaticFallbacks.isEmpty {
                return try resolveRequestedFamilies(
                    [],
                    projectFonts: projectFonts,
                    appFonts: appFonts,
                    systemFonts: systemFonts,
                    implicitFallbackFamily: nil,
                    automaticFallbackFamilies: automaticFallbacks,
                    warningFamilies: automaticFallbacks,
                    requiredCodepoints: requiredCodepoints
                )
            }
            return .empty
        }

        let requestedMatches = scanResult.families.flatMap {
            selectMatches(for: $0, projectFonts: projectFonts, appFonts: appFonts, systemFonts: systemFonts)
        }
        var automaticFallbacks: [String] = []
        if let implicitCJKFamily,
           textProfile.containsCJK,
           !requestedMatches.contains(where: { Self.font($0, supports: .cjk) }) {
            automaticFallbacks.append(implicitCJKFamily)
        }
        if let emojiFallbackFamily,
           textProfile.containsEmoji,
           !requestedMatches.contains(where: { Self.font($0, supports: .emoji) }) {
            automaticFallbacks.append(emojiFallbackFamily)
        }
        if let latinFallbackFamily,
           textProfile.containsLatin,
           !requestedMatches.contains(where: { Self.font($0, supports: .latin) }) {
            automaticFallbacks.append(latinFallbackFamily)
        }

        return try resolveRequestedFamilies(
            scanResult.families,
            projectFonts: projectFonts,
            appFonts: appFonts,
            systemFonts: systemFonts,
            implicitFallbackFamily: nil,
            automaticFallbackFamilies: automaticFallbacks,
            warningFamilies: automaticFallbacks,
            additionalFonts: dynamicFontDatabase,
            requiredCodepoints: requiredCodepoints
        )
    }

    static func effectiveSource(for source: String, resolvedFonts: ResolvedCompileFonts) -> String {
        guard let implicitFallbackFamily = resolvedFonts.implicitFallbackFamily else {
            return source
        }

        let escapedFamily = implicitFallbackFamily.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        #set text(font: ("Libertinus Serif", "\(escapedFamily)"))
        \(source)
        """
    }

    private func resolveRequestedFamilies(
        _ requestedFamilies: [String],
        projectFonts: [AvailableCompileFont],
        appFonts: [AvailableCompileFont],
        systemFonts: [AvailableCompileFont],
        implicitFallbackFamily: String?,
        automaticFallbackFamilies: [String],
        warningFamilies: [String],
        additionalFonts: [AvailableCompileFont] = [],
        requiredCodepoints: [UInt32]
    ) throws -> ResolvedCompileFonts {
        var fontPaths: [String] = []
        var selectedFamilies: [String] = []
        var sourcesByFamily: [String: CompileFontSource] = [:]
        var unresolvedFamilies: [String] = []
        var seenPaths = Set<String>()
        var fallbackFamilies: [String] = []
        var seenFallbacks = Set<String>()

        for family in requestedFamilies {
            let matches = selectMatches(for: family, projectFonts: projectFonts, appFonts: appFonts, systemFonts: systemFonts)
            guard !matches.isEmpty else {
                unresolvedFamilies.append(family)
                continue
            }

            selectedFamilies.append(family)
            sourcesByFamily[family] = matches[0].source

            for match in Self.compileFaces(from: matches) {
                let effectivePath = Self.effectiveFontPath(for: match, requiredCodepoints: requiredCodepoints)
                guard seenPaths.insert(effectivePath).inserted else { continue }
                fontPaths.append(effectivePath)
            }
        }

        for font in additionalFonts {
            let normalizedFamily = FontManager.normalizeFamilyName(font.familyName)
            if !selectedFamilies.contains(where: { FontManager.normalizeFamilyName($0) == normalizedFamily }),
               !fallbackFamilies.contains(where: { FontManager.normalizeFamilyName($0) == normalizedFamily }),
               sourcesByFamily[font.familyName] == nil {
                sourcesByFamily[font.familyName] = font.source
            }

            let effectivePath = Self.effectiveFontPath(for: font, requiredCodepoints: requiredCodepoints)
            guard seenPaths.insert(effectivePath).inserted else { continue }
            fontPaths.append(effectivePath)
        }

        if !unresolvedFamilies.isEmpty {
            throw FontResolutionFailure(
                message: L10n.fontResolutionMissingFamilies(unresolvedFamilies)
            )
        }

        // Register automatic fallback font files without exposing the family
        // in `selectedFamilies`. Typst auto-fallback scans every registered font
        // for missing glyphs (text.fallback: true by default), so this lets
        // CJK, Latin cascade, and emoji codepoints find viable system faces
        // without rewriting the user's explicit `#set text(font: ...)`.
        for fallbackFamily in automaticFallbackFamilies {
            let normalizedSilent = FontManager.normalizeFamilyName(fallbackFamily)
            let alreadyIncluded = selectedFamilies.contains {
                FontManager.normalizeFamilyName($0) == normalizedSilent
            }
            guard !alreadyIncluded else { continue }

            let matches = selectMatches(
                for: fallbackFamily,
                projectFonts: projectFonts,
                appFonts: appFonts,
                systemFonts: systemFonts
            )
            guard !matches.isEmpty else { continue }
            if seenFallbacks.insert(normalizedSilent).inserted {
                fallbackFamilies.append(fallbackFamily)
                sourcesByFamily[fallbackFamily] = matches[0].source
            }
            for match in Self.compileFaces(from: matches) {
                let effectivePath = Self.effectiveFontPath(for: match, requiredCodepoints: requiredCodepoints)
                guard seenPaths.insert(effectivePath).inserted else { continue }
                fontPaths.append(effectivePath)
            }
        }

        let warningSourceFamilies = fallbackFamilies + (implicitFallbackFamily.map { [$0] } ?? [])
        let warnings = warningFamilies
            .filter { warningFamily in
                warningSourceFamilies.contains {
                    FontManager.normalizeFamilyName($0) == FontManager.normalizeFamilyName(warningFamily)
                }
            }
            .uniqueByNormalizedFontFamily()
            .map { CompileFontWarning(message: L10n.fontFallbackWarning(family: $0)) }

        return ResolvedCompileFonts(
            fontPaths: fontPaths,
            families: selectedFamilies,
            sourcesByFamily: sourcesByFamily,
            implicitFallbackFamily: implicitFallbackFamily,
            fallbackFamilies: fallbackFamilies,
            warnings: warnings
        )
    }

    /// iOS system and user-installed fonts are often delivered as TTC
    /// collections or on-demand `AssetsV2` assets. Reading those paths
    /// directly from Rust (`std::fs::read` + `Font::iter`) is unreliable: it
    /// can pick the wrong face (family-name mismatch vs CoreText) or fail
    /// outright on dataless assets, which produces PDFs whose CJK text has
    /// glyph references but no visible outlines. We instead rebuild a clean
    /// single-face sfnt file through CoreText and hand Rust that path.
    /// Project and app-imported fonts are kept as-is — those live in our
    /// sandbox and are regular self-contained files.
    private static func effectiveFontPath(
        for font: AvailableCompileFont,
        requiredCodepoints: [UInt32]
    ) -> String {
        switch font.source {
        case .system, .installed:
            // NEVER hand Rust the raw system font path on iOS. Even when
            // `FileManager.isReadableFile` returns true, Apple's AssetsV2
            // pipeline frequently serves placeholder bytes for fonts like
            // AppleColorEmoji.ttc — parsing those as sfnt yields nonsense
            // (zero-byte tags, empty tables), which Typst silently treats as
            // ".notdef for everything". Always go through CoreText, which is
            // responsible for materializing the real table bytes regardless
            // of the on-disk representation.
            guard CoreTextFontMaterializer.canMaterialize(postScriptName: font.postScriptName) else {
                return font.path
            }
            return CoreTextFontMaterializer.plannedPath(
                forPostScriptName: font.postScriptName,
                familyName: font.familyName,
                styleName: font.faceName,
                originalPath: font.path,
                requiredCodepoints: requiredCodepoints
            )
                ?? font.path
        case .project, .app:
            return font.path
        }
    }

    private static func compileFaces(from matches: [AvailableCompileFont]) -> [AvailableCompileFont] {
        guard matches.contains(where: { $0.source == .system || $0.source == .installed }) else {
            return matches
        }

        var selected: [AvailableCompileFont] = []
        appendBestFace(
            from: matches,
            to: &selected,
            matchingAny: ["regular", "normal", "roman", "plain", "w3", "w4"]
        )
        appendBestFace(
            from: matches,
            to: &selected,
            matchingAny: ["bold", "semibold", "demi", "heavy", "black", "w6", "w7"]
        )
        appendBestFace(
            from: matches,
            to: &selected,
            matchingAny: ["italic", "oblique"]
        )

        if selected.isEmpty {
            selected.append(contentsOf: matches.prefix(1))
        }

        return selected
    }

    private static func appendBestFace(
        from matches: [AvailableCompileFont],
        to selected: inout [AvailableCompileFont],
        matchingAny preferredTokens: [String]
    ) {
        guard let match = bestFace(in: matches, matchingAny: preferredTokens) else { return }
        guard !selected.contains(where: {
            $0.postScriptName == match.postScriptName && $0.path == match.path
        }) else {
            return
        }
        selected.append(match)
    }

    private static func bestFace(
        in matches: [AvailableCompileFont],
        matchingAny preferredTokens: [String]
    ) -> AvailableCompileFont? {
        for token in preferredTokens {
            if let match = matches.first(where: {
                FontManager.normalizeFamilyName($0.faceName).contains(token)
                    || FontManager.normalizeFamilyName($0.postScriptName).contains(token)
            }) {
                return match
            }
        }
        return nil
    }

    private func implicitCJKFallbackFamily(from systemFonts: [AvailableCompileFont]) -> String? {
        let preferredLanguage = preferredLanguagesProvider().first?.lowercased() ?? ""
        let candidates = implicitCJKFamilyCandidates(for: preferredLanguage)

        return firstAvailableFamily(from: candidates, in: systemFonts, requiresMaterialization: true)
    }

    private func implicitCJKFamilyCandidates(for preferredLanguage: String) -> [String] {
        // Order matters: prefer the platform-native CJK families first. Some
        // iOS 26 faces store outlines in Apple's private `hvgl` table; those
        // are materialized into standard TrueType outlines before Rust sees
        // them.
        if preferredLanguage.hasPrefix("zh-hant-hk") || preferredLanguage.hasPrefix("zh-hk") {
            return [
                "PingFang HK",
                "PingFang TC",
                "PingFang SC",
                "Heiti TC",
                "Songti TC",
                "Hiragino Sans",
                "Hiragino Sans GB",
                "Hiragino Mincho ProN",
            ]
        }

        if preferredLanguage.hasPrefix("zh-hant") || preferredLanguage.hasPrefix("zh-tw") {
            return [
                "PingFang TC",
                "PingFang HK",
                "PingFang SC",
                "Heiti TC",
                "Songti TC",
                "Hiragino Sans",
                "Hiragino Sans GB",
                "Hiragino Mincho ProN",
            ]
        }

        return [
            "PingFang SC",
            "PingFang TC",
            "PingFang HK",
            "Heiti SC",
            "Songti SC",
            "Heiti TC",
            "Songti TC",
            "Hiragino Sans",
            "Hiragino Sans GB",
            "Hiragino Mincho ProN",
        ]
    }

    private func latinFallbackFamilyCandidates() -> [String] {
        [
            ".AppleSystemUIFont",
            "SF Pro",
            "SF Pro Text",
            "SF Pro Display",
            "Helvetica Neue",
            "Helvetica",
            "Arial",
        ]
    }

    private func emojiFallbackFamilyCandidates() -> [String] {
        [
            "Apple Color Emoji",
        ]
    }

    private func firstAvailableFamily(
        from candidates: [String],
        in fonts: [AvailableCompileFont],
        requiresMaterialization: Bool
    ) -> String? {
        for family in candidates {
            let normalizedFamily = FontManager.normalizeFamilyName(family)
            let faces = fonts.filter {
                FontManager.normalizeFamilyName($0.familyName) == normalizedFamily
            }
            guard !faces.isEmpty else { continue }

            let usable = faces.contains { face in
                if requiresMaterialization {
                    return CoreTextFontMaterializer.canMaterialize(postScriptName: face.postScriptName)
                }

                return CoreTextFontMaterializer.canMaterialize(postScriptName: face.postScriptName)
                    || !face.path.isEmpty
            }
            if usable { return family }
        }

        return nil
    }

    private func selectMatches(
        for family: String,
        projectFonts: [AvailableCompileFont],
        appFonts: [AvailableCompileFont],
        systemFonts: [AvailableCompileFont]
    ) -> [AvailableCompileFont] {
        if let matches = matchingFonts(in: projectFonts, family: family), !matches.isEmpty {
            return matches
        }

        if let matches = matchingFonts(in: appFonts, family: family), !matches.isEmpty {
            return matches
        }

        let installedMatches = matchingFonts(in: systemFonts.filter { $0.source == .installed }, family: family) ?? []
        if !installedMatches.isEmpty {
            return installedMatches
        }

        return matchingFonts(in: systemFonts.filter { $0.source == .system }, family: family) ?? []
    }

    private enum CoverageSample {
        case latin
        case cjk
        case emoji

        var text: String {
            switch self {
            case .latin:
                return "A"
            case .cjk:
                return "中"
            case .emoji:
                return "😀"
            }
        }
    }

    private static func font(_ font: AvailableCompileFont, supports sample: CoverageSample) -> Bool {
        switch font.source {
        case .system, .installed:
            guard let ctFont = coreTextFont(postScriptName: font.postScriptName) else {
                return false
            }
            return fontSupports(ctFont, sample)
        case .project, .app:
            guard let ctFont = coreTextFont(filePath: font.path) else {
                return false
            }
            return fontSupports(ctFont, sample)
        }
    }

    private static func coreTextFont(postScriptName: String) -> CTFont? {
        guard !postScriptName.isEmpty else { return nil }
        let attrs: [CFString: Any] = [kCTFontNameAttribute: postScriptName]
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12.0, nil)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        guard resolvedName == postScriptName else {
            return nil
        }
        return font
    }

    private static func coreTextFont(filePath: String) -> CTFont? {
        guard !filePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: filePath)
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }
        return CTFontCreateWithGraphicsFont(cgFont, 12.0, nil, nil)
    }

    private static func fontSupports(_ font: CTFont, _ sample: CoverageSample) -> Bool {
        let ns = sample.text as NSString
        guard ns.length > 0 else { return false }
        var chars = (0..<ns.length).map { ns.character(at: $0) }
        var glyphs = Array(repeating: CGGlyph(0), count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) else {
            return false
        }
        return glyphs.contains { $0 != 0 }
    }

    private func matchingFonts(in fonts: [AvailableCompileFont], family: String) -> [AvailableCompileFont]? {
        let normalizedFamily = FontManager.normalizeFamilyName(family)
        let matches = fonts.filter { FontManager.normalizeFamilyName($0.familyName) == normalizedFamily }
        guard !matches.isEmpty else { return nil }

        return matches.sorted { lhs, rhs in
            if lhs.faceName != rhs.faceName {
                return lhs.faceName.localizedCaseInsensitiveCompare(rhs.faceName) == .orderedAscending
            }
            if lhs.postScriptName != rhs.postScriptName {
                return lhs.postScriptName.localizedCaseInsensitiveCompare(rhs.postScriptName) == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    /// Collect the set of Unicode scalars that must be materialized so that
    /// outline synthesis can be subsetted.
    ///
    /// The set always includes the full ASCII printable range (0x20–0x7E)
    /// plus a few common punctuation/whitespace control codes as a baseline.
    /// This matters because CJK fonts like PingFang SC *do* carry their own
    /// Latin glyphs, and Typst's fallback cascade will happily use them for
    /// Latin runs when PingFang is the primary `#set text(font: ...)`. If we
    /// subsetted to only the non-ASCII scalars actually typed in the source,
    /// PingFang's Latin GIDs would end up as empty `loca` entries and render
    /// as invisible `.notdef` glyphs. Keeping ASCII as a baseline also has a
    /// nice side effect: every document shares the same baseline so the
    /// cache key only differs on the CJK/symbol portion.
    private func collectRequiredCodepoints(from sources: [String: String]) -> [UInt32] {
        var set = Set<UInt32>()
        set.reserveCapacity(512)
        // Baseline: ASCII printable + TAB/LF/CR so any font that's asked to
        // render Latin runs has its full Latin-1 repertoire available.
        for value in 0x20...0x7E { set.insert(UInt32(value)) }
        set.insert(0x09)
        set.insert(0x0A)
        set.insert(0x0D)
        for content in sources.values {
            for scalar in content.unicodeScalars {
                set.insert(scalar.value)
            }
        }
        return set.sorted()
    }

    private static func readProjectSources(
        for document: InkPondDocument,
        entrySourceOverride: String?
    ) -> [String: String] {
        var fileContents: [String: String] = [:]

        let sourceFiles = document.isExternalFolder
            ? [document.entryFileName]
            : ProjectFileManager.listAllTypFiles(for: document)

        for fileName in sourceFiles {
            if fileName == document.entryFileName, let entrySourceOverride {
                fileContents[fileName] = entrySourceOverride
                continue
            }

            if let content = try? ProjectFileManager.readTypFile(named: fileName, for: document) {
                fileContents[fileName] = content
            }
        }

        if fileContents[document.entryFileName] == nil, let entrySourceOverride {
            fileContents[document.entryFileName] = entrySourceOverride
        }

        return fileContents
    }
}

private struct SourceTextProfile {
    let containsCJK: Bool
    let containsEmoji: Bool
    let containsLatin: Bool

    init(fileContents: [String: String]) {
        var hasCJK = false
        var hasEmoji = false
        var hasLatin = false

        for content in fileContents.values {
            for scalar in content.unicodeScalars {
                if scalar.isCJKUnifiedIdeograph {
                    hasCJK = true
                }
                if scalar.isEmojiPresentationCandidate {
                    hasEmoji = true
                }
                if scalar.isLatinText {
                    hasLatin = true
                }

                if hasCJK && hasEmoji && hasLatin {
                    break
                }
            }
            if hasCJK && hasEmoji && hasLatin {
                break
            }
        }

        containsCJK = hasCJK
        containsEmoji = hasEmoji
        containsLatin = hasLatin
    }
}

private extension Unicode.Scalar {
    var isCJKUnifiedIdeograph: Bool {
        switch value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    var isEmojiPresentationCandidate: Bool {
        switch value {
        case 0x00A9,
             0x00AE,
             0x203C,
             0x2049,
             0x2122,
             0x2139,
             0x2194...0x21AA,
             0x231A...0x231B,
             0x2328,
             0x23CF,
             0x23E9...0x23F3,
             0x23F8...0x23FA,
             0x24C2,
             0x25AA...0x25AB,
             0x25B6,
             0x25C0,
             0x25FB...0x25FE,
             0x2600...0x27BF,
             0x2934...0x2935,
             0x2B05...0x2B55,
             0x3030,
             0x303D,
             0x3297,
             0x3299,
             0x1F000...0x1FAFF:
            return true
        default:
            return false
        }
    }

    var isLatinText: Bool {
        switch value {
        case 0x0041...0x005A,
             0x0061...0x007A,
             0x00C0...0x024F,
             0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }
}

private extension Array where Element == String {
    func uniqueByNormalizedFontFamily() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for family in self {
            let normalized = FontManager.normalizeFamilyName(family)
            guard seen.insert(normalized).inserted else { continue }
            result.append(family)
        }
        return result
    }
}
