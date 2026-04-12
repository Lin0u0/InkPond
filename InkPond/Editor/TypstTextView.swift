//
//  TypstTextView.swift
//  InkPond
//

import os
import UIKit
import UniformTypeIdentifiers

enum JumpHighlightTimeline {
    static let fadeInDuration: CFTimeInterval = 0.18
    static let holdDuration: CFTimeInterval = 0.18
    static let fadeOutDuration: CFTimeInterval = 0.82

    static var totalDuration: CFTimeInterval {
        fadeInDuration + holdDuration + fadeOutDuration
    }

    static func opacity(at elapsed: CFTimeInterval) -> CGFloat {
        switch elapsed {
        case ..<0:
            return 0
        case 0..<fadeInDuration:
            let progress = elapsed / fadeInDuration
            return CGFloat(eased(progress))
        case fadeInDuration..<(fadeInDuration + holdDuration):
            return 1
        case (fadeInDuration + holdDuration)...totalDuration:
            let progress = (elapsed - fadeInDuration - holdDuration) / fadeOutDuration
            return CGFloat(1 - eased(progress))
        default:
            return 0
        }
    }

    private static func eased(_ progress: Double) -> Double {
        let clamped = max(0, min(progress, 1))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

final class TypstTextView: UITextView {
    enum PasteFragment {
        case text(String)
        case imageData(Data, suggestedFileName: String?)
        case imageRemoteURL(URL, suggestedFileName: String?)
    }

    private let highlighter = SyntaxHighlighter()
    private lazy var highlightScheduler = HighlightScheduler { [weak self] in
        self?.applyHighlightingNow()
    }
    private(set) var gutterView: LineNumberGutterView!
    private var storedTheme: EditorTheme = .system
    private var appearanceRegistration: (any UITraitChangeRegistration)?
    private var jumpHighlightDisplayLink: CADisplayLink?
    private var jumpHighlightAnimationStartTime: CFTimeInterval?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InkPond", category: "EditorHighlight")
    private static let signposter = OSSignposter(logger: logger)

    // MARK: - Completion
    private let completionEngine = CompletionEngine.shared
    private var completionPopup: CompletionPopupView?
    /// The `#`-prefixed text that is being completed (e.g. "#se").
    private var completionPrefix: String?
    /// When true, the next `textViewDidChangeSelection` call should not re-trigger completion.
    /// Set after a tap-to-dismiss so the selection change from the same tap doesn't re-show the popup.
    private(set) var suppressNextSelectionCompletion = false

    /// When true, `resignFirstResponder()` is refused for this editor instance.
    /// Set by PDFKitView during document reload to prevent PDFKit from
    /// dismissing the software keyboard on iPadOS.
    var suppressResignFirstResponder = false
    var topViewportInset: CGFloat = 0 {
        didSet {
            guard oldValue != topViewportInset else { return }
            updateViewportInsetsIfNeeded()
        }
    }

    var onPhotoButtonTapped: (() -> Void)? {
        didSet { (inputAccessoryView as? KeyboardAccessoryView)?.onPhotoButtonTapped = onPhotoButtonTapped }
    }
    var onSnippetButtonTapped: (() -> Void)? {
        didSet { (inputAccessoryView as? KeyboardAccessoryView)?.onSnippetButtonTapped = onSnippetButtonTapped }
    }
    var onImagePasted: ((Data, NSRange) -> Void)?
    var onRichPaste: (([PasteFragment], NSRange) -> Void)?
    private let pasteImageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .webP]

    // MARK: - Init (Force TextKit 1)

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        configureAppearance()
        setupGutter()
        setupAccessoryView()
        setupFindInteraction()
        setupAppearanceObservation()
        setupKeyboardAvoidance()
        setupCompletionDismissTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
        setupGutter()
        setupAccessoryView()
        setupFindInteraction()
        setupAppearanceObservation()
        setupKeyboardAvoidance()
        setupCompletionDismissTap()
    }

