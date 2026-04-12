//
//  L10n.swift
//  InkPond
//

import Foundation

enum L10n {
    nonisolated static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    nonisolated static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    nonisolated static var appName: String { tr("app.name") }
    nonisolated static var untitledBase: String { tr("doc.untitled.base") }

    nonisolated static func untitled(number: Int) -> String {
        format("doc.untitled.numbered", number)
    }

    nonisolated static func deleteDocumentMessage(title: String) -> String {
        format("alert.delete_document.message", title)
    }

    nonisolated static func unlinkDocumentMessage(title: String) -> String {
        format("alert.unlink_document.message", title)
    }

    nonisolated static func imageInserted(path: String) -> String {
        format("toast.image_inserted.single", path)
    }

    nonisolated static func imagesInserted(count: Int) -> String {
        format("toast.image_inserted.multiple", count)
    }

    nonisolated static var appFontsTitle: String { tr("app_fonts.title") }
    nonisolated static var projectFontsTitle: String { tr("project_fonts.title") }
    nonisolated static var appFontsBuiltInOnlySummary: String { tr("app_fonts.summary.built_in_only") }
    nonisolated static func appFontsImportedSummary(count: Int) -> String {
        format("app_fonts.summary.imported", count)
    }
    nonisolated static var appFontsErrorTitle: String { tr("app_fonts.alert.error") }
    nonisolated static var appFontsOverviewTitle: String { tr("app_fonts.overview.title") }
    nonisolated static var appFontsOverviewDetail: String { tr("app_fonts.overview.detail") }
    nonisolated static var projectFontsFooter: String { tr("project_fonts.footer") }
    nonisolated static var noProjectFonts: String { tr("project_fonts.empty") }
    nonisolated static var fontScopeBuiltIn: String { tr("font.scope.built_in") }
    nonisolated static var fontScopeApp: String { tr("font.scope.app") }
    nonisolated static var fontScopeProject: String { tr("font.scope.project") }
    nonisolated static func fontFacesCount(_ count: Int) -> String { format("font.faces_count", count) }
    nonisolated static var appFontsExportWarningTitle: String { tr("app_fonts.export_warning.title") }
    nonisolated static var appFontsExportWarningMessage: String { tr("app_fonts.export_warning.message") }
    nonisolated static var uiTestSampleDocumentTitle: String { tr("ui_test.sample_document_title") }

    nonisolated static var docListNewDocument: String { tr("doc.list.action.new") }
    nonisolated static var docListLinkExternalFolder: String { tr("doc.list.action.link_external") }

