//
//  CoreTextFontMaterializer.swift
//  InkPond
//
//  Reassembles a self-contained single-face OpenType file from a CoreText
//  font, so Typst's Rust side (which does `std::fs::read(path)` +
//  `Font::iter(bytes)`) always sees a clean, complete sfnt container with a
//  name table that matches what Swift advertised to the resolver.
//
//  This exists because iOS system CJK fonts are typically delivered either as
//  `.ttc` collections (where Rust may pick a face whose `name` table does not
//  match the family name Swift discovered through CoreText) or as on-demand
//  `AssetsV2` assets (where raw `std::fs::read` from the sandbox can fail or
//  return a stub). Materializing through CoreText sidesteps both problems:
//  CoreText is responsible for providing the real table bytes, regardless of
//  how the asset is physically stored on disk.
//

import CoreText
import Foundation
import os.log

struct MaterializedFontCacheEntry: Identifiable, Equatable, Sendable {
    let path: String
    let fileName: String
    let postScriptName: String
    let familyName: String?
    let styleName: String?
    let sizeInBytes: Int64
    let modifiedAt: Date

    nonisolated var id: String { path }

    nonisolated var displayName: String {
        if let familyName, !familyName.isEmpty {
            if let styleName, !styleName.isEmpty {
                return "\(familyName) \(styleName)"
            }
            return familyName
        }
        return postScriptName
    }
}

struct MaterializedFontCacheSnapshot: Equatable, Sendable {
    let entries: [MaterializedFontCacheEntry]

    nonisolated var totalSizeInBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeInBytes }
    }
}

enum MaterializedFontCacheError: LocalizedError {
    case unsafeCachePath

    nonisolated var errorDescription: String? {
        switch self {
        case .unsafeCachePath:
            return L10n.tr("error.cache.unsafe_path")
        }
    }
}

enum CoreTextFontMaterializer {
    nonisolated private struct Request: Codable, Sendable {
        let postScriptName: String
        let familyName: String?
        let styleName: String?
        let originalPath: String?
        /// Sorted list of Unicode scalar values this font is expected to
        /// cover in the current document. When present, glyph outline
        /// synthesis is subsetted to only these codepoints (+ notdef),
        /// avoiding full-font materialization for large CJK/system fonts.
        /// Omitted for fonts that already ship with standard outlines —
        /// those are pass-through and don't benefit from subsetting.
        let requiredCodepoints: [UInt32]?

        nonisolated func hasSameFontIdentity(as other: Request) -> Bool {
            postScriptName == other.postScriptName
                && familyName == other.familyName
                && styleName == other.styleName
                && originalPath == other.originalPath
        }

        nonisolated func replacingRequiredCodepoints(_ codepoints: [UInt32]?) -> Request {
            Request(
                postScriptName: postScriptName,
                familyName: familyName,
                styleName: styleName,
                originalPath: originalPath,
                requiredCodepoints: codepoints
            )
        }
    }

    private struct Table {
        let tag: UInt32
        var data: Data
    }

