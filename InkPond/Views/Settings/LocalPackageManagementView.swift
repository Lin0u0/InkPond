//
//  LocalPackageManagementView.swift
//  InkPond
//

import SwiftUI
import UniformTypeIdentifiers

struct LocalPackageManagementView: View {
    @Environment(StorageManager.self) private var storageManager

    @State private var snapshot = LocalPackageSnapshot(entries: [])
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var isChangingNamespace = false
    @State private var errorMessage: String?
    @State private var showingImporter = false
    @State private var showingClearAllConfirmation = false
    @State private var successMessage: String?
    @State private var statusMessage: String?
    @State private var editingNamespaceEntry: LocalPackageEntry?
    @State private var editingNamespaceValue: String = ""
    @State private var directoryMonitor = DirectoryMonitor()
    @AppStorage("localPackageDefaultNamespace") private var defaultNamespace: String = "local"

    private var store: LocalPackageStore { LocalPackageStore() }

    var body: some View {
        List {
            importSection
            infoSection
            if isPerformingOperation || statusMessage != nil {
                statusSection
            }
            packagesSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("local_packages.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            try? store.ensureRootDirectory()
            await refresh()
            await MainActor.run {
                startMonitoringPackagesDirectory()
            }
        }
        .refreshable { await refresh() }
        .onAppear {
            startMonitoringPackagesDirectory()
        }
        .onDisappear {
            directoryMonitor.stop()
        }
        .onChange(of: storageManager.mode) { _, _ in
            try? store.ensureRootDirectory()
            startMonitoringPackagesDirectory()
            Task { await refresh() }
        }
        .onChange(of: storageManager.syncPackagesInICloud) { _, _ in
            try? store.ensureRootDirectory()
            startMonitoringPackagesDirectory()
            Task { await refresh() }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.supportedImportTypes,
            allowsMultipleSelection: true
        ) { result in
            handleItemsImport(result)
        }
        .alert(L10n.tr("Error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.tr("OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            L10n.tr("local_packages.success_title"),
            isPresented: Binding(
                get: { successMessage != nil },
                set: { if !$0 { successMessage = nil } }
            )
        ) {
            Button(L10n.tr("OK")) { successMessage = nil }
        } message: {
            if let successMessage {
                Text(successMessage)
            }
        }
        .alert(L10n.tr("local_packages.clear_all_title"), isPresented: $showingClearAllConfirmation) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("local_packages.clear_all_button"), role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text(L10n.tr("local_packages.clear_all_message"))
        }
        .sheet(item: $editingNamespaceEntry) { entry in
            namespaceEditorSheet(for: entry)
        }
    }

    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("local_packages.namespace"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text(verbatim: "@")
                        .font(.subheadline.monospaced().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .accessibilityHidden(true)

                    TextField(
                        L10n.tr("local_packages.namespace"),
                        text: $defaultNamespace,
                        prompt: Text(verbatim: "local")
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .accessibilityLabel(L10n.tr("local_packages.namespace"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .systemFloatingSurface(cornerRadius: 16)
            }
            .padding(.vertical, 4)
        } footer: {
            Text(L10n.tr("local_packages.namespace_hint"))
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label(L10n.tr("local_packages.import"), systemImage: "square.and.arrow.down")
            }
            .disabled(isPerformingOperation)
        } footer: {
            Text(L10n.tr("local_packages.import_tips.footer"))
        }
    }

    private func packageRow(_ entry: LocalPackageEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(entry.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(formattedSize(entry.sizeInBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Menu {
                Button {
                    beginNamespaceEdit(for: entry)
                } label: {
                    Label(L10n.tr("local_packages.change_namespace"), systemImage: "arrow.left.arrow.right")
                }

                Button(L10n.tr("Delete"), role: .destructive) {
                    Task { await delete(entry) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
            .disabled(isPerformingOperation)
            .accessibilityLabel(L10n.tr("local_packages.actions"))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                beginNamespaceEdit(for: entry)
            } label: {
                Label(L10n.tr("local_packages.change_namespace"), systemImage: "arrow.left.arrow.right")
            }

            Button(L10n.tr("Delete"), role: .destructive) {
                Task { await delete(entry) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(L10n.tr("Delete"), role: .destructive) {
                Task { await delete(entry) }
            }
            .disabled(isPerformingOperation)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginNamespaceEdit(for: entry)
            } label: {
                Label(L10n.tr("local_packages.change_namespace"), systemImage: "arrow.left.arrow.right")
            }
            .tint(.blue)
            .disabled(isPerformingOperation)
        }
        .accessibilityLabel(entry.spec)
        .accessibilityValue(formattedSize(entry.sizeInBytes))
    }

    private func beginNamespaceEdit(for entry: LocalPackageEntry) {
        editingNamespaceValue = entry.namespace
        editingNamespaceEntry = entry
    }

    private var statusSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if isPerformingOperation {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                }

                Text(statusMessage ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var packagesSection: some View {
        Section(L10n.tr("local_packages.section_title")) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if snapshot.entries.isEmpty {
                Text(L10n.tr("local_packages.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.entries) { entry in
                    packageRow(entry)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button(L10n.tr("local_packages.clear_all_button"), role: .destructive) {
                showingClearAllConfirmation = true
            }
            .disabled(isLoading || snapshot.entries.isEmpty || isPerformingOperation)
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            let rootURL = store.rootURL
            let latestSnapshot = try await Task.detached(priority: .userInitiated) {
                try LocalPackageStore(rootURL: rootURL).snapshot()
            }.value
            snapshot = latestSnapshot
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func importFolders(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        isImporting = true
        successMessage = nil
        statusMessage = nil
        defer { isImporting = false }

        let rootURL = store.rootURL
        let namespace = normalizedNamespace
        var importedResults: [LocalPackageImportResult] = []
        var errors: [String] = []

        for url in urls {
            statusMessage = L10n.format("local_packages.status.importing", url.lastPathComponent)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalPackageStore(rootURL: rootURL).importItem(at: url, defaultNamespace: namespace)
                }.value
                importedResults.append(result)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        consumeImportResults(importedResults, errors: errors)
        await refresh()
    }

    private func handleItemsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            return
        }

        guard !urls.isEmpty else { return }
        Task { await importFolders(urls) }
    }

    private func consumeImportResults(_ results: [LocalPackageImportResult], errors: [String]) {
        if !results.isEmpty {
            let importedSpecs = results.map(\.spec)
            let downloadedItemCount = results.reduce(0) { $0 + $1.downloadedItemCount }
            let archiveImportCount = results.filter(\.importedFromArchive).count

            var message = L10n.format("local_packages.imported_message", importedSpecs.joined(separator: "\n"))
            var notes: [String] = []
            if archiveImportCount > 0 {
                notes.append(L10n.format("local_packages.imported_archive_note", archiveImportCount))
            }
            if downloadedItemCount > 0 {
                notes.append(L10n.format("local_packages.imported_downloaded_note", downloadedItemCount))
            }
            if !notes.isEmpty {
                message += "\n\n" + notes.joined(separator: "\n")
                statusMessage = notes.joined(separator: " ")
            } else {
                statusMessage = nil
            }
            successMessage = message
        } else {
            statusMessage = nil
        }

        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    private func delete(_ entry: LocalPackageEntry) async {
        do {
            let rootURL = store.rootURL
            try await Task.detached(priority: .userInitiated) {
                try LocalPackageStore(rootURL: rootURL).remove(entry)
            }.value
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func changeNamespace(for entry: LocalPackageEntry) async {
        isChangingNamespace = true
        statusMessage = L10n.format("local_packages.status.changing_namespace", entry.spec)
        defer { isChangingNamespace = false }

        do {
            let rootURL = store.rootURL
            let targetNamespace = normalizedEditingNamespace
            let updatedEntry = try await Task.detached(priority: .userInitiated) {
                try LocalPackageStore(rootURL: rootURL).changeNamespace(of: entry, to: targetNamespace)
            }.value

            statusMessage = nil
            successMessage = L10n.format(
                "local_packages.namespace_updated_message",
                entry.spec,
                updatedEntry.spec
            )
            editingNamespaceEntry = nil
            await refresh()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func clearAll() async {
        do {
            let rootURL = store.rootURL
            try await Task.detached(priority: .userInitiated) {
                try LocalPackageStore(rootURL: rootURL).clearAll()
            }.value
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var normalizedNamespace: String {
        let trimmed = defaultNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "local" : trimmed
    }

    private var normalizedEditingNamespace: String {
        editingNamespaceValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPerformingOperation: Bool {
        isImporting || isChangingNamespace
    }

    private static var supportedImportTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        if let tar = UTType(filenameExtension: "tar") {
            types.append(tar)
        }
        if let gzip = UTType(filenameExtension: "gz") {
            types.append(gzip)
        }
        if let tgz = UTType(filenameExtension: "tgz") {
            types.append(tgz)
        }
        return Array(Set(types))
    }

    @MainActor
    private func startMonitoringPackagesDirectory() {
        guard let directoryURL = store.rootURL else { return }
        try? store.ensureRootDirectory()

        directoryMonitor.stop()
        directoryMonitor.onChange = {
            Task { await refresh() }
        }
        directoryMonitor.start(url: directoryURL)
    }

    @ViewBuilder
    private func namespaceEditorSheet(for entry: LocalPackageEntry) -> some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.spec)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    TextField(
                        L10n.tr("local_packages.change_namespace_placeholder"),
                        text: $editingNamespaceValue
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } footer: {
                    Text(L10n.tr("local_packages.change_namespace_body"))
                }
            }
            .navigationTitle(L10n.tr("local_packages.change_namespace_title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isChangingNamespace)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) {
                        editingNamespaceEntry = nil
                    }
                    .disabled(isChangingNamespace)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Save")) {
                        Task { await changeNamespace(for: entry) }
                    }
                    .disabled(
                        isChangingNamespace ||
                        normalizedEditingNamespace.isEmpty ||
                        normalizedEditingNamespace == entry.namespace
                    )
                }
            }
        }
    }
}
