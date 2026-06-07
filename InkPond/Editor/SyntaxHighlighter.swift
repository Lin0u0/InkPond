//
//  SyntaxHighlighter.swift
//  InkPond
//

import UIKit

final class SyntaxHighlighter {
    private var baseFont: UIFont
    private let tokenProvider: (String) -> [TypstSyntaxToken]?
    private var theme: EditorTheme

    private var boldFont: UIFont {
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold)
        return descriptor.map { UIFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
    }

    private var italicFont: UIFont {
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic)
        return descriptor.map { UIFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
    }

    /// Lines (1-based) with compilation errors — set externally.
    var errorLines: Set<Int> = []
    /// Line (1-based) to temporarily emphasize after a sync jump.
    var jumpHighlightLine: Int?
    /// Current emphasis strength for the jump highlight, normalized to 0...1.
    var jumpHighlightOpacity: CGFloat = 0

    init(font: UIFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
         theme: EditorTheme = .system,
         tokenProvider: @escaping (String) -> [TypstSyntaxToken]? = TypstBridge.syntaxHighlightTokens) {
        self.baseFont = font
        self.tokenProvider = tokenProvider
        self.theme = theme
    }

    func updateTheme(_ theme: EditorTheme) {
        self.theme = theme
    }

    func updateFont(_ font: UIFont) {
        baseFont = font
    }

    // MARK: - Highlight

