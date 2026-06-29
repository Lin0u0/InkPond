//
//  ExpandableFontList.swift
//  InkPond
//

import SwiftUI
import UIKit

struct ExpandableFontList: View {
    let groups: [AppFontGroup]
    let scopeLabel: (AppFontGroup) -> String
    var onDeleteGroup: ((AppFontGroup) -> Void)? = nil

    @State private var expandedGroupIDs: Set<String> = []
    private let previewText = "AaBb 0123456789 .,!? 中文预览"

    private var visibleRows: [VisibleFontRow] {
        var rows: [VisibleFontRow] = []
        for group in groups {
            let isExpanded = expandedGroupIDs.contains(group.id)
            rows.append(VisibleFontRow(kind: .group(group), depth: 0, isExpanded: isExpanded))
            if isExpanded, group.count > 1 {
                for face in group.faces {
                    rows.append(VisibleFontRow(kind: .face(groupID: group.id, face: face), depth: 1, isExpanded: false))
                }
            }
        }
        return rows
    }

    var body: some View {
        ForEach(visibleRows) { row in
            switch row.kind {
            case .group(let group):
                Button {
                    guard group.count > 1 else { return }
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
                        if expandedGroupIDs.contains(group.id) {
                            expandedGroupIDs.remove(group.id)
                        } else {
                            expandedGroupIDs.insert(group.id)
                        }
                    }
                } label: {
                    fontGroupRowLabel(for: group, row: row)
                }
                .buttonStyle(FontListRowButtonStyle())
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = group.familyName
                    } label: {
                        Label(L10n.tr("font.copyName"), systemImage: "doc.on.doc")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if let onDeleteGroup, !group.fileNames.isEmpty {
                        Button(L10n.tr("Delete"), role: .destructive) {
                            onDeleteGroup(group)
                        }
                    }
                }
            case .face(_, let face):
                fontFaceRowLabel(face: face, depth: row.depth)
                    .padding(.vertical, 2)
            }
        }
    }

    private func fontGroupRowLabel(for group: AppFontGroup, row: VisibleFontRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if group.count > 1 {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 18, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: 12, height: 18)
                }
                Image(systemName: "character.textbox")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
                    .frame(width: 22, height: 18, alignment: .center)
                Text(group.familyName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if group.count > 1 {
                    Text(L10n.fontFacesCount(group.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(scopeLabel(group))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            FontPreviewLine(
                fontPath: group.previewPath,
                text: previewText,
                fallbackTextStyle: .caption1
            )
            .padding(.leading, 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0.9)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func fontFaceRowLabel(face: AppFontFace, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 12, height: 18)
                Color.clear
                    .frame(width: 22, height: 18)
                Text(face.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }

            FontPreviewLine(
                fontPath: face.path,
                text: previewText,
                fallbackTextStyle: .caption2
            )
            .padding(.leading, 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0.9)
        }
        .padding(.leading, CGFloat(depth) * 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct VisibleFontRow: Identifiable {
    enum Kind {
        case group(AppFontGroup)
        case face(groupID: String, face: AppFontFace)
    }

    let kind: Kind
    let depth: Int
    let isExpanded: Bool

    var id: String {
        switch kind {
        case .group(let group):
            return "group:\(group.id)"
        case .face(let groupID, let face):
            return "face:\(groupID):\(face.id)"
        }
    }
}

private struct FontListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct FontGroupRow: View {
    let group: AppFontGroup
    let scopeLabel: String

    var body: some View {
        ExpandableFontList(groups: [group], scopeLabel: { _ in scopeLabel })
    }
}

private struct FontPreviewLine: UIViewRepresentable {
    let fontPath: String?
    let text: String
    let fallbackTextStyle: UIFont.TextStyle

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.55
        label.lineBreakMode = .byTruncatingTail
        label.textColor = UIColor.secondaryLabel
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        if let fontPath, !fontPath.isEmpty,
           let font = FontManager.previewUIFont(forFontAtPath: fontPath, size: 13) {
            label.font = font
        } else {
            label.font = UIFont.preferredFont(forTextStyle: fallbackTextStyle)
        }
    }
}
