//
//  ProjectSettingsSheet.swift
//  InkPond
//

import SwiftUI
import UniformTypeIdentifiers

struct ProjectSettingsSheet: View {
    @Bindable var document: InkPondDocument
    var openFile: ((String) -> Void)?
    @Environment(AppFontLibrary.self) private var appFontLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var typFiles: [String] = []
    @State private var showingFontPicker = false
    @State private var actionError: String?

    @MainActor
    private var projectFontGroups: [AppFontGroup] {
        var grouped: [String: (fileNames: [String], faces: [AppFontFace])] = [:]

        for fileName in document.fontFileNames {
            let fallbackName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            let path = FontManager.fontFilePath(for: fileName, in: document)
            let familyName = path.flatMap(FontManager.typstFamilyName(forFontAtPath:)) ?? fallbackName
            let faceName = path.flatMap(FontManager.typstFaceName(forFontAtPath:)) ?? fallbackName
            let face = AppFontFace(displayName: faceName, path: path ?? "")
            grouped[familyName, default: ([], [])].fileNames.append(fileName)
            grouped[familyName, default: ([], [])].faces.append(face)
        }

        return grouped.map { familyName, group in
            AppFontGroup(
                familyName: familyName,
                isBuiltIn: false,
                fileNames: group.fileNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                faces: group.faces.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                },
                count: max(1, group.faces.count)
            )
        }
        .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Entry File
                Section("Entry File") {
                    Picker("Entry File", selection: $document.entryFileName) {
                        ForEach(typFiles, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: document.entryFileName) { _, newName in
                        openFile?(newName)
                    }
                }

                // MARK: Image
                Section("Image Insertion") {
                    Picker("Format", selection: $document.imageInsertMode) {
                        Text("#image(\"path\")").tag("image")
                        Text("#figure(image(\"path\"), caption: [...])").tag("figure")
                    }
                }

                Section("Image Directory") {
                    TextField("Subdirectory name", text: $document.imageDirectoryName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                // MARK: Fonts
                Section(
                    header: Text("Fonts"),
                    footer: Text(L10n.projectFontsFooter)
                ) {
                    ExpandableFontList(
                        groups: appFontLibrary.groupedItems,
                        scopeLabel: { _ in L10n.fontScopeApp }
                    )

                    if document.fontFileNames.isEmpty {
                        Text(L10n.noProjectFonts)
                            .foregroundStyle(.tertiary)
                    }

                    ExpandableFontList(
                        groups: projectFontGroups,
                        scopeLabel: { _ in L10n.fontScopeProject },
                        onDeleteGroup: { group in
                            InteractionFeedback.notify(.warning)
                            let nameSet = Set(group.fileNames)
                            var removedNames = Set<String>()
                            for name in nameSet {
                                do {
                                    try FontManager.deleteFont(fileName: name, from: document)
                                    removedNames.insert(name)
                                } catch {
                                    actionError = actionError ?? error.localizedDescription
                                }
                            }
                            document.fontFileNames.removeAll { removedNames.contains($0) }
                        }
                    )

                    Button {
                        InteractionFeedback.impact(.light)
                        showingFontPicker = true
                    } label: {
                        Label("Add Font…", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Project Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        InteractionFeedback.impact(.light)
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
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
            var firstError: Error?
            for url in urls {
                do {
                    let name = try FontManager.importFont(from: url, for: document)
                    if !document.fontFileNames.contains(name) {
                        document.fontFileNames.append(name)
                    }
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                actionError = firstError.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(preferredFontPickerDirectory)
        .onAppear {
            typFiles = ProjectFileManager.listAllTypFiles(for: document)
            if typFiles.isEmpty { typFiles = [document.entryFileName] }
        }
    }

    private var preferredFontPickerDirectory: URL? {
        if StorageSyncPreferences.syncFonts,
           let ubiquityDocuments = FileManager.default
            .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true) {
            return ubiquityDocuments
        }
        return nil
    }
}