    func highlight(_ textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()

        // Reset to base attributes — clear any previous error underlines too
        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.text,
            .paragraphStyle: EditorFontSettings.paragraphStyle(for: baseFont),
        ], range: fullRange)

        let excludedOffsets: IndexSet
        if let tokens = tokenProvider(textStorage.string) {
            excludedOffsets = applyTypstTokens(tokens, to: textStorage)
        } else {
            excludedOffsets = IndexSet()
        }

        // Rainbow bracket pass (runs last, overrides all)
        applyRainbowBrackets(textStorage, fullRange: fullRange, excludedOffsets: excludedOffsets)

        // Bracket mismatch detection (context-aware)
        applyBracketMismatchUnderlines(textStorage, excludedOffsets: excludedOffsets)

        // Compilation error line underlines
        applyErrorLineUnderlines(textStorage)
        applyJumpLineHighlight(textStorage)

        textStorage.endEditing()
    }

    private func applyTypstTokens(_ tokens: [TypstSyntaxToken], to textStorage: NSTextStorage) -> IndexSet {
        var excludedOffsets = IndexSet()

        for token in tokens {
            let range = NSRange(location: token.location, length: token.length)
            guard range.length > 0,
                  range.location >= 0,
                  NSMaxRange(range) <= textStorage.length else {
                continue
            }

            textStorage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
            switch token.kind {
            case .heading, .keyword, .strong, .listTerm:
                textStorage.addAttribute(.font, value: boldFont, range: range)
            case .comment, .emphasis:
                textStorage.addAttribute(.font, value: italicFont, range: range)
            default:
                break
            }

            if shouldExcludeFromBracketCheck(token.kind) {
                excludedOffsets.insert(integersIn: range.location..<NSMaxRange(range))
            }

            if token.kind == .error {
                textStorage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: UIColor.systemRed,
                    .foregroundColor: UIColor.systemRed,
                ], range: range)
            }
        }

        return excludedOffsets
    }

    private func color(for kind: TypstSyntaxToken.Kind) -> UIColor {
        switch kind {
        case .comment:
            return theme.comment
        case .punctuation:
            return theme.text
        case .escape, .strong, .emphasis, .listMarker, .listTerm:
            return theme.markup
        case .link, .label, .reference:
            return theme.label
        case .raw:
            return theme.code
        case .heading:
            return theme.heading
        case .mathDelimiter, .mathOperator:
            return theme.math
        case .keyword, .operatorToken:
            return theme.keyword
        case .number:
            return theme.number
        case .string:
            return theme.string
        case .function, .interpolated:
            return theme.functionColor
        case .error:
            return UIColor.systemRed
        }
    }

    private func shouldExcludeFromBracketCheck(_ kind: TypstSyntaxToken.Kind) -> Bool {
        switch kind {
        case .comment, .raw, .string:
            return true
        default:
            return false
        }
    }

    // MARK: - Rainbow Brackets

    private func applyRainbowBrackets(
        _ textStorage: NSTextStorage,
        fullRange: NSRange,
        excludedOffsets: IndexSet
    ) {
        let utf16 = textStorage.string.utf16
        let rainbow = theme.rainbow
        let count = rainbow.count
        var depth = 0

        for (i, unit) in utf16.enumerated() {
            guard !excludedOffsets.contains(i) else { continue }
            switch unit {
            case 123, 40, 91:  // { ( [
                let color = rainbow[depth % count]
                textStorage.addAttribute(.foregroundColor, value: color,
                                         range: NSRange(location: i, length: 1))
                depth += 1
            case 125, 41, 93:  // } ) ]
                if depth > 0 { depth -= 1 }
                let color = rainbow[depth % count]
                textStorage.addAttribute(.foregroundColor, value: color,
                                         range: NSRange(location: i, length: 1))
            default:
                break
            }
        }
    }

    // MARK: - Bracket Mismatch Detection

    private func applyBracketMismatchUnderlines(_ textStorage: NSTextStorage, excludedOffsets: IndexSet) {
        let utf16 = textStorage.string.utf16
        // Stack stores (opening bracket UTF-16 unit, offset)
        var stack: [(UInt16, Int)] = []
        let errorAttrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .underlineColor: UIColor.systemRed,
            .foregroundColor: UIColor.systemRed,
        ]

        for (i, unit) in utf16.enumerated() {
            guard !excludedOffsets.contains(i) else { continue }
            switch unit {
            case 123, 40, 91:  // { ( [
                stack.append((unit, i))
            case 125, 41, 93:  // } ) ]
                let expected: UInt16 = unit == 125 ? 123 : (unit == 41 ? 40 : 91)
                if let last = stack.last, last.0 == expected {
                    stack.removeLast()
                } else {
                    // Unmatched closing bracket
                    textStorage.addAttributes(errorAttrs, range: NSRange(location: i, length: 1))
                }
            default:
                break
            }
        }

        // Remaining are unmatched opening brackets
        for (_, offset) in stack {
            textStorage.addAttributes(errorAttrs, range: NSRange(location: offset, length: 1))
        }
    }

    // MARK: - Compilation Error Line Underlines

    private func applyErrorLineUnderlines(_ textStorage: NSTextStorage) {
        guard !errorLines.isEmpty else { return }
        let errorUnderline: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: UIColor.systemRed,
            .backgroundColor: errorHighlightColor,
        ]

        enumerateLines(in: textStorage, targeting: errorLines) { info in
            if info.trimmedRange.length > 0 {
                textStorage.addAttributes(errorUnderline, range: info.trimmedRange)
            }
        }
    }

    private func applyJumpLineHighlight(_ textStorage: NSTextStorage) {
        guard let jumpHighlightLine, jumpHighlightOpacity > 0 else { return }

        enumerateLines(in: textStorage, targeting: [jumpHighlightLine]) { info in
            if info.range.length > 0 {
                textStorage.addAttribute(
                    .backgroundColor,
                    value: jumpHighlightColor(opacity: jumpHighlightOpacity),
                    range: info.range
                )
            }
        }
    }

    func refreshJumpHighlight(
        in textStorage: NSTextStorage,
        previousLine: Int?,
        line: Int?,
        opacity: CGFloat
    ) {
        let clampedOpacity = max(0, min(opacity, 1))
        let affectedLines = Set([previousLine, line].compactMap { $0 })
        jumpHighlightLine = line
        jumpHighlightOpacity = clampedOpacity

        guard !affectedLines.isEmpty else { return }

        textStorage.beginEditing()

        enumerateLines(in: textStorage, targeting: affectedLines) { info in
            if info.range.length > 0 {
                textStorage.removeAttribute(.backgroundColor, range: info.range)
            }
            if errorLines.contains(info.lineNumber), info.trimmedRange.length > 0 {
                textStorage.addAttribute(
                    .backgroundColor,
                    value: errorHighlightColor,
                    range: info.trimmedRange
                )
            }
            if info.lineNumber == line,
               clampedOpacity > 0,
               info.range.length > 0 {
                textStorage.addAttribute(
                    .backgroundColor,
                    value: jumpHighlightColor(opacity: clampedOpacity),
                    range: info.range
                )
            }
        }

        textStorage.endEditing()
    }

    private var errorHighlightColor: UIColor {
        UIColor.systemRed.withAlphaComponent(0.08)
    }

    private func jumpHighlightColor(opacity: CGFloat) -> UIColor {
        theme.label.withAlphaComponent(0.14 * opacity)
    }

    /// Iterate lines of `textStorage` using `NSString.lineRange`,
    /// calling `body` only for lines whose 1-based number is in `targetLines`.
    /// Stops early once all target lines have been visited.
    private func enumerateLines(
        in textStorage: NSTextStorage,
        targeting targetLines: Set<Int>,
        body: (LineInfo) -> Void
    ) {
        let nsText = textStorage.string as NSString
        let length = nsText.length
        var index = 0
        var lineNumber = 1
        var remaining = targetLines

        while index <= length, !remaining.isEmpty {
            let lineRange: NSRange
            if index < length {
                lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
            } else {
                // Handle trailing newline (empty last line)
                lineRange = NSRange(location: index, length: 0)
            }
            // Exclude the line terminator from the content range
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  contentEnd - 1 < length,
                  nsText.character(at: contentEnd - 1) == 10 /* \n */ || nsText.character(at: contentEnd - 1) == 13 /* \r */ {
                contentEnd -= 1
            }
            let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)

            if remaining.contains(lineNumber) {
                let firstNonWS = nsText.rangeOfCharacter(
                    from: CharacterSet.whitespaces.inverted,
                    range: contentRange
                ).location
                let trimmedStart = firstNonWS == NSNotFound ? contentRange.length : firstNonWS - contentRange.location

                body(LineInfo(
                    lineNumber: lineNumber,
                    range: contentRange,
                    trimmedRange: NSRange(
                        location: contentRange.location + trimmedStart,
                        length: max(0, contentRange.length - trimmedStart)
                    )
                ))
                remaining.remove(lineNumber)
            }

            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= index { break }
            index = nextIndex
            lineNumber += 1
        }
    }

    private struct LineInfo {
        let lineNumber: Int
        let range: NSRange
        let trimmedRange: NSRange
    }
}
