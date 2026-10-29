import CoreGraphics
import Foundation

/// Pure geometry in the accessory's coordinate space. Regions are already expanded
/// by their asymmetric margins. Solve from the native bottom, not current overlap.
enum KeyboardAccessoryGeometry {
    struct Solution: Equatable {
        let padding: CGFloat
        let span: CGRect
    }

    static func solve(width: CGFloat, bottom: CGFloat, regions: [CGRect], scale: CGFloat, availableTop: CGFloat = -.greatestFiniteMagnitude) -> Solution? {
        guard width.isFinite, width >= 44, bottom.isFinite, scale.isFinite, scale > 0,
              regions.allSatisfy({ !$0.isNull && !$0.isInfinite && $0.minX.isFinite &&
                  $0.minY.isFinite && $0.width > 0 && $0.height > 0 }) else { return nil }
        let baselineTop = bottom - 60 + 8
        let baselineBottom = bottom - 60 + 52
        // Evaluate all contiguous spans delimited by protected edges; no pose or
        // orientation classification. Prefer the widest span, then least movement.
        let edges = ([CGFloat(0), width] + regions.flatMap { [$0.minX - 1, $0.maxX + 1] })
            .filter { $0 >= 0 && $0 <= width }.sorted()
        var best: Solution?
        for left in edges {
            for right in edges where right - left >= 44 {
                var padding: CGFloat = 0
                for _ in 0...regions.count {
                    let oldPadding = padding
                    for region in regions where region.maxX > left && region.minX < right {
                        if region.minY < baselineBottom - padding + 1 && region.maxY > baselineTop - padding - 1 {
                            padding = max(padding, baselineBottom - region.minY + 1)
                        }
                    }
                    padding = ceil(max(0, padding) * scale) / scale
                    if oldPadding == padding { break }
                }
                // Moving above a full-height region is not a usable accessory.
                // Require the visual bar to remain within the owning coordinate extent.
                guard baselineTop - padding >= availableTop else { continue }
                let candidate = Solution(padding: padding,
                    span: CGRect(x: left, y: 0, width: right - left, height: 60))
                if best == nil || candidate.padding < best!.padding ||
                    (candidate.padding == best!.padding && candidate.span.width > best!.span.width) {
                    best = candidate
                }
            }
        }
        return best
    }
}
