//
//  TrueTypeGlyfSynthesizer.swift
//  InkPond
//
//  Reconstructs a standard TrueType `glyf`/`loca` pair for fonts whose glyph
//  outlines live in Apple's proprietary `hvgl` table (PingFang, modern
//  STHeiti, etc. on iOS 26). Rust's `ttf-parser` — and therefore Typst —
//  cannot decode `hvgl`, so without this step CJK text would fall back to
//  `.notdef`, producing selectable-but-invisible glyphs.
//
//  Strategy: ask CoreText for each glyph's outline via
//  `CTFontCreatePathForGlyph`, which works regardless of how the outlines
//  are physically stored. Walk the resulting CGPath, quantize to em units,
//  convert cubic Béziers to quadratics (TrueType only supports quadratics),
//  and emit a simple-glyph record. Then splice a fresh `glyf`/`loca`/`maxp`
//  into the sfnt alongside the font's existing `cmap`/`hmtx`/`head` tables.
//

import CoreText
import CoreGraphics
import Foundation

enum TrueTypeGlyfSynthesizer {
    struct Output {
        let glyf: Data
        let loca: Data
        let locaIsLong: Bool
        let maxp: Data
        let xMin: Int16
        let yMin: Int16
        let xMax: Int16
        let yMax: Int16
    }

    nonisolated static func canSynthesize(font: CTFont) -> Bool {
        let numGlyphs = CTFontGetGlyphCount(font)
        guard numGlyphs > 0, numGlyphs <= 0xFFFF, CTFontGetUnitsPerEm(font) > 0 else {
            return false
        }

        let emFont = CTFontCreateCopyWithAttributes(font, CGFloat(CTFontGetUnitsPerEm(font)), nil, nil)
        for scalar in ["中", "文", "A"] {
            let ns = scalar as NSString
            var chars: [UniChar] = [ns.character(at: 0)]
            var glyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(emFont, &chars, &glyphs, 1)
            guard glyphs[0] != 0 else { continue }
            if let path = CTFontCreatePathForGlyph(emFont, glyphs[0], nil), !path.isEmpty {
                return true
            }
        }

        // Some symbol fonts do not map the sample characters above but still
        // expose CoreText paths for glyph IDs. A tiny bounded probe keeps this
        // preflight cheap while avoiding false negatives for such fonts.
        let probeCount = min(numGlyphs, 32)
        for gid in 1..<probeCount {
            if let path = CTFontCreatePathForGlyph(emFont, CGGlyph(gid), nil), !path.isEmpty {
                return true
            }
        }

        return false
    }

    /// Returns true if the font exposes at least one non-empty outline via
    /// CoreText. Color fonts with `sbix`/`COLR`/`SVG `/`CBDT` are accepted by
    /// the materializer before reaching this outline-only check.
    nonisolated static func hasAnyOutline(font: CTFont) -> Bool {
        let numGlyphs = CTFontGetGlyphCount(font)
        guard numGlyphs > 0, CTFontGetUnitsPerEm(font) > 0 else { return false }
        let emFont = CTFontCreateCopyWithAttributes(font, CGFloat(CTFontGetUnitsPerEm(font)), nil, nil)
        let probeCount = min(numGlyphs, 64)
        for gid in 0..<probeCount {
            if let path = CTFontCreatePathForGlyph(emFont, CGGlyph(gid), nil), !path.isEmpty {
                return true
            }
        }
        return false
    }

