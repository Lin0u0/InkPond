//
//  CompletionPopupView.swift
//  InkPond
//

import UIKit

final class CompletionPopupView: UIView {
    var onSelect: ((CompletionItem) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var items: [CompletionItem] = []
    private var selectedIndex = 0
    private var theme: EditorTheme = .system

    private static let cellID = "CompletionCell"
    private static let maxVisibleRows = 5
    private static let rowHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 0.5
        clipsToBounds = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Self.rowHeight
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.showsVerticalScrollIndicator = false
        tableView.register(CompletionCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.layer.cornerRadius = 8
        tableView.clipsToBounds = true

        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func applyTheme(_ theme: EditorTheme) {
        self.theme = theme
        backgroundColor = theme.gutterBackground
        layer.borderColor = theme.gutterForeground.withAlphaComponent(0.28).cgColor
        tableView.backgroundColor = .clear
        for case let cell as CompletionCell in tableView.visibleCells {
            cell.applyTheme(theme)
        }
    }

    func update(items: [CompletionItem]) {
        self.items = items
        self.selectedIndex = 0
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .top)
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let rows = min(items.count, Self.maxVisibleRows)
        return CGSize(width: 240, height: CGFloat(rows) * Self.rowHeight)
    }

    func confirmSelection() {
        guard selectedIndex < items.count else { return }
        guard items[selectedIndex].isInsertable else { return }
        onSelect?(items[selectedIndex])
    }

    var hasInsertableSelection: Bool {
        guard selectedIndex < items.count else { return false }
        return items[selectedIndex].isInsertable
    }

    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        let indexPath = IndexPath(row: selectedIndex, section: 0)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .middle)
        InteractionFeedback.selection()
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        let indexPath = IndexPath(row: selectedIndex, section: 0)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .middle)
        InteractionFeedback.selection()
    }
}

// MARK: - UITableViewDataSource & Delegate

extension CompletionPopupView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath) as? CompletionCell else {
            return tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        }
        let item = items[indexPath.row]
        cell.configure(with: item, theme: theme)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedIndex = indexPath.row
        InteractionFeedback.selection()
        let item = items[indexPath.row]
        guard item.isInsertable else { return }
        onSelect?(item)
    }
}

// MARK: - CompletionCell

private final class CompletionCell: UITableViewCell {
    private let selectionCardView = UIView()
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let modeLabel = UILabel()
    private var isHintOnlyItem = false
    private var theme: EditorTheme = .system

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        selectionCardView.translatesAutoresizingMaskIntoConstraints = false
        selectionCardView.backgroundColor = .clear
        selectionCardView.layer.cornerRadius = 6
        selectionCardView.layer.shadowColor = UIColor.systemBlue.cgColor
        selectionCardView.layer.shadowOffset = CGSize(width: 0, height: 2)
        selectionCardView.layer.shadowRadius = 8
        selectionCardView.layer.shadowOpacity = 0
        selectionCardView.isUserInteractionEnabled = false
        contentView.insertSubview(selectionCardView, at: 0)

        iconLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        iconLabel.textAlignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

        nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabel
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.textAlignment = .center
        modeLabel.text = "Hint"
        modeLabel.textColor = .secondaryLabel
        modeLabel.backgroundColor = .systemGray5
        modeLabel.layer.cornerRadius = 8
        modeLabel.clipsToBounds = true
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        modeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let stack = UIStackView(arrangedSubviews: [iconLabel, nameLabel, detailLabel, modeLabel])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            selectionCardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            selectionCardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            selectionCardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            selectionCardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        updateSelectionAppearance(isActive: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionCardView.layer.shadowPath = UIBezierPath(
            roundedRect: selectionCardView.bounds,
            cornerRadius: selectionCardView.layer.cornerRadius
        ).cgPath
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateSelectionAppearance(isActive: selected)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updateSelectionAppearance(isActive: highlighted || isSelected)
    }

    func applyTheme(_ theme: EditorTheme) {
        self.theme = theme
        nameLabel.textColor = theme.text
        detailLabel.textColor = theme.gutterForeground
        modeLabel.textColor = theme.text.withAlphaComponent(0.78)
        modeLabel.backgroundColor = theme.gutterForeground.withAlphaComponent(0.18)
        updateSelectionAppearance(isActive: isSelected || isHighlighted)
    }

    func configure(with item: CompletionItem, theme: EditorTheme) {
        applyTheme(theme)
        switch item.kind {
        case .keyword:
            iconLabel.text = "K"
            iconLabel.textColor = theme.keyword
        case .function:
            iconLabel.text = "F"
            iconLabel.textColor = theme.functionColor
        case .snippet:
            iconLabel.text = "S"
            iconLabel.textColor = theme.math
        case .parameter:
            iconLabel.text = "P"
            iconLabel.textColor = theme.code
        case .value:
            iconLabel.text = "V"
            iconLabel.textColor = theme.string
        case .reference:
            iconLabel.text = "@"
            iconLabel.textColor = theme.heading
        }
        nameLabel.text = item.label
        detailLabel.text = item.detail
        isHintOnlyItem = !item.isInsertable
        modeLabel.isHidden = item.isInsertable
        let alpha: CGFloat = item.isInsertable ? 1 : 0.7
        iconLabel.alpha = alpha
        nameLabel.alpha = alpha
        detailLabel.alpha = alpha
        updateSelectionAppearance(isActive: isSelected || isHighlighted)
    }

    private func updateSelectionAppearance(isActive: Bool) {
        let changes = {
            if isActive {
                if self.isHintOnlyItem {
                    self.selectionCardView.backgroundColor = self.theme.gutterForeground.withAlphaComponent(0.16)
                    self.selectionCardView.layer.shadowColor = self.theme.gutterForeground.cgColor
                    self.selectionCardView.layer.shadowOpacity = 0.12
                    self.selectionCardView.layer.borderColor = self.theme.gutterForeground.withAlphaComponent(0.24).cgColor
                    self.selectionCardView.layer.borderWidth = 0.8
                } else {
                    self.selectionCardView.backgroundColor = self.theme.heading.withAlphaComponent(0.16)
                    self.selectionCardView.layer.shadowColor = self.theme.heading.cgColor
                    self.selectionCardView.layer.shadowOpacity = 0.18
                    self.selectionCardView.layer.borderColor = self.theme.heading.withAlphaComponent(0.22).cgColor
                    self.selectionCardView.layer.borderWidth = 0.8
                }
            } else {
                self.selectionCardView.backgroundColor = .clear
                self.selectionCardView.layer.shadowOpacity = 0
                self.selectionCardView.layer.borderColor = UIColor.clear.cgColor
                self.selectionCardView.layer.borderWidth = 0
            }
        }

        if UIView.areAnimationsEnabled {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
}
