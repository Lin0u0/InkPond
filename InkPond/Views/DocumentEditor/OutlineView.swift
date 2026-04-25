//
//  OutlineView.swift
//  InkPond
//

import SwiftUI

struct OutlineItem: Identifiable {
    let id = UUID()
    let level: Int
    let title: String
    let characterOffset: Int
}

struct OutlineView: View {
    let editorText: String
    let onJump: (Int) -> Void

    @Environment(\.dismiss) var dismiss

    private var items: [OutlineItem] {
        Self.parseHeadings(from: editorText)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("outline.empty.title"),
                        systemImage: "list.bullet",
                        description: Text(L10n.tr("outline.empty.message"))
                    )
                } else {
                    List(items) { item in
                        Button {
                            dismiss()
                            onJump(item.characterOffset)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "text.alignleft")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                            }
                            .padding(.leading, CGFloat(item.level - 1) * 16)
                        }
                        .foregroundStyle(.primary)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.tr("outline.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    static func parseHeadings(from text: String) -> [OutlineItem] {
        guard let entries = TypstBridge.outlineItems(source: text) else { return [] }
        return entries.map { entry in
            OutlineItem(
                level: entry.level,
                title: entry.title,
                characterOffset: entry.location
            )
        }
    }
}
