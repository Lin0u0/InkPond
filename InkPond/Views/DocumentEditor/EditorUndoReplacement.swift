import UIKit

/// Registers the inverse during undo/redo as well, so queued insertions share
/// the live text view's bidirectional stack rather than a separate history.
@MainActor
enum EditorUndoReplacement {
    static func register(in view: UITextView, range: NSRange, replacement: String, selection: NSRange) {
        view.undoManager?.registerUndo(withTarget: view) { target in
            let text = target.text as NSString
            guard NSMaxRange(range) <= text.length else { return }
            let inverse = text.substring(with: range)
            let inverseRange = NSRange(location: range.location, length: replacement.utf16.count)
            register(in: target, range: inverseRange, replacement: inverse, selection: target.selectedRange)
            target.textStorage.replaceCharacters(in: range, with: replacement)
            target.selectedRange = selection
            target.delegate?.textViewDidChange?(target)
        }
    }
}
