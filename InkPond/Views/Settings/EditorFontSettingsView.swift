//
//  EditorFontSettingsView.swift
//  InkPond
//

import SwiftUI

struct EditorFontSettingsView: View {
    @Bindable var editorFontSettings: EditorFontSettings
    @State private var fontFamilies = EditorFontSettings.availableFontFamilies

    var body: some View {
        Form {
            previewSection
            sizeSection
            fontSection
        }
        .navigationTitle(L10n.tr("Editor Font"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fontFamilies = EditorFontSettings.availableFontFamilies
        }
    }

    private var previewSection: some View {
        Section(L10n.tr("Preview")) {
            Text(L10n.tr("editor_font.preview_text"))
                .font(previewFont)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .accessibilityIdentifier("settings.editor-font.preview")
        }
    }

    private var sizeSection: some View {
        Section(L10n.tr("Font Size")) {
            Stepper(
                value: $editorFontSettings.fontSize,
                in: EditorFontSettings.minimumFontSize...EditorFontSettings.maximumFontSize,
                step: 1
            ) {
                HStack {
                    Label(L10n.tr("Size"), systemImage: "textformat.size")
                    Spacer()
                    Text(L10n.format("editor_font.size_value", Int(editorFontSettings.fontSize.rounded())))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.editor-font.size-stepper")

            Slider(
                value: $editorFontSettings.fontSize,
                in: EditorFontSettings.minimumFontSize...EditorFontSettings.maximumFontSize,
                step: 1
            )
            .accessibilityIdentifier("settings.editor-font.size-slider")
        }
    }

    private var fontSection: some View {
        Section {
            NavigationLink {
                EditorFontFamilyPickerView(
                    editorFontSettings: editorFontSettings,
                    fontFamilies: fontFamilies
                )
            } label: {
                HStack {
                    Label(L10n.tr("Font Family"), systemImage: "textformat")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(editorFontSettings.familyDisplayName)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.editor-font.family")

            if editorFontSettings.selectedFamily.faces.count > 1 {
                Picker(selection: $editorFontSettings.fontID) {
                    ForEach(editorFontSettings.selectedFamily.faces) { face in
                        Text(face.displayName).tag(face.id)
                    }
                } label: {
                    Label(L10n.tr("Style"), systemImage: "bold.italic.underline")
                }
                .accessibilityIdentifier("settings.editor-font.style")
            }
        } header: {
            Text(L10n.tr("Font"))
        } footer: {
            Text(L10n.tr("Changes apply to the editor only. Typst document output still follows the fonts declared in your source."))
        }
    }

    private var previewFont: Font {
        if editorFontSettings.fontID == EditorFontSettings.systemMonospacedFontID {
            return .system(size: editorFontSettings.fontSize, design: .monospaced)
        }
        return .custom(editorFontSettings.fontID, size: editorFontSettings.fontSize)
    }
}

private struct EditorFontFamilyPickerView: View {
    @Bindable var editorFontSettings: EditorFontSettings
    let fontFamilies: [EditorFontFamilyOption]
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(filteredFamilies) { family in
                    Button {
                        editorFontSettings.selectFamily(family)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(family.displayName)
                                    .foregroundStyle(.primary)
                                if family.faces.count > 1 {
                                    Text(L10n.format("editor_font.styles_count", family.faces.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if editorFontSettings.selectedFamily.id == family.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.editor-font.family.\(family.id)")
                }
            }
        }
        .navigationTitle(L10n.tr("Font Family"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: L10n.tr("Search Fonts"))
    }

    private var filteredFamilies: [EditorFontFamilyOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fontFamilies }

        return fontFamilies.filter { family in
            family.displayName.localizedCaseInsensitiveContains(query)
                || family.faces.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
    }
}
