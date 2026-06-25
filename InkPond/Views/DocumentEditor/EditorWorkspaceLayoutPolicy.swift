//
//  EditorWorkspaceLayoutPolicy.swift
//  InkPond
//

import CoreGraphics

enum EditorWorkspaceLayoutKind: Equatable {
    case compact
    case split
    case expandedSplit
}

struct EditorWorkspaceLayoutPolicy: Equatable {
    static let splitMinimumWidth: CGFloat = 860
    static let splitMinimumHeight: CGFloat = 520
    static let expandedSplitMinimumWidth: CGFloat = 1100
    static let minimumEditorWidth: CGFloat = 360
    static let minimumPreviewWidth: CGFloat = 320

    let size: CGSize
    let kind: EditorWorkspaceLayoutKind

    init(size: CGSize) {
        let normalizedSize = CGSize(
            width: max(size.width, 0),
            height: max(size.height, 0)
        )
        self.size = normalizedSize

        if normalizedSize.width < Self.splitMinimumWidth || normalizedSize.height < Self.splitMinimumHeight {
            kind = .compact
        } else if normalizedSize.width >= Self.expandedSplitMinimumWidth {
            kind = .expandedSplit
        } else {
            kind = .split
        }
    }

    var usesCompactWorkspace: Bool {
        kind == .compact
    }

    var usesSplitWorkspace: Bool {
        kind != .compact
    }

    var allowsInlineProjectFileTree: Bool {
        kind == .expandedSplit
    }

    func clampedEditorFraction(
        _ fraction: CGFloat,
        workspaceWidth: CGFloat,
        splitHandleWidth: CGFloat
    ) -> CGFloat {
        let availablePaneWidth = max(workspaceWidth - splitHandleWidth, 1)
        let minimumEditorFraction = min(Self.minimumEditorWidth / availablePaneWidth, 0.5)
        let maximumEditorFraction = max(1 - Self.minimumPreviewWidth / availablePaneWidth, minimumEditorFraction)
        return min(max(fraction, minimumEditorFraction), maximumEditorFraction)
    }

    func splitMetrics(
        totalWidth: CGFloat,
        editorFraction: CGFloat,
        isProjectFileTreeVisible: Bool,
        splitHandleWidth: CGFloat,
        collapsedHeaderMinimumWidth: CGFloat,
        collapsedHeaderMaximumWidth: CGFloat
    ) -> EditorWorkspaceLayoutMetrics {
        let wantsTree = allowsInlineProjectFileTree && isProjectFileTreeVisible
        let preferredTreeWidth = min(max(totalWidth * 0.22, 240), 320)
        let maximumTreeWidth = max(
            totalWidth - Self.minimumEditorWidth - Self.minimumPreviewWidth - splitHandleWidth - 1,
            0
        )
        let treeWidth = wantsTree ? min(preferredTreeWidth, maximumTreeWidth) : 0
        let treeDividerWidth: CGFloat = treeWidth > 0 ? 1 : 0
        let workspaceWidth = max(totalWidth - treeWidth - treeDividerWidth, 1)
        let availablePaneWidth = max(workspaceWidth - splitHandleWidth, 1)
        let clampedFraction = clampedEditorFraction(
            editorFraction,
            workspaceWidth: workspaceWidth,
            splitHandleWidth: splitHandleWidth
        )
        let editorWidth = min(
            max(availablePaneWidth * clampedFraction, 1),
            max(availablePaneWidth - 1, 1)
        )
        let collapsedHeaderWidth = min(
            max(totalWidth * 0.17, collapsedHeaderMinimumWidth),
            collapsedHeaderMaximumWidth
        )

        return EditorWorkspaceLayoutMetrics(
            totalWidth: totalWidth,
            treeWidth: treeWidth,
            treeDividerWidth: treeDividerWidth,
            projectHeaderWidth: collapsedHeaderWidth,
            workspaceWidth: workspaceWidth,
            editorWidth: editorWidth,
            splitHandleWidth: splitHandleWidth
        )
    }
}

struct EditorWorkspaceLayoutMetrics: Equatable {
    let totalWidth: CGFloat
    let treeWidth: CGFloat
    let treeDividerWidth: CGFloat
    let projectHeaderWidth: CGFloat
    let workspaceWidth: CGFloat
    let editorWidth: CGFloat
    let splitHandleWidth: CGFloat

    var editorStartX: CGFloat { treeWidth + treeDividerWidth }
    var previewStartX: CGFloat { editorStartX + editorWidth + splitHandleWidth }
    var previewWidth: CGFloat { max(workspaceWidth - editorWidth - splitHandleWidth, 1) }
}
