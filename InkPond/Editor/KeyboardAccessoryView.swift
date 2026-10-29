//
//  KeyboardAccessoryView.swift
//  InkPond
//

import UIKit
import Foundation
import GameController

final class KeyboardAccessoryView: UIInputView, UIScrollViewDelegate {
    private final class NotificationObserverToken: @unchecked Sendable {
        nonisolated(unsafe) let token: NSObjectProtocol

        init(_ token: NSObjectProtocol) {
            self.token = token
        }

        nonisolated func remove() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private final class LayoutReportingStack: UIStackView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    private struct SymbolItem {
        let label: String
        let insert: String
    }

    private weak var textView: UITextView?
    private var chromeAppearanceRegistration: (any UITraitChangeRegistration)?
    var onPreferredAccessorySizeChanged: ((CGSize) -> Void)?
    var onPhotoButtonTapped: (() -> Void)?
    var onSnippetButtonTapped: (() -> Void)?
    private let separator = UIView()
    private lazy var snippetButton = makeButton(systemImage: "text.badge.plus") { [weak self] in
        guard self?.textView?.isEditable == true else { return }
        InteractionFeedback.impact(.light)
        self?.onSnippetButtonTapped?()
    }
    private lazy var photoButton = makeButton(systemImage: "photo") { [weak self] in
        InteractionFeedback.impact(.light)
        self?.onPhotoButtonTapped?()
    }
    private lazy var undoButton = makeButton(systemImage: "arrow.uturn.backward") { [weak self] in
        InteractionFeedback.impact(.light)
        self?.textView?.undoManager?.undo()
    }
    private lazy var redoButton = makeButton(systemImage: "arrow.uturn.forward") { [weak self] in
        InteractionFeedback.impact(.light)
        self?.textView?.undoManager?.redo()
    }
    private lazy var dismissKeyboardButton = makeButton(systemImage: "keyboard.chevron.compact.down") { [weak self] in
        InteractionFeedback.impact(.light)
        _ = self?.textView?.resignFirstResponder()
    }
    private lazy var rightStack: UIStackView = {
        let stack = LayoutReportingStack(arrangedSubviews: [snippetButton, photoButton, undoButton, redoButton, dismissKeyboardButton])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.onLayout = { [weak self] in self?.validateRealizedControls() }
        return stack
    }()
    private var workspaceChromeBackgroundColor: UIColor = .secondarySystemGroupedBackground
    private var hardwareKeyboardObservers: [NotificationObserverToken] = []
    private static let barHeight: CGFloat = 60
    private let visualContent = UIView()
    private var visualLeading: NSLayoutConstraint!
    private var visualWidth: NSLayoutConstraint!
    private var targetButtons: [UIButton] = []
    private var buttonMinima: [NSLayoutConstraint] = []
    private var symbolHeight: NSLayoutConstraint!
    private var symbolStack: UIStackView!
    private var symbolScroll: UIScrollView!
    private var ordinaryContentConstraints: [NSLayoutConstraint] = []
    private var adaptedInsets: [NSLayoutConstraint] = []
    private var adapted = false
    private weak var sampledSceneIdentity: AnyObject?
    private var ordinaryInsetValues: [CGFloat] = []
    private var ordinaryActionHost: UIView!
    private var adaptedTrailing: NSLayoutConstraint?
    private var adaptedHeight: NSLayoutConstraint?
    private var adaptedWidth: NSLayoutConstraint?
    private weak var glassView: UIVisualEffectView?
    private var preparedOwningWidth: CGFloat = 0
    private var realizedProtectedRegions: [CGRect]?
    private var hasFeasibleRequestedGeometry = true
    private var samplePending = false
    // Opt-in Release diagnostics: geometry only, no visible UI or telemetry.
    static let geometryDiagnosticsEnabled: Bool = {
        if ProcessInfo.processInfo.arguments.contains("UITEST_ACCESSORY_GEOMETRY") { return true }
        let value = Bundle.main.object(forInfoDictionaryKey: "INKPOND_ACCESSORY_GEOMETRY")
        if let enabled = value as? Bool { return enabled }
        return (value as? String)?.uppercased() == "YES"
    }()
    private var geometryDiagnosticKeys: Set<String> = []
    private var geometryDiagnosticOrder: [String] = []
    private var lastChromeColorDiagnostic = "chromeColor pending"
    private var lastSourceLayoutDiagnostic = "sourceLayout pending"
    private var lastUnderlapDiagnostic = "underlap pending"
    private var lastSampleDiagnostic = "sample pending"
    private var lastRealizedDiagnostic = "realized pending"

