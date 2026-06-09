//
//  KeyboardAccessoryView.swift
//  InkPond
//

import UIKit
import GameController

final class KeyboardAccessoryView: UIView {
    private final class NotificationObserverToken: @unchecked Sendable {
        nonisolated(unsafe) let token: NSObjectProtocol

        init(_ token: NSObjectProtocol) {
            self.token = token
        }

        nonisolated func remove() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private struct SymbolItem {
        let label: String
        let insert: String
    }

    private weak var textView: UITextView?
    var onPhotoButtonTapped: (() -> Void)?
    var onSnippetButtonTapped: (() -> Void)?
    private let separator = UIView()
    private lazy var snippetButton = makeButton(systemImage: "text.badge.plus") { [weak self] in
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
    private lazy var rightStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [snippetButton, photoButton, undoButton, redoButton])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private var workspaceChromeBackgroundColor: UIColor = .secondarySystemGroupedBackground
    private var hardwareKeyboardObservers: [NotificationObserverToken] = []
    private static let barHeight: CGFloat = 60

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
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight))
        autoresizingMask = [.flexibleWidth]
        configureActionButtons()
        setupViews()
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
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: Self.barHeight)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyWorkspaceChromeBackground()
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
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
    }

    private func startObservingHardwareKeyboard() {
        guard isPad else { return }

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
        let showsUndoRedo = !isPad || hasHardwareKeyboard
        undoButton.isHidden = !showsUndoRedo
        redoButton.isHidden = !showsUndoRedo
    }

    private func setupViews() {
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
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 25
        glass.layer.cornerCurve = .continuous
        addSubview(glass)

        // Build content inside the glass
        let (scrollView, rightStack, separator) = buildContent()

        glass.contentView.addSubview(scrollView)
        glass.contentView.addSubview(separator)
        glass.contentView.addSubview(rightStack)

        let constraints = [
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

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

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Pre-iOS 26 Layout

    private func setupLegacyLayout() {
        applyWorkspaceChromeBackground()

        let (scrollView, rightStack, separator) = buildContent()

        addSubview(scrollView)
        addSubview(separator)
        addSubview(rightStack)

        let constraints = [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 28),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -8),
        ]

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Shared Content

    private func buildContent() -> (scrollView: UIScrollView, rightStack: UIStackView, separator: UIView) {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for symbol in symbols {
            let button = makeButton(title: symbol.label) { [weak self] in
                InteractionFeedback.selection()
                self?.textView?.insertText(symbol.insert)
            }
            button.accessibilityLabel = L10n.keyboardSymbolAccessibilityLabel(for: symbol.label)
            button.accessibilityHint = L10n.a11yKeyboardInsertHint
            stackView.addArrangedSubview(button)
        }

        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stackView.heightAnchor.constraint(equalToConstant: 32),
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
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
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
    }

    private var controlForegroundColor: UIColor {
        let color = workspaceChromeBackgroundColor.resolvedColor(with: traitCollection)
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
