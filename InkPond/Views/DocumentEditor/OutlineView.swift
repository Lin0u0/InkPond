//
//  OutlineView.swift
//  InkPond
//

import SwiftUI

struct OutlineItem: Identifiable {
    let id: String
    let level: Int
    let title: String
    let characterOffset: Int
}

struct OutlineView: View {
    let editorText: String
    let projectID: String
    let fileName: String
    let onJump: (Int) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var collapsedItemIDs: Set<String> = []
    @State private var didLoadCollapsedState = false

    private var items: [OutlineItem] {
        Self.parseHeadings(from: editorText)
    }

    private var visibleRows: [VisibleOutlineRow] {
        var rows: [VisibleOutlineRow] = []
        var collapsedAncestorLevels: [Int] = []

        for index in items.indices {
            let item = items[index]
            while let collapsedLevel = collapsedAncestorLevels.last, item.level <= collapsedLevel {
                collapsedAncestorLevels.removeLast()
            }
            guard collapsedAncestorLevels.isEmpty else { continue }

            let nextIndex = items.index(after: index)
            let hasChildren = nextIndex < items.endIndex && items[nextIndex].level > item.level
            let isCollapsed = collapsedItemIDs.contains(item.id)
            rows.append(VisibleOutlineRow(item: item, hasChildren: hasChildren, isCollapsed: isCollapsed))

            if hasChildren, isCollapsed {
                collapsedAncestorLevels.append(item.level)
            }
        }

        return rows
    }

    var body: some View {
        NavigationStack {
            outlineContent
                .navigationTitle(L10n.tr("outline.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("Done")) {
                            InteractionFeedback.impact(.light)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            loadCollapsedState()
        }
        .onChange(of: editorText) { _, _ in
            pruneCollapsedItems()
        }
        .onChange(of: fileName) { _, _ in
            loadCollapsedState()
        }
        .onChange(of: collapsedItemIDs) { _, _ in
            saveCollapsedState()
        }
    }

    @ViewBuilder
    private var outlineContent: some View {
        Form {
            if items.isEmpty {
                Section {
                    emptyOutlineView
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 24, trailing: 16))
                }
            } else {
                Section {
                    ForEach(visibleRows) { row in
                        outlineRow(row)
                    }
                }
            }
        }
    }

    private var emptyOutlineView: some View {
        ContentUnavailableView(
            L10n.tr("outline.empty.title"),
            systemImage: "list.bullet",
            description: Text(L10n.tr("outline.empty.message"))
        )
    }

    private func outlineRow(_ row: VisibleOutlineRow) -> some View {
        HStack(spacing: 8) {
            outlineDisclosureButton(row)
            Button {
                dismiss()
                onJump(row.item.characterOffset)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.item.title)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(.leading, CGFloat(max(row.item.level - 1, 0)) * 16)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func outlineDisclosureButton(_ row: VisibleOutlineRow) -> some View {
        if row.hasChildren {
            Button {
                toggleCollapse(row.item)
            } label: {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 18, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.item.title)
            .accessibilityValue(row.isCollapsed ? L10n.a11yStateCollapsed : L10n.a11yStateExpanded)
        } else {
            Color.clear
                .frame(width: 12, height: 18)
        }
    }

    private func toggleCollapse(_ item: OutlineItem) {
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
            if collapsedItemIDs.contains(item.id) {
                collapsedItemIDs.remove(item.id)
            } else {
                collapsedItemIDs.insert(item.id)
            }
        }
    }

    private func pruneCollapsedItems() {
        collapsedItemIDs.formIntersection(Set(items.map(\.id)))
        saveCollapsedState()
    }

    private func loadCollapsedState() {
        didLoadCollapsedState = true
        collapsedItemIDs = ProjectEditorStateStore.outlineCollapsedItemIDs(
            projectID: projectID,
            fileName: fileName
        )
        pruneCollapsedItems()
    }

    private func saveCollapsedState() {
        guard didLoadCollapsedState, !fileName.isEmpty else { return }
        ProjectEditorStateStore.saveOutlineCollapsedItemIDs(
            projectID: projectID,
            fileName: fileName,
            collapsedItemIDs: collapsedItemIDs
        )
    }

    static func parseHeadings(from text: String) -> [OutlineItem] {
        guard let entries = TypstBridge.outlineItems(source: text) else { return [] }
        var stack: [(level: Int, component: String)] = []
        var siblingCounts: [String: Int] = [:]

        return entries.map { entry in
            while let last = stack.last, last.level >= entry.level {
                stack.removeLast()
            }

            let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleComponent = normalizedTitle.isEmpty ? L10n.tr("outline.title") : normalizedTitle
            let parentPath = stack.map(\.component).joined(separator: "/")
            let siblingKey = "\(parentPath)|\(entry.level)|\(titleComponent)"
            let occurrence = siblingCounts[siblingKey, default: 0]
            siblingCounts[siblingKey] = occurrence + 1
            let component = "\(entry.level):\(titleComponent)#\(occurrence)"
            stack.append((level: entry.level, component: component))

            return OutlineItem(
                id: stack.map(\.component).joined(separator: "/"),
                level: entry.level,
                title: entry.title,
                characterOffset: entry.location
            )
        }
    }
}

private struct VisibleOutlineRow: Identifiable {
    let item: OutlineItem
    let hasChildren: Bool
    let isCollapsed: Bool

    var id: String { item.id }
}
