//
//  SourceMap.swift
//  InkPond
//
//  Bidirectional mapping between editor source locations and PDF positions.
//

import Foundation

nonisolated struct SourceMapLocation: Sendable, Equatable, Codable {
    let page: Int
    let yPoints: Float
    let xPoints: Float
    let line: Int      // 1-based
    let column: Int    // 1-based
    let sourceOffset: Int
    let sourceLength: Int
}

nonisolated struct SourceMap: Sendable, Equatable, Codable {
    /// Entries sorted by source offset (for editor -> preview lookup).
    let byOffset: [SourceMapLocation]
    /// Entries sorted by (page, yPoints) (for preview -> editor lookup).
    let byPosition: [SourceMapLocation]

    var isEmpty: Bool { byOffset.isEmpty }

    /// Find the PDF position for a given 1-based line number.
    /// Returns the closest entry at or before the given line.
    func pdfPosition(forLine line: Int) -> SourceMapLocation? {
        guard !byOffset.isEmpty else { return nil }

        // Binary search for the first entry with line >= target.
        var lo = 0
        var hi = byOffset.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if byOffset[mid].line < line {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // If exact match, pick the entry with the largest Y among all entries
        // on the same line.  When a heading appears both in a navigation bar
        // (small Y at page top) and in the body (larger Y), this selects the
        // body occurrence.  For normal wrapped text on the same page, entries
        // have close Y values so the choice is inconsequential.
        if lo < byOffset.count && byOffset[lo].line == line {
            var best = byOffset[lo]
            var i = lo + 1
            while i < byOffset.count && byOffset[i].line == line {
                let candidate = byOffset[i]
                if candidate.yPoints > best.yPoints {
                    best = candidate
                }
                i += 1
            }
            return best
        } else if lo > 0 {
            return byOffset[lo - 1]
        }
        return byOffset.first
    }

    /// Find the source location for a tap at a given page and Y position.
    /// Returns the closest entry at or before the given Y on that page.
    func sourceLocation(forPage page: Int, yPoints: Float) -> SourceMapLocation? {
        guard !byPosition.isEmpty else { return nil }

        // Find entries on the target page.
        var lo = 0
        var hi = byPosition.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if byPosition[mid].page < page {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let pageStart = lo
        lo = pageStart
        hi = byPosition.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if byPosition[mid].page <= page {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let pageEnd = lo

        guard pageStart < pageEnd else { return nil }

        // Within this page's entries, find the closest entry at or before the tap.
        lo = pageStart
        hi = pageEnd
        while lo < hi {
            let mid = (lo + hi) / 2
            if byPosition[mid].yPoints < yPoints {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        if lo < pageEnd, byPosition[lo].yPoints == yPoints {
            return byPosition[lo]
        } else if lo > pageStart {
            return byPosition[lo - 1]
        }
        return byPosition[pageStart]
    }
}
