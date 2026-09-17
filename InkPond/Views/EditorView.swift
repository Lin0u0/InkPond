//
//  EditorView.swift
//  InkPond
//

import Foundation
import SwiftUI
import UIKit

struct EditorViewState: Equatable {
    var selectedLocation: Int = 0
    var selectedLength: Int = 0
    var contentOffset: CGPoint = .zero
}

struct EditorInsertionRequest: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let targetRange: NSRange
    let targetFileName: String
}

struct EditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var insertionRequest: EditorInsertionRequest?
    @Binding var findRequested: Bool
    @Binding var viewState: EditorViewState
    @Binding var cursorJumpOffset: Int?
    var fileLoadToken: UUID = UUID()
    var session: DocumentSession? = nil
    var acceptsCallbacks: () -> Bool = { true }
    var attachmentIsValid: () -> Bool = { true }
    var focusCoordinator: EditorFocusCoordinator? = nil
    var topViewportInset: CGFloat = 0
    var sourceMap: SourceMap?
    var syncCoordinator: SyncCoordinator?
    var theme: EditorTheme = .system
    var externalChromeBackgroundColor: UIColor = .secondarySystemGroupedBackground
    var editorFont: UIFont = EditorFontSettings.defaultUIFont
    var errorLines: Set<Int> = []
    var isEditable: Bool = true
    var onPhotoTapped: () -> Void = {}
    var onSnippetTapped: () -> Void = {}
    var onImagePasted: (Data, NSRange) -> Void = { _, _ in }
    var onRichPaste: ([TypstTextView.PasteFragment], NSRange) -> Void = { _, _ in }
    var fontFamilies: [String] = []
    var bibEntries: [TypstBibliographyEntry] = []
    var externalLabels: [(name: String, kind: String)] = []
    var imageFiles: [String] = []
    var packageSpecs: [String] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> TypstTextView {
        makeTextView(coordinator: context.coordinator)
    }

    // Shared production entry point, also usable by deterministic UIKit lifecycle tests.
    func makeTextView(coordinator: Coordinator) -> TypstTextView {
        let textView = TypstTextView()
        focusCoordinator?.register(textView)
        textView.applyEditorFont(editorFont)
        textView.applyExternalChromeBackground(externalChromeBackgroundColor)
        textView.applyTheme(theme)
        textView.topViewportInset = topViewportInset
        textView.accessibilityLabel = L10n.a11yEditorLabel
        textView.accessibilityHint = L10n.a11yEditorHint
        textView.accessibilityIdentifier = "editor.text-view"
        textView.isEditable = isEditable
        textView.delegate = coordinator
        coordinator.installBuffer(in: textView)
        return textView
    }

    func updateUIView(_ textView: TypstTextView, context: Context) {
        updateTextView(textView, coordinator: context.coordinator)
    }

    func updateTextView(_ textView: TypstTextView, coordinator: Coordinator) {
        coordinator.prepareForUpdate(self, in: textView)
        coordinator.performProgrammaticUpdate {
        focusCoordinator?.register(textView)
        textView.applyEditorFont(editorFont)
        textView.applyExternalChromeBackground(externalChromeBackgroundColor)
        textView.applyTheme(theme)
        textView.topViewportInset = topViewportInset
        textView.setErrorLines(errorLines)
        textView.accessibilityLabel = L10n.a11yEditorLabel
        textView.accessibilityHint = L10n.a11yEditorHint
        textView.isEditable = isEditable
        textView.onPhotoButtonTapped = onPhotoTapped
        textView.onSnippetButtonTapped = onSnippetTapped
        textView.onImagePasted = onImagePasted
        textView.onRichPaste = onRichPaste
        textView.updateFontFamilies(fontFamilies)
        textView.updateBibEntries(bibEntries)
        textView.updateExternalLabels(externalLabels)
        textView.updateImageFiles(imageFiles)
        textView.updatePackageSpecs(packageSpecs)
        }

        coordinator.installBuffer(in: textView)
        let generation = coordinator.installationGeneration

        // Consume pending find request — defer mutation to avoid writing state during view update.
        if findRequested {
            Task { @MainActor in
                guard coordinator.acceptsDeferredWork(generation, in: textView) else { return }
                textView.presentFind(showingReplace: true)
                self.findRequested = false
            }
        }

        // Apply insertions before cursor jumps so post-insert jumps run against the new buffer.
        if let request = insertionRequest {
                Task { @MainActor in
                guard coordinator.acceptsDeferredWork(generation, in: textView),
                      self.insertionRequest?.id == request.id else { return }
                self.insertionRequest = nil
                coordinator.insertText(request)
            }
            return
        }

        // Consume pending cursor jump request
        if let jumpOffset = cursorJumpOffset {
                Task { @MainActor in
                guard coordinator.acceptsDeferredWork(generation, in: textView),
                      self.cursorJumpOffset == jumpOffset else { return }
                self.cursorJumpOffset = nil
                let maxOffset = textView.text.utf16.count
                let safeOffset = min(max(0, jumpOffset), maxOffset)
                textView.dismissCompletion()
                textView.suppressCompletionForNextSelectionChange()
                textView.selectedRange = NSRange(location: safeOffset, length: 0)
                coordinator.captureViewState(from: textView)
                let line = coordinator.lineNumber(forUTF16Offset: safeOffset, in: textView.text)
                textView.flashJumpHighlight(atLine: line)
                if self.syncCoordinator?.activeDirection == .previewToEditor {
                    self.syncCoordinator?.endSync()
                }
                // Scroll to reveal cursor after layout and activate keyboard
                DispatchQueue.main.async {
                    guard coordinator.acceptsDeferredWork(generation, in: textView) else { return }
                    textView.scrollSelectionToUpperThird(animated: false)
                    coordinator.captureViewState(from: textView)
                    if !textView.isFirstResponder {
                        _ = textView.becomeFirstResponder()
                    }
                }
            }
        }
    }

    static func dismantleUIView(_ textView: TypstTextView, coordinator: Coordinator) {
        coordinator.detach(from: textView)
        // Do NOT write to the @Binding here. During view graph teardown,
        // SwiftUI's StoredLocation already has an active access; writing
        // triggers a Swift exclusivity violation (SIGABRT).
        // The viewState binding is kept current by captureViewState() calls
        // in textViewDidChange / textViewDidChangeSelection / scrollViewDidScroll,
        // and the parent persists cursor position in onDisappear before teardown.
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditorView
        weak var textView: TypstTextView?
        var lastAppliedFileLoadToken: UUID?
        private var lastAppliedViewState: EditorViewState?
        private weak var installedSession: DocumentSession?
        private var installedSessionID: ObjectIdentifier?
        private var historyAttachmentID = UUID()
        private(set) var installationGeneration = UUID()
        private var navigationGeneration = UUID()
        // Injectable queue, so cancellation tests execute the exact restoration work
        // deterministically rather than depending on run-loop sleeps.
        var enqueueRestoration: (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { work() }
        }
        private var committedSelection = NSRange(location: 0, length: 0)
        private var compositionBaseline: EditorUndoSnapshot?
        /// Set during `textViewDidChange` so the subsequent `textViewDidChangeSelection` knows
        /// the cursor moved because of typing, not a deliberate navigation.
        private var isProcessingTextChange = false
        private var isApplyingProgrammaticUpdate = false
        private var textChangeSelectionLocationToSkip: Int?
        /// Track previous text length to detect deletion.
        var previousTextLength: Int = 0

        init(_ parent: EditorView) {
            self.parent = parent
        }

        /// Shared by makeUIView, updates and undo replay; identity is independent of text equality.
        func prepareForUpdate(_ next: EditorView, in textView: TypstTextView) {
            if installedSessionID != next.session.map(ObjectIdentifier.init) {
                detach(from: textView)
            }
            parent = next
        }

        private var acceptsCallbacks: Bool {
            parent.attachmentIsValid() && parent.acceptsCallbacks() && (parent.session == nil ||
                parent.session?.editorUndoHistory.attachmentID == historyAttachmentID)
        }

        func acceptsDeferredWork(_ generation: UUID, in view: TypstTextView) -> Bool {
            generation == installationGeneration && textView === view && acceptsCallbacks
        }

        private func captureFind(in view: TypstTextView) {
            // Navigation can revoke the document attachment before UIKit dismantles
            // its view. Find is outgoing presentation state, not a text mutation.
            guard textView === view, let session = installedSession,
                  session.editorUndoHistory.attachmentID == historyAttachmentID,
                  let interaction = view.findInteraction else { return }
            session.findState = EditorFindState(query: interaction.searchText,
                                               replacement: interaction.replacementText,
                                               isPresented: interaction.isFindNavigatorVisible)
        }

        func detach(from view: TypstTextView) {
            captureFind(in: view)
            // Commit the outgoing composition while its session still owns the view.
            view.unmarkText()
            compositionBaseline = nil
            view.onMarkedTextWillBegin = nil
            view.onMarkedTextDidUpdate = nil
            installationGeneration = UUID()
            navigationGeneration = UUID()
            if let history = installedSession?.editorUndoHistory,
               history.attachmentID == historyAttachmentID {
                history.attachmentID = nil
                history.canReplay = nil
                history.didReplay = nil
            }
            performProgrammaticUpdate { view.findInteraction?.dismissFindNavigator() }
            view.rejectedSessionMutationDiagnostics = nil
            view.sessionUndoHistory = nil
            view.sessionUndoAttachmentID = nil
            textView = nil
            // Do not fall back to a native manager containing stale TextKit actions.
            installedSession = nil
            installedSessionID = nil
            lastAppliedFileLoadToken = nil
            lastAppliedViewState = nil
        }

        func installBuffer(in view: TypstTextView, replay: Bool = false) {
            // Even a not-yet-active bootstrap view must reject edits, rather than
            // falling through to native undo while awaiting production activation.
            view.usesSessionUndo = parent.session != nil
#if DEBUG
            view.rejectedSessionMutationDiagnostics = { [weak self, weak view] in
                guard let self, let view else { return "coordinatorAlive=false" }
                let session = self.parent.session
                let context = session?.context
                return [
                    "attachmentValid=\(self.parent.attachmentIsValid())",
                    "callbacksAccepted=\(self.parent.acceptsCallbacks())",
                    "viewMatches=\(self.textView === view)",
                    "session=\(String(describing: session.map(ObjectIdentifier.init)))",
                    "installedSession=\(String(describing: self.installedSessionID))",
                    "retainedMatches=\(session.map { $0.context.sessions[$0.currentFileName] === $0 } ?? false)",
                    "activeMatches=\(session.map { $0.context.activeTextSession === $0 } ?? false)",
                    "activeSession=\(String(describing: context?.activeTextSession.map(ObjectIdentifier.init)))",
                    "coordinatorAttachment=\(self.historyAttachmentID)"
                ].joined(separator: " ")
            }
#endif
            // A valid workspace attachment alone does not make this representation
            // current. Inactive SwiftUI updates must not steal the live history.
            guard parent.attachmentIsValid(), parent.acceptsCallbacks() else { return }
            let identity = parent.session.map(ObjectIdentifier.init)
            let lostHistory = parent.session.map {
                $0.editorUndoHistory.attachmentID != historyAttachmentID
            } ?? false
            let attaching = textView !== view || installedSessionID != identity
                || lastAppliedFileLoadToken == nil || lostHistory
            let force = attaching || lastAppliedFileLoadToken != parent.fileLoadToken || replay
            guard force || view.text != parent.text else { return }
            textView = view
            if force { installationGeneration = UUID(); lastAppliedViewState = nil }
            if attaching {
                installedSession = parent.session
                installedSessionID = identity
                historyAttachmentID = UUID()
                view.usesSessionUndo = parent.session != nil
                view.sessionUndoHistory = parent.session?.editorUndoHistory
                view.sessionUndoAttachmentID = historyAttachmentID
                parent.session?.hasEditorSnapshot = true
                if let history = view.sessionUndoHistory {
                    history.attachmentID = historyAttachmentID
                    let attachment = historyAttachmentID
                    history.canReplay = { [weak self, weak view, weak history] in
                        guard let self, let view else { return false }
                        return history?.attachmentID == attachment && self.textView === view
                            && self.acceptsCallbacks
                    }
                    history.didReplay = { [weak self, weak view] in
                        guard let self, let view, self.parent.acceptsCallbacks() else { return }
                        self.installBuffer(in: view, replay: true)
                    }
                }
            }
            view.onMarkedTextWillBegin = { [weak self, weak view] in
                guard let self, let view, !self.isApplyingProgrammaticUpdate,
                      self.acceptsCallbacks, self.textView === view,
                      self.compositionBaseline == nil else { return }
                // Capture before UIKit can move the selection or install preedit text.
                self.compositionBaseline = EditorUndoSnapshot(
                    text: self.parent.text, selection: view.selectedRange)
            }
            view.onMarkedTextDidUpdate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.textViewDidChange(view)
            }
            lastAppliedFileLoadToken = parent.fileLoadToken
            performProgrammaticUpdate {
                // A load/replay replaces the buffer, rather than committing old preedit into it.
                compositionBaseline = nil
                view.unmarkText()
                // Install the buffer BEFORE applying selection. Installation never publishes text.
                if view.text != parent.text { view.text = parent.text }
                view.scheduleHighlighting(.immediate, textChanged: true)
                restoreViewStateIfNeeded(in: view)
                committedSelection = view.selectedRange
                previousTextLength = view.text.utf16.count
            }
            if attaching, let find = parent.session?.findState {
                // nil lets UIKit supply a previous query when the navigator opens.
                // A new session instead owns an explicitly empty find field.
                view.findInteraction?.searchText = find.query ?? ""
                view.findInteraction?.replacementText = find.replacement ?? ""
                if find.isPresented {
                    let generation = installationGeneration
                    enqueueRestoration { [weak self, weak view] in
                        guard let self, let view, self.acceptsDeferredWork(generation, in: view) else { return }
                        view.presentFind(showingReplace: true)
                    }
                }
            }
        }

        func performProgrammaticUpdate(_ update: () -> Void) {
            let wasApplying = isApplyingProgrammaticUpdate
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = wasApplying }
            update()
        }

        func insertText(_ request: EditorInsertionRequest) {
            guard let textView, acceptsCallbacks,
                  parent.session == nil || parent.session?.currentFileName == request.targetFileName else { return }
            let nsString = textView.text as NSString
            let safeLocation = min(max(0, request.targetRange.location), nsString.length)
            let safeLength = min(max(0, request.targetRange.length), nsString.length - safeLocation)
            let selectedRange = NSRange(location: safeLocation, length: safeLength)
            let originalContent = nsString.substring(with: selectedRange)
            let insertedRange = NSRange(
                location: selectedRange.location,
                length: (request.text as NSString).length
            )

            textView.undoManager?.registerUndo(withTarget: textView) { tv in
                tv.textStorage.replaceCharacters(in: insertedRange, with: originalContent)
                tv.selectedRange = selectedRange
                tv.delegate?.textViewDidChange?(tv)
            }
            textView.undoManager?.setActionName(L10n.tr("action.insert_image"))

            textView.textStorage.replaceCharacters(in: selectedRange, with: request.text)
            textView.selectedRange = NSRange(location: selectedRange.location + insertedRange.length, length: 0)
            textViewDidChange(textView)
            textView.scheduleHighlighting(.immediate, textChanged: true)
            let generation = installationGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.acceptsDeferredWork(generation, in: textView) else { return }
                textView.scrollSelectionToUpperThird(animated: false)
                self.captureViewState(from: textView)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let typstTextView = textView as? TypstTextView else { return }
            if isApplyingProgrammaticUpdate {
                previousTextLength = textView.text.utf16.count
                return
            }
            guard acceptsCallbacks, self.textView === typstTextView else { return }
            let composing = typstTextView.isUpdatingMarkedText || textView.markedTextRange != nil
            if let baseline = compositionBaseline {
                if !composing {
                    compositionBaseline = nil
                    parent.session?.editorUndoHistory.record(
                        before: baseline,
                        after: EditorUndoSnapshot(text: textView.text, selection: textView.selectedRange)
                    )
                    committedSelection = textView.selectedRange
                    captureViewState(from: typstTextView)
                }
            } else if textView.text != parent.text {
                parent.session?.editorUndoHistory.record(
                    before: EditorUndoSnapshot(text: parent.text, selection: committedSelection),
                    after: EditorUndoSnapshot(text: textView.text, selection: textView.selectedRange)
                )
                committedSelection = textView.selectedRange
            }
            guard textView.text != parent.text else { return }
            isProcessingTextChange = true
            defer { isProcessingTextChange = false }
            let newLength = textView.text.utf16.count
            previousTextLength = newLength
            parent.text = textView.text
            captureViewState(from: typstTextView)
            typstTextView.scheduleHighlighting(.debounced, textChanged: true)
            textChangeSelectionLocationToSkip = typstTextView.selectedRange.location
            typstTextView.updateCompletion()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let typstTextView = textView as? TypstTextView else { return }
            guard !isApplyingProgrammaticUpdate, acceptsCallbacks,
                  self.textView === typstTextView else { return }
            // Preedit selection callbacks must not replace the pre-composition baseline.
            guard compositionBaseline == nil, !typstTextView.isUpdatingMarkedText,
                  textView.markedTextRange == nil else { return }
            // UIKit reports selection during an edit before didChange. Keep its pre-edit selection.
            guard textView.text == parent.text else { return }
            committedSelection = textView.selectedRange
            captureViewState(from: typstTextView)
            // After a tap-to-dismiss, skip re-triggering completion for this selection change
            if typstTextView.consumeSelectionSuppression() { return }
            if textChangeSelectionLocationToSkip == typstTextView.selectedRange.location {
                textChangeSelectionLocationToSkip = nil
                return
            }
            textChangeSelectionLocationToSkip = nil
            typstTextView.updateCompletion()
            // Only sync cursor to preview on deliberate navigation (tap, arrow keys),
            // not on every keystroke — typing causes noisy preview jumps.
            if !isProcessingTextChange,
               parent.syncCoordinator?.isEditorToPreviewSyncEnabled == true {
                syncCursorToPreview(textView)
            }
        }

        private func syncCursorToPreview(_ textView: UITextView) {
            guard let syncCoordinator = parent.syncCoordinator,
                  let sourceMap = parent.sourceMap,
                  !sourceMap.isEmpty else { return }
            guard syncCoordinator.beginSync(.editorToPreview) else { return }

            let cursorLocation = textView.selectedRange.location
            let text = textView.text as NSString
            let line = Self.lineNumber(atUTF16Offset: cursorLocation, in: text)

            if let target = sourceMap.pdfPosition(forLine: line) {
                syncCoordinator.previewScrollTarget = PreviewScrollTarget(
                    page: target.page,
                    yPoints: target.yPoints,
                    xPoints: target.xPoints
                )
            }
            syncCoordinator.endSync()
        }

        private static func lineNumber(atUTF16Offset cursorLocation: Int, in text: NSString) -> Int {
            let upperBound = min(max(cursorLocation, 0), text.length)
            guard upperBound > 0 else { return 1 }

            var line = 1
            for index in 0..<upperBound where text.character(at: index) == 10 {
                line += 1
            }
            return line
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let typstTextView = scrollView as? TypstTextView else { return }
            captureViewState(from: typstTextView)
            if scrollView.isDragging || scrollView.isDecelerating { typstTextView.dismissCompletion() }
        }

        func captureViewState(from textView: TypstTextView) {
            guard !isApplyingProgrammaticUpdate, acceptsCallbacks, self.textView === textView,
                  textView.text == parent.text else { return }
            navigationGeneration = UUID()
            parent.focusCoordinator?.updateSelectionState(selectedLength: textView.selectedRange.length)
            let newState = EditorViewState(
                selectedLocation: textView.selectedRange.location,
                selectedLength: textView.selectedRange.length,
                contentOffset: textView.contentOffset
            )
            guard parent.viewState != newState else { return }
            parent.viewState = newState
        }

        func restoreViewStateIfNeeded(in textView: TypstTextView) {
            guard lastAppliedViewState != parent.viewState else { return }

            let utf16Count = textView.text.utf16.count
            let location = min(max(0, parent.viewState.selectedLocation), utf16Count)
            let length = min(max(0, parent.viewState.selectedLength), utf16Count - location)
            let restoredRange = NSRange(location: location, length: length)

            if textView.selectedRange != restoredRange {
                textView.selectedRange = restoredRange
            }
            parent.focusCoordinator?.updateSelectionState(selectedLength: restoredRange.length)

            var targetOffset = parent.viewState.contentOffset
            // The default viewState has contentOffset (0,0), which assumed no
            // top content inset. When a top inset is present (e.g. to clear the
            // navigation bar), remap the default "at top" position to the
            // inset-adjusted top so content isn't hidden behind the bar.
            if targetOffset == .zero && textView.contentInset.top > 0 {
                targetOffset = CGPoint(x: 0, y: -textView.contentInset.top)
            }
            // Always remeasure, even when UIKit's current offset happens to match:
            // a new buffer or viewport can make that offset out of bounds.
            let generation = installationGeneration
            let navigation = navigationGeneration
            enqueueRestoration { [weak self, weak textView] in
                guard let self, let textView,
                      self.acceptsDeferredWork(generation, in: textView),
                      self.navigationGeneration == navigation else { return }
                self.performProgrammaticUpdate {
                    textView.layoutIfNeeded()
                    textView.setContentOffset(Self.clampedOffset(targetOffset, in: textView), animated: false)
                }
            }

            lastAppliedViewState = parent.viewState
        }

        static func clampedOffset(_ offset: CGPoint, in view: UIScrollView) -> CGPoint {
            let inset = view.adjustedContentInset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, view.contentSize.width - view.bounds.width + inset.right)
            let maxY = max(minY, view.contentSize.height - view.bounds.height + inset.bottom)
            return CGPoint(x: offset.x.isFinite ? min(max(offset.x, minX), maxX) : minX,
                           y: offset.y.isFinite ? min(max(offset.y, minY), maxY) : minY)
        }

        func lineNumber(forUTF16Offset offset: Int, in text: String) -> Int {
            let nsText = text as NSString
            let clampedOffset = min(max(offset, 0), nsText.length)
            let prefix = nsText.substring(to: clampedOffset)
            return prefix.components(separatedBy: "\n").count
        }
    }
}
