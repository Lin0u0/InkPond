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
        guard let regex = try? NSRegularExpression(pattern: #"^(={1,6})\s+(.+)$"#, options: .anchorsMatchLines) else {
            return []
        }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let equalsRange = match.range(at: 1)
            let titleRange = match.range(at: 2)
            let level = equalsRange.length
            var title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespaces)
            // Strip trailing Typst bookmark labels like <intro>
            if let labelRange = title.range(of: #"\s*<[^>]+>\s*$"#, options: .regularExpression) {
                title = String(title[title.startIndex..<labelRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard !title.isEmpty else { return nil }
            let characterOffset = match.range.location
            return OutlineItem(level: level, title: title, characterOffset: characterOffset)
        }
    }
}