    /// Synthesize a `glyf`/`loca`/`maxp` triple from CoreText outlines.
    ///
    /// - Parameters:
    ///   - font: source font.
    ///   - requiredGlyphs: if non-nil, only these glyph IDs (plus GID 0, the
    ///     notdef) will have their outlines materialized. Every other GID is
    ///     emitted as a zero-length `loca` entry, preserving `numGlyphs` so
    ///     the `cmap` and `hmtx` tables remain valid while dramatically
    ///     reducing work for large CJK fonts.
    nonisolated static func synthesize(
        font: CTFont,
        requiredGlyphs: Set<CGGlyph>? = nil
    ) -> Output? {
        let numGlyphs = CTFontGetGlyphCount(font)
        guard numGlyphs > 0, numGlyphs <= 0xFFFF else { return nil }
        let upem = CTFontGetUnitsPerEm(font)
        guard upem > 0 else { return nil }

        // Create a font scaled so that CoreText paths come back in em units.
        let emFont = CTFontCreateCopyWithAttributes(font, CGFloat(upem), nil, nil)

        var glyfData = Data()
        var offsets: [UInt32] = []
        offsets.reserveCapacity(numGlyphs + 1)

        var maxPoints = 0
        var maxContours = 0
        var gotBBox = false
        var minX: Int16 = 0, minY: Int16 = 0
        var maxX: Int16 = 0, maxY: Int16 = 0

        for gid in 0..<numGlyphs {
            offsets.append(UInt32(glyfData.count))
            // GID 0 (.notdef) is always materialized so Typst has a fallback
            // glyph; everything else is gated by the subset when present.
            if let requiredGlyphs, gid != 0, !requiredGlyphs.contains(CGGlyph(gid)) {
                continue
            }
            guard let path = CTFontCreatePathForGlyph(emFont, CGGlyph(gid), nil) else {
                continue
            }
            guard let record = buildSimpleGlyph(from: path) else {
                continue
            }
            glyfData.append(record.data)
            if record.data.count & 1 != 0 {
                glyfData.append(0)  // pad glyph records to 2-byte boundary
            }
            maxPoints = max(maxPoints, record.numPoints)
            maxContours = max(maxContours, record.numContours)
            if !gotBBox {
                minX = record.xMin; maxX = record.xMax
                minY = record.yMin; maxY = record.yMax
                gotBBox = true
            } else {
                minX = min(minX, record.xMin); maxX = max(maxX, record.xMax)
                minY = min(minY, record.yMin); maxY = max(maxY, record.yMax)
            }
        }
        offsets.append(UInt32(glyfData.count))

        // Short loca stores offset/2 as uint16, capping at 0x1FFFE bytes total.
        let locaIsLong = glyfData.count > 0x1FFFE
        var locaData = Data(capacity: offsets.count * (locaIsLong ? 4 : 2))
        if locaIsLong {
            for off in offsets {
                var be = off.bigEndian
                withUnsafeBytes(of: &be) { locaData.append(contentsOf: $0) }
            }
        } else {
            for off in offsets {
                let half = UInt16(off / 2)
                var be = half.bigEndian
                withUnsafeBytes(of: &be) { locaData.append(contentsOf: $0) }
            }
        }

        // maxp v1.0 (32 bytes) — required for TrueType.
        var maxp = Data()
        func a32(_ v: UInt32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { maxp.append(contentsOf: $0) }
        }
        func a16(_ v: UInt16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { maxp.append(contentsOf: $0) }
        }
        a32(0x0001_0000)
        a16(UInt16(numGlyphs))
        a16(UInt16(min(maxPoints, 65535)))
        a16(UInt16(min(maxContours, 65535)))
        a16(0)  // maxCompositePoints
        a16(0)  // maxCompositeContours
        a16(2)  // maxZones
        a16(0)  // maxTwilightPoints
        a16(0)  // maxStorage
        a16(0)  // maxFunctionDefs
        a16(0)  // maxInstructionDefs
        a16(0)  // maxStackElements
        a16(0)  // maxSizeOfInstructions
        a16(0)  // maxComponentElements
        a16(0)  // maxComponentDepth

        return Output(
            glyf: glyfData,
            loca: locaData,
            locaIsLong: locaIsLong,
            maxp: maxp,
            xMin: gotBBox ? minX : 0,
            yMin: gotBBox ? minY : 0,
            xMax: gotBBox ? maxX : 0,
            yMax: gotBBox ? maxY : 0
        )
    }

    // MARK: - Simple-glyph assembly

    private struct TTPoint {
        var x: Int16
        var y: Int16
        var onCurve: Bool
    }

    private struct GlyphRecord {
        let data: Data
        let xMin: Int16
        let yMin: Int16
        let xMax: Int16
        let yMax: Int16
        let numPoints: Int
        let numContours: Int
    }

