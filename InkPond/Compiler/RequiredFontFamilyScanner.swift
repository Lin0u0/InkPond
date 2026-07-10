//
//  RequiredFontFamilyScanner.swift
//  InkPond
//

import Foundation

struct RequiredFontFamilyScanner {
    struct UnresolvedExpression: Equatable, Hashable, Sendable {
        let fileName: String
        let expression: String
    }

    struct ScanResult: Equatable, Sendable {
        let families: [String]
        let unresolvedExpressions: [UnresolvedExpression]
        let hasIncompleteExpressions: Bool
    }

    private enum ParseResult {
        case families([String], String.Index)
        case unresolved(String, String.Index)
        case incomplete
    }

    private static let assignmentRegex = try! NSRegularExpression(pattern: #"font\s*:"#)

    nonisolated init() {}

    func scan(fileContents: [String: String]) -> ScanResult {
        var seenFamilies = Set<String>()
        var families: [String] = []
        var unresolvedExpressions: [UnresolvedExpression] = []
        var hasIncompleteExpressions = false

        for fileName in fileContents.keys.sorted() {
            guard let content = fileContents[fileName] else { continue }
            let ignoredRanges = ignoredSourceRanges(in: content)

            for unresolvedExpression in scanUnresolvedExpressions(
                in: content,
                fileName: fileName,
                ignoredRanges: ignoredRanges,
                seenFamilies: &seenFamilies,
                families: &families
            ) {
                unresolvedExpressions.append(unresolvedExpression)
            }

            hasIncompleteExpressions = hasIncompleteExpressions || contentHasIncompleteExpression(
                content,
                ignoredRanges: ignoredRanges
            )
        }

        return ScanResult(
            families: families,
            unresolvedExpressions: unresolvedExpressions,
            hasIncompleteExpressions: hasIncompleteExpressions
        )
    }

    private func scanUnresolvedExpressions(
        in content: String,
        fileName: String,
        ignoredRanges: [Range<String.Index>],
        seenFamilies: inout Set<String>,
        families: inout [String]
    ) -> [UnresolvedExpression] {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = Self.assignmentRegex.matches(in: content, range: nsRange)
        var unresolved: [UnresolvedExpression] = []

        for match in matches {
            guard let matchRange = Range(match.range, in: content) else { continue }
            guard !isIgnored(matchRange.lowerBound, in: ignoredRanges) else { continue }
            let valueStart = skipWhitespace(in: content, from: matchRange.upperBound)

            switch parseExpression(in: content, from: valueStart) {
            case .families(let literalFamilies, _):
                for family in literalFamilies where seenFamilies.insert(family).inserted {
                    families.append(family)
                }
            case .unresolved(let expression, _):
                unresolved.append(UnresolvedExpression(fileName: fileName, expression: expression))
            case .incomplete:
                continue
            }
        }

        return unresolved
    }

    private func contentHasIncompleteExpression(
        _ content: String,
        ignoredRanges: [Range<String.Index>]
    ) -> Bool {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = Self.assignmentRegex.matches(in: content, range: nsRange)

        for match in matches {
            guard let matchRange = Range(match.range, in: content) else { continue }
            guard !isIgnored(matchRange.lowerBound, in: ignoredRanges) else { continue }
            let valueStart = skipWhitespace(in: content, from: matchRange.upperBound)
            if case .incomplete = parseExpression(in: content, from: valueStart) {
                return true
            }
        }

        return false
    }

    private func ignoredSourceRanges(in content: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = content.startIndex

        while cursor < content.endIndex {
            if content[cursor] == "\"" {
                let end = parseQuotedString(in: content, from: cursor)?.1 ?? content.endIndex
                ranges.append(cursor..<end)
                cursor = end
                continue
            }

            if startsLineComment(in: content, at: cursor) {
                let start = cursor
                cursor = advanceTwoCharacters(in: content, from: cursor)
                while cursor < content.endIndex, content[cursor] != "\n", content[cursor] != "\r" {
                    cursor = content.index(after: cursor)
                }
                ranges.append(start..<cursor)
                continue
            }

            if startsBlockComment(in: content, at: cursor) {
                let start = cursor
                cursor = advanceTwoCharacters(in: content, from: cursor)
                var depth = 1

                while cursor < content.endIndex {
                    if startsBlockComment(in: content, at: cursor) {
                        depth += 1
                        cursor = advanceTwoCharacters(in: content, from: cursor)
                        continue
                    }

                    if endsBlockComment(in: content, at: cursor) {
                        depth -= 1
                        cursor = advanceTwoCharacters(in: content, from: cursor)
                        if depth == 0 { break }
                        continue
                    }

                    cursor = content.index(after: cursor)
                }

                ranges.append(start..<cursor)
                continue
            }

            cursor = content.index(after: cursor)
        }

        return ranges
    }

    private func isIgnored(_ index: String.Index, in ranges: [Range<String.Index>]) -> Bool {
        ranges.contains { $0.contains(index) }
    }

    private func parseExpression(in content: String, from start: String.Index) -> ParseResult {
        guard start < content.endIndex else { return .incomplete }

        switch content[start] {
        case "\"":
            return parseStringLiteral(in: content, from: start)
        case "(":
            return parseTupleLiteral(in: content, from: start)
        default:
            return parseGeneralExpression(in: content, from: start)
        }
    }

    private func parseStringLiteral(in content: String, from start: String.Index) -> ParseResult {
        guard let (literal, nextIndex) = parseQuotedString(in: content, from: start) else {
            return .incomplete
        }
        return .families([literal], nextIndex)
    }

    private func parseTupleLiteral(in content: String, from start: String.Index) -> ParseResult {
        var cursor = content.index(after: start)
        var families: [String] = []

        while true {
            cursor = skipWhitespace(in: content, from: cursor)
            guard cursor < content.endIndex else { return .incomplete }

            if content[cursor] == ")" {
                return .families(families, content.index(after: cursor))
            }

            guard content[cursor] == "\"" else {
                let expression = trimExpression(in: content[start..<cursor])
                return expression.isEmpty
                    ? .incomplete
                    : .unresolved(expression, cursor)
            }

            guard let (literal, nextIndex) = parseQuotedString(in: content, from: cursor) else {
                return .incomplete
            }
            families.append(literal)
            cursor = skipWhitespace(in: content, from: nextIndex)
            guard cursor < content.endIndex else { return .incomplete }

            if content[cursor] == "," {
                cursor = content.index(after: cursor)
                continue
            }

            if content[cursor] == ")" {
                return .families(families, content.index(after: cursor))
            }

            let expression = trimExpression(in: content[start..<cursor])
            return expression.isEmpty
                ? .incomplete
                : .unresolved(expression, cursor)
        }
    }

    private func parseGeneralExpression(in content: String, from start: String.Index) -> ParseResult {
        var cursor = start
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        while cursor < content.endIndex {
            let character = content[cursor]

            if character == "\"" {
                guard let (_, nextIndex) = parseQuotedString(in: content, from: cursor) else {
                    return .incomplete
                }
                cursor = nextIndex
                continue
            }

            switch character {
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    let expression = trimExpression(in: content[start..<cursor])
                    return expression.isEmpty
                        ? .incomplete
                        : .unresolved(expression, cursor)
                }
                parenDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth == 0, parenDepth == 0, braceDepth == 0 {
                    let expression = trimExpression(in: content[start..<cursor])
                    return expression.isEmpty
                        ? .incomplete
                        : .unresolved(expression, cursor)
                }
                bracketDepth -= 1
            case "{":
                braceDepth += 1
            case "}":
                if braceDepth == 0, parenDepth == 0, bracketDepth == 0 {
                    let expression = trimExpression(in: content[start..<cursor])
                    return expression.isEmpty
                        ? .incomplete
                        : .unresolved(expression, cursor)
                }
                braceDepth -= 1
            case ",", "\n", "\r":
                if parenDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    let expression = trimExpression(in: content[start..<cursor])
                    return expression.isEmpty
                        ? .incomplete
                        : .unresolved(expression, cursor)
                }
            default:
                break
            }

            cursor = content.index(after: cursor)
        }