    nonisolated private static let cacheVersion = "ctsfnt-v7"
    nonisolated private static let manifestExtension = "json"
    nonisolated private static let materializationLock = NSLock()
    nonisolated private static let capabilityLock = NSLock()
    nonisolated private static let cacheKeyLock = NSLock()
    nonisolated(unsafe) private static var capabilityCache: [String: Bool] = [:]
    nonisolated(unsafe) private static var codepointSpecificCacheRequirementCache: [String: Bool] = [:]

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InkPond",
        category: "CoreTextFontMaterializer"
    )

    nonisolated private static let cacheDirURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MaterializedFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeItemFromBackup(at: dir)
        return dir
    }()

    nonisolated private static let legacyCacheDirURL: URL? = {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MaterializedFonts", isDirectory: true)
    }()

    /// Return the deterministic materialized font path and persist a tiny sidecar
    /// request, but do not do any heavy table extraction or glyph synthesis.
    nonisolated static func plannedPath(
        forPostScriptName postScriptName: String,
        familyName: String?,
        styleName: String?,
        originalPath: String?,
        requiredCodepoints: [UInt32]? = nil
    ) -> String? {
        guard !postScriptName.isEmpty else { return nil }
        let normalizedCodepoints = cacheKeyCodepoints(
            forPostScriptName: postScriptName,
            requestedCodepoints: requiredCodepoints
        )
        let baseRequest = Request(
            postScriptName: postScriptName,
            familyName: familyName,
            styleName: styleName,
            originalPath: originalPath,
            requiredCodepoints: normalizedCodepoints
        )
        let request = expandedCacheRequest(for: baseRequest)
        let dest = destinationURL(for: request)
        writeRequestIfNeeded(request, beside: dest)
        return dest.path
    }

    nonisolated static func materializePlannedFonts(in paths: [String]) -> [String] {
        paths.map { path in
            guard let request = request(forPlannedPath: path) else {
                return path
            }
            return materializedPath(
                forPostScriptName: request.postScriptName,
                familyName: request.familyName,
                styleName: request.styleName,
                originalPath: request.originalPath,
                requiredCodepoints: request.requiredCodepoints
            ) ?? request.originalPath ?? path
        }
    }

    nonisolated static func persistentCacheSnapshot() throws -> MaterializedFontCacheSnapshot {
        prunePersistentCache()

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirURL, withIntermediateDirectories: true)
        excludeItemFromBackup(at: cacheDirURL)

        let urls = try fm.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let entries = try urls.compactMap { url -> MaterializedFontCacheEntry? in
            excludeItemFromBackup(at: url)
            guard url.pathExtension.lowercased() == "otf" else { return nil }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true else { return nil }

            let request = request(forCachedFontURL: url)
            let sidecarURL = requestURL(forFontURL: url)
            let sidecarSize = fileSizeIfPresent(at: sidecarURL)
            let fontSize = Int64(values.fileSize ?? 0)
            let fallbackName = url.deletingPathExtension().lastPathComponent

            return MaterializedFontCacheEntry(
                path: url.path,
                fileName: url.lastPathComponent,
                postScriptName: request?.postScriptName ?? fallbackName,
                familyName: request?.familyName,
                styleName: request?.styleName,
                sizeInBytes: fontSize + sidecarSize,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        return MaterializedFontCacheSnapshot(entries: entries)
    }

    nonisolated static func removeCachedFont(_ entry: MaterializedFontCacheEntry) throws {
        let url = URL(fileURLWithPath: entry.path)
        guard url.deletingLastPathComponent().standardizedFileURL == cacheDirURL.standardizedFileURL else {
            throw MaterializedFontCacheError.unsafeCachePath
        }

        materializationLock.lock()
        defer { materializationLock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        let sidecarURL = requestURL(forFontURL: url)
        if fm.fileExists(atPath: sidecarURL.path) {
            try fm.removeItem(at: sidecarURL)
        }
    }

    nonisolated static func clearPersistentCache() throws {
        materializationLock.lock()
        defer { materializationLock.unlock() }

        let fm = FileManager.default
        removeLegacyCacheDirectory()
        if fm.fileExists(atPath: cacheDirURL.path) {
            try fm.removeItem(at: cacheDirURL)
        }
        try fm.createDirectory(at: cacheDirURL, withIntermediateDirectories: true)
        excludeItemFromBackup(at: cacheDirURL)
    }

    nonisolated static func prunePersistentCache(maxEntries: Int = 96, orphanMaxAge: TimeInterval = 7 * 24 * 60 * 60) {
        let fm = FileManager.default
        removeLegacyCacheDirectory()
        excludeItemFromBackup(at: cacheDirURL)
        guard let urls = try? fm.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let currentSuffix = "-\(cacheVersion).otf"
        let orphanCutoff = Date().addingTimeInterval(-orphanMaxAge)
        var currentFonts: [(url: URL, modifiedAt: Date)] = []

        for url in urls {
            excludeItemFromBackup(at: url)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            if url.pathExtension.lowercased() == "otf" {
                if url.lastPathComponent.hasSuffix(currentSuffix) {
                    currentFonts.append((url, values?.contentModificationDate ?? .distantPast))
                } else {
                    try? fm.removeItem(at: url)
                    try? fm.removeItem(at: requestURL(forFontURL: url))
                }
                continue
            }

            if url.pathExtension.lowercased() == manifestExtension {
                let fontURL = url.deletingPathExtension().appendingPathExtension("otf")
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if !fm.fileExists(atPath: fontURL.path), modifiedAt < orphanCutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        guard currentFonts.count > maxEntries else { return }
        let staleFonts = currentFonts
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .dropFirst(maxEntries)
        for entry in staleFonts {
            try? fm.removeItem(at: entry.url)
            try? fm.removeItem(at: requestURL(forFontURL: entry.url))
        }
    }

    /// Return a filesystem path to a self-contained sfnt file for the font
    /// identified by `postScriptName`. The file is regenerated from CoreText
    /// tables on demand and cached. Returns `nil` if the font can't be
    /// materialized (caller should fall back to the original path).
    nonisolated static func materializedPath(
        forPostScriptName postScriptName: String,
        familyName: String? = nil,
        styleName: String? = nil,
        originalPath: String? = nil,
        requiredCodepoints: [UInt32]? = nil
    ) -> String? {
        guard !postScriptName.isEmpty else { return nil }

        let normalizedCodepoints = cacheKeyCodepoints(
            forPostScriptName: postScriptName,
            requestedCodepoints: requiredCodepoints
        )
        let baseRequest = Request(
            postScriptName: postScriptName,
            familyName: familyName,
            styleName: styleName,
            originalPath: originalPath,
            requiredCodepoints: normalizedCodepoints
        )
        let request = expandedCacheRequest(for: baseRequest)
        let dest = destinationURL(for: request)
        writeRequestIfNeeded(request, beside: dest)

        if FileManager.default.fileExists(atPath: dest.path) {
            removeRedundantCacheVariants(matching: request, keeping: dest)
            return dest.path
        }

        if let compatibleURL = existingCompatibleMaterializedFile(for: request) {
            removeRedundantCacheVariants(matching: request, keeping: compatibleURL)
            return compatibleURL.path
        }

        materializationLock.lock()
        defer { materializationLock.unlock() }

        let lockedRequest = expandedCacheRequest(for: request)
        let lockedDest = destinationURL(for: lockedRequest)
        writeRequestIfNeeded(lockedRequest, beside: lockedDest)

        if FileManager.default.fileExists(atPath: lockedDest.path) {
            removeRedundantCacheVariants(matching: lockedRequest, keeping: lockedDest)
            return lockedDest.path
        }

        if let compatibleURL = existingCompatibleMaterializedFile(for: lockedRequest) {
            removeRedundantCacheVariants(matching: lockedRequest, keeping: compatibleURL)
            return compatibleURL.path
        }

        guard let data = buildSFNTData(
            forPostScriptName: postScriptName,
            familyName: familyName,
            styleName: styleName,
            requiredCodepoints: lockedRequest.requiredCodepoints
        ) else {
            logger.error("Failed to materialize font for \(postScriptName, privacy: .public)")
            return nil
        }

        do {
            try data.write(to: lockedDest, options: .atomic)
            Self.excludeItemFromBackup(at: lockedDest)
            removeRedundantCacheVariants(matching: lockedRequest, keeping: lockedDest)
            return lockedDest.path
        } catch {
            logger.error(
                "Failed to write materialized font \(postScriptName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Cheap preflight used by the resolver to choose an implicit fallback
    /// family without eagerly synthesizing every face in every candidate
    /// family. Full materialization is still deferred until a face is selected
    /// for compilation.
    nonisolated static func canMaterialize(postScriptName: String) -> Bool {
        guard !postScriptName.isEmpty else { return false }

        capabilityLock.lock()
        if let cached = capabilityCache[postScriptName] {
            capabilityLock.unlock()
            return cached
        }
        capabilityLock.unlock()

        let result: Bool
        if let existing = existingMaterializedFile(forPostScriptName: postScriptName),
           FileManager.default.fileExists(atPath: existing.path) {
            result = true
        } else if let font = makeFont(postScriptName: postScriptName) {
            let tags = Set(availableTableTags(for: font))
            // Color / bitmap glyph tables Typst 0.14.x knows how to rasterize
            // directly into PDF image XObjects, bypassing the outline pipeline
            // entirely. Apple Color Emoji lives here — its `glyf` is empty but
            // `sbix` carries the actual PNG artwork per glyph.
            let hasColorOrBitmapTables = hasUsableColorGlyphTables(tags)
            let hasStandardOutlineTables =
                tags.contains(Self.glyfTag) || tags.contains(Self.cffTag) || tags.contains(Self.cff2Tag)
            if hasColorOrBitmapTables {
                // Pass-through: the materializer will preserve the color/bitmap
                // tables as-is and Typst will read them.
                result = true
            } else if hasStandardOutlineTables {
                // Outline-only fonts must actually carry outlines; bare table
                // presence is not enough (some malformed faces ship empty glyf).
                result = TrueTypeGlyfSynthesizer.hasAnyOutline(font: font)
            } else {
                // No standard outlines — try synthesizing from CoreText paths
                // (the iOS 26 PingFang `hvgl` case).
                result = TrueTypeGlyfSynthesizer.canSynthesize(font: font)
            }
        } else {
            result = false
        }
        capabilityLock.lock()
        capabilityCache[postScriptName] = result
        capabilityLock.unlock()
        return result
    }

    // MARK: - sfnt assembly

    nonisolated private static let glyfTag: UInt32 = 0x676C_7966  // 'glyf'
    nonisolated private static let cffTag: UInt32 = 0x4346_4620   // 'CFF '
    nonisolated private static let cff2Tag: UInt32 = 0x4346_4632  // 'CFF2'
    nonisolated private static let sbixTag: UInt32 = 0x7362_6978  // 'sbix'
    nonisolated private static let colrTag: UInt32 = 0x434F_4C52  // 'COLR'
    nonisolated private static let svgTag: UInt32 = 0x5356_4720   // 'SVG '
    nonisolated private static let cbdtTag: UInt32 = 0x4342_4454  // 'CBDT'
    nonisolated private static let headTag: UInt32 = 0x6865_6164  // 'head'
    nonisolated private static let locaTag: UInt32 = 0x6C6F_6361  // 'loca'
    nonisolated private static let maxpTag: UInt32 = 0x6D61_7870  // 'maxp'
    nonisolated private static let nameTag: UInt32 = 0x6E61_6D65  // 'name'

    nonisolated static func hasUsableColorGlyphTables(_ tags: Set<UInt32>) -> Bool {
        tags.contains(sbixTag)
            || tags.contains(colrTag)
            || tags.contains(svgTag)
            || tags.contains(cbdtTag)
    }

    private nonisolated static func buildSFNTData(
        forPostScriptName postScriptName: String,
        familyName: String?,
        styleName: String?,
        requiredCodepoints: [UInt32]?
    ) -> Data? {
        guard let font = makeFont(postScriptName: postScriptName) else {
            return nil
        }

        let tableTags = availableTableTags(for: font)
        guard !tableTags.isEmpty else { return nil }
        let tagSet = Set(tableTags)

        var tables: [Table] = []
        tables.reserveCapacity(tableTags.count)
        var hasReadableOutlines = false
        let hasColorOrBitmapTables = Self.hasUsableColorGlyphTables(tagSet)

        for tag in tableTags {
            guard let cfData = CTFontCopyTable(font, CTFontTableTag(tag), CTFontTableOptions(rawValue: 0)) else {
                continue
            }
            if tag == Self.glyfTag || tag == Self.cffTag || tag == Self.cff2Tag {
                hasReadableOutlines = true
            }
            tables.append(Table(tag: tag, data: ownedTableData(from: cfData)))
        }
        guard !tables.isEmpty else { return nil }

        // If the font advertises an `sbix` table but the bytes we got back
        // are not the macOS-format PNG strikes krilla expects (iOS Apple
        // Color Emoji is the canonical example — its payload is Apple's
        // private `bgcl`-indexed format), replace the sbix with one we
        // synthesize by rasterizing each required glyph via CoreText.
        //
        // We only attempt this when we actually have a codepoint subset
        // from the document; otherwise the production flow would ask us
        // to rasterize every single glyph in the font (thousands), which
        // is wasteful. The resolver always supplies a non-empty set in
        // real compiles — the missing-codepoints case is hit by unit tests
        // that just want a parseable sfnt.
        if let sbixIndex = tables.firstIndex(where: { $0.tag == Self.sbixTag }),
           let cps = requiredCodepoints,
           !cps.isEmpty,
           AppleColorEmojiSbixSynthesizer.sbixNeedsSynthesis(tables[sbixIndex].data) {
            let numGlyphs = Int(CTFontGetGlyphCount(font))
            let requiredGlyphs = glyphIDs(for: cps, in: font)
            if !requiredGlyphs.isEmpty,
               let synthesizedSbix = AppleColorEmojiSbixSynthesizer.synthesize(
                   font: font,
                   numGlyphs: numGlyphs,
                   requiredGlyphs: requiredGlyphs
               ) {
                tables[sbixIndex].data = synthesizedSbix
            }
        }

        var synthesizedTrueTypeOutlines = false
        if !hasReadableOutlines && !hasColorOrBitmapTables {
            let requiredGlyphs = requiredCodepoints.flatMap { glyphIDs(for: $0, in: font) }
            guard let synthesized = TrueTypeGlyfSynthesizer.synthesize(
                font: font,
                requiredGlyphs: requiredGlyphs
            ) else {
                logger.notice(
                    "Skipping \(postScriptName, privacy: .public): no standard outlines and glyf synthesis failed"
                )
                return nil
            }

            tables.removeAll {
                $0.tag == Self.glyfTag
                    || $0.tag == Self.locaTag
                    || $0.tag == Self.maxpTag
                    || $0.tag == Self.cffTag
                    || $0.tag == Self.cff2Tag
            }
            upsertTable(tag: Self.glyfTag, data: synthesized.glyf, in: &tables)
            upsertTable(tag: Self.locaTag, data: synthesized.loca, in: &tables)
            upsertTable(tag: Self.maxpTag, data: synthesized.maxp, in: &tables)
            patchHeadForSynthesizedTrueType(
                in: &tables,
                locaIsLong: synthesized.locaIsLong,
                xMin: synthesized.xMin,
                yMin: synthesized.yMin,
                xMax: synthesized.xMax,
                yMax: synthesized.yMax
            )
            synthesizedTrueTypeOutlines = true
        }

        if let familyName,
           !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let index = tables.firstIndex(where: { $0.tag == Self.nameTag }),
           let patched = patchNameTable(
                tables[index].data,
                familyName: familyName,
                styleName: styleName,
                postScriptName: postScriptName
           ) {
            tables[index].data = patched
        }

        // Table records must be sorted by tag in the sfnt directory.
        tables.sort { $0.tag < $1.tag }

        let sfntVersion: UInt32 = !synthesizedTrueTypeOutlines && tables.contains { $0.tag == Self.cffTag || $0.tag == Self.cff2Tag }
            ? 0x4F54_544F  // 'OTTO' (CFF-based OpenType)
            : 0x0001_0000  // TrueType

        // Per spec: zero out head.checkSumAdjustment before checksumming.
        var headIndex: Int?
        for (idx, table) in tables.enumerated() where table.tag == Self.headTag {
            if tables[idx].data.count >= 12 {
                tables[idx].data.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            }
            headIndex = idx
            break
        }

        let numTables = UInt16(tables.count)
        let entrySelector = UInt16(floor(log2(Double(numTables))))
        let searchRange = UInt16(1 << entrySelector) &* 16
        let rangeShift = numTables &* 16 &- searchRange

        let headerSize = 12 + 16 * tables.count
        let bodySize = tables.reduce(0) { $0 + paddedLength($1.data.count) }
        var output = Data(capacity: headerSize + bodySize)

        appendU32(&output, sfntVersion)
        appendU16(&output, numTables)
        appendU16(&output, searchRange)
        appendU16(&output, entrySelector)
        appendU16(&output, rangeShift)

        var offsets: [Int] = []
        offsets.reserveCapacity(tables.count)
        var runningOffset = headerSize
        for table in tables {
            offsets.append(runningOffset)
            runningOffset += paddedLength(table.data.count)
        }

        for (idx, table) in tables.enumerated() {
            appendU32(&output, table.tag)
            appendU32(&output, checksum(of: table.data))
            appendU32(&output, UInt32(offsets[idx]))
            appendU32(&output, UInt32(table.data.count))
        }

        for table in tables {
            output.append(table.data)
            let pad = paddedLength(table.data.count) - table.data.count
            if pad > 0 {
                output.append(Data(repeating: 0, count: pad))
            }
        }

        // Patch head.checkSumAdjustment = 0xB1B0AFBA - checksum(entire file)
        if let headIndex {
            let globalChecksum = checksum(of: output)
            let adjustment: UInt32 = 0xB1B0_AFBA &- globalChecksum
            let fieldStart = offsets[headIndex] + 8
            let fieldEnd = fieldStart + 4
            if fieldEnd <= output.count {
                let beAdjustment = adjustment.bigEndian
                withUnsafeBytes(of: beAdjustment) { raw in
                    output.replaceSubrange(fieldStart..<fieldEnd, with: raw)
                }
            }
        }

        return output
    }

    // MARK: - Helpers

    private nonisolated static func makeFont(postScriptName: String) -> CTFont? {
        let attrs: [CFString: Any] = [kCTFontNameAttribute: postScriptName]
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12.0, nil)
        let resolvedName = CTFontCopyPostScriptName(font) as String
        guard resolvedName == postScriptName else {
            logger.notice(
                "Skipping \(postScriptName, privacy: .public): CoreText resolved descriptor to \(resolvedName, privacy: .public)"
            )
            return nil
        }
        return font
    }

    private nonisolated static func availableTableTags(for font: CTFont) -> [UInt32] {
        guard let tagsArray = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)) else {
            return []
        }

        let tagCount = CFArrayGetCount(tagsArray)
        guard tagCount > 0 else { return [] }

        var tags: [UInt32] = []
        tags.reserveCapacity(tagCount)
        for i in 0..<tagCount {
            let rawPtr = CFArrayGetValueAtIndex(tagsArray, i)
            tags.append(UInt32(UInt(bitPattern: rawPtr) & 0xFFFF_FFFF))
        }
        return tags
    }

    /// Convert a sorted list of Unicode scalar values into the corresponding
    /// glyph IDs in `font`. Scalars outside the BMP are encoded as UTF-16
    /// surrogate pairs and both halves are passed to CoreText, so the caller
    /// gets the real GID (not just the lead-surrogate GID).
    private nonisolated static func glyphIDs(
        for codepoints: [UInt32],
        in font: CTFont
    ) -> Set<CGGlyph> {
        guard !codepoints.isEmpty else { return [] }
        var utf16: [UniChar] = []
        utf16.reserveCapacity(codepoints.count)
        var starts: [Int] = []
        starts.reserveCapacity(codepoints.count)
        for cp in codepoints {
            guard let scalar = Unicode.Scalar(cp) else { continue }
            starts.append(utf16.count)
            for unit in String(scalar).utf16 {
                utf16.append(unit)
            }
        }
        guard !utf16.isEmpty else { return [] }
        var glyphs = Array(repeating: CGGlyph(0), count: utf16.count)
        CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        var result: Set<CGGlyph> = []
        for start in starts {
            guard start < glyphs.count else { continue }
            let gid = glyphs[start]
            if gid != 0 {
                result.insert(gid)
            }
        }
        return result
    }

    private nonisolated static func upsertTable(
        tag: UInt32,
        data: Data,
        in tables: inout [Table]
    ) {
        if let index = tables.firstIndex(where: { $0.tag == tag }) {
            tables[index].data = data
        } else {
            tables.append(Table(tag: tag, data: data))
        }
    }

    private nonisolated static func cacheKeyCodepoints(
        forPostScriptName postScriptName: String,
        requestedCodepoints: [UInt32]?
    ) -> [UInt32]? {
        guard let requestedCodepoints, !requestedCodepoints.isEmpty else { return nil }
        guard requiresCodepointSpecificCache(postScriptName: postScriptName) else { return nil }
        return Array(Set(requestedCodepoints)).sorted()
    }

    /// Most CoreText materialized fonts are full, self-contained sfnt files and
    /// should share one cache file across all documents. Only fonts whose output
    /// is synthesized from a subset of document glyphs need codepoints in the
    /// cache key.
    private nonisolated static func requiresCodepointSpecificCache(postScriptName: String) -> Bool {
        cacheKeyLock.lock()
        if let cached = codepointSpecificCacheRequirementCache[postScriptName] {
            cacheKeyLock.unlock()
            return cached
        }
        cacheKeyLock.unlock()

        let result: Bool
        if let font = makeFont(postScriptName: postScriptName) {
            let tags = Set(availableTableTags(for: font))
            let hasColorOrBitmapTables = hasUsableColorGlyphTables(tags)
            let hasStandardOutlineTables =
                tags.contains(Self.glyfTag) || tags.contains(Self.cffTag) || tags.contains(Self.cff2Tag)
            result = hasColorOrBitmapTables || !hasStandardOutlineTables
        } else {
            result = false
        }

        cacheKeyLock.lock()
        codepointSpecificCacheRequirementCache[postScriptName] = result
        cacheKeyLock.unlock()
        return result
    }

    /// Subset-dependent fonts should converge to one growing cache file per
    /// font identity. If we keep one file per document-specific codepoint set,
    /// emoji/CJK fallback text changes can fragment the cache into many
    /// equally large files.
    private nonisolated static func expandedCacheRequest(for request: Request) -> Request {
        guard let requestedCodepoints = request.requiredCodepoints, !requestedCodepoints.isEmpty else {
            return request
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return request
        }

        var merged = Set(requestedCodepoints)
        for url in urls where url.pathExtension.lowercased() == "otf" {
            guard let existingRequest = self.request(forCachedFontURL: url),
                  existingRequest.hasSameFontIdentity(as: request),
                  let existingCodepoints = existingRequest.requiredCodepoints,
                  !existingCodepoints.isEmpty else {
                continue
            }
            merged.formUnion(existingCodepoints)
        }

        let mergedCodepoints = merged.sorted()
        guard mergedCodepoints != requestedCodepoints else { return request }
        return request.replacingRequiredCodepoints(mergedCodepoints)
    }

    private nonisolated static func destinationURL(for request: Request) -> URL {
        let safeName = sanitizeFileName(request.postScriptName)
        let codepointsKey: String
        if let cps = request.requiredCodepoints, !cps.isEmpty {
            // Stable hash over the sorted codepoint set for fonts whose
            // materialized output is genuinely subset-dependent.
            codepointsKey = "cp:" + cps.map { String($0, radix: 16) }.joined(separator: ",")
        } else {
            codepointsKey = "cp:*"
        }
        let hashInput = [
            request.postScriptName,
            request.familyName ?? "",
            request.styleName ?? "",
            request.originalPath ?? "",
            codepointsKey,
            cacheVersion,
        ].joined(separator: "\u{1F}")
        let suffix = stableHashHex(hashInput)
        return cacheDirURL.appendingPathComponent("\(safeName)-\(suffix)-\(cacheVersion).otf")
    }

    private nonisolated static func requestURL(forFontURL url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(manifestExtension)
    }

    private nonisolated static func writeRequestIfNeeded(_ request: Request, beside fontURL: URL) {
        let requestURL = requestURL(forFontURL: fontURL)
        if let data = try? Data(contentsOf: requestURL),
           let existing = try? JSONDecoder().decode(Request.self, from: data),
           existing.postScriptName == request.postScriptName,
           existing.familyName == request.familyName,
           existing.styleName == request.styleName,
           existing.originalPath == request.originalPath,
           existing.requiredCodepoints == request.requiredCodepoints {
            return
        }
        guard let data = try? JSONEncoder().encode(request) else { return }
        if (try? data.write(to: requestURL, options: .atomic)) != nil {
            excludeItemFromBackup(at: requestURL)
        }
    }

    private nonisolated static func request(forPlannedPath path: String) -> Request? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL == cacheDirURL.standardizedFileURL else {
            return nil
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let requestURL = requestURL(forFontURL: url)
        guard let data = try? Data(contentsOf: requestURL) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    private nonisolated static func request(forCachedFontURL url: URL) -> Request? {
        let requestURL = requestURL(forFontURL: url)
        guard let data = try? Data(contentsOf: requestURL) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    private nonisolated static func existingCompatibleMaterializedFile(for request: Request) -> URL? {
        guard let requestedCodepoints = request.requiredCodepoints, !requestedCodepoints.isEmpty else {
            return nil
        }
        let requestedSet = Set(requestedCodepoints)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, coverageCount: Int, modifiedAt: Date)] = []
        for url in urls where url.pathExtension.lowercased() == "otf" {
            guard FileManager.default.fileExists(atPath: url.path),
                  let existingRequest = self.request(forCachedFontURL: url),
                  existingRequest.hasSameFontIdentity(as: request),
                  let existingCodepoints = existingRequest.requiredCodepoints,
                  Set(existingCodepoints).isSuperset(of: requestedSet) else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            candidates.append((url, existingCodepoints.count, modifiedAt))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.coverageCount != rhs.coverageCount {
                return lhs.coverageCount < rhs.coverageCount
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }.first?.url
    }

    private nonisolated static func removeRedundantCacheVariants(matching request: Request, keeping keptURL: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls where url.pathExtension.lowercased() == "otf" {
            guard url.standardizedFileURL != keptURL.standardizedFileURL,
                  let existingRequest = self.request(forCachedFontURL: url),
                  existingRequest.hasSameFontIdentity(as: request) else {
                continue
            }

            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: requestURL(forFontURL: url))
        }
    }

    private nonisolated static func removeLegacyCacheDirectory() {
        guard let legacyCacheDirURL,
              legacyCacheDirURL.standardizedFileURL != cacheDirURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacyCacheDirURL.path) else {
            return
        }
        try? FileManager.default.removeItem(at: legacyCacheDirURL)
    }

    private nonisolated static func fileSizeIfPresent(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            return 0
        }
        return Int64(values.fileSize ?? 0)
    }

    private nonisolated static func excludeItemFromBackup(at url: URL) {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    private nonisolated static func existingMaterializedFile(forPostScriptName postScriptName: String) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let prefix = "\(sanitizeFileName(postScriptName))-"
        return urls.first {
            $0.lastPathComponent.hasPrefix(prefix)
                && $0.lastPathComponent.hasSuffix("-\(cacheVersion).otf")
        }
    }

    private struct NameRecord {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16
        let bytes: Data
    }

    private nonisolated static func patchNameTable(
        _ data: Data,
        familyName: String,
        styleName: String?,
        postScriptName: String
    ) -> Data? {
        guard data.count >= 6,
              let count = readU16(data, at: 2),
              let stringOffset = readU16(data, at: 4) else {
            return nil
        }

        let trimmedFamily = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFamily.isEmpty else { return nil }
        let trimmedStyle = (styleName ?? "Regular").trimmingCharacters(in: .whitespacesAndNewlines)
        let style = trimmedStyle.isEmpty ? "Regular" : trimmedStyle
        let fullName = "\(trimmedFamily) \(style)"

        var records: [NameRecord] = [
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 1, bytes: utf16BE(trimmedFamily)),
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 2, bytes: utf16BE(style)),
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 4, bytes: utf16BE(fullName)),
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 6, bytes: utf16BE(postScriptName)),
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 16, bytes: utf16BE(trimmedFamily)),
            NameRecord(platformID: 3, encodingID: 1, languageID: 0x0409, nameID: 17, bytes: utf16BE(style)),
        ]

        let protectedNameIDs: Set<UInt16> = [1, 2, 4, 6, 16, 17]
        for i in 0..<Int(count) {
            let recordOffset = 6 + i * 12
            guard recordOffset + 12 <= data.count,
                  let platformID = readU16(data, at: recordOffset),
                  let encodingID = readU16(data, at: recordOffset + 2),
                  let languageID = readU16(data, at: recordOffset + 4),
                  let nameID = readU16(data, at: recordOffset + 6),
                  let length = readU16(data, at: recordOffset + 8),
                  let offset = readU16(data, at: recordOffset + 10) else {
                continue
            }

            if platformID == 3,
               encodingID == 1,
               languageID == 0x0409,
               protectedNameIDs.contains(nameID) {
                continue
            }

            let start = Int(stringOffset) + Int(offset)
            let end = start + Int(length)
            guard start >= 0, end <= data.count else { continue }
            records.append(
                NameRecord(
                    platformID: platformID,
                    encodingID: encodingID,
                    languageID: languageID,
                    nameID: nameID,
                    bytes: data.subdata(in: start..<end)
                )
            )
        }

        guard records.count <= Int(UInt16.max) else { return nil }
        let newStringOffset = 6 + records.count * 12
        guard newStringOffset <= Int(UInt16.max) else { return nil }

        var output = Data()
        appendU16(&output, 0)
        appendU16(&output, UInt16(records.count))
        appendU16(&output, UInt16(newStringOffset))

        var strings = Data()
        for record in records {
            guard strings.count <= Int(UInt16.max),
                  record.bytes.count <= Int(UInt16.max) else {
                return nil
            }
            appendU16(&output, record.platformID)
            appendU16(&output, record.encodingID)
            appendU16(&output, record.languageID)
            appendU16(&output, record.nameID)
            appendU16(&output, UInt16(record.bytes.count))
            appendU16(&output, UInt16(strings.count))
            strings.append(record.bytes)
        }

        output.append(strings)
        return output
    }

    private nonisolated static func patchHeadForSynthesizedTrueType(
        in tables: inout [Table],
        locaIsLong: Bool,
        xMin: Int16,
        yMin: Int16,
        xMax: Int16,
        yMax: Int16
    ) {
        guard let index = tables.firstIndex(where: { $0.tag == Self.headTag }) else {
            return
        }
        guard tables[index].data.count >= 54 else {
            return
        }

        replaceInt16(xMin, in: &tables[index].data, at: 36)
        replaceInt16(yMin, in: &tables[index].data, at: 38)
        replaceInt16(xMax, in: &tables[index].data, at: 40)
        replaceInt16(yMax, in: &tables[index].data, at: 42)
        replaceInt16(locaIsLong ? 1 : 0, in: &tables[index].data, at: 50)
        replaceInt16(0, in: &tables[index].data, at: 52)
    }

    private nonisolated static func replaceInt16(_ value: Int16, in data: inout Data, at offset: Int) {
        guard offset >= 0, offset + 2 <= data.count else { return }
        var be = UInt16(bitPattern: value).bigEndian
        withUnsafeBytes(of: &be) { raw in
            data.replaceSubrange(offset..<(offset + 2), with: raw)
        }
    }

    private nonisolated static func ownedTableData(from cfData: CFData) -> Data {
        (cfData as Data).withUnsafeBytes { Data($0) }
    }

    private nonisolated static func readU16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
    }

    private nonisolated static func utf16BE(_ string: String) -> Data {
        var data = Data()
        data.reserveCapacity(string.utf16.count * 2)
        for codeUnit in string.utf16 {
            appendU16(&data, codeUnit)
        }
        return data
    }

    private nonisolated static func paddedLength(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private nonisolated static func checksum(of data: Data) -> UInt32 {
        var sum: UInt32 = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0
            while i + 4 <= count {
                let v = (UInt32(bytes[i])     << 24)
                      | (UInt32(bytes[i + 1]) << 16)
                      | (UInt32(bytes[i + 2]) << 8)
                      |  UInt32(bytes[i + 3])
                sum = sum &+ v
                i += 4
            }
            if i < count {
                var tail: UInt32 = 0
                var shift: Int = 24
                while i < count {
                    tail |= UInt32(bytes[i]) << shift
                    shift -= 8
                    i += 1
                }
                sum = sum &+ tail
            }
        }
        return sum
    }

    private nonisolated static func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private nonisolated static func appendU16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private nonisolated static func sanitizeFileName(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\0" {
                out.append("_")
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }

    private nonisolated static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
