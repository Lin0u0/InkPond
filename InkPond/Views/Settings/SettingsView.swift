//
//  SettingsView.swift
//  InkPond
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    private static let githubIssuesURL = URL(string: "https://github.com/lin0u0/Typist/issues")!

    @Environment(AppFontLibrary.self) var appFontLibrary
    @Environment(AppAppearanceManager.self) var appAppearanceManager
    @Environment(ThemeManager.self) var themeManager
    @Environment(EditorFontSettings.self) var editorFontSettings
    @Environment(StorageManager.self) var storageManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss

    @State var showingZipImporter = false
    @State var zipImportError: String?

    var onImport: (URL) -> Void
    var onLinkExternalFolder: () -> Void

    var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L10n.format("settings.version_format", v, b)
    }

    var typstVersionString: String? {
        guard let version = TypstBridge.runtimeVersion else { return nil }
        return L10n.format("settings.typst_version_format", version)
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                iCloudSection
                appearanceSection
                keyboardShortcutsSection
                projectsSection
                packagesSection
                fontsSection
                cacheSection
                feedbackSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) {
                        InteractionFeedback.impact(.light)
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
            .fileImporter(isPresented: $showingZipImporter, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url):
                    onImport(url)
                    dismiss()
                case .failure(let error):
                    zipImportError = error.localizedDescription
                }
            }
            .alert(L10n.tr("Import Error"), isPresented: Binding(
                get: { zipImportError != nil },
                set: { if !$0 { zipImportError = nil } }
            )) {
                Button(L10n.tr("OK")) { zipImportError = nil }
            } message: {
                Text(zipImportError ?? "")
            }
        }
    }
}

extension SettingsView {
    var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                appIconView
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .accessibilityHidden(true)
                Text(L10n.appName)
                    .font(.title2.bold())
                Text(versionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let typstVersionString {
                    Text(typstVersionString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.a11ySettingsHeaderLabel)
            .accessibilityValue(
                L10n.a11ySettingsHeaderValue(version: versionString, typstVersion: typstVersionString)
            )
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    var appIconView: some View {
        Image("AppIconDisplay")
            .resizable()
            .scaledToFit()
    }

    var iCloudSection: some View {
        Section(L10n.tr("icloud.title")) {
            NavigationLink {
                ICloudSettingsView()
            } label: {
                HStack {
                    Label(L10n.tr("icloud.title"), systemImage: "icloud")
                        .foregroundStyle(.primary)
                    Spacer()
                    if storageManager.mode == .iCloud {
                        Text(L10n.tr("icloud.summary.on"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("icloud.summary.off"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("settings.icloud")
        }
    }

    var appearanceSection: some View {
        SettingsAppearanceSection(
            appAppearanceManager: appAppearanceManager,
            themeManager: themeManager,
            editorFontSettings: editorFontSettings
        )
    }

    var keyboardShortcutsSection: some View {
        Section {
            NavigationLink {
                KeyboardShortcutsView()
            } label: {
                Label(L10n.tr("shortcuts.title"), systemImage: "keyboard")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.keyboard-shortcuts")
        }
    }

    var projectsSection: some View {
        Section(L10n.tr("settings.import_link.section")) {
            Button {
                showingZipImporter = true
            } label: {
                Label(L10n.tr("Import ZIP"), systemImage: "square.and.arrow.down")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.import-zip")

            Button {
                onLinkExternalFolder()
                dismiss()
            } label: {
                Label(L10n.docListLinkExternalFolder, systemImage: "link")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.link-external-folder")
        }
    }

    var packagesSection: some View {
        Section(L10n.tr("Packages")) {
            NavigationLink {
                LocalPackageManagementView()
            } label: {
                Label(L10n.tr("local_packages.title"), systemImage: "shippingbox")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.local-packages")
        }
    }

    var fontsSection: some View {
        Section(L10n.tr("Fonts")) {
            NavigationLink {
                AppFontManagementView()
            } label: {
                HStack {
                    Label(L10n.appFontsTitle, systemImage: "character.textbox")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(L10n.appFontsImportedSummary(count: appFontLibrary.fileNames.count))
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.fonts")
        }
    }

    var cacheSection: some View {
        Section(L10n.tr("Cache")) {
            NavigationLink {
                CompiledPreviewCacheManagementView()
            } label: {
                Label(L10n.tr("Manage Compile Cache"), systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.compile-cache")

            NavigationLink {
                PreviewPackageCacheManagementView()
            } label: {
                Label(L10n.tr("Manage Package Cache"), systemImage: "externaldrive.badge.person.crop")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.cache")

            NavigationLink {
                MaterializedFontCacheManagementView()
            } label: {
                Label(L10n.tr("Manage System Font Cache"), systemImage: "textformat")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.system-font-cache")
        }
    }

    var aboutSection: some View {
        Section {
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label(L10n.tr("Acknowledgements"), systemImage: "heart")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.acknowledgements")
        }
    }

    var feedbackSection: some View {
        Section(L10n.tr("settings.feedback.section")) {
            Link(destination: Self.githubIssuesURL) {
                Label(L10n.tr("settings.feedback.github_issues"), systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.feedback.github-issues")
            .accessibilityHint(L10n.tr("settings.feedback.github_issues.hint"))
        }
    }
}

private struct SettingsAppearanceSection: View {
    @Bindable var appAppearanceManager: AppAppearanceManager
    @Bindable var themeManager: ThemeManager
    @Bindable var editorFontSettings: EditorFontSettings

    var body: some View {
        Section(L10n.tr("Appearance")) {
            Picker(selection: $appAppearanceManager.mode) {
                Text(L10n.tr("Follow System")).tag(AppAppearanceMode.system.rawValue)
                Text(L10n.tr("Light")).tag(AppAppearanceMode.light.rawValue)
                Text(L10n.tr("Dark")).tag(AppAppearanceMode.dark.rawValue)
            } label: {
                Label(L10n.tr("App Appearance"), systemImage: "circle.lefthalf.filled")
            }

            Picker(selection: $themeManager.themeID) {
                Text(L10n.tr("Auto")).tag("system")
                Text(L10n.tr("Mocha · Dark")).tag("mocha")
                Text(L10n.tr("Latte · Light")).tag("latte")
            } label: {
                Label(L10n.tr("Editor Theme"), systemImage: "paintpalette")
            }

            NavigationLink {
                EditorFontSettingsView(editorFontSettings: editorFontSettings)
            } label: {
                HStack {
                    Label(L10n.tr("Editor Font"), systemImage: "textformat.size")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(editorFontSettings.fontDisplayName)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.editor-font")
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
