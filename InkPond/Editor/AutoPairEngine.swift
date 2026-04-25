//
//  AutoPairEngine.swift
//  InkPond
//

import UIKit

struct AutoPairEngine {

    private static let pairs: [(open: String, close: String)] = [
        ("{", "}"),
        ("[", "]"),
        ("(", ")"),
        ("\"", "\""),
        ("$", "$"),
    ]

    private static let openToClose: [String: String] = Dictionary(uniqueKeysWithValues: pairs.map { ($0.open, $0.close) })
    private static let closeChars: Set<String> = Set(pairs.map { $0.close })
    private static let bracketOpens: Set<String> = ["{", "["]

    // MARK: - Insert Text

    /// Returns true if the event was handled (default insertion should be skipped).
    static func handleInsert(_ text: String, in textView: UITextView) -> Bool {
        let storage = textView.textStorage
        let selectedRange = textView.selectedRange
        let nsString = storage.string as NSString
        let source = storage.string

        // Handle Enter key — auto-indent
        if text == "\n" {
            return handleNewline(in: textView, storage: storage, selectedRange: selectedRange, nsString: nsString, source: source)
        }

        // Only handle single-character inserts for pairing
        guard text.count == 1 else { return false }

        let cursorLocation = selectedRange.location
        let context = TypstBridge.contextAt(source: source, utf16Offset: cursorLocation)

        // Type-over: if typing a closing char and next char matches, just move cursor
        if closeChars.contains(text),
           cursorLocation < nsString.length {
            let nextChar = nsString.substring(with: NSRange(location: cursorLocation, length: 1))
            if nextChar == text {
                textView.selectedRange = NSRange(location: cursorLocation + 1, length: 0)
                return true
            }
        }

        // Auto-close: if typing an opening char, insert the pair
        if let close = openToClose[text] {
            guard shouldAutoClose(text, context: context) else { return false }

            // For quotes and $, only auto-close if not already adjacent to same char
            if text == "\"" || text == "$" {
                if cursorLocation > 0 {
                    let prevChar = nsString.substring(with: NSRange(location: cursorLocation - 1, length: 1))
                    if prevChar == text { return false }
                }
                if cursorLocation < nsString.length {
                    let nextChar = nsString.substring(with: NSRange(location: cursorLocation, length: 1))
                    if nextChar == text { return false }
                }
            }

            let pair = text + close

            // Capture original content for undo (handles both empty and non-empty selection)
            let originalContent = (nsString.substring(with: selectedRange))
            textView.undoManager?.registerUndo(withTarget: textView) { tv in
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: selectedRange.location, length: (pair as NSString).length),
                    with: originalContent
                )
                tv.selectedRange = selectedRange
                tv.delegate?.textViewDidChange?(tv)
            }
            textView.undoManager?.setActionName(L10n.tr("action.typing"))

