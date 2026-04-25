//
//  AppleColorEmojiSbixSynthesizer.swift
//  InkPond
//
//  iOS ships Apple Color Emoji with a non-standard `sbix`: the table is
//  present and enormous, but its payload is Apple-proprietary bitmap data
//  indexed through the private `bgcl` table — *not* a set of PNG glyph
//  entries the way the macOS `Apple Color Emoji.ttc` stores them. Krilla
//  (Typst 0.14.x's PDF backend) only understands spec-compliant sbix with
//  PNG payloads, so it can't render iOS emoji through that path and falls
//  back to the (empty) outline pipeline → `.notdef` for every codepoint.
//
//  This synthesizer reconstructs a real, PNG-based sbix table by asking
//  CoreText to rasterize each required emoji glyph into a CGImage, encoding
//  the image as PNG via ImageIO, and packaging the result into a single
//  OpenType sbix strike. After the materializer swaps the original sbix
//  bytes for this one, krilla sees a font structurally identical to macOS's
//  Apple Color Emoji and happily emits `/Subtype /Image` XObjects in the
//  PDF.
//
//  Only glyphs required by the document (plus `.notdef`) are rasterized;
//  every other `glyphDataOffsets` entry is zero-length per the sbix spec.
//  The materializer cache is keyed by the codepoint subset so repeated
//  compiles don't re-rasterize.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

