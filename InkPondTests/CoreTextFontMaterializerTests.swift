import Testing
import CoreText
import Foundation
@testable import InkPond

@Suite(.serialized)
struct CoreTextFontMaterializerTests {
    @Test func enumerateAllSystemFontsForCJKGlyph() throws {
        // Enumerate EVERY system font and find ones that:
        //  (a) have standard glyph tables (glyf or CFF/CFF2), AND
        //  (b) produce a non-.notdef glyph for '中'.
        let descriptors = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let all = CTFontCollectionCreateMatchingFontDescriptors(descriptors) as? [CTFontDescriptor] else {
            Issue.record("no descriptors")
            return
        }
        let glyf: UInt32 = 0x676C7966
        let cff: UInt32 = 0x43464620
        let cff2: UInt32 = 0x43464632
        var found: [(String, String, String)] = []  // (family, ps, outline)
        for d in all {
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            guard let tags = CTFontCopyAvailableTables(font, .init(rawValue: 0)) else { continue }
            var outline: String? = nil
            for i in 0..<CFArrayGetCount(tags) {
                let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tags, i)) & 0xFFFFFFFF)
                if tag == glyf { outline = "glyf"; break }
                if tag == cff { outline = "CFF"; break }
                if tag == cff2 { outline = "CFF2"; break }
            }
            guard let outline else { continue }
            var ch: [UniChar] = [0x4E2D]  // 中
            var g: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(font, &ch, &g, 1)
            guard g[0] != 0 else { continue }
            let family = (CTFontCopyFamilyName(font) as String)
            let ps = (CTFontCopyPostScriptName(font) as String)
            found.append((family, ps, outline))
        }
        found.sort { $0.0 < $1.0 }
        for (f, p, o) in found {
            print("[cjk-capable] family=\(f) ps=\(p) outline=\(o)")
        }
        print("[cjk-capable] total=\(found.count)")
    }

    @Test func diagnoseEmojiFontTables() throws {
        for name in ["AppleColorEmoji", ".AppleColorEmojiUI", "AppleColorEmojiUI"] {
            let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
            guard let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL else {
                print("[emoji] \(name): not found")
                continue
            }
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            guard let tags = CTFontCopyAvailableTables(font, .init(rawValue: 0)) else { continue }
            var tagStrings: [String] = []
            for i in 0..<CFArrayGetCount(tags) {
                let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tags, i)) & 0xFFFFFFFF)
                let bytes = withUnsafeBytes(of: tag.bigEndian) { Data($0) }
                tagStrings.append(String(data: bytes, encoding: .ascii) ?? "????")
            }
            // Try to get a glyph for 😀 U+1F600
            let ns = "😀" as NSString
            var chars: [UniChar] = (0..<ns.length).map { ns.character(at: $0) }
            var glyphs = Array(repeating: CGGlyph(0), count: chars.count)
            CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
            let hasGlyph = glyphs.contains { $0 != 0 }
            let gid = glyphs.first(where: { $0 != 0 }) ?? 0
            let path = gid != 0 ? CTFontCreatePathForGlyph(font, gid, nil) : nil
            print("[emoji] ps=\(CTFontCopyPostScriptName(font) as String) url=\(url.lastPathComponent) tables=\(tagStrings.sorted().joined(separator: ",")) hasGlyph=\(hasGlyph) pathNil=\(path == nil) pathEmpty=\(path?.isEmpty ?? true)")
        }
    }

    @Test func diagnoseEmojiCompilePipelineEndToEnd() throws {
        // Reproduce the macOS CLI test: compile `😴` and inspect whether
        // Typst emitted PDF Image XObjects (sbix PNGs) or just a .notdef.
        let emojiDesc = CTFontDescriptorCreateWithAttributes(
            [kCTFontNameAttribute: "AppleColorEmoji"] as CFDictionary
        )
        guard let emojiURL = CTFontDescriptorCopyAttribute(emojiDesc, kCTFontURLAttribute) as? URL else {
            Issue.record("AppleColorEmoji not present on simulator")
            return
        }
        print("[emoji-e2e] original url=\(emojiURL.path)")
        print("[emoji-e2e] original readable=\(FileManager.default.isReadableFile(atPath: emojiURL.path))")

        // The resolver always materializes system fonts through CoreText on
        // iOS — handing Rust the raw AssetsV2 path yields an unreadable stub.
        // Pass the codepoints we're actually going to compile so the
        // materializer can build a subsetted sbix with PNG entries for
        // just those glyphs (matching the production resolver's call).
        // 0x1F634 = 😴. ASCII baseline included so cmap lookup has the
        // same shape as real compiles.
        var cps: [UInt32] = Array(0x20...0x7E).map(UInt32.init)
        cps.append(0x1F634)
        guard let pickedPath = CoreTextFontMaterializer.materializedPath(
            forPostScriptName: "AppleColorEmoji",
            familyName: "Apple Color Emoji",
            styleName: "Regular",
            originalPath: emojiURL.path,
            requiredCodepoints: cps
        ) else {
            Issue.record("materialization failed")
            return
        }
        print("[emoji-e2e] pipeline chose: MATERIALIZED \(pickedPath)")

        let fileData = try Data(contentsOf: URL(fileURLWithPath: pickedPath))
        let tags = sfntTableTags(in: fileData)
        let tableSummary = sfntTableSummary(in: fileData)

        // Count PNG signatures inside sbix
        var sbixBytes = 0
        var pngCount = 0
        if let sbixRange = sfntTableRange(in: fileData, tag: "sbix") {
            let sbixData = fileData.subdata(in: sbixRange)
            sbixBytes = sbixData.count
            let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            var idx = 0
            let bytes = [UInt8](sbixData)
            while idx + 8 <= bytes.count {
                if Array(bytes[idx..<(idx+8)]) == pngSig {
                    pngCount += 1
                    idx += 8
                } else {
                    idx += 1
                }
            }
        }

        var diagnosticLines: [String] = []
        diagnosticLines.append("origUrl=\(emojiURL.path)")
        diagnosticLines.append("origReadable=\(FileManager.default.isReadableFile(atPath: emojiURL.path))")
        diagnosticLines.append("picked=\(pickedPath)")
        diagnosticLines.append("pickedBytes=\(fileData.count)")
        diagnosticLines.append("tables=\(tags.sorted().joined(separator: ","))")
        diagnosticLines.append("sizes=\(tableSummary)")
        diagnosticLines.append("sbixBytes=\(sbixBytes) pngsInSbix=\(pngCount)")

        #expect(tags.contains("sbix"), "picked font file does not contain sbix table")

        let source = "#set page(width: 120pt, height: 120pt, margin: 12pt)\n#set text(font: \"Apple Color Emoji\", size: 72pt)\n😴"
        let result = TypstBridge.compile(source: source, fontPaths: [pickedPath], rootDir: nil)
        switch result {
        case .success(let pdf):
            let raw = String(data: pdf, encoding: .isoLatin1) ?? ""
            let hasImageXObject = raw.contains("/Subtype /Image") || raw.contains("/Subtype/Image")
            let hasType3 = raw.contains("/Subtype /Type3") || raw.contains("/Subtype/Type3")
            let hasCIDType0 = raw.contains("/Subtype /CIDFontType0") || raw.contains("/Subtype/CIDFontType0")
            let hasCIDType2 = raw.contains("/Subtype /CIDFontType2") || raw.contains("/Subtype/CIDFontType2")
            let hasTrueType = raw.contains("/Subtype /TrueType") || raw.contains("/Subtype/TrueType")
            let hasAppleColorEmoji = raw.localizedCaseInsensitiveContains("AppleColorEmoji")
            // Extract font subtype used for drawing
            diagnosticLines.append("pdfBytes=\(pdf.count)")
            diagnosticLines.append("imageXObject=\(hasImageXObject) type3=\(hasType3) trueType=\(hasTrueType) cid0=\(hasCIDType0) cid2=\(hasCIDType2) hasACE=\(hasAppleColorEmoji)")
            // Gist of PDF to look for ToUnicode / FontDescriptor / encoding
            let lowered = raw
            for needle in ["/Subtype", "/BaseFont", "/FontDescriptor", "/FontFile", "/CIDSystemInfo", "/Encoding", "/ToUnicode"] {
                let count = lowered.components(separatedBy: needle).count - 1
                diagnosticLines.append("needle\(needle)=\(count)")
            }
            if !hasImageXObject {
                let joined = diagnosticLines.joined(separator: "\n")
                Issue.record("Typst did NOT emit an Image XObject. Diagnostic:\n\(joined)")
            }
        case .failure(let err):
            let joined = diagnosticLines.joined(separator: " | ")
            Issue.record("compile failed: \(err.localizedDescription). Diagnostic: \(joined)")
        }
    }

    @Test func materializerTreatsColorGlyphTablesAsUsableRenderData() {
        for tag in ["sbix", "COLR", "SVG ", "CBDT"] {
            #expect(
                CoreTextFontMaterializer.hasUsableColorGlyphTables([sfntTag(tag)]),
                "\(tag) should be accepted as color glyph render data"
            )
        }
    }

    @Test func materializerPreservesAppleColorEmojiSbixTable() throws {
        let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "AppleColorEmoji"] as CFDictionary)
        guard (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL) != nil else {
            Issue.record("Apple Color Emoji not available on simulator")
            return
        }

        #expect(CoreTextFontMaterializer.canMaterialize(postScriptName: "AppleColorEmoji"))

        guard let path = CoreTextFontMaterializer.materializedPath(
            forPostScriptName: "AppleColorEmoji",
            familyName: "Apple Color Emoji",
            styleName: "Regular"
        ) else {
            Issue.record("materializedPath returned nil for AppleColorEmoji")
            return
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let tags = sfntTableTags(in: data)
        #expect(tags.contains("sbix"))
        #expect(FontManager.typstFamilyName(forFontAtPath: path) == "Apple Color Emoji")
    }

    @Test func materializerSynthesizesProprietaryHvglOutlines() throws {
        // PingFang SC on iOS 26 uses Apple's private `hvgl` glyph table. Rust's
        // ttf-parser cannot render that table directly, so the materializer
        // must synthesize standard TrueType `glyf` outlines from CoreText.
        let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "PingFangSC-Regular"] as CFDictionary)
        guard (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL) != nil else {
            Issue.record("PingFang SC not available on simulator")
            return
        }
        #expect(CoreTextFontMaterializer.canMaterialize(postScriptName: "PingFangSC-Regular"))

        guard let path = CoreTextFontMaterializer.materializedPath(
            forPostScriptName: "PingFangSC-Regular",
            familyName: "PingFang SC",
            styleName: "Regular"
        ) else {
            Issue.record("materializedPath returned nil for PingFangSC-Regular")
            return
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let tags = sfntTableTags(in: data)
        #expect(tags.contains("glyf"))
        #expect(tags.contains("loca"))
        #expect(tags.contains("maxp"))
        #expect(FontManager.typstFamilyName(forFontAtPath: path) == "PingFang SC")

        let provider = CGDataProvider(data: data as CFData)!
        let cgFont = CGFont(provider)
        #expect(cgFont != nil, "CGFont rejected synthesized PingFang bytes")
        guard let cgFont else { return }

        let ct = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        for sample in ["A", "中"] {
            let ns = sample as NSString
            var chars: [UniChar] = [ns.character(at: 0)]
            var glyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, 1)
            #expect(glyphs[0] != 0, "CMap lookup for \(sample) returned .notdef")

            var bbox = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(ct, .horizontal, &glyphs, &bbox, 1)
            #expect(bbox.width > 0 && bbox.height > 0, "synthesized glyph \(sample) has zero bbox")
        }
    }

    @Test func materializedFontReloadsThroughCoreText() throws {
        let candidates = ["HiraginoSans-W3", "HiraMinProN-W3", "AppleSDGothicNeo-Regular"]
        var psName: String?
        for name in candidates {
            let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
            if (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL) != nil {
                psName = name; break
            }
        }
        guard let psName else {
            Issue.record("No CJK font available on this simulator")
            return
        }
        guard let path = CoreTextFontMaterializer.materializedPath(forPostScriptName: psName) else {
            Issue.record("materializedPath returned nil for \(psName)")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 1000)
        let sfnt = data.prefix(4)
        #expect(sfnt == Data([0x4F, 0x54, 0x54, 0x4F]) || sfnt == Data([0x00, 0x01, 0x00, 0x00]))

        // Dump sfnt directory so we can see what tables we emitted.
        let numTables = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        print("[materializer-test] path=\(path) bytes=\(data.count) numTables=\(numTables)")
        var present: [String] = []
        for i in 0..<numTables {
            let base = 12 + i * 16
            let tagBytes = data.subdata(in: base..<(base + 4))
            let tag = String(data: tagBytes, encoding: .ascii) ?? "????"
            let offset = UInt32(data[base + 8]) << 24 | UInt32(data[base + 9]) << 16 | UInt32(data[base + 10]) << 8 | UInt32(data[base + 11])
            let length = UInt32(data[base + 12]) << 24 | UInt32(data[base + 13]) << 16 | UInt32(data[base + 14]) << 8 | UInt32(data[base + 15])
            present.append("\(tag)@\(offset)+\(length)")
        }
        print("[materializer-test] tables: \(present.joined(separator: ", "))")

        // Round-trip: ask CoreText to read our written file back.
        let provider = CGDataProvider(data: data as CFData)!
        let cgFont = CGFont(provider)
        #expect(cgFont != nil, "CGFont rejected materialized bytes")
        if let cgFont {
            let ct = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
            let family = CTFontCopyFamilyName(ct) as String
            print("[materializer-test] PSName=\(psName) → family=\(family), bytes=\(data.count)")
            #expect(!family.isEmpty)

            // Glyph for '中' must exist and have a non-trivial bounding box.
            let str = "中" as NSString
            var ch: [UniChar] = [str.character(at: 0)]
            var glyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(ct, &ch, &glyphs, 1)
            print("[materializer-test] glyph for 中 = \(glyphs[0])")
            #expect(glyphs[0] != 0, "CMap lookup for 中 returned .notdef")
            var bbox = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(ct, .horizontal, &glyphs, &bbox, 1)
            print("[materializer-test] bbox for 中 = \(bbox)")
            #expect(bbox.width > 0 && bbox.height > 0, "glyph has zero bbox — outline missing")
        }
    }

    private func sfntTableSummary(in data: Data) -> String {
        guard data.count >= 12 else { return "" }
        let numTables = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        guard data.count >= 12 + numTables * 16 else { return "" }
        var parts: [String] = []
        for i in 0..<numTables {
            let base = 12 + i * 16
            let tagBytes = data.subdata(in: base..<(base + 4))
            let tag = String(data: tagBytes, encoding: .ascii) ?? "????"
            let length = UInt32(data[base + 12]) << 24 | UInt32(data[base + 13]) << 16 | UInt32(data[base + 14]) << 8 | UInt32(data[base + 15])
            parts.append("\(tag)=\(length)")
        }
        return parts.joined(separator: ",")
    }

    private func sfntTableRange(in data: Data, tag: String) -> Range<Int>? {
        guard data.count >= 12 else { return nil }
        let numTables = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        guard data.count >= 12 + numTables * 16 else { return nil }
        let targetBytes = Array(tag.utf8.prefix(4))
        for i in 0..<numTables {
            let base = 12 + i * 16
            let tagBytes = Array(data.subdata(in: base..<(base + 4)))
            if tagBytes == targetBytes {
                let offset = Int(UInt32(data[base + 8]) << 24 | UInt32(data[base + 9]) << 16 | UInt32(data[base + 10]) << 8 | UInt32(data[base + 11]))
                let length = Int(UInt32(data[base + 12]) << 24 | UInt32(data[base + 13]) << 16 | UInt32(data[base + 14]) << 8 | UInt32(data[base + 15]))
                guard offset + length <= data.count else { return nil }
                return offset..<(offset + length)
            }
        }
        return nil
    }

    private func sfntTableTags(in data: Data) -> Set<String> {
        guard data.count >= 12 else { return [] }
        let numTables = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        guard data.count >= 12 + numTables * 16 else { return [] }

        var tags = Set<String>()
        for i in 0..<numTables {
            let base = 12 + i * 16
            let tagBytes = data.subdata(in: base..<(base + 4))
            if let tag = String(data: tagBytes, encoding: .ascii) {
                tags.insert(tag)
            }
        }
        return tags
    }

    private func sfntTag(_ string: String) -> UInt32 {
        var bytes = Array(string.utf8.prefix(4))
        while bytes.count < 4 {
            bytes.append(0x20)
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
