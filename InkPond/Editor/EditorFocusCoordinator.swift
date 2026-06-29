import Foundation
import UIKit

@MainActor
final class EditorFocusCoordinator {
    private weak var textView: TypstTextView?
    private var suppressionCount = 0
    private var shouldRestoreFocus = false
    private var restoreTask: Task<Void, Never>?
    private(set) var isTextSelectionDragActive = false
    private(set) var hasActiveTextSelection = false

    var isTextSelectionInteractionActive: Bool {
        isTextSelectionDragActive || (isEditorFocused && hasActiveTextSelection)
    }

    var isEditorFocused: Bool {
        textView?.isFirstResponder == true
    }

    func register(_ textView: TypstTextView) {
        self.textView = textView
        textView.suppressResignFirstResponder = suppressionCount > 0
        hasActiveTextSelection = textView.selectedRange.length > 0
        textView.onTextSelectionDragActiveChanged = { [weak self] isActive in
            self?.isTextSelectionDragActive = isActive
        }
    }

    func updateSelectionState(selectedLength: Int) {
        hasActiveTextSelection = selectedLength > 0
    }

    func setResignSuppressed(_ isSuppressed: Bool) {
        if isSuppressed {
            if textView?.isFirstResponder == true {
                shouldRestoreFocus = true
            }
            suppressionCount += 1
            restoreTask?.cancel()
            restoreTask = nil
            textView?.suppressResignFirstResponder = true
            return
        }

        guard suppressionCount > 0 else {
            textView?.suppressResignFirstResponder = false
            return
        }

        suppressionCount -= 1
        let remainsSuppressed = suppressionCount > 0
        textView?.suppressResignFirstResponder = remainsSuppressed
        guard !remainsSuppressed else { return }
        restoreFocusIfNeeded()
    }

    func clearFocusPreservation() {
        suppressionCount = 0
        shouldRestoreFocus = false
        restoreTask?.cancel()
        restoreTask = nil
        textView?.suppressResignFirstResponder = false
    }

    func dismissKeyboard() {
        clearFocusPreservation()
        isTextSelectionDragActive = false
        textView?.resignFirstResponder()
    }

    func activateKeyboard() {
        guard let textView, !textView.isFirstResponder else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, !textView.isFirstResponder else { return }
            _ = textView.becomeFirstResponder()
        }
    }

    private func restoreFocusIfNeeded() {
        guard shouldRestoreFocus else { return }
        shouldRestoreFocus = false
        guard let textView, !textView.isFirstResponder else { return }

        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak textView] in
            await Task.yield()
            guard let textView, !textView.isFirstResponder else { return }
            _ = textView.becomeFirstResponder()
        }
    }
}