    deinit {
        jumpHighlightDisplayLink?.invalidate()
        completionPopup?.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    private func configureAppearance() {
        font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        autocorrectionType = .no
        autocapitalizationType = .none
        smartDashesType = .no
        smartQuotesType = .no
        spellCheckingType = .no
        backgroundColor = .clear
        textColor = .label
        contentInsetAdjustmentBehavior = .never
        accessibilityTraits.insert(.allowsDirectInteraction)
        accessibilityLabel = L10n.a11yEditorLabel
        accessibilityHint = L10n.a11yEditorHint
    }

    private func setupGutter() {
        gutterView = LineNumberGutterView(textView: self)
        gutterView.isAccessibilityElement = false
        gutterView.accessibilityElementsHidden = true
        addSubview(gutterView)
        updateGutterLayout()
    }

    private func updateGutterLayout() {
        let width = gutterView.gutterWidth
        textContainerInset = UIEdgeInsets(top: 12, left: width + 4, bottom: 12, right: 12)
        gutterView.frame = CGRect(x: 0, y: 0, width: width, height: max(contentSize.height, bounds.height))
        gutterView.setNeedsDisplay()
    }

    private func updateViewportInsetsIfNeeded() {
        let previousAdjustedTop = adjustedContentInset.top
        let wasPinnedToTop = abs(contentOffset.y + previousAdjustedTop) < 2

        if contentInset.top != topViewportInset {
            var insets = contentInset
            insets.top = topViewportInset
            contentInset = insets
        }

        if verticalScrollIndicatorInsets.top != topViewportInset {
            var indicatorInsets = verticalScrollIndicatorInsets
            indicatorInsets.top = topViewportInset
            verticalScrollIndicatorInsets = indicatorInsets
        }

        if wasPinnedToTop {
            setContentOffset(
                CGPoint(x: contentOffset.x, y: -adjustedContentInset.top),
                animated: false
            )
        }
    }

    private func setupAccessoryView() {
        inputAccessoryView = KeyboardAccessoryView(textView: self)
    }

    private func setupFindInteraction() {
        isFindInteractionEnabled = true
    }

    private func setupAppearanceObservation() {
        appearanceRegistration = registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (view: TypstTextView, _: UITraitCollection) in
            view.typingAttributes[.foregroundColor] = view.storedTheme.text
            view.scheduleHighlighting(.immediate)
        }
    }