nonisolated enum AppleColorEmojiSbixSynthesizer {
    /// PNG signature. We use this both to detect a "real" sbix payload
    /// (pass-through eligible) and to verify our freshly encoded bytes are
    /// actually PNG before packing them into a glyph entry.
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A quick heuristic: if an existing sbix table doesn't contain *any*
    /// PNG signature in a reasonable window, it's the iOS proprietary format
    /// and needs to be replaced. macOS-format sbix has PNG headers in the
    /// very first glyph entry, so scanning the first 1 MB is always enough.
    static func sbixNeedsSynthesis(_ sbixData: Data) -> Bool {
        guard sbixData.count >= pngSignature.count else { return true }
        let scanLimit = min(sbixData.count, 1 << 20)  // 1 MiB window
        let needle = Data(pngSignature)
        if sbixData.prefix(scanLimit).range(of: needle) != nil {
            return false  // real PNG-based sbix — pass through
        }
        return true
    }

    /// Build an OpenType `sbix` table containing a single PNG-based strike
    /// that covers the requested glyph IDs.
    ///
    /// - Parameters:
    ///   - font: The CoreText font to rasterize with.
    ///   - numGlyphs: The font's glyph count (matches the `maxp` value). All
    ///     `numGlyphs + 1` offset entries are emitted so the table is
    ///     structurally valid even for glyphs we skipped.
    ///   - requiredGlyphs: The subset of glyph IDs the document actually
    ///     needs; every other glyph gets a zero-length entry. `.notdef`
    ///     (GID 0) is always skipped.
    ///   - ppem: The strike resolution in pixels-per-em. Defaults to 128,
    ///     the commonly-used macOS Apple Color Emoji strike size, which
    ///     is high enough for print-quality PDFs without being wasteful.
    /// - Returns: The raw bytes of the sbix table, or `nil` if the font
    ///   couldn't produce any usable bitmaps.
    static func synthesize(
        font: CTFont,
        numGlyphs: Int,
        requiredGlyphs: Set<CGGlyph>,
        ppem: UInt16 = 128
    ) -> Data? {
        guard numGlyphs > 0 else { return nil }

        // Work with a font copy sized to the strike's ppem so that all
        // CoreText metric queries return values in bitmap pixels (since at
        // this size 1pt == 1px in the bitmap context we'll create).
        let sizedFont = CTFontCreateCopyWithAttributes(
            font, CGFloat(ppem), nil, nil
        )

        struct GlyphEntry {
            let originOffsetX: Int16
            let originOffsetY: Int16
            let png: Data
        }

        var entries: [CGGlyph: GlyphEntry] = [:]
        entries.reserveCapacity(requiredGlyphs.count)

        for gid in requiredGlyphs {
            guard gid != 0, Int(gid) < numGlyphs else { continue }
            guard let entry = rasterize(glyph: gid, font: sizedFont) else {
                continue
            }
            entries[gid] = GlyphEntry(
                originOffsetX: entry.originOffsetX,
                originOffsetY: entry.originOffsetY,
                png: entry.png
            )
        }

        guard !entries.isEmpty else {
            // Nothing to pack — signal failure so the materializer can fall
            // back to whatever the font supplied (even if it's broken, at
            // least we don't write a misleading "valid" sbix).
            return nil
        }

        // ---- Strike body ----
        // Layout per OpenType sbix spec:
        //   uint16 ppem
        //   uint16 ppi
        //   Offset32 glyphDataOffsets[numGlyphs + 1]   // offsets from strike start
        //   uint8[] glyphData
        //
        // Each glyph data entry:
        //   int16   originOffsetX
        //   int16   originOffsetY
        //   uint32  graphicType     ('png ' == 0x706E6720)
        //   uint8[] data (PNG)
        let offsetCount = numGlyphs + 1
        let strikeHeaderSize = 4  // ppem(2) + ppi(2)
        let offsetsSize = offsetCount * 4
        let glyphsBase = strikeHeaderSize + offsetsSize

        var glyphPayload = Data()
        var offsets = [UInt32]()
        offsets.reserveCapacity(offsetCount)

        for gid in 0..<numGlyphs {
            offsets.append(UInt32(glyphsBase + glyphPayload.count))
            guard let entry = entries[CGGlyph(gid)] else {
                continue  // zero-length glyph entry
            }
            appendU16(&glyphPayload, UInt16(bitPattern: entry.originOffsetX))
            appendU16(&glyphPayload, UInt16(bitPattern: entry.originOffsetY))
            appendU32(&glyphPayload, 0x706E_6720)  // 'png '
            glyphPayload.append(entry.png)
        }
        // Sentinel end offset so consumers can compute the last glyph's
        // length as offsets[i+1] - offsets[i].
        offsets.append(UInt32(glyphsBase + glyphPayload.count))

        var strike = Data(capacity: strikeHeaderSize + offsetsSize + glyphPayload.count)
        appendU16(&strike, ppem)
        appendU16(&strike, 72)  // ppi — not used by krilla, spec-conformant default
        for off in offsets {
            appendU32(&strike, off)
        }
        strike.append(glyphPayload)

        // ---- sbix table header ----
        // uint16 version   = 1
        // uint16 flags     = 0x0001 (bit 0 reserved = 1, bit 1 cleared = don't draw outlines)
        // uint32 numStrikes = 1
        // Offset32 strikeOffsets[1]
        let sbixHeaderSize = 2 + 2 + 4 + 4

        var sbix = Data(capacity: sbixHeaderSize + strike.count)
        appendU16(&sbix, 1)                        // version
        appendU16(&sbix, 1)                        // flags: bit 0 = 1 (reserved)
        appendU32(&sbix, 1)                        // numStrikes
        appendU32(&sbix, UInt32(sbixHeaderSize))   // strikeOffsets[0] → right after header
        sbix.append(strike)

        return sbix
    }

    // MARK: - Rasterization

    private struct RasterizedGlyph {
        let originOffsetX: Int16
        let originOffsetY: Int16
        let png: Data
    }

    private static func rasterize(glyph gid: CGGlyph, font: CTFont) -> (originOffsetX: Int16, originOffsetY: Int16, png: Data)? {
        var glyph = gid
        // Ink bounding box in the font's current (ppem-sized) coordinate
        // space. For color bitmap fonts this is the bounds of the rasterized
        // artwork, which is exactly what we need.
        var imageBounds = CGRect.zero
        _ = withUnsafeMutablePointer(to: &glyph) { glyphPtr in
            withUnsafeMutablePointer(to: &imageBounds) { rectPtr in
                CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphPtr, rectPtr, 1)
            }
        }
        guard imageBounds.width.isFinite, imageBounds.height.isFinite else { return nil }
        guard imageBounds.width > 0.5, imageBounds.height > 0.5 else { return nil }

        // Pad 1px around the ink for safety against anti-aliased fringes
        // getting clipped at bitmap edges.
        let padding: CGFloat = 1
        let width = max(1, Int(ceil(imageBounds.width + padding * 2)))
        let height = max(1, Int(ceil(imageBounds.height + padding * 2)))
        let originX = Int(floor(imageBounds.origin.x - padding))
        let originY = Int(floor(imageBounds.origin.y - padding))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)

        // Draw so that the glyph's design origin lands at bitmap coordinate
        // (-originX, -originY); the ink then fills the bitmap area except
        // for the 1px padding on each side. In sbix glyph-data semantics,
        // the bitmap's *bottom-left* is placed at (originOffsetX, originOffsetY)
        // relative to the glyph's design origin, so we report the same
        // (originX, originY) values.
        var position = CGPoint(x: -CGFloat(originX), y: -CGFloat(originY))
        var mutableGlyph = gid
        withUnsafePointer(to: &mutableGlyph) { glyphPtr in
            withUnsafePointer(to: &position) { posPtr in
                CTFontDrawGlyphs(font, glyphPtr, posPtr, 1, ctx)
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        guard let png = encodePNG(image) else { return nil }
        guard !png.isEmpty else { return nil }

        return (
            originOffsetX: Int16(clamping: originX),
            originOffsetY: Int16(clamping: originY),
            png: png
        )
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        let uti: CFString
        if #available(iOS 14.0, *) {
            uti = UTType.png.identifier as CFString
        } else {
            uti = "public.png" as CFString
        }
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData, uti, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    // MARK: - Byte packing

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
