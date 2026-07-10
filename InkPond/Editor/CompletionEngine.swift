//
//  CompletionEngine.swift
//  InkPond
//

import UIKit

struct CompletionItem {
    let label: String
    let insertText: String?
    let kind: Kind
    let detail: String?

    enum Kind {
        case keyword
        case function
        case snippet
        case parameter
        case value
        case reference
    }

    var isInsertable: Bool {
        insertText != nil
    }
}

final class CompletionEngine {
    static let shared = CompletionEngine()

    private var cachedSymbolSource: String?
    private var cachedSymbols: [TypstCompletionSymbolInfo] = []

    /// Result type that distinguishes `#function` completions from parameter completions.
    enum CompletionContext {
        /// Completing after `#` — prefix includes the `#`.
        case hashPrefix(prefix: String, items: [CompletionItem])
        /// Completing a parameter name inside `funcname(...)` — prefix is the partial param name typed.
        case parameter(prefix: String, items: [CompletionItem])
        /// Completing a parameter value after `paramName:` — prefix is the partial value typed (without quotes).
        case value(prefix: String, isQuoted: Bool, items: [CompletionItem])
        /// Completing after `@` — cross-references and citations.
        case atPrefix(prefix: String, items: [CompletionItem])
        /// Completing inside `<>` for `#cite(<>)` or `#ref(<>)`.
        case angleBracket(prefix: String, items: [CompletionItem])
    }

    // MARK: - Dynamic Data (set from outside)

    /// Available font family names for value completion.
    var fontFamilies: [String] = []

    /// Bibliography citation keys parsed by Hayagriva.
    var bibEntries: [TypstBibliographyEntry] = []

    /// Labels defined in other project files (not the current editor text).
    var externalLabels: [(name: String, kind: String)] = []

    /// Image file paths relative to the project root, for path completion inside `image("")`.
    var imageFiles: [String] = []

    /// Available package specs for import completion (e.g. "@local/mypackage:1.0.0").
    var packageSpecs: [String] = []

    // MARK: - Public API

    /// Returns completion context for the given cursor position, or nil if none.
    func completions(for text: String, cursorOffset: Int) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset > 0, cursorOffset <= utf16.count else { return nil }
        var semanticSymbols: [TypstCompletionSymbolInfo]?
        let symbolsProvider = {
            if let semanticSymbols {
                return semanticSymbols
            }
            let loaded = self.symbols(for: text)
            semanticSymbols = loaded
            return loaded
        }

        // Try import/package completion (inside `#import "@..."`)
        if let importResult = importCompletions(for: text, cursorOffset: cursorOffset) {
            return importResult
        }

        // Try image/file path completion (inside `image("...")` etc.)
        if let pathResult = pathCompletions(for: text, cursorOffset: cursorOffset) {
            return pathResult
        }

        // Try value completion first (highest priority when after `param:`)
        if let valueResult = valueCompletions(for: text, cursorOffset: cursorOffset, symbols: symbolsProvider) {
            return valueResult
        }

        // Try parameter completion (when inside parens)
        if let paramResult = parameterCompletions(for: text, cursorOffset: cursorOffset, symbols: symbolsProvider) {
            return paramResult
        }

        // Try `@` reference completion
        if let refResult = referenceCompletions(for: text, cursorOffset: cursorOffset) {
            return refResult
        }

        // Try `<>` angle-bracket completion inside cite()/ref()
        if let abResult = angleBracketCompletions(for: text, cursorOffset: cursorOffset) {
            return abResult
        }