            storage.replaceCharacters(in: selectedRange, with: pair)
            textView.selectedRange = NSRange(location: cursorLocation + 1, length: 0)
            return true
        }

        return false
    }

    // MARK: - Delete Backward

    /// Returns true if handled (deleted both chars of an empty pair).
    static func handleDelete(in textView: UITextView) -> Bool {
        let storage = textView.textStorage
        let selectedRange = textView.selectedRange
        let nsString = storage.string as NSString

        let cursor = selectedRange.location
        guard selectedRange.length == 0, cursor > 0, cursor < nsString.length else { return false }

        let prevChar = nsString.substring(with: NSRange(location: cursor - 1, length: 1))
        let nextChar = nsString.substring(with: NSRange(location: cursor, length: 1))

        if let close = openToClose[prevChar], close == nextChar {
            let deletedPair = prevChar + nextChar
            let deleteLocation = cursor - 1

            textView.undoManager?.registerUndo(withTarget: textView) { tv in
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: deleteLocation, length: 0),
                    with: deletedPair
                )
                tv.selectedRange = NSRange(location: cursor, length: 0)
                tv.delegate?.textViewDidChange?(tv)
            }
            textView.undoManager?.setActionName(L10n.tr("action.delete"))

            storage.replaceCharacters(in: NSRange(location: cursor - 1, length: 2), with: "")
            textView.selectedRange = NSRange(location: cursor - 1, length: 0)
            return true
        }

        return false
    }

    // MARK: - Newline / Auto-indent

    private static func handleNewline(
        in textView: UITextView,
        storage: NSTextStorage,
        selectedRange: NSRange,
        nsString: NSString,
        source: String
    ) -> Bool {
        let cursor = selectedRange.location
        let context = TypstBridge.contextAt(source: source, utf16Offset: cursor)

        // Find current line's leading whitespace
        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = nsString.substring(with: lineRange)
        let leadingWhitespace = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))

        // Check if char before cursor is a bracket opener
        let charBefore = cursor > 0 ? nsString.substring(with: NSRange(location: cursor - 1, length: 1)) : ""
        let charAfter = cursor < nsString.length ? nsString.substring(with: NSRange(location: cursor, length: 1)) : ""

        if bracketOpens.contains(charBefore), shouldAutoIndent(after: charBefore, context: context) {
            let indent = leadingWhitespace + "    "
            var insertion = "\n" + indent
            let expectedClose = charBefore == "{" ? "}" : "]"
            if charAfter == expectedClose {
                insertion += "\n" + leadingWhitespace
            }
            let insertedRange = NSRange(location: selectedRange.location, length: (insertion as NSString).length)
            let originalContent = nsString.substring(with: selectedRange)
            textView.undoManager?.registerUndo(withTarget: textView) { tv in
                tv.textStorage.replaceCharacters(in: insertedRange, with: originalContent)
                tv.selectedRange = selectedRange
                tv.delegate?.textViewDidChange?(tv)
            }
            textView.undoManager?.setActionName(L10n.tr("action.typing"))

            storage.replaceCharacters(in: selectedRange, with: insertion)
            textView.selectedRange = NSRange(location: cursor + 1 + indent.count, length: 0)
            return true
        }

        // Default: just preserve indentation
        if !leadingWhitespace.isEmpty {
            let insertion = "\n" + leadingWhitespace
            let insertedRange = NSRange(location: selectedRange.location, length: (insertion as NSString).length)
            let originalContent = nsString.substring(with: selectedRange)
            textView.undoManager?.registerUndo(withTarget: textView) { tv in
                tv.textStorage.replaceCharacters(in: insertedRange, with: originalContent)
                tv.selectedRange = selectedRange
                tv.delegate?.textViewDidChange?(tv)
            }
            textView.undoManager?.setActionName(L10n.tr("action.typing"))

            storage.replaceCharacters(in: selectedRange, with: insertion)
            textView.selectedRange = NSRange(location: cursor + insertion.count, length: 0)
            return true
        }

        return false
    }

    private static func shouldAutoClose(_ text: String, context: TypstCursorContext?) -> Bool {
        guard let context, !isSuppressedPairingContext(context) else { return false }

        switch text {
        case "$":
            return context.contains("Markup") && !context.contains("Equation") && !context.contains("Math")
        case "\"":
            return context.contains("Code")
                || context.contains("Args")
                || context.contains("Named")
                || context.contains("ModuleImport")
                || context.contains("ModuleInclude")
        default:
            return true
        }
    }

    private static func shouldAutoIndent(after opener: String, context: TypstCursorContext?) -> Bool {
        guard let context, !isSuppressedPairingContext(context) else { return false }

        switch opener {
        case "{":
            return context.contains("Code")
                || context.contains("CodeBlock")
                || context.contains("Conditional")
                || context.contains("WhileLoop")
                || context.contains("ForLoop")
        case "[":
            return context.contains("ContentBlock")
                || context.contains("Markup")
                || context.contains("Args")
                || context.contains("FuncCall")
        default:
            return false
        }
    }

    private static func isSuppressedPairingContext(_ context: TypstCursorContext) -> Bool {
        context.contains("Raw")
            || context.contains("RawLang")
            || context.contains("RawDelim")
            || context.contains("LineComment")
            || context.contains("BlockComment")
            || context.contains("Str")
    }
}