        if parenDepth > 0 || bracketDepth > 0 || braceDepth > 0 {
            return .incomplete
        }

        let expression = trimExpression(in: content[start..<content.endIndex])
        return expression.isEmpty
            ? .incomplete
            : .unresolved(expression, content.endIndex)
    }

    private func parseQuotedString(
        in content: String,
        from start: String.Index
    ) -> (String, String.Index)? {
        var cursor = content.index(after: start)
        var value = ""
        var isEscaped = false

        while cursor < content.endIndex {
            let character = content[cursor]

            if isEscaped {
                value.append(character)
                isEscaped = false
                cursor = content.index(after: cursor)
                continue
            }

            if character == "\\" {
                isEscaped = true
                cursor = content.index(after: cursor)
                continue
            }

            if character == "\"" {
                return (value, content.index(after: cursor))
            }

            value.append(character)
            cursor = content.index(after: cursor)
        }

        return nil
    }

    private func skipWhitespace(in content: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < content.endIndex, content[cursor].isWhitespace {
            cursor = content.index(after: cursor)
        }
        return cursor
    }

    private func startsLineComment(in content: String, at index: String.Index) -> Bool {
        content[index] == "/" && character(after: index, in: content) == "/"
    }

    private func startsBlockComment(in content: String, at index: String.Index) -> Bool {
        content[index] == "/" && character(after: index, in: content) == "*"
    }

    private func endsBlockComment(in content: String, at index: String.Index) -> Bool {
        content[index] == "*" && character(after: index, in: content) == "/"
    }

    private func character(after index: String.Index, in content: String) -> Character? {
        let next = content.index(after: index)
        return next < content.endIndex ? content[next] : nil
    }

    private func advanceTwoCharacters(in content: String, from index: String.Index) -> String.Index {
        content.index(after: content.index(after: index))
    }

    private func trimExpression<S: StringProtocol>(in expression: S) -> String {
        expression.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