        // Finally try `#` symbol completion.
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        var start = cursorIndex
        while start > utf16.startIndex {
            let prev = utf16.index(before: start)
            let ch = text[prev]
            if ch == "#" {
                let prefix = String(text[prev..<cursorIndex])
                let query = String(prefix.dropFirst())
                let hashItems = completionItems(from: symbolsProvider(), cursorOffset: cursorOffset)
                let filtered = query.isEmpty ? hashItems : hashItems.filter { $0.label.hasPrefix(query) }
                guard !filtered.isEmpty else { return nil }
                if filtered.count == 1, filtered[0].label == query { return nil }
                return .hashPrefix(prefix: prefix, items: filtered)
            } else if ch.isLetter || ch == "_" || ch == "-" || ch.isNumber || ch == "." {
                start = prev
                continue
            } else {
                break
            }
        }
        return nil
    }

    private func symbols(for text: String) -> [TypstCompletionSymbolInfo] {
        if cachedSymbolSource == text {
            return cachedSymbols
        }

        let symbols = TypstBridge.completionSymbols(source: text) ?? []
        cachedSymbolSource = text
        cachedSymbols = symbols
        return symbols
    }

    private func completionItems(from symbols: [TypstCompletionSymbolInfo], cursorOffset: Int) -> [CompletionItem] {
        symbols.compactMap { symbol in
            if let location = symbol.utf16Location, location > cursorOffset {
                return nil
            }
            if let scopeEnd = symbol.utf16ScopeEnd, cursorOffset > scopeEnd {
                return nil
            }

            let kind: CompletionItem.Kind
            switch symbol.kind {
            case .keyword:
                kind = .keyword
            case .function:
                kind = .function
            case .local, .value, .type, .module:
                kind = .value
            }

            return CompletionItem(
                label: symbol.name,
                insertText: insertText(for: symbol),
                kind: kind,
                detail: symbol.detail
            )
        }
    }

    private func insertText(for symbol: TypstCompletionSymbolInfo) -> String? {
        switch symbol.kind {
        case .keyword:
            return keywordInsertText(symbol.name)
        case .function:
            return functionInsertText(symbol)
        case .local, .value, .type, .module:
            return symbol.name
        }
    }

    private func keywordInsertText(_ keyword: String) -> String {
        switch keyword {
        case "return", "break", "continue":
            return keyword
        default:
            return keyword + " "
        }
    }

    private func functionInsertText(_ symbol: TypstCompletionSymbolInfo) -> String {
        let params = symbol.params
        guard !params.isEmpty else { return symbol.name + "()" }

        let bodyParam = params.first { param in
            param.positional && (param.name == "body" || param.input?.localizedCaseInsensitiveContains("content") == true)
        }
        let hasNonBodyParams = params.contains { param in
            param.name != bodyParam?.name && (param.named || param.positional)
        }

        if bodyParam != nil {
            return hasNonBodyParams ? "\(symbol.name)()[]" : "\(symbol.name)[]"
        }

        if let first = params.first,
           first.positional,
           first.input?.localizedCaseInsensitiveContains("label") == true {
            return "\(symbol.name)(<>)"
        }

        return symbol.name + "()"
    }

    private func functionSymbol(named rawName: String, in symbols: [TypstCompletionSymbolInfo]) -> TypstCompletionSymbolInfo? {
        let functions = symbols.filter { $0.kind == .function }
        if let exact = functions.first(where: { $0.name == rawName }) {
            return exact
        }

        if let baseName = rawName.split(separator: ".").first,
           let base = functions.first(where: { $0.name == String(baseName) }) {
            return base
        }

        return nil
    }

    private func parameterDetail(_ param: TypstCompletionParamInfo) -> String? {
        var parts: [String] = []
        if let docs = param.docs { parts.append(docs) }
        if let input = param.input { parts.append(input) }
        if let defaultValue = param.defaultValue { parts.append("default: \(defaultValue)") }
        if param.required { parts.append("required") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func enclosingFunctionName(in text: String, beforeOffset cursorOffset: Int) -> String? {
        TypstBridge.contextAt(source: text, utf16Offset: cursorOffset)?.functionName
    }

    // MARK: - Import / Package Completion

    /// Detects `#import "@partial` or `#import "@local/partial` and suggests package specs.
    private func importCompletions(for text: String, cursorOffset: Int) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset > 0, cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Walk backwards from cursor to find the opening `"`
        var probe = cursorIndex
        var quotePos: String.Index?
        while probe > utf16.startIndex {
            let prev = utf16.index(before: probe)
            let ch = text[prev]
            if ch == "\"" {
                quotePos = prev
                break
            }
            if ch == "\n" || ch == "\r" { return nil }
            probe = prev
        }
        guard let openQuote = quotePos else { return nil }

        let valueStart = utf16.index(after: openQuote)
        let typed = String(text[valueStart..<cursorIndex])

        // Must start with `@` to be a package import
        guard typed.hasPrefix("@") else { return nil }

        // Verify this is an import/include context: walk backwards from `"` past whitespace
        // and check for `import` or `include` keyword
        var scan = openQuote
        while scan > utf16.startIndex {
            let prev = utf16.index(before: scan)
            let ch = text[prev]
            if ch == " " || ch == "\t" { scan = prev; continue }
            break
        }

        // Collect the keyword before the quote
        let kwEnd = scan
        var kwStart = kwEnd
        while kwStart > utf16.startIndex {
            let prev = utf16.index(before: kwStart)
            let c = text[prev]
            if c.isLetter || c == "#" { kwStart = prev } else { break }
        }
        let keyword = String(text[kwStart..<kwEnd]).replacingOccurrences(of: "#", with: "")
        guard keyword == "import" || keyword == "include" else { return nil }

        guard !packageSpecs.isEmpty else { return nil }

        let query = typed.lowercased()
        let filtered = packageSpecs.filter { spec in
            spec.lowercased().hasPrefix(query) || spec.lowercased().contains(query.dropFirst()) // drop @
        }

        guard !filtered.isEmpty else { return nil }
        if filtered.count == 1, filtered[0] == typed { return nil }

        let items = filtered.map { spec in
            CompletionItem(label: spec, insertText: spec, kind: .value, detail: L10n.tr("Package"))
        }
        return .value(prefix: typed, isQuoted: true, items: items)
    }

    // MARK: - Path Completion (image/include/import)

    /// Functions whose first positional string argument is a file path.
    private static let pathFunctions: Set<String> = ["image", "figure", "bibliography", "csv", "json", "toml", "yaml", "xml", "read"]

    /// Detects cursor inside a quoted string that is a positional or `source:`/`path:` argument
    /// of a path-accepting function, and suggests matching project files.
    private func pathCompletions(for text: String, cursorOffset: Int) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset > 0, cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Walk backwards from cursor to find the opening `"`
        var probe = cursorIndex
        var quotePos: String.Index?
        while probe > utf16.startIndex {
            let prev = utf16.index(before: probe)
            let ch = text[prev]
            if ch == "\"" {
                quotePos = prev
                break
            }
            // Stop at newline or closing quote (means we're not inside a string)
            if ch == "\n" || ch == "\r" { return nil }
            probe = prev
        }
        guard let openQuote = quotePos else { return nil }

        // The typed path so far (between opening `"` and cursor)
        let valueStart = utf16.index(after: openQuote)
        let typedPath = String(text[valueStart..<cursorIndex])

        // From the `"`, determine context: is this inside a path-accepting function?
        // Walk backwards from `"` skipping whitespace to check what precedes it.
        var scan = openQuote
        while scan > utf16.startIndex {
            let prev = utf16.index(before: scan)
            let ch = text[prev]
            if ch == " " || ch == "\t" { scan = prev; continue }
            break
        }

        // Check for `paramName: "` pattern — accept `source:` or `path:`
        var isNamedPathParam = false
        if scan > utf16.startIndex {
            let charBefore = text[utf16.index(before: scan)]
            if charBefore == ":" {
                // Extract param name before `:`
                let colonPos = utf16.index(before: scan)
                var paramEnd = colonPos
                while paramEnd > utf16.startIndex {
                    let prev = utf16.index(before: paramEnd)
                    if text[prev] == " " || text[prev] == "\t" { paramEnd = prev } else { break }
                }
                var paramStart = paramEnd
                while paramStart > utf16.startIndex {
                    let prev = utf16.index(before: paramStart)
                    let c = text[prev]
                    if c.isLetter || c == "-" || c == "_" || c.isNumber { paramStart = prev } else { break }
                }
                if paramStart < paramEnd {
                    let paramName = String(text[paramStart..<paramEnd])
                    if paramName == "source" || paramName == "path" {
                        isNamedPathParam = true
                    }
                }
            }
        }

        // Check for positional argument: `("`  or  `, "`
        var isPositional = false
        if !isNamedPathParam, scan > utf16.startIndex {
            let charBefore = text[utf16.index(before: scan)]
            if charBefore == "(" || charBefore == "," {
                isPositional = true
            }
        }

        guard isNamedPathParam || isPositional else { return nil }

        // Determine the enclosing function name
        guard let funcName = enclosingFunctionName(in: text, beforeOffset: cursorOffset),
              Self.pathFunctions.contains(funcName) else { return nil }

        // Select candidate files based on function
        let candidates: [CompletionItem]
        if funcName == "image" || funcName == "figure" {
            candidates = imageFiles.map {
                CompletionItem(label: $0, insertText: $0, kind: .value, detail: L10n.tr("Image"))
            }
        } else {
            // For bibliography, csv, json, etc. — no candidates yet (can be extended)
            return nil
        }

        guard !candidates.isEmpty else { return nil }

        let filtered: [CompletionItem]
        if typedPath.isEmpty {
            filtered = candidates
        } else {
            let lowerTyped = typedPath.lowercased()
            filtered = candidates.filter { item in
                let path = item.label.lowercased()
                // Path prefix match: "images/p" matches "images/photo.png"
                if path.hasPrefix(lowerTyped) { return true }
                // No slash typed → also match against filename: "photo" matches "images/photo.png"
                if !lowerTyped.contains("/") {
                    let fileName = (item.label as NSString).lastPathComponent.lowercased()
                    if fileName.contains(lowerTyped) { return true }
                }
                return false
            }
        }

        guard !filtered.isEmpty else { return nil }
        if filtered.count == 1, filtered[0].label == typedPath { return nil }

        return .value(prefix: typedPath, isQuoted: true, items: filtered)
    }

    // MARK: - Parameter Completion

    private func parameterCompletions(
        for text: String,
        cursorOffset: Int,
        symbols: () -> [TypstCompletionSymbolInfo]
    ) -> CompletionContext? {
        // Walk backwards from cursor to determine if we're at a parameter-name position
        // i.e., right after `(` or `,` with optional whitespace, possibly with a partial name typed.
        let utf16 = text.utf16
        guard cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Collect the partial word being typed (letters, digits, hyphens)
        var wordStart = cursorIndex
        while wordStart > utf16.startIndex {
            let prev = utf16.index(before: wordStart)
            let ch = text[prev]
            if ch.isLetter || ch == "-" || ch == "_" || ch.isNumber {
                wordStart = prev
            } else {
                break
            }
        }
        let typedPrefix = String(text[wordStart..<cursorIndex])

        // From wordStart, skip whitespace backwards to find `(` or `,`
        var scan = wordStart
        while scan > utf16.startIndex {
            let prev = utf16.index(before: scan)
            let ch = text[prev]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                scan = prev
            } else {
                break
            }
        }
        guard scan > utf16.startIndex else { return nil }
        let trigger = text[utf16.index(before: scan)]
        guard trigger == "(" || trigger == "," else { return nil }

        // Check we're not after `:` (typing a value, not a param name)
        // Walk backwards from wordStart skipping whitespace — if we hit `:` before `(` or `,`, bail
        var valCheck = wordStart
        while valCheck > utf16.startIndex {
            let prev = utf16.index(before: valCheck)
            let ch = text[prev]
            if ch == " " || ch == "\t" { valCheck = prev; continue }
            if ch == ":" { return nil } // we're in value position
            break
        }

        // Find the function name: walk backwards from the unmatched `(` to get the identifier
        let funcName = enclosingFunctionName(in: text, beforeOffset: cursorOffset)
        guard let funcName,
              let function = functionSymbol(named: funcName, in: symbols()) else { return nil }

        // Collect already-used parameter names in this call
        let usedParams = findUsedParameters(in: text, cursorOffset: cursorOffset)

        let paramItems: [CompletionItem] = function.params.compactMap { param in
            guard !usedParams.contains(param.name) else { return nil }
            if !typedPrefix.isEmpty, !param.name.hasPrefix(typedPrefix) { return nil }
            let insertText = param.named ? param.name + ": " : nil
            return CompletionItem(label: param.name, insertText: insertText, kind: .parameter, detail: parameterDetail(param))
        }

        let valueItems = function.params
            .filter(\.positional)
            .flatMap(\.values)
            .compactMap { value -> CompletionItem? in
                if !typedPrefix.isEmpty, !value.label.localizedCaseInsensitiveContains(typedPrefix) { return nil }
                return CompletionItem(label: value.label, insertText: value.insertText, kind: .value, detail: value.detail)
        }

        let allItems = valueItems + paramItems
        guard !allItems.isEmpty else { return nil }
        if allItems.count == 1, allItems[0].label == typedPrefix { return nil }
        return .parameter(prefix: typedPrefix, items: allItems)
    }

    /// Collect parameter names already used in the current function call.
    private func findUsedParameters(in text: String, cursorOffset: Int) -> Set<String> {
        let utf16 = text.utf16
        let limit = utf16.index(utf16.startIndex, offsetBy: min(cursorOffset, utf16.count))
        var depth = 0
        var pos = limit
        var openParenPos: String.Index?

        // Find the unmatched `(`
        while pos > utf16.startIndex {
            pos = utf16.index(before: pos)
            let ch = text[pos]
            if ch == ")" { depth += 1 }
            else if ch == "(" {
                if depth == 0 { openParenPos = utf16.index(after: pos); break }
                depth -= 1
            }
        }
        guard let start = openParenPos else { return [] }

        // Scan forward from `(` to cursor, collecting `name:` patterns at depth 0
        var used = Set<String>()
        var scanDepth = 0
        var i = start
        while i < limit {
            let ch = text[i]
            if ch == "(" || ch == "[" { scanDepth += 1 }
            else if ch == ")" || ch == "]" { scanDepth -= 1 }
            else if ch == ":" && scanDepth == 0 {
                // Walk backwards from `:` to get the name
                var nameEnd = i
                // skip whitespace before `:`
                while nameEnd > start {
                    let prev = utf16.index(before: nameEnd)
                    if text[prev] == " " || text[prev] == "\t" { nameEnd = prev } else { break }
                }
                var nameStart = nameEnd
                while nameStart > start {
                    let prev = utf16.index(before: nameStart)
                    let c = text[prev]
                    if c.isLetter || c == "-" || c == "_" || c.isNumber { nameStart = prev } else { break }
                }
                if nameStart < nameEnd {
                    used.insert(String(text[nameStart..<nameEnd]))
                }
            }
            i = utf16.index(after: i)
        }
        return used
    }

    // MARK: - Value Completion

    private func valueCompletions(
        for text: String,
        cursorOffset: Int,
        symbols: () -> [TypstCompletionSymbolInfo]
    ) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset > 0, cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Try to detect if we're in a value position: after `paramName:` with optional whitespace and quote.
        // Case 1: Inside quotes — `param: "partial`
        // Case 2: Unquoted — `param: partial`

        var isQuoted = false
        var valueStart = cursorIndex
        var scanFrom = cursorIndex

        // Walk backwards to find opening `"` or a delimiter
        var probe = cursorIndex
        while probe > utf16.startIndex {
            let prev = utf16.index(before: probe)
            let ch = text[prev]
            if ch == "\"" {
                isQuoted = true
                valueStart = probe   // first char after the quote
                scanFrom = prev      // the quote itself
                break
            } else if ch == ":" || ch == "(" || ch == "," || ch == ")" || ch == "\n" {
                break
            }
            probe = prev
        }

        if !isQuoted {
            // Collect identifier chars for unquoted value
            valueStart = cursorIndex
            while valueStart > utf16.startIndex {
                let prev = utf16.index(before: valueStart)
                let ch = text[prev]
                if ch.isLetter || ch == "-" || ch == "_" || ch.isNumber {
                    valueStart = prev
                } else {
                    break
                }
            }
            scanFrom = valueStart
        }

        let typedValue = String(text[valueStart..<cursorIndex])

        // From scanFrom, skip whitespace backwards to find `:`
        var colonScan = scanFrom
        while colonScan > utf16.startIndex {
            let prev = utf16.index(before: colonScan)
            let ch = text[prev]
            if ch == " " || ch == "\t" {
                colonScan = prev
            } else {
                break
            }
        }
        guard colonScan > utf16.startIndex else { return nil }
        let charBeforeValue = text[utf16.index(before: colonScan)]
        // Direct `param: value` — proceed below.
        // Array context: `param: ("v1", "partial` — walk back past array elements to find `:`.
        if charBeforeValue != ":" {
            colonScan = scanBackPastArrayElements(in: text, from: colonScan)
            guard colonScan > utf16.startIndex else { return nil }
            guard text[utf16.index(before: colonScan)] == ":" else { return nil }
        }

        // Get parameter name before `:`
        let colonPos = utf16.index(before: colonScan)
        var paramEnd = colonPos
        while paramEnd > utf16.startIndex {
            let prev = utf16.index(before: paramEnd)
            if text[prev] == " " || text[prev] == "\t" { paramEnd = prev } else { break }
        }
        var paramStart = paramEnd
        while paramStart > utf16.startIndex {
            let prev = utf16.index(before: paramStart)
            let c = text[prev]
            if c.isLetter || c == "-" || c == "_" || c.isNumber {
                paramStart = prev
            } else {
                break
            }
        }
        guard paramStart < paramEnd else { return nil }
        let paramName = String(text[paramStart..<paramEnd])
        let functionName = enclosingFunctionName(in: text, beforeOffset: cursorOffset)

        // Look up value suggestions
        let suggestions = valueSuggestionsForParam(paramName, in: functionName, symbols: symbols)
        guard !suggestions.isEmpty else { return nil }

        let filtered: [CompletionItem]
        if typedValue.isEmpty {
            filtered = suggestions
        } else {
            filtered = suggestions.filter {
                $0.label.localizedCaseInsensitiveContains(typedValue)
            }
        }
        guard !filtered.isEmpty else { return nil }
        if filtered.count == 1, filtered[0].label.caseInsensitiveCompare(typedValue) == .orderedSame { return nil }

        return .value(prefix: typedValue, isQuoted: isQuoted, items: filtered)
    }

    /// Walk backwards past array elements like `("val1", "val2",` to find the opening `(` and then `:`.
    /// Returns scan position just after any whitespace following the `(`, or `from` if not an array context.
    private func scanBackPastArrayElements(in text: String, from: String.UTF16View.Index) -> String.UTF16View.Index {
        let utf16 = text.utf16
        var pos = from

        // Walk past commas, quoted strings, identifiers, and whitespace
        while pos > utf16.startIndex {
            // Skip whitespace
            while pos > utf16.startIndex {
                let prev = utf16.index(before: pos)
                let ch = text[prev]
                if ch == " " || ch == "\t" { pos = prev } else { break }
            }
            guard pos > utf16.startIndex else { break }

            let ch = text[utf16.index(before: pos)]
            if ch == "(" {
                // Found opening paren — skip it and any whitespace, then return for `:` check
                pos = utf16.index(before: pos)
                while pos > utf16.startIndex {
                    let prev = utf16.index(before: pos)
                    if text[prev] == " " || text[prev] == "\t" { pos = prev } else { break }
                }
                return pos
            } else if ch == "," {
                pos = utf16.index(before: pos)
            } else if ch == "\"" {
                // Skip backwards over a quoted string
                pos = utf16.index(before: pos) // skip closing quote
                while pos > utf16.startIndex {
                    let prev = utf16.index(before: pos)
                    if text[prev] == "\"" { pos = prev; break }
                    pos = prev
                }
            } else if ch.isLetter || ch == "-" || ch == "_" || ch.isNumber {
                // Skip an unquoted value
                while pos > utf16.startIndex {
                    let prev = utf16.index(before: pos)
                    let c = text[prev]
                    if c.isLetter || c == "-" || c == "_" || c.isNumber { pos = prev } else { break }
                }
            } else {
                break
            }
        }
        return from // not an array context
    }

    private func valueSuggestionsForParam(
        _ paramName: String,
        in functionName: String?,
        symbols: () -> [TypstCompletionSymbolInfo]
    ) -> [CompletionItem] {
        switch paramName {
        case "font":
            return fontFamilies.map {
                CompletionItem(label: $0, insertText: $0, kind: .value, detail: L10n.tr("Font family"))
            }
        default:
            guard let functionName,
                  let function = functionSymbol(named: functionName, in: symbols()),
                  let param = function.params.first(where: { $0.name == paramName }) else { return [] }
            return param.values.map { value in
                CompletionItem(label: value.label, insertText: value.insertText, kind: .value, detail: value.detail)
            }
        }
    }

    // MARK: - Reference Completion (@)

    /// Detects `@partial` and suggests labels + bib keys.
    private func referenceCompletions(for text: String, cursorOffset: Int) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Walk backwards collecting identifier chars (letters, digits, hyphen, underscore, dot, colon)
        var start = cursorIndex
        while start > utf16.startIndex {
            let prev = utf16.index(before: start)
            let ch = text[prev]
            if ch == "@" {
                let query = String(text[start..<cursorIndex])
                let allRefs = allReferenceItems(for: text)
                let filtered = query.isEmpty ? allRefs : allRefs.filter {
                    $0.label.localizedCaseInsensitiveContains(query)
                }
                guard !filtered.isEmpty else { return nil }
                if filtered.count == 1, filtered[0].label == query { return nil }
                let prefix = String(text[prev..<cursorIndex])  // includes `@`
                return .atPrefix(prefix: prefix, items: filtered)
            } else if ch.isLetter || ch == "-" || ch == "_" || ch.isNumber || ch == "." || ch == ":" {
                start = prev
                continue
            } else {
                break
            }
        }
        return nil
    }

    /// Detects `<partial` inside `cite(<partial)` or `ref(<partial)`.
    private func angleBracketCompletions(for text: String, cursorOffset: Int) -> CompletionContext? {
        let utf16 = text.utf16
        guard cursorOffset <= utf16.count else { return nil }
        let cursorIndex = utf16.index(utf16.startIndex, offsetBy: cursorOffset)

        // Walk backwards collecting label chars
        var start = cursorIndex
        while start > utf16.startIndex {
            let prev = utf16.index(before: start)
            let ch = text[prev]
            if ch == "<" {
                let query = String(text[start..<cursorIndex])
                // Determine context: inside cite() → bib keys; inside ref() or unknown → labels
                let funcName = enclosingFunctionName(in: text, beforeOffset: cursorOffset)
                let candidates: [CompletionItem]
                if funcName == "cite" {
                    candidates = bibEntries.map {
                        CompletionItem(label: $0.key, insertText: $0.key, kind: .reference, detail: $0.completionDetail)
                    }
                } else {
                    candidates = allReferenceItems(for: text)
                }
                let filtered = query.isEmpty ? candidates : candidates.filter {
                    $0.label.localizedCaseInsensitiveContains(query)
                }
                guard !filtered.isEmpty else { return nil }
                if filtered.count == 1, filtered[0].label == query { return nil }
                return .angleBracket(prefix: query, items: filtered)
            } else if ch.isLetter || ch == "-" || ch == "_" || ch.isNumber || ch == "." || ch == ":" {
                start = prev
                continue
            } else {
                break
            }
        }
        return nil
    }

    /// Builds the full list of reference items: labels from current text + external labels + bib keys.
    private func allReferenceItems(for text: String) -> [CompletionItem] {
        var items: [CompletionItem] = []

        // Labels from current text
        for (name, kind) in scanLabels(in: text) {
            items.append(CompletionItem(label: name, insertText: name, kind: .reference, detail: kind))
        }

        // Labels from other project files
        for (name, kind) in externalLabels {
            items.append(CompletionItem(label: name, insertText: name, kind: .reference, detail: kind))
        }

        // Bibliography keys
        for entry in bibEntries {
            items.append(CompletionItem(label: entry.key, insertText: entry.key, kind: .reference, detail: entry.completionDetail))
        }

        return items
    }

    // MARK: - Label Scanning

    /// Parses Typst source for `<label-name>` definitions and their attached syntax kind.
    func scanLabels(in text: String) -> [(name: String, kind: String)] {
        TypstBridge.labels(source: text)?.map { (name: $0.name, kind: $0.kind) } ?? []
    }
}