    private func reportGeometry(_ message: @autoclosure () -> String) {
        guard Self.geometryDiagnosticsEnabled else { return }
        recordGeometryDiagnostic(message())
    }

    // Internal ingestion seam for diagnostic regression tests; callers gate opt-in.
    func recordGeometryDiagnostic(_ value: String) {
        let isNewRecord = !geometryDiagnosticKeys.contains(value)
        if isNewRecord {
            // Bound deduplication history, not the lifetime of current diagnostics.
            if geometryDiagnosticOrder.count == 128 {
                geometryDiagnosticKeys.remove(geometryDiagnosticOrder.removeFirst())
            }
            geometryDiagnosticOrder.append(value)
            geometryDiagnosticKeys.insert(value)
        }
        if value.hasPrefix("chromeColor") {
            lastChromeColorDiagnostic = String(value.prefix(2_000))
        } else if value.hasPrefix("sourceLayout") {
            lastSourceLayoutDiagnostic = String(value.prefix(8_000))
        } else if value.hasPrefix("underlap") {
            lastUnderlapDiagnostic = String(value.prefix(5_000))
        } else if value.hasPrefix("sample") {
            lastSampleDiagnostic = String(value.prefix(5_000))
        } else if value.hasPrefix("realized") {
            lastRealizedDiagnostic = String(value.prefix(14_000))
        }
        // Shared-simulator process logs may omit NSLog. Expose the latest pair
        // through the existing editor AX node; never touch its hint when off.
        let hint = "[AccessoryFoldGeometry] records=\(geometryDiagnosticKeys.count)/128\nSAMPLE: \(lastSampleDiagnostic)\nREALIZED: \(lastRealizedDiagnostic)\nUNDERLAP: \(lastUnderlapDiagnostic)\nSOURCE_LAYOUT: \(lastSourceLayoutDiagnostic)\nCHROME_COLOR: \(lastChromeColorDiagnostic)"
        if let editor = textView as? TypstTextView {
            if editor.accessoryGeometryDiagnosticHint != hint { editor.accessoryGeometryDiagnosticHint = hint }
        } else if textView?.accessibilityHint != hint {
            textView?.accessibilityHint = hint
        }
        guard isNewRecord else { return }
        NSLog("[AccessoryFoldGeometry] %@", value)
    }

    /// Publish the owning extent even when the realized host is still stale or
    /// geometry is infeasible. Height-only notifications strand preferred width
    /// after a rotation that leaves protection padding unchanged.
    func updateControllerHostingWidth(_ width: CGFloat) {
        guard adapted, width.isFinite, width > 0 else { return }
        let changed = preparedOwningWidth != width
        preparedOwningWidth = width
        updateAdaptedWidth(width)
        if changed {
            onPreferredAccessorySizeChanged?(CGSize(width: width, height: Self.barHeight + bottomProtectionPadding))
        }
    }
    private(set) var bottomProtectionPadding: CGFloat = 0

    func prepareControllerHosting(sceneIdentity: AnyObject, owningWidth: CGFloat) {
        guard owningWidth.isFinite, owningWidth > 0 else { return }
        // A validated division scene must never expose fallback-sized controls
        // while UIKit has yet to assign the input controller root a usable size.
        applyValidatedGeometry(sceneIdentity: sceneIdentity, hasDivision: true,
                               result: nil, protectedRegions: [])
        updateControllerHostingWidth(owningWidth)
    }

    private func updateAdaptedWidth(_ width: CGFloat) {
        guard adapted, width.isFinite, width > 0 else { return }
        if let constraint = adaptedWidth {
            if constraint.constant != width { constraint.constant = width; setNeedsLayout() }
        } else {
            let constraint = widthAnchor.constraint(equalToConstant: width)
            constraint.identifier = "KeyboardAccessory.adaptedWidth"
            adaptedWidth = constraint
            constraint.isActive = true
        }
    }