    // MARK: - Key Commands (Cmd+F, Completion navigation)

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        let findCommand = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(showFind))
        findCommand.discoverabilityTitle = L10n.tr("action.find_replace")
        commands.append(findCommand)

        // Completion keyboard navigation (only when popup is visible)
        if isCompletionVisible {
            let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(completionMoveUp))
            up.wantsPriorityOverSystemBehavior = true
            let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(completionMoveDown))
            down.wantsPriorityOverSystemBehavior = true
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(completionDismiss))
            escape.wantsPriorityOverSystemBehavior = true
            commands.append(contentsOf: [up, down, escape])

            if completionPopup?.hasInsertableSelection == true {
                let enter = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(completionConfirm))
                enter.wantsPriorityOverSystemBehavior = true
                let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(completionConfirm))
                tab.wantsPriorityOverSystemBehavior = true
                commands.append(contentsOf: [enter, tab])
            }
        }

        return commands
    }

    @objc private func showFind() {
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    @objc private func completionMoveUp() {
        completionPopup?.moveSelectionUp()
    }

    @objc private func completionMoveDown() {
        completionPopup?.moveSelectionDown()
    }

    @objc private func completionConfirm() {
        completionPopup?.confirmSelection()
    }

    @objc private func completionDismiss() {
        dismissCompletion()
    }

    private var isCompletionVisible: Bool {
        completionPopup?.isHidden == false
    }

    // MARK: - Tap-to-Dismiss Completion (iOS touch)

    private var completionDismissTap: UITapGestureRecognizer?

    private func setupCompletionDismissTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToDismissCompletion(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        completionDismissTap = tap
    }

    @objc private func handleTapToDismissCompletion(_ gesture: UITapGestureRecognizer) {
        guard isCompletionVisible else { return }
        // Don't dismiss if the tap landed on the popup itself
        if let popup = completionPopup {
            let locationInPopup = gesture.location(in: popup)
            if popup.bounds.contains(locationInPopup) { return }
        }
        suppressNextSelectionCompletion = true
        dismissCompletion()
    }

    func consumeSelectionSuppression() -> Bool {
        guard suppressNextSelectionCompletion else { return false }
        suppressNextSelectionCompletion = false
        return true
    }

    func suppressCompletionForNextSelectionChange() {
        suppressNextSelectionCompletion = true
    }

    // MARK: - First Responder Guard

    @discardableResult
    override func resignFirstResponder() -> Bool {
        if suppressResignFirstResponder { return false }
        dismissCompletion()
        return super.resignFirstResponder()
    }

    // MARK: - Auto-pair Integration

    override func insertText(_ text: String) {
        if AutoPairEngine.handleInsert(text, in: self) {
            // applyHighlighting() is handled by Coordinator.textViewDidChange below
            delegate?.textViewDidChange?(self)
            return
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        if AutoPairEngine.handleDelete(in: self) {
            // applyHighlighting() is handled by Coordinator.textViewDidChange below
            delegate?.textViewDidChange?(self)
            return
        }
        super.deleteBackward()
    }

    override func paste(_ sender: Any?) {
        let fragments = pasteFragmentsFromPasteboard()
        guard !fragments.isEmpty else {
            super.paste(sender)
            return
        }

        if let onRichPaste {
            onRichPaste(fragments, selectedRange)
            return
        }

        var textBuffer = ""
        for fragment in fragments {
            switch fragment {
            case .text(let text):
                textBuffer.append(text)
            case .imageData(let data, _):
                if !textBuffer.isEmpty {
                    if let range = selectedTextRange {
                        replace(range, withText: textBuffer)
                    } else {
                        insertText(textBuffer)
                    }
                    textBuffer = ""
                }
                onImagePasted?(data, selectedRange)
            case .imageRemoteURL:
                // Fallback path cannot import remote URLs synchronously.
                // If rich paste handler isn't set, ignore remote image fragments.
                continue
            }
        }
        if !textBuffer.isEmpty {
            if let range = selectedTextRange {
                replace(range, withText: textBuffer)
            } else {
                insertText(textBuffer)
            }
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            if pb.hasStrings || pb.hasImages || pb.hasURLs || pb.numberOfItems > 0 {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = gutterView.gutterWidth
        gutterView.frame = CGRect(x: 0, y: 0, width: width, height: max(contentSize.height, bounds.height))
        gutterView.setNeedsDisplay()
    }

    // MARK: - Theme

    func applyTheme(_ theme: EditorTheme) {
        guard theme.id != storedTheme.id else { return }
        storedTheme = theme
        backgroundColor = theme.background
        textColor = theme.text
        typingAttributes = [
            .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: theme.text,
        ]
        highlighter.updateTheme(theme)
        gutterView.applyTheme(theme)
        scheduleHighlighting(.immediate)
    }

    // MARK: - Error Lines

    func setErrorLines(_ lines: Set<Int>) {
        guard lines != highlighter.errorLines else { return }
        highlighter.errorLines = lines
        scheduleHighlighting(.immediate)
    }

    func flashJumpHighlight(atLine line: Int) {
        jumpHighlightAnimationStartTime = CACurrentMediaTime()
        applyJumpHighlight(line: line, opacity: 0)
        startJumpHighlightDisplayLinkIfNeeded()
        advanceJumpHighlightAnimation(to: CACurrentMediaTime())
    }

    // MARK: - Highlighting

    func scheduleHighlighting(_ mode: HighlightMode, textChanged: Bool = false) {
        if textChanged {
            gutterView.textDidChange()
            setNeedsLayout()
        }
        highlightScheduler.schedule(mode)
    }

    private func applyHighlightingNow() {
        let interval = Self.signposter.beginInterval("editor.highlight")
        highlighter.highlight(textStorage)
        gutterView.setNeedsDisplay()
        Self.signposter.endInterval("editor.highlight", interval)
    }

    // MARK: - Keyboard Avoidance

    private func setupKeyboardAvoidance() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    /// Extra bottom padding (in points) added on top of the keyboard overlap.
    /// This gives UITextView's native scroll-to-cursor enough breathing room
    /// so the cursor never sits right at the keyboard edge.
    private static let keyboardBottomPadding: CGFloat = 80

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard window != nil,
              let userInfo = notification.userInfo,
              let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        // How much does the keyboard overlap the bottom of this view (in window coordinates)?
        let viewBottomY = convert(CGPoint(x: 0, y: bounds.maxY), to: nil).y
        let overlap = max(0, viewBottomY - endFrame.minY)
        // Add extra padding so UITextView's native scrolling keeps the cursor
        // comfortably above the keyboard, not right at the edge.
        let totalInset = overlap > 0 ? overlap + Self.keyboardBottomPadding : 0

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7

        UIView.animate(
            withDuration: duration, delay: 0,
            options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curveRaw << 16)]
        ) {
            self.contentInset.bottom = totalInset
            self.verticalScrollIndicatorInsets.bottom = overlap
            if overlap > 0 {
                self.layoutIfNeeded()
                self.scrollSelectionToUpperThird(animated: false)
            }
        }
    }

    func scrollSelectionToUpperThird(animated: Bool) {
        guard let range = selectedTextRange else { return }
        let caret = caretRect(for: range.end)
        let anchorRatio: CGFloat = 0.33
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        guard visibleHeight > 0 else {
            scrollRectToVisible(caret.insetBy(dx: 0, dy: -8), animated: animated)
            return
        }

        let desiredOffsetY = caret.minY - visibleHeight * anchorRatio - textContainerInset.top
        let minOffsetY = -adjustedContentInset.top
        let maxOffsetY = max(minOffsetY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(desiredOffsetY, minOffsetY), maxOffsetY)),
            animated: animated
        )
    }

    private func startJumpHighlightDisplayLinkIfNeeded() {
        jumpHighlightDisplayLink?.invalidate()

        let displayLink = CADisplayLink(target: self, selector: #selector(handleJumpHighlightDisplayLink(_:)))
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        } else {
            displayLink.preferredFramesPerSecond = 30
        }
        displayLink.add(to: .main, forMode: .common)
        jumpHighlightDisplayLink = displayLink
    }

    @objc private func handleJumpHighlightDisplayLink(_ displayLink: CADisplayLink) {
        advanceJumpHighlightAnimation(to: displayLink.timestamp)
    }

    private func advanceJumpHighlightAnimation(to timestamp: CFTimeInterval) {
        guard let startTime = jumpHighlightAnimationStartTime,
              let line = highlighter.jumpHighlightLine else {
            clearJumpHighlight()
            return
        }

        let elapsed = timestamp - startTime
        let opacity = JumpHighlightTimeline.opacity(at: elapsed)
        applyJumpHighlight(line: line, opacity: opacity)

        if elapsed >= JumpHighlightTimeline.totalDuration {
            clearJumpHighlight()
        }
    }

    private func applyJumpHighlight(line: Int?, opacity: CGFloat) {
        let previousLine = highlighter.jumpHighlightLine
        highlighter.refreshJumpHighlight(
            in: textStorage,
            previousLine: previousLine,
            line: line,
            opacity: opacity
        )
        gutterView.setJumpHighlight(line: line, opacity: opacity)
    }

    private func clearJumpHighlight() {
        jumpHighlightAnimationStartTime = nil
        jumpHighlightDisplayLink?.invalidate()
        jumpHighlightDisplayLink = nil
        applyJumpHighlight(line: nil, opacity: 0)
    }

    private func pasteFragmentsFromPasteboard() -> [PasteFragment] {
        let pasteboard = UIPasteboard.general
        var fragments: [PasteFragment] = []

        for item in pasteboard.items {
            if let htmlFragments = htmlFragmentsFromPasteboardItem(item),
               !htmlFragments.isEmpty {
                fragments.append(contentsOf: htmlFragments)
                continue
            }
            if let (data, suggestedName) = imageDataFromPasteboardItem(item) {
                fragments.append(.imageData(data, suggestedFileName: suggestedName))
                continue
            }
            if let (remoteURL, suggestedName) = remoteImageURLFromPasteboardItem(item) {
                fragments.append(.imageRemoteURL(remoteURL, suggestedFileName: suggestedName))
                continue
            }
            if let text = textFromPasteboardItem(item),
               !text.isEmpty,
               !shouldSuppressTextFallback(text, for: item) {
                fragments.append(.text(text))
            }
        }

        if fragments.isEmpty, let string = pasteboard.string, !string.isEmpty {
            fragments.append(.text(string))
        }

        if fragments.isEmpty, let image = pasteboard.image {
            if let data = image.pngData() ?? image.jpegData(compressionQuality: 1.0) {
                fragments.append(.imageData(data, suggestedFileName: nil))
            }
        }

        return mergedAdjacentTextFragments(fragments)
    }

    private func htmlFragmentsFromPasteboardItem(_ item: [String: Any]) -> [PasteFragment]? {
        guard let raw = item[UTType.html.identifier] ?? item["public.html"] else { return nil }
        let html: String?
        if let str = raw as? String {
            html = str
        } else if let data = raw as? Data {
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
        } else {
            html = nil
        }
        guard let html, !html.isEmpty else { return nil }

        let imgPattern = #"(?is)<img\b[^>]*>"#
        guard let imgRegex = try? NSRegularExpression(pattern: imgPattern) else { return nil }

        let nsHTML = html as NSString
        let matches = imgRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return nil }

        var fragments: [PasteFragment] = []
        var cursor = 0
        for match in matches {
            let textRange = NSRange(location: cursor, length: max(0, match.range.location - cursor))
            if textRange.length > 0 {
                let textChunk = nsHTML.substring(with: textRange)
                let normalized = normalizedHTMLText(textChunk)
                if !normalized.isEmpty {
                    fragments.append(.text(normalized))
                }
            }

            let tag = nsHTML.substring(with: match.range)
            if let (remoteURL, suggestedName) = remoteImageFromHTMLTag(tag) {
                fragments.append(.imageRemoteURL(remoteURL, suggestedFileName: suggestedName))
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsHTML.length {
            let tail = nsHTML.substring(from: cursor)
            let normalizedTail = normalizedHTMLText(tail)
            if !normalizedTail.isEmpty {
                fragments.append(.text(normalizedTail))
            }
        }
        return fragments
    }

    private func remoteImageFromHTMLTag(_ tag: String) -> (URL, String?)? {
        let srcPattern = #"(?is)src\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#
        guard let srcRegex = try? NSRegularExpression(pattern: srcPattern) else { return nil }
        let nsTag = tag as NSString
        guard let match = srcRegex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)) else { return nil }

        var src: String?
        for index in 1...3 {
            let range = match.range(at: index)
            if range.location != NSNotFound, range.length > 0 {
                src = nsTag.substring(with: range)
                break
            }
        }
        guard var src else { return nil }
        src = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if src.hasPrefix("//") {
            src = "https:" + src
        }
        guard let url = URL(string: src),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return (url, suggestedFileName(fromRemoteURL: url))
    }

    private func normalizedHTMLText(_ html: String) -> String {
        var value = html
        let breakPatterns = [
            #"(?i)<br\s*/?>"#,
            #"(?i)</p>"#, #"(?i)</div>"#, #"(?i)</li>"#, #"(?i)</h[1-6]>"#, #"(?i)</blockquote>"#
        ]
        for pattern in breakPatterns {
            value = value.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)

        if let data = value.data(using: .utf8),
           let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
           ) {
            value = attributed.string
        }
        value = value.replacingOccurrences(of: "\u{00A0}", with: " ")
        value = value.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergedAdjacentTextFragments(_ fragments: [PasteFragment]) -> [PasteFragment] {
        var merged: [PasteFragment] = []
        var textBuffer = ""

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            merged.append(.text(textBuffer))
            textBuffer = ""
        }

        for fragment in fragments {
            switch fragment {
            case .text(let text):
                textBuffer.append(text)
            case .imageData, .imageRemoteURL:
                flushText()
                merged.append(fragment)
            }
        }
        flushText()
        return merged
    }

    private func textFromPasteboardItem(_ item: [String: Any]) -> String? {
        let textTypeIdentifiers = [
            UTType.utf8PlainText.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier,
            "public.text",
        ]

        for identifier in textTypeIdentifiers {
            guard let raw = item[identifier] else { continue }
            if let text = raw as? String { return text }
            if let data = raw as? Data, let text = String(data: data, encoding: .utf8) { return text }
        }
        return nil
    }

    private func imageDataFromPasteboardItem(_ item: [String: Any]) -> (Data, String?)? {
        var suggestedName: String?
        var fileURLFromItem: URL?
        if let fileURLRaw = item[UTType.fileURL.identifier] {
            if let fileURL = fileURLRaw as? URL {
                fileURLFromItem = fileURL
                suggestedName = fileURL.lastPathComponent
            } else if let fileURLString = fileURLRaw as? String,
                      let fileURL = URL(string: fileURLString) {
                fileURLFromItem = fileURL
                suggestedName = fileURL.lastPathComponent
            } else if let fileURLData = fileURLRaw as? Data,
                      let fileURL = URL(dataRepresentation: fileURLData, relativeTo: nil) {
                fileURLFromItem = fileURL
                suggestedName = fileURL.lastPathComponent
            }
        }

        for type in pasteImageTypes {
            guard let raw = item[type.identifier] else { continue }
            if let data = raw as? Data { return (data, suggestedName) }
            if let image = raw as? UIImage {
                if let data = image.pngData() ?? image.jpegData(compressionQuality: 1.0) {
                    return (data, suggestedName)
                }
            }
        }

        // Some web sources provide only file URL + filename text. Load the image bytes from URL.
        if let fileURLFromItem,
           isLikelyImageFile(url: fileURLFromItem) {
            let accessing = fileURLFromItem.startAccessingSecurityScopedResource()
            defer { if accessing { fileURLFromItem.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: fileURLFromItem),
               UIImage(data: data) != nil {
                return (data, suggestedName)
            }
        }
        return nil
    }

    private func shouldSuppressTextFallback(_ text: String, for item: [String: Any]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid inserting placeholder filename text when clipboard item is image-like.
        if isImageLikePasteboardItem(item) && isLikelyImageFileName(trimmed) {
            return true
        }
        if isImageLikePasteboardItem(item),
           let suggested = suggestedNameFromPasteboardItem(item),
           isLikelyPlaceholderName(trimmed, suggestedName: suggested) {
            return true
        }
        return false
    }

    private func isImageLikePasteboardItem(_ item: [String: Any]) -> Bool {
        for key in item.keys {
            if key == UTType.fileURL.identifier { return true }
            if key == UTType.url.identifier || key == "public.url" {
                if remoteImageURLFromPasteboardItem(item) != nil { return true }
            }
            if let type = UTType(key), type.conforms(to: .image) { return true }
            if key.contains("public.image") || key.contains("png") || key.contains("jpeg") || key.contains("gif") || key.contains("heic") || key.contains("webp") {
                return true
            }
        }
        return false
    }

    private func isLikelyImageFile(url: URL) -> Bool {
        isLikelyImageFileName(url.lastPathComponent)
    }

    private func isLikelyImageFileName(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exts = [".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".webp", ".tiff", ".bmp"]
        return exts.contains { name.hasSuffix($0) }
    }

    private func remoteImageURLFromPasteboardItem(_ item: [String: Any]) -> (URL, String?)? {
        let raw = item[UTType.url.identifier] ?? item["public.url"]
        guard let raw else { return nil }

        let url: URL?
        if let direct = raw as? URL {
            url = direct
        } else if let string = raw as? String {
            url = URL(string: string)
        } else if let data = raw as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
            url = nil
        }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        guard isLikelyRemoteImageURL(url) else { return nil }
        return (url, suggestedNameFromPasteboardItem(item) ?? suggestedFileName(fromRemoteURL: url))
    }

    private func isLikelyRemoteImageURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        let indicators = [".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".webp", ".tiff", ".bmp", "raw=true", "image"]
        return indicators.contains { lower.contains($0) }
    }

    private func suggestedNameFromPasteboardItem(_ item: [String: Any]) -> String? {
        if let raw = item[UTType.fileURL.identifier] {
            if let fileURL = raw as? URL { return fileURL.lastPathComponent }
            if let str = raw as? String, let fileURL = URL(string: str) { return fileURL.lastPathComponent }
            if let data = raw as? Data, let fileURL = URL(dataRepresentation: data, relativeTo: nil) { return fileURL.lastPathComponent }
        }
        if let raw = item[UTType.url.identifier] ?? item["public.url"] {
            let remoteURL: URL?
            if let direct = raw as? URL {
                remoteURL = direct
            } else if let str = raw as? String {
                remoteURL = URL(string: str)
            } else if let data = raw as? Data {
                remoteURL = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                remoteURL = nil
            }
            guard let remoteURL else { return nil }
            let last = suggestedFileName(fromRemoteURL: remoteURL) ?? remoteURL.lastPathComponent
            if !last.isEmpty { return last }
            if let q = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.lowercased().contains("filename") })?.value,
               !q.isEmpty {
                return q
            }
        }
        return nil
    }

    private func suggestedFileName(fromRemoteURL url: URL) -> String? {
        let direct = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty, direct != "/" {
            return direct
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryItems = components.queryItems ?? []
        let candidates = ["filename", "file", "name", "download", "url", "src"]

        for key in candidates {
            guard let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
                  !value.isEmpty else { continue }

            if let nestedURL = URL(string: value.removingPercentEncoding ?? value) {
                let nestedName = nestedURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !nestedName.isEmpty, nestedName != "/" {
                    return nestedName
                }
            }

            let raw = URL(fileURLWithPath: value).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, raw != "/" {
                return raw
            }
        }
        return nil
    }

    private func isLikelyPlaceholderName(_ text: String, suggestedName: String) -> Bool {
        let normalizedText = text.lowercased()
        let suggestedStem = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent.lowercased()
        if normalizedText == suggestedStem { return true }
        if let prefix = suggestedStem.split(separator: "-").first.map(String.init),
           !prefix.isEmpty,
           normalizedText == prefix {
            return true
        }
        if suggestedStem.hasPrefix(normalizedText), normalizedText.count >= 6 {
            return true
        }
        return false
    }

    // MARK: - Find (programmatic trigger)

    func presentFind(showingReplace: Bool = false) {
        findInteraction?.presentFindNavigator(showingReplace: showingReplace)
    }

    // MARK: - Completion

    /// Which kind of completion is currently active.
    private enum ActiveCompletionKind {
        case hash, parameter, value(isQuoted: Bool), atPrefix, angleBracket
    }
    private var activeCompletionKind: ActiveCompletionKind?

    /// Update available font families for value completion.
    func updateFontFamilies(_ families: [String]) {
        completionEngine.fontFamilies = families
    }

    /// Update image file paths (relative to project root) for path completion.
    func updateImageFiles(_ files: [String]) {
        completionEngine.imageFiles = files
    }

    /// Update BibTeX citation keys for reference completion.
    func updateBibEntries(_ entries: [(key: String, type: String)]) {
        completionEngine.bibEntries = entries
    }

    /// Update labels from other project files.
    func updateExternalLabels(_ labels: [(name: String, kind: String)]) {
        completionEngine.externalLabels = labels
    }

    /// Update available package specs for import completion.
    func updatePackageSpecs(_ specs: [String]) {
        completionEngine.packageSpecs = specs
    }

    func updateCompletion() {
        let cursorOffset = selectedRange.location
        guard selectedRange.length == 0,
              let result = completionEngine.completions(for: text, cursorOffset: cursorOffset) else {
            dismissCompletion()
            return
        }

        let prefix: String
        let items: [CompletionItem]
        let kind: ActiveCompletionKind

        switch result {
        case .hashPrefix(let p, let i):
            prefix = p; items = i; kind = .hash
        case .parameter(let p, let i):
            prefix = p; items = i; kind = .parameter
        case .value(let p, let isQuoted, let i):
            prefix = p; items = i; kind = .value(isQuoted: isQuoted)
        case .atPrefix(let p, let i):
            prefix = p; items = i; kind = .atPrefix
        case .angleBracket(let p, let i):
            prefix = p; items = i; kind = .angleBracket
        }

        completionPrefix = prefix
        activeCompletionKind = kind
        let popup = ensureCompletionPopup()
        popup.update(items: items)
        positionCompletionPopup(popup)
        popup.isHidden = false
    }

    func dismissCompletion() {
        completionPopup?.isHidden = true
        completionPrefix = nil
        activeCompletionKind = nil
    }

    func acceptCompletion(_ item: CompletionItem) {
        guard let prefix = completionPrefix, let kind = activeCompletionKind else { return }
        guard let rawInsertText = item.insertText else { return }
        let prefixLen = (prefix as NSString).length

        let insertText: String

        switch kind {
        case .value(let isQuoted):
            if isQuoted {
                insertText = rawInsertText
            } else {
                insertText = "\"" + rawInsertText + "\""
            }
        case .parameter:
            insertText = rawInsertText  // e.g. "size: "
        case .hash:
            insertText = "#" + rawInsertText  // e.g. "#text()"
        case .atPrefix:
            insertText = "@" + rawInsertText  // e.g. "@fig:diagram"
        case .angleBracket:
            insertText = rawInsertText  // just the key, `<` already typed
        }

        let insertLen = (insertText as NSString).length

        let replaceStart = selectedRange.location - prefixLen
        guard replaceStart >= 0 else { return }
        let replaceRange = NSRange(location: replaceStart, length: prefixLen)

        // Undo support
        let originalContent = (textStorage.string as NSString).substring(with: replaceRange)
        let insertedRange = NSRange(location: replaceStart, length: insertLen)
        undoManager?.registerUndo(withTarget: self) { tv in
            tv.textStorage.replaceCharacters(in: insertedRange, with: originalContent)
            tv.selectedRange = NSRange(location: replaceStart + prefixLen, length: 0)
            tv.delegate?.textViewDidChange?(tv)
        }
        undoManager?.setActionName(L10n.tr("action.typing"))

        textStorage.replaceCharacters(in: replaceRange, with: insertText)

        switch kind {
        case .value, .parameter, .atPrefix, .angleBracket:
            selectedRange = NSRange(location: replaceStart + insertLen, length: 0)
        case .hash:
            // Place cursor intelligently: inside () or [] or after text
            var cursorPos = replaceStart + insertLen
            let insertNS = insertText as NSString
            for i in 0..<insertNS.length {
                let ch = insertNS.character(at: i)
                if ch == 0x28 || ch == 0x5B || ch == 0x22 { // ( [ "
                    cursorPos = replaceStart + i + 1
                    break
                }
            }
            selectedRange = NSRange(location: cursorPos, length: 0)
        }

        dismissCompletion()
        delegate?.textViewDidChange?(self)
        scheduleHighlighting(.immediate, textChanged: true)
    }

    private func ensureCompletionPopup() -> CompletionPopupView {
        if let popup = completionPopup { return popup }
        let popup = CompletionPopupView()
        popup.onSelect = { [weak self] item in
            self?.acceptCompletion(item)
        }
        // Add to superview so it can overflow the text view bounds
        if let superview {
            superview.addSubview(popup)
        } else {
            addSubview(popup)
        }
        completionPopup = popup
        return popup
    }

    private func positionCompletionPopup(_ popup: CompletionPopupView) {
        guard let cursorRange = selectedTextRange else { return }
        let caretRect = self.caretRect(for: cursorRange.start)
        let size = popup.intrinsicContentSize

        // Convert caret rect to the popup's superview coordinate space
        let targetView = popup.superview ?? self
        let caretInTarget = convert(caretRect, to: targetView)

        let margin: CGFloat = 4
        var x = caretInTarget.minX
        var y = caretInTarget.minY - size.height - margin  // prefer above

        // If no room above, show below
        if y < targetView.safeAreaInsets.top {
            y = caretInTarget.maxY + margin
        }

        // Clamp horizontal — guard against popup wider than available space
        let maxX = targetView.bounds.width - size.width - 8
        if maxX >= 8 {
            x = min(max(8, x), maxX)
        } else {
            // Popup wider than view: pin to leading edge
            x = 8
        }

        popup.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TypstTextView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow the completion-dismiss tap to coexist with the text view's own gestures
        if gestureRecognizer === completionDismissTap { return true }
        return false
    }
}
