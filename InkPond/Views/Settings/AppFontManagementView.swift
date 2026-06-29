//
//  AppFontManagementView.swift
//  InkPond
//

import SwiftUI
import UniformTypeIdentifiers

struct AppFontManagementView: View {
    @Environment(AppFontLibrary.self) private var appFontLibrary

    @State private var showingFontPicker = false
    @State private var actionError: String?

    var body: some View {
        List {
            overviewSection
            fontsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.appFontsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFontPicker,
            allowedContentTypes: [.font],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result {
                    actionError = error.localizedDescription
                }
                return
            }

            do {
                try appFontLibrary.importFonts(from: urls)
            } catch {
                actionError = error.localizedDescription
            }
        }
        .alert(L10n.appFontsErrorTitle, isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(L10n.tr("OK")) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .fileDialogDefaultDirectory(preferredPickerDirectory)
    }

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.appFontsOverviewTitle)
                    .font(.body.weight(.medium))
                Text(L10n.appFontsOverviewDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var fontsSection: some View {
        Section(L10n.appFontsTitle) {
            ExpandableFontList(
                groups: appFontLibrary.groupedItems,
                scopeLabel: { _ in L10n.fontScopeApp },
                onDeleteGroup: { group in
                    guard !group.isBuiltIn else { return }
                    InteractionFeedback.notify(.warning)
                    for fileName in group.fileNames {
                        appFontLibrary.delete(fileName: fileName)
                    }
                }
            )

            Button {
                InteractionFeedback.impact(.light)
                showingFontPicker = true
            } label: {
                Label(L10n.tr("Add Font…"), systemImage: "plus.circle")
                    .foregroundStyle(.primary)
            }
        }
    }

    private var preferredPickerDirectory: URL? {
        if StorageSyncPreferences.syncFonts,
           let ubiquityDocuments = FileManager.default
            .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true) {
            return ubiquityDocuments
        }
        return nil
    }
}