    private func fittingWidth(_ requested: CGFloat) -> CGFloat {
        requested > 0 && requested.isFinite ? requested : preparedOwningWidth
    }

    func requestGeometrySample() {
        guard !samplePending else { return }
        samplePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.samplePending = false
            self.sampleGeometry()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        requestGeometrySample()
    }

    func reportSourceUnderlapGeometry(_ message: @autoclosure () -> String) {
        guard Self.geometryDiagnosticsEnabled else { return }
        reportGeometry("underlap " + message())
    }

    func reportSourceLayoutGeometry(_ message: @autoclosure () -> String) {
        guard Self.geometryDiagnosticsEnabled else { return }
        reportGeometry("sourceLayout " + message())
    }

    private func sampleGeometry() {
        guard let owner = window, let scene = owner.windowScene,
              let editorWindow = textView?.window,
              editorWindow.windowScene === scene, editorWindow.screen === owner.screen,
              owner.bounds.width.isFinite, owner.bounds.width > 0 else {
            reportGeometry("sample guardFailed ownerPresent=\(window != nil) ownerScenePresent=\(window?.windowScene != nil) editorWindowPresent=\(textView?.window != nil) editorScenePresent=\(textView?.window?.windowScene != nil) sameScene=\(window?.windowScene === textView?.window?.windowScene) sameScreen=\(window?.screen === textView?.window?.screen) ownerBounds=\(String(describing: window?.bounds)) actualFrame=\(frame) actualBounds=\(bounds) adapted=\(adapted)")
            return
        }
        if adapted {
            updateControllerHostingWidth(owner.bounds.width)
        }
        guard bounds.width > 0, bounds.height > 0 else {
            reportGeometry("sample guardFailed unusableBounds ownerBounds=\(owner.bounds) actualFrame=\(frame) actualBounds=\(bounds) requested=\(CGSize(width: preparedOwningWidth, height: Self.barHeight + bottomProtectionPadding))")
            return
        }
        (textView as? TypstTextView)?.accessoryAttachmentGeometryDidChange()
        var protected: [CGRect] = []
        var measuredRegions: [String] = []
        var hasDivision = false
        #if compiler(>=6.2) && INKPOND_DUO_SDK
        if #available(iOS 27.1, *) {
            let divisions = owner.reservedRegions(kind: .division, options: [])
            hasDivision = !divisions.isEmpty
            if Self.geometryDiagnosticsEnabled {
                measuredRegions = divisions.map { "frame=\($0.frame) margins=\($0.margins) active=\($0.isActive)" }
            }
            for region in divisions where region.isActive {
                let m = region.margins
                let expanded = CGRect(x: region.frame.minX - m.left, y: region.frame.minY - m.top,
                                      width: region.frame.width + m.left + m.right,
                                      height: region.frame.height + m.top + m.bottom)
                protected.append(owner.convert(expanded, to: self))
            }
        }
        #endif
        // The actual native host bottom is invariant under intrinsic-height changes.
        let result = KeyboardAccessoryGeometry.solve(width: bounds.width, bottom: bounds.maxY,
            regions: protected, scale: owner.screen.scale,
            availableTop: owner.convert(owner.bounds, to: self).minY)
        applyValidatedGeometry(sceneIdentity: scene, hasDivision: hasDivision, result: result, protectedRegions: protected)
        var chromeDiagnostic = ""
        if Self.geometryDiagnosticsEnabled, let editor = textView {
            var chrome: [String] = []
            var ancestor: UIView? = self
            while let current = ancestor, chrome.count < 10 {
                let color = current.backgroundColor.map { String(describing: $0.resolvedColor(with: current.traitCollection)) } ?? "nil"
                chrome.append("class=\(type(of: current)) background=\(color) opaque=\(current.isOpaque)")
                ancestor = current.superview
            }
            chromeDiagnostic = " editorInWindow=\(editor.convert(editor.bounds, to: editorWindow)) accessoryInEditorWindow=\(convert(bounds, to: editorWindow)) chrome=\(chrome)"
        }
        reportGeometry("sample ownerClass=\(type(of: owner)) ownerFrame=\(owner.frame) ownerBounds=\(owner.bounds) ownerConverted=\(owner.convert(owner.bounds, to: self)) editorWindowBounds=\(editorWindow.bounds) actualFrame=\(frame) actualBounds=\(bounds) requested=\(CGSize(width: preparedOwningWidth, height: Self.barHeight + bottomProtectionPadding)) scale=\(owner.screen.scale) division=\(hasDivision) regions=\(measuredRegions) protected=\(protected) solution=\(String(describing: result))\(chromeDiagnostic)")
    }