    private nonisolated static func buildSimpleGlyph(from path: CGPath) -> GlyphRecord? {
        var contours: [[TTPoint]] = []
        var current: [TTPoint] = []
        var lastPoint: CGPoint = .zero

        path.applyWithBlock { elemPtr in
            let elem = elemPtr.pointee
            switch elem.type {
            case .moveToPoint:
                if !current.isEmpty {
                    contours.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                let p = elem.points[0]
                lastPoint = p
                current.append(TTPoint(x: Int16(clamping: Int(p.x.rounded())),
                                       y: Int16(clamping: Int(p.y.rounded())),
                                       onCurve: true))

            case .addLineToPoint:
                let p = elem.points[0]
                lastPoint = p
                current.append(TTPoint(x: Int16(clamping: Int(p.x.rounded())),
                                       y: Int16(clamping: Int(p.y.rounded())),
                                       onCurve: true))

            case .addQuadCurveToPoint:
                let cp = elem.points[0]
                let ep = elem.points[1]
                current.append(TTPoint(x: Int16(clamping: Int(cp.x.rounded())),
                                       y: Int16(clamping: Int(cp.y.rounded())),
                                       onCurve: false))
                current.append(TTPoint(x: Int16(clamping: Int(ep.x.rounded())),
                                       y: Int16(clamping: Int(ep.y.rounded())),
                                       onCurve: true))
                lastPoint = ep

            case .addCurveToPoint:
                let cp1 = elem.points[0]
                let cp2 = elem.points[1]
                let ep = elem.points[2]
                // Split cubic into two quadratics by subdividing at t=0.5 and
                // approximating each half. Visually adequate at reading sizes;
                // can be deepened if we ever need higher fidelity.
                let q0 = CGPoint(x: (lastPoint.x + cp1.x) / 2, y: (lastPoint.y + cp1.y) / 2)
                let q1 = CGPoint(x: (cp1.x + cp2.x) / 2, y: (cp1.y + cp2.y) / 2)
                let q2 = CGPoint(x: (cp2.x + ep.x) / 2, y: (cp2.y + ep.y) / 2)
                let r0 = CGPoint(x: (q0.x + q1.x) / 2, y: (q0.y + q1.y) / 2)
                let r1 = CGPoint(x: (q1.x + q2.x) / 2, y: (q1.y + q2.y) / 2)
                let mid = CGPoint(x: (r0.x + r1.x) / 2, y: (r0.y + r1.y) / 2)
                // Left-half quadratic control = (3*q0 - lastPoint + 3*r0 - mid) / 4
                let lcx = (3 * q0.x - lastPoint.x + 3 * r0.x - mid.x) / 4
                let lcy = (3 * q0.y - lastPoint.y + 3 * r0.y - mid.y) / 4
                // Right-half quadratic control = (3*r1 - mid + 3*q2 - ep) / 4
                let rcx = (3 * r1.x - mid.x + 3 * q2.x - ep.x) / 4
                let rcy = (3 * r1.y - mid.y + 3 * q2.y - ep.y) / 4
                current.append(TTPoint(x: Int16(clamping: Int(lcx.rounded())),
                                       y: Int16(clamping: Int(lcy.rounded())),
                                       onCurve: false))
                current.append(TTPoint(x: Int16(clamping: Int(mid.x.rounded())),
                                       y: Int16(clamping: Int(mid.y.rounded())),
                                       onCurve: true))
                current.append(TTPoint(x: Int16(clamping: Int(rcx.rounded())),
                                       y: Int16(clamping: Int(rcy.rounded())),
                                       onCurve: false))
                current.append(TTPoint(x: Int16(clamping: Int(ep.x.rounded())),
                                       y: Int16(clamping: Int(ep.y.rounded())),
                                       onCurve: true))
                lastPoint = ep

            case .closeSubpath:
                if !current.isEmpty {
                    contours.append(current)
                    current.removeAll(keepingCapacity: true)
                }

            @unknown default:
                break
            }
        }
        if !current.isEmpty {
            contours.append(current)
        }

        // Drop degenerate trailing-duplicate endpoints left by closeSubpath +
        // lineTo patterns.
        var normalized: [[TTPoint]] = []
        normalized.reserveCapacity(contours.count)
        for contour in contours {
            var c = contour
            if c.count >= 2, let first = c.first, let last = c.last,
               first.x == last.x, first.y == last.y, first.onCurve == last.onCurve {
                c.removeLast()
            }
            if !c.isEmpty {
                normalized.append(c)
            }
        }
        guard !normalized.isEmpty else { return nil }

        var allPoints: [TTPoint] = []
        var endPts: [UInt16] = []
        for contour in normalized {
            allPoints.append(contentsOf: contour)
            guard allPoints.count <= Int(UInt16.max) else { return nil }
            endPts.append(UInt16(allPoints.count - 1))
        }
        guard normalized.count <= Int(Int16.max) else { return nil }

        let xs = allPoints.map { $0.x }
        let ys = allPoints.map { $0.y }
        guard let xMin = xs.min(), let xMax = xs.max(),
              let yMin = ys.min(), let yMax = ys.max() else { return nil }

        var data = Data()
        func a16s(_ v: Int16) {
            var be = UInt16(bitPattern: v).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        func a16u(_ v: UInt16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }

        a16s(Int16(normalized.count))
        a16s(xMin)
        a16s(yMin)
        a16s(xMax)
        a16s(yMax)
        for e in endPts { a16u(e) }
        a16u(0)  // instructionLength — we emit no hints

        // Flags: bit 0 = ON_CURVE_POINT. All other bits 0 → long (int16)
        // relative coordinates encoded below.
        for p in allPoints {
            data.append(p.onCurve ? 0x01 : 0x00)
        }

        var prevX: Int16 = 0
        for p in allPoints {
            let delta = Int32(p.x) - Int32(prevX)
            a16s(Int16(clamping: delta))
            prevX = p.x
        }
        var prevY: Int16 = 0
        for p in allPoints {
            let delta = Int32(p.y) - Int32(prevY)
            a16s(Int16(clamping: delta))
            prevY = p.y
        }

        return GlyphRecord(
            data: data,
            xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax,
            numPoints: allPoints.count,
            numContours: normalized.count
        )
    }
}
