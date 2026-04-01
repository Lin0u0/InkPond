//
//  InitialEntryFilePickerSheet.swift
//  InkPond
//

import SwiftUI

struct InitialEntryFilePickerSheet: View {
    @Bindable var document: InkPondProject
    let completeImport: (_ selectedEntry: String?, _ selectedImageDirectory: String?, _ selectedFontDirectory: String?) -> Void

    @State private var selectedEntryFile: String?
    @State private var selectedImageDirectory: String?
    @State private var selectedFontDirectory: String?

    private var entryFileOptions: [String] {
        document.importEntryFileOptions.isEmpty ? ProjectFileManager.listAllTypFiles(for: document) : document.importEntryFileOptions
    }

    private var imageDirectoryOptions: [String] {
        document.importImageDirectoryOptions
    }

    private var fontDirectoryOptions: [String] {
        document.importFontDirectoryOptions
    }

    private var requiresEntrySelection: Bool {
        document.requiresInitialEntrySelection
    }

    private var canContinue: Bool {
        !requiresEntrySelection || selectedEntryFile != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if requiresEntrySelection {
                    Section("Entry File") {
                        if entryFileOptions.isEmpty {
                            ContentUnavailableView(
                                "No .typ Files Found",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("InkPond could not find any .typ files in this project.")
                            )
                        } else {
                            Picker("Entry File", selection: Binding(
                                get: { selectedEntryFile ?? document.entryFileName },
                                set: { selectedEntryFile = $0 }
                            )) {
                                ForEach(entryFileOptions, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            Text("This project does not include main.typ. Choose the file used for compilation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !imageDirectoryOptions.isEmpty {
                    Section("Image Directory") {
                        Picker("Image Directory", selection: $selectedImageDirectory) {
                            Text("Skip").tag(String?.none)
                            ForEach(imageDirectoryOptions, id: \.self) { directory in
                                Text(directoryLabel(for: directory)).tag(Optional(directory))
                            }
                        }
                    }
                }

                if !fontDirectoryOptions.isEmpty {
                    Section("Fonts") {
                        Picker("Font Directory", selection: $selectedFontDirectory) {
                            Text("Skip").tag(String?.none)
                            ForEach(fontDirectoryOptions, id: \.self) { directory in
                                Text(directoryLabel(for: directory)).tag(Optional(directory))
                            }
                        }

                        Text("Selecting a font directory imports its font files into the project font library. You can also skip this step.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        completeImport(selectedEntryFile, selectedImageDirectory, selectedFontDirectory)
                    }
                    .disabled(!canContinue)
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
        .onAppear {
            if requiresEntrySelection {
                selectedEntryFile = entryFileOptions.contains(document.entryFileName) ? document.entryFileName : entryFileOptions.first
            }
        }
    }

    private func directoryLabel(for directory: String) -> String {
        directory.isEmpty ? L10n.tr("Project Root") : directory
    }
}