    /// Only call after validating an attached owning/editor window pair. Detached
    /// samples must never replace a known layout. Factored for view-level tests.
    func applyValidatedGeometry(sceneIdentity: AnyObject, hasDivision: Bool,
                                result: KeyboardAccessoryGeometry.Solution?, protectedRegions: [CGRect]? = nil) {
        realizedProtectedRegions = protectedRegions
        hasFeasibleRequestedGeometry = result != nil
        if sampledSceneIdentity !== sceneIdentity {
            restoreOrdinaryControls()
            sampledSceneIdentity = sceneIdentity
        }
        // Keep 44-point controls sticky within the same division-capable scene,
        // including flat-open transitions; never carry adaptation to another scene.
        if hasDivision { enableAdaptedControls() }
        let usable = result != nil
        visualContent.isHidden = !usable
        visualContent.isUserInteractionEnabled = usable
        visualContent.accessibilityElementsHidden = !usable
        guard let result else { return }
        let padding = adapted ? result.padding : 0
        let span = adapted ? result.span : CGRect(x: 0, y: 0, width: bounds.width, height: 60)
        if visualLeading.constant != span.minX || visualWidth.constant != span.width {
            visualLeading.constant = span.minX
            visualWidth.constant = span.width
            visualContent.setNeedsLayout()
            symbolScroll.setNeedsLayout()
            symbolStack.setNeedsLayout()
            rightStack.setNeedsLayout()
            setNeedsLayout()
        }
        if bottomProtectionPadding != padding {
            bottomProtectionPadding = padding
            adaptedHeight?.constant = Self.barHeight + padding
            invalidateIntrinsicContentSize()
            onPreferredAccessorySizeChanged?(CGSize(width: preparedOwningWidth > 0 ? preparedOwningWidth : bounds.width, height: Self.barHeight + padding))
            setNeedsLayout()
        }
        validateRealizedControls()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        validateRealizedControls()
    }

