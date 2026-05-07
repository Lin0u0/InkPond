//
//  LineNumberGutterView.swift
//  InkPond
//

import UIKit

final class LineNumberGutterView: UIView {

    private static let minGutterWidth: CGFloat = 36

    private weak var textView: UITextView?
    private var gutterBgColor: UIColor = .secondarySystemBackground
    private var gutterFgColor: UIColor = .secondaryLabel
    private var gutterFont = EditorFontSettings.lineNumberFont(for: EditorFontSettings.defaultUIFont)
    private var lineStartOffsets: [Int] = [0]
    private var cachedGutterWidth: CGFloat = LineNumberGutterView.minGutterWidth
    private var needsLineMetricsRefresh = true
    var jumpHighlightLine: Int?
    var jumpHighlightOpacity: CGFloat = 0

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    func applyTheme(_ theme: EditorTheme) {
        gutterBgColor = theme.gutterBackground
        gutterFgColor = theme.gutterForeground
        setNeedsDisplay()
    }

    func applyEditorFont(_ font: UIFont) {
        let nextGutterFont = EditorFontSettings.lineNumberFont(for: font)
        guard abs(nextGutterFont.pointSize - gutterFont.pointSize) > 0.1 else { return }
        gutterFont = nextGutterFont
        needsLineMetricsRefresh = true
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textDidChange() {
        needsLineMetricsRefresh = true
        setNeedsDisplay()
    }

    func setJumpHighlight(line: Int?, opacity: CGFloat) {
        let clampedOpacity = max(0, min(opacity, 1))
        guard jumpHighlightLine != line || abs(jumpHighlightOpacity - clampedOpacity) > 0.001 else {
            return
        }
        jumpHighlightLine = line
        jumpHighlightOpacity = clampedOpacity
        setNeedsDisplay()
    }

    var gutterWidth: CGFloat {
        refreshLineMetricsIfNeeded()
        return cachedGutterWidth
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        refreshLineMetricsIfNeeded()

        // Resolve dynamic UIColors against the current trait collection before converting to CGColor.
        let resolvedBg = gutterBgColor.resolvedColor(with: traitCollection)
        let resolvedFg = gutterFgColor.resolvedColor(with: traitCollection)
        let jumpAccent = UIColor.systemBlue.resolvedColor(with: traitCollection)
        let highlightOpacity = max(0, min(jumpHighlightOpacity, 1))
        let jumpFill = jumpAccent.withAlphaComponent(0.14 * highlightOpacity)
        let jumpStroke = jumpAccent.withAlphaComponent(0.8 * highlightOpacity)
        let highlightedNumberColor = blendedColor(from: resolvedFg, to: jumpAccent, progress: highlightOpacity)

        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(resolvedBg.cgColor)
        context?.fill(CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: resolvedFg,
        ]

        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.bounds, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let nsString = textView.text as NSString
        let firstVisibleLineIndex = lineIndex(forCharacterOffset: visibleCharRange.location)
        var lineIndex = firstVisibleLineIndex
        let visibleEnd = NSMaxRange(visibleCharRange)

        func caretRectForOffset(_ offset: Int) -> CGRect? {
            let clampedOffset = min(max(offset, 0), nsString.length)
            guard let position = textView.position(from: textView.beginningOfDocument, offset: clampedOffset) else {
                return nil
            }
            return textView.caretRect(for: position)
        }

        while lineIndex < lineStartOffsets.count {
            let offset = lineStartOffsets[lineIndex]
            if offset > visibleEnd && lineIndex != firstVisibleLineIndex {
                break
            }

            guard let startCaretRect = caretRectForOffset(offset) else {
                break
            }

            if jumpHighlightLine == lineIndex + 1, highlightOpacity > 0 {
                let highlightRect = CGRect(
                    x: 4,
                    y: startCaretRect.minY + 1,
                    width: gutterWidth - 8,
                    height: max(startCaretRect.height - 2, gutterFont.lineHeight + 2)
                )
                let path = UIBezierPath(roundedRect: highlightRect, cornerRadius: 8)
                jumpFill.setFill()
                path.fill()

                let markerRect = CGRect(
                    x: 6,
                    y: highlightRect.minY + 2,
                    width: 3,
                    height: highlightRect.height - 4
                )
                let markerPath = UIBezierPath(roundedRect: markerRect, cornerRadius: 1.5)
                jumpStroke.setFill()
                markerPath.fill()
            }

            let numberString = "\(lineIndex + 1)" as NSString
            let effectiveAttributes: [NSAttributedString.Key: Any] = jumpHighlightLine == lineIndex + 1
                ? [
                    .font: gutterFont,
                    .foregroundColor: highlightedNumberColor,
                ]
                : attributes
            let stringSize = numberString.size(withAttributes: effectiveAttributes)
            let drawPoint = CGPoint(
                x: gutterWidth - stringSize.width - 8,
                y: startCaretRect.minY + (max(startCaretRect.height, gutterFont.lineHeight) - stringSize.height) / 2
            )
            numberString.draw(at: drawPoint, withAttributes: effectiveAttributes)

            lineIndex += 1
        }
    }

    private func refreshLineMetricsIfNeeded() {
        guard needsLineMetricsRefresh, let textView else { return }

        let nsString = textView.text as NSString
        let length = nsString.length
        var starts = [0]
        var index = 0

        while index < length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex < length {
                starts.append(nextIndex)
            } else if nextIndex == length, length > 0, nsString.character(at: length - 1) == 10 {
                starts.append(length)
            }

            guard nextIndex > index else { break }
            index = nextIndex
        }

        lineStartOffsets = starts

        let digits = String(max(starts.count, 1)).count
        let sampleString = String(repeating: "8", count: max(digits, 2)) as NSString
        let size = sampleString.size(withAttributes: [.font: gutterFont])
        cachedGutterWidth = max(ceil(size.width) + 16, Self.minGutterWidth)
        needsLineMetricsRefresh = false
    }

    private func lineIndex(forCharacterOffset offset: Int) -> Int {
        guard !lineStartOffsets.isEmpty else { return 0 }

        var lowerBound = 0
        var upperBound = lineStartOffsets.count

        while lowerBound < upperBound {
            let mid = (lowerBound + upperBound) / 2
            if lineStartOffsets[mid] <= offset {
                lowerBound = mid + 1
            } else {
                upperBound = mid
            }
        }

        return max(0, lowerBound - 1)
    }

    private func blendedColor(from source: UIColor, to target: UIColor, progress: CGFloat) -> UIColor {
        let clampedProgress = max(0, min(progress, 1))
        var sourceRed: CGFloat = 0
        var sourceGreen: CGFloat = 0
        var sourceBlue: CGFloat = 0
        var sourceAlpha: CGFloat = 0
        var targetRed: CGFloat = 0
        var targetGreen: CGFloat = 0
        var targetBlue: CGFloat = 0
        var targetAlpha: CGFloat = 0

        guard source.getRed(&sourceRed, green: &sourceGreen, blue: &sourceBlue, alpha: &sourceAlpha),
              target.getRed(&targetRed, green: &targetGreen, blue: &targetBlue, alpha: &targetAlpha) else {
            return target.withAlphaComponent(clampedProgress)
        }

        return UIColor(
            red: sourceRed + (targetRed - sourceRed) * clampedProgress,
            green: sourceGreen + (targetGreen - sourceGreen) * clampedProgress,
            blue: sourceBlue + (targetBlue - sourceBlue) * clampedProgress,
            alpha: sourceAlpha + (targetAlpha - sourceAlpha) * clampedProgress
        )
    }
}