    nonisolated static var a11yDocumentListSettingsLabel: String { tr("a11y.document_list.settings.label") }
    nonisolated static var a11yDocumentListSettingsHint: String { tr("a11y.document_list.settings.hint") }
    nonisolated static var a11yDocumentListAddLabel: String { tr("a11y.document_list.add.label") }
    nonisolated static var a11yDocumentListAddHint: String { tr("a11y.document_list.add.hint") }
    nonisolated static var a11yDocumentRowHint: String { tr("a11y.document_row.hint") }
    nonisolated static func a11yDocumentRowLabel(title: String, createdAt: String, modifiedAt: String) -> String {
        format("a11y.document_row.label_format", title, createdAt, modifiedAt)
    }
    nonisolated static func a11ySortChanged(_ value: String) -> String {
        format("a11y.sort.changed", value)
    }
    nonisolated static func a11ySortValue(field: String, direction: String) -> String {
        format("a11y.sort.value_format", field, direction)
    }
    nonisolated static func a11yDocumentCreated(_ title: String) -> String {
        format("a11y.document.created", title)
    }
    nonisolated static func a11yDocumentImported(_ title: String) -> String {
        format("a11y.document.imported", title)
    }
    nonisolated static var a11yExportReady: String { tr("a11y.export.ready") }
    nonisolated static var a11yProjectFilesSettingsLabel: String { tr("a11y.project_files.settings.label") }
    nonisolated static var a11yProjectFilesSettingsHint: String { tr("a11y.project_files.settings.hint") }
    nonisolated static var a11yProjectFilesAddLabel: String { tr("a11y.project_files.add_menu.label") }
    nonisolated static var a11yProjectFilesAddHint: String { tr("a11y.project_files.add_menu.hint") }
    nonisolated static var a11yProjectFilesExpandHint: String { tr("a11y.project_files.row.hint.expand") }
    nonisolated static var a11yProjectFilesOpenHint: String { tr("a11y.project_files.row.hint.open") }
    nonisolated static var a11yProjectFilesPreviewHint: String { tr("a11y.project_files.row.hint.preview") }
    nonisolated static func a11yProjectFilesFolderLabel(_ name: String) -> String {
        format("a11y.project_files.row.folder.label", name)
    }
    nonisolated static func a11yProjectFilesFileLabel(kind: String, name: String) -> String {
        format("a11y.project_files.row.file.label", kind, name)
    }
    nonisolated static var a11yStateExpanded: String { tr("a11y.state.expanded") }
    nonisolated static var a11yStateCollapsed: String { tr("a11y.state.collapsed") }
    nonisolated static var a11yClosePreview: String { tr("a11y.preview.close") }
    nonisolated static var a11yEditorShareLabel: String { tr("a11y.editor.share.label") }
    nonisolated static var a11yEditorShareHint: String { tr("a11y.editor.share.hint") }
    nonisolated static var a11yEditorMenuLabel: String { tr("a11y.editor.menu.label") }
    nonisolated static var a11yEditorMenuHint: String { tr("a11y.editor.menu.hint") }
    nonisolated static var a11yEditorLabel: String { tr("a11y.editor.text.label") }
    nonisolated static var a11yEditorHint: String { tr("a11y.editor.text.hint") }
    nonisolated static var a11yEditorSplitLabel: String { tr("a11y.editor.split.label") }
    nonisolated static var a11yEditorSplitHint: String { tr("a11y.editor.split.hint") }
    nonisolated static var a11yEditorSplitReset: String { tr("a11y.editor.split.action.reset") }
    nonisolated static func a11yEditorSplitValue(editorPercent: Int, previewPercent: Int) -> String {
        format("a11y.editor.split.value_format", editorPercent, previewPercent)
    }
    nonisolated static var a11yPreviewLabel: String { tr("a11y.preview.label") }
    nonisolated static var a11yPreviewHint: String { tr("a11y.preview.hint") }
    nonisolated static var a11yPreviewValueReady: String { tr("a11y.preview.value.ready") }
    nonisolated static var a11yPreviewValueEmpty: String { tr("a11y.preview.value.empty") }
    nonisolated static var a11yPreviewValueError: String { tr("a11y.preview.value.error") }
    nonisolated static var a11yPreviewPlaceholderLabel: String { tr("a11y.preview.placeholder.label") }
    nonisolated static var a11yPreviewPlaceholderHint: String { tr("a11y.preview.placeholder.hint") }
    nonisolated static func previewStatsPages(_ count: Int) -> String { format("preview.stats.pages", count) }
    nonisolated static func previewStatsWords(_ count: Int) -> String { format("preview.stats.words", count) }
    nonisolated static func previewStatsTokens(_ count: Int) -> String { format("preview.stats.tokens", count) }
    nonisolated static func previewStatsCharacters(_ count: Int) -> String { format("preview.stats.characters", count) }
    nonisolated static func previewStatsExpandedValue(pages: String, words: String, characters: String) -> String {
        format("preview.stats.a11y.value.expanded", pages, words, characters)
    }
    nonisolated static var previewStatsHintCollapsed: String { tr("preview.stats.a11y.hint.collapsed") }
    nonisolated static var previewStatsHintExpanded: String { tr("preview.stats.a11y.hint.expanded") }
    nonisolated static var a11yCompileSuccess: String { tr("a11y.compile.success") }
    nonisolated static var a11yCompileFailed: String { tr("a11y.compile.failed") }
    nonisolated static var a11yCacheRefreshStarted: String { tr("a11y.cache_refresh.started") }
    nonisolated static var a11yKeyboardInsertHint: String { tr("a11y.keyboard.insert.hint") }
    nonisolated static var a11yKeyboardPhotoLabel: String { tr("a11y.keyboard.photo.label") }
    nonisolated static var a11yKeyboardPhotoHint: String { tr("a11y.keyboard.photo.hint") }
    nonisolated static var a11yKeyboardUndoLabel: String { tr("a11y.keyboard.undo.label") }
    nonisolated static var a11yKeyboardUndoHint: String { tr("a11y.keyboard.undo.hint") }
    nonisolated static var a11yKeyboardRedoLabel: String { tr("a11y.keyboard.redo.label") }
    nonisolated static var a11yKeyboardRedoHint: String { tr("a11y.keyboard.redo.hint") }
    nonisolated static var a11yKeyboardSnippetLabel: String { tr("a11y.keyboard.snippet.label") }
    nonisolated static var a11yKeyboardSnippetHint: String { tr("a11y.keyboard.snippet.hint") }
    nonisolated static var a11ySettingsHeaderLabel: String { tr("a11y.settings.header.label") }
    nonisolated static func a11ySettingsHeaderValue(version: String, typstVersion: String?) -> String {
        if let typstVersion {
            return format("a11y.settings.header.value_with_typst", version, typstVersion)
        }
        return format("a11y.settings.header.value", version)
    }

    nonisolated static func keyboardSymbolAccessibilityLabel(for symbol: String) -> String {
        switch symbol {
        case "⇥": tr("a11y.keyboard.symbol.tab")
        case "#": tr("a11y.keyboard.symbol.hash")
        case "$": tr("a11y.keyboard.symbol.dollar")
        case "=": tr("a11y.keyboard.symbol.equals")
        case "*": tr("a11y.keyboard.symbol.asterisk")
        case "_": tr("a11y.keyboard.symbol.underscore")
        case "{": tr("a11y.keyboard.symbol.left_brace")
        case "}": tr("a11y.keyboard.symbol.right_brace")
        case "[": tr("a11y.keyboard.symbol.left_bracket")
        case "]": tr("a11y.keyboard.symbol.right_bracket")
        case "(": tr("a11y.keyboard.symbol.left_parenthesis")
        case ")": tr("a11y.keyboard.symbol.right_parenthesis")
        case "<": tr("a11y.keyboard.symbol.left_angle")
        case ">": tr("a11y.keyboard.symbol.right_angle")
        case "@": tr("a11y.keyboard.symbol.at_sign")
        case "/": tr("a11y.keyboard.symbol.slash")
        default: symbol
        }
    }
}