    private func validateRealizedControls() {
        guard adapted, let protected = realizedProtectedRegions else {
            reportGeometry("realized guardFailed adapted=\(adapted) regionsPresent=\(realizedProtectedRegions != nil) actualFrame=\(frame) actualBounds=\(bounds)")
            return
        }
        var effectiveClip = bounds
        var ancestor = superview
        var measuredAncestors: [String] = []
        while let current = ancestor {
            // UIView hit testing requires every ancestor's bounds, even when the
            // ancestor permits visual overflow through clipsToBounds=false.
            let converted = current.convert(current.bounds, to: self)
            effectiveClip = effectiveClip.intersection(converted)
            if Self.geometryDiagnosticsEnabled {
                measuredAncestors.append("class=\(type(of: current)) frame=\(current.frame) bounds=\(current.bounds) converted=\(converted) cumulativeClip=\(effectiveClip) clipsToBounds=\(current.clipsToBounds) hidden=\(current.isHidden) interaction=\(current.isUserInteractionEnabled)")
            }
            ancestor = current.superview
        }
        effectiveClip = effectiveClip.intersection(visualContent.convert(visualContent.bounds, to: self))
        var targets: [(frame: CGRect, visible: CGRect)] = []
        var unsafeVerticalOrFold = false
        var measuredTargets: [String] = []
        func visit(_ view: UIView, clip: CGRect) {
            guard !view.isHidden else { return }
            let frame = view.convert(view.bounds, to: self)
            let nextClip = view.clipsToBounds ? clip.intersection(frame) : clip
            if let button = view as? UIButton {
                let visible = frame.intersection(nextClip)
                if Self.geometryDiagnosticsEnabled { measuredTargets.append("class=\(type(of: button)) localFrame=\(button.frame) localBounds=\(button.bounds) convertedFrame=\(frame) visible=\(visible)") }
                let visibleNonempty = !visible.isNull && !visible.isEmpty
                let full = visibleNonempty && visible.width >= 44 && visible.height >= 44 &&
                    frame.width >= 44 && frame.height >= 44
                button.isUserInteractionEnabled = full
                button.accessibilityElementsHidden = !full
                button.isAccessibilityElement = full
                if visibleNonempty {
                    if visible.height < 44 || frame.height < 44 || protected.contains(where: { $0.intersects(visible) }) {
                        unsafeVerticalOrFold = true
                    }
                    if full { targets.append((frame, visible)) }
                }
            }
            for child in view.subviews { visit(child, clip: nextClip) }
        }
        // Ignore our own fail-closed hidden state while measuring realized layout.
        for child in visualContent.subviews { visit(child, clip: effectiveClip) }
        let safe = hasFeasibleRequestedGeometry && !unsafeVerticalOrFold &&
            Self.realizedTargetsAreSafe(targets, protectedRegions: protected)
        reportGeometry("realized actualFrame=\(frame) actualBounds=\(bounds) requested=\(CGSize(width: preparedOwningWidth, height: Self.barHeight + bottomProtectionPadding)) ancestors=\(measuredAncestors) visualFrame=\(visualContent.frame) visualBounds=\(visualContent.bounds) clip=\(effectiveClip) feasible=\(hasFeasibleRequestedGeometry) unsafe=\(unsafeVerticalOrFold) safe=\(safe) protected=\(protected) targets=\(measuredTargets)")
        visualContent.isHidden = !safe
        visualContent.isUserInteractionEnabled = safe
        visualContent.accessibilityElementsHidden = !safe
    }

    static func realizedTargetsAreSafe(_ targets: [(frame: CGRect, visible: CGRect)],
                                      protectedRegions: [CGRect]) -> Bool {
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { target in
            target.frame.width >= 44 && target.frame.height >= 44 &&
            target.visible.width >= 44 && target.visible.height >= 44 &&
            !protectedRegions.contains { $0.intersects(target.visible) }
        }
    }

    private func enableAdaptedControls() {
        guard !adapted else { return }
        adapted = true
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        updateAdaptedWidth(preparedOwningWidth > 0 ? preparedOwningWidth : bounds.width)
        // Express the adapted input-view size through public Auto Layout as well
        // as fitting. UIKit can otherwise retain its initial accessory host height
        // after a deferred reserved-region sample changes the requested size.
        let height = heightAnchor.constraint(equalToConstant: Self.barHeight + bottomProtectionPadding)
        height.identifier = "KeyboardAccessory.adaptedHeight"
        adaptedHeight = height
        height.isActive = true
        autoresizingMask.insert(.flexibleHeight)
        buttonMinima.forEach { $0.constant = 44 }
        ordinaryInsetValues = adaptedInsets.map(\.constant)
        adaptedInsets.forEach { $0.constant = 0 }
        glassView?.layer.cornerRadius = 0
        symbolHeight.constant = 44
        NSLayoutConstraint.deactivate(ordinaryContentConstraints)
        separator.isHidden = true
        rightStack.removeFromSuperview()
        symbolStack.addArrangedSubview(rightStack)
        ordinaryActionHost = symbolScroll.superview
        adaptedTrailing = symbolScroll.trailingAnchor.constraint(equalTo: ordinaryActionHost.trailingAnchor)
        adaptedTrailing?.isActive = true
        // Constant changes on descendants do not reliably dirty an already laid
        // out accessory root (notably when UIKit retains its native host size).
        // Request one deferred root pass only when the presentation changes.
        visualContent.setNeedsLayout()
        symbolScroll.setNeedsLayout()
        symbolStack.setNeedsLayout()
        rightStack.setNeedsLayout()
        setNeedsLayout()
        updateActionButtonsVisibility()
    }

    private func restoreOrdinaryControls() {
        guard adapted else { return }
        adaptedTrailing?.isActive = false
        adaptedHeight?.isActive = false
        adaptedHeight = nil
        adaptedWidth?.isActive = false
        adaptedWidth = nil
        translatesAutoresizingMaskIntoConstraints = true
        symbolStack.removeArrangedSubview(rightStack)
        rightStack.removeFromSuperview()
        ordinaryActionHost.addSubview(rightStack)
        buttonMinima.forEach { $0.constant = 36 }
        for (constraint, value) in zip(adaptedInsets, ordinaryInsetValues) { constraint.constant = value }
        symbolHeight.constant = 32
        glassView?.layer.cornerRadius = 25
        separator.isHidden = false
        NSLayoutConstraint.activate(ordinaryContentConstraints)
        for button in targetButtons {
            button.isUserInteractionEnabled = true
            button.accessibilityElementsHidden = false
            button.isAccessibilityElement = true
        }
        adapted = false
        preparedOwningWidth = 0
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        visualLeading.constant = 0
        visualWidth.constant = bounds.width
        if bottomProtectionPadding != 0 {
            bottomProtectionPadding = 0
            invalidateIntrinsicContentSize()
            onPreferredAccessorySizeChanged?(CGSize(width: bounds.width, height: Self.barHeight))
        }
        visualContent.setNeedsLayout()
        symbolScroll.setNeedsLayout()
        symbolStack.setNeedsLayout()
        rightStack.setNeedsLayout()
        setNeedsLayout()
        updateActionButtonsVisibility()
    }

    private let symbols: [SymbolItem] = [
        SymbolItem(label: "⇥", insert: "  "),
        SymbolItem(label: "#", insert: "#"),
        SymbolItem(label: "$", insert: "$"),
        SymbolItem(label: "=", insert: "="),
        SymbolItem(label: "*", insert: "*"),
        SymbolItem(label: "_", insert: "_"),
        SymbolItem(label: "{", insert: "{"),
        SymbolItem(label: "}", insert: "}"),
        SymbolItem(label: "[", insert: "["),
        SymbolItem(label: "]", insert: "]"),
        SymbolItem(label: "(", insert: "("),
        SymbolItem(label: ")", insert: ")"),
        SymbolItem(label: "<", insert: "<"),
        SymbolItem(label: ">", insert: ">"),
        SymbolItem(label: "@", insert: "@"),
        SymbolItem(label: "/", insert: "/"),
    ]

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight), inputViewStyle: .default)
        autoresizingMask = [.flexibleWidth]
        configureActionButtons()
        setupViews()
        chromeAppearanceRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (accessory: KeyboardAccessoryView, _: UITraitCollection) in
            accessory.applyWorkspaceChromeBackground()
        }
        startObservingHardwareKeyboard()
        updateActionButtonsVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in hardwareKeyboardObservers {
            observer.remove()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight + bottomProtectionPadding)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: Self.barHeight + bottomProtectionPadding)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        guard adapted else { return super.systemLayoutSizeFitting(targetSize) }
        return CGSize(width: fittingWidth(targetSize.width), height: Self.barHeight + bottomProtectionPadding)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                         withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                         verticalFittingPriority: UILayoutPriority) -> CGSize {
        guard adapted else {
            return super.systemLayoutSizeFitting(targetSize,
                withHorizontalFittingPriority: horizontalFittingPriority,
                verticalFittingPriority: verticalFittingPriority)
        }
        return CGSize(width: fittingWidth(targetSize.width), height: Self.barHeight + bottomProtectionPadding)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { (textView as? TypstTextView)?.accessoryAttachmentGeometryDidChange() }
        requestGeometrySample()
        #if DEBUG
        (textView as? TypstTextView)?.scheduleKeyboardGeometryReport()
        #endif
        applyWorkspaceChromeBackground()
        updateActionButtonsVisibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        validateRealizedControls()
        if !adapted { visualWidth.constant = bounds.width }
        requestGeometrySample()
        #if DEBUG
        (textView as? TypstTextView)?.scheduleKeyboardGeometryReport()
        #endif
        updateActionButtonsVisibility()
    }

    private var hasHardwareKeyboard: Bool {
        GCKeyboard.coalesced != nil
    }

    private func configureActionButtons() {
        separator.backgroundColor = .separator.withAlphaComponent(0.3)
        separator.translatesAutoresizingMaskIntoConstraints = false

        snippetButton.accessibilityLabel = L10n.a11yKeyboardSnippetLabel
        snippetButton.accessibilityHint = L10n.a11yKeyboardSnippetHint
        photoButton.accessibilityLabel = L10n.a11yKeyboardPhotoLabel
        photoButton.accessibilityHint = L10n.a11yKeyboardPhotoHint
        undoButton.accessibilityLabel = L10n.a11yKeyboardUndoLabel
        undoButton.accessibilityHint = L10n.a11yKeyboardUndoHint
        redoButton.accessibilityLabel = L10n.a11yKeyboardRedoLabel
        redoButton.accessibilityHint = L10n.a11yKeyboardRedoHint
        dismissKeyboardButton.accessibilityLabel = L10n.tr("Done")
    }

    private func startObservingHardwareKeyboard() {
        hardwareKeyboardObservers = [
            NotificationObserverToken(NotificationCenter.default.addObserver(
                forName: Notification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateActionButtonsVisibility()
                }
            }),
            NotificationObserverToken(NotificationCenter.default.addObserver(
                forName: Notification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateActionButtonsVisibility()
                }
            })
        ]
    }

    private func updateActionButtonsVisibility() {
        // Give the symbol strip usable space as the keyboard/accessory resizes.
        if adapted {
            undoButton.isHidden = false
            redoButton.isHidden = false
            dismissKeyboardButton.isHidden = hasHardwareKeyboard
            return
        }
        let width = bounds.width > 0 ? bounds.width : (textView?.bounds.width ?? 0)
        let showsUndoRedo = width >= 400 || (hasHardwareKeyboard && width >= 340)
        undoButton.isHidden = !showsUndoRedo
        redoButton.isHidden = !showsUndoRedo
        dismissKeyboardButton.isHidden = hasHardwareKeyboard || width < 300
    }

    private func setupViews() {
        visualContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualContent)
        visualLeading = visualContent.leadingAnchor.constraint(equalTo: leadingAnchor)
        visualWidth = visualContent.widthAnchor.constraint(equalToConstant: bounds.width)
        NSLayoutConstraint.activate([visualLeading, visualWidth,
            visualContent.topAnchor.constraint(equalTo: topAnchor),
            visualContent.heightAnchor.constraint(equalToConstant: 60)])
        if #available(iOS 26, *) {
            setupGlassLayout()
        } else {
            setupLegacyLayout()
        }
    }

    // MARK: - iOS 26+ Floating Glass Bar

    @available(iOS 26, *)
    private func setupGlassLayout() {
        applyWorkspaceChromeBackground()

        // Glass container
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glassView = glass
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 25
        glass.layer.cornerCurve = .continuous
        visualContent.addSubview(glass)

        // Build content inside the glass
        let (scrollView, rightStack, separator) = buildContent()

        glass.contentView.addSubview(scrollView)
        glass.contentView.addSubview(separator)
        glass.contentView.addSubview(rightStack)

        let constraints = [
            glass.leadingAnchor.constraint(equalTo: visualContent.leadingAnchor, constant: 10),
            glass.trailingAnchor.constraint(equalTo: visualContent.trailingAnchor, constant: -10),
            glass.topAnchor.constraint(equalTo: visualContent.topAnchor, constant: 4),
            glass.heightAnchor.constraint(equalToConstant: 52),

            // Scroll view constraints (always active)
            scrollView.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
            scrollView.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            rightStack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            rightStack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 24),
            separator.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -4),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -4),
        ]

        adaptedInsets = constraints.filter {
            (($0.firstItem as? UIView) !== rightStack && ($0.firstItem as? UIView) !== separator) &&
            ($0.firstAttribute == .leading || $0.firstAttribute == .trailing)
        }
        ordinaryContentConstraints = constraints.filter {
            ($0.firstItem as? UIView) === rightStack || ($0.firstItem as? UIView) === separator ||
            (($0.firstItem as? UIView) === scrollView && $0.firstAttribute == .trailing)
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Pre-iOS 26 Layout

    private func setupLegacyLayout() {
        applyWorkspaceChromeBackground()

        let (scrollView, rightStack, separator) = buildContent()

        visualContent.addSubview(scrollView)
        visualContent.addSubview(separator)
        visualContent.addSubview(rightStack)

        let constraints = [
            scrollView.leadingAnchor.constraint(equalTo: visualContent.leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: visualContent.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualContent.bottomAnchor),
            rightStack.trailingAnchor.constraint(equalTo: visualContent.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: visualContent.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 28),
            separator.centerYAnchor.constraint(equalTo: visualContent.centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -8),
        ]

        adaptedInsets = constraints.filter {
            (($0.firstItem as? UIView) !== rightStack && ($0.firstItem as? UIView) !== separator) &&
            ($0.firstAttribute == .leading || $0.firstAttribute == .trailing)
        }
        ordinaryContentConstraints = constraints.filter {
            ($0.firstItem as? UIView) === rightStack || ($0.firstItem as? UIView) === separator ||
            (($0.firstItem as? UIView) === scrollView && $0.firstAttribute == .trailing)
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Shared Content

    private func buildContent() -> (scrollView: UIScrollView, rightStack: UIStackView, separator: UIView) {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = LayoutReportingStack()
        stackView.onLayout = { [weak self] in self?.validateRealizedControls() }
        stackView.axis = .horizontal
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for symbol in symbols {
            let button = makeButton(title: symbol.label) { [weak self] in
                guard let textView = self?.textView, textView.isEditable else { return }
                InteractionFeedback.selection()
                textView.insertText(symbol.insert)
            }
            button.accessibilityLabel = L10n.keyboardSymbolAccessibilityLabel(for: symbol.label)
            button.accessibilityHint = L10n.a11yKeyboardInsertHint
            stackView.addArrangedSubview(button)
        }

        symbolStack = stackView
        symbolScroll = scrollView
        symbolHeight = stackView.heightAnchor.constraint(equalToConstant: 32)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            symbolHeight!,
        ])

        return (scrollView, rightStack, separator)
    }

    private func makeButton(title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = controlForegroundColor
        if let title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attrs = incoming
                attrs.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                    for: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
                )
                return attrs
            }
        }
        if let systemImage {
            config.image = UIImage(systemName: systemImage)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        targetButtons.append(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        let minima = [button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
                      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)]
        buttonMinima.append(contentsOf: minima)
        NSLayoutConstraint.activate(minima)
        return button
    }

    func applyWorkspaceChromeBackground(_ color: UIColor? = nil) {
        if let color {
            workspaceChromeBackgroundColor = color
        }
        if #available(iOS 26, *) {
            backgroundColor = .clear
            isOpaque = false
        } else {
            backgroundColor = workspaceChromeBackgroundColor
            isOpaque = true
        }
        separator.backgroundColor = controlForegroundColor.withAlphaComponent(0.22)
        applyControlForegroundColor(in: self)
        if Self.geometryDiagnosticsEnabled {
            reportGeometry("chromeColor accessoryStyle=\(traitCollection.userInterfaceStyle.rawValue) editorStyle=\(textView?.traitCollection.userInterfaceStyle.rawValue ?? -1) editorWindowStyle=\(textView?.window?.traitCollection.userInterfaceStyle.rawValue ?? -1) resolvedStyle=\(chromeContrastTraits.userInterfaceStyle.rawValue) background=\(workspaceChromeBackgroundColor.resolvedColor(with: chromeContrastTraits)) foreground=\(controlForegroundColor)")
        }
    }

    private var chromeContrastTraits: UITraitCollection {
        // Native keyboard hosting can retain different appearance traits from
        // the editor. Resolve external workspace chrome in its owning window.
        textView?.window?.traitCollection ?? traitCollection
    }

    private var controlForegroundColor: UIColor {
        let color = workspaceChromeBackgroundColor.resolvedColor(with: chromeContrastTraits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .label
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance < 0.5 ? .white : .black
    }

    private func applyControlForegroundColor(in view: UIView) {
        if let button = view as? UIButton {
            var config = button.configuration
            config?.baseForegroundColor = controlForegroundColor
            button.configuration = config
            button.tintColor = controlForegroundColor
        }
        view.subviews.forEach(applyControlForegroundColor)
    }
}
