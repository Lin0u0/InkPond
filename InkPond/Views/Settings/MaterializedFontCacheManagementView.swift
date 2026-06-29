//
//  MaterializedFontCacheManagementView.swift
//  InkPond
//

import SwiftUI

struct MaterializedFontCacheManagementView: View {
    @State private var snapshot = MaterializedFontCacheSnapshot(entries: [])
    @State private var isLoading = true
    @State private var cacheError: String?
    @State private var showingClearAllConfirmation = false

    var body: some View {
        List {
            overviewSection
            fontsSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("System Font Cache"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .alert(L10n.tr("Cache Error"), isPresented: Binding(
            get: { cacheError != nil },
            set: { if !$0 { cacheError = nil } }
        )) {
            Button(L10n.tr("OK")) { cacheError = nil }
        } message: {
            Text(cacheError ?? "")
        }
        .alert(L10n.tr("Clear System Font Cache?"), isPresented: $showingClearAllConfirmation) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Clear All"), role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text(L10n.tr("This removes generated system font files. InkPond will rebuild them the next time a document needs them."))
        }
    }

    private var overviewSection: some View {
        Section(L10n.tr("Overview")) {
            HStack {
                Label(L10n.tr("Total Size"), systemImage: "internaldrive")
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Text(formattedSize(snapshot.totalSizeInBytes))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label(L10n.tr("Cached Fonts"), systemImage: "textformat")
                Spacer()
                Text(snapshot.entries.count, format: .number)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr("Generated system font files stay local to this device and are excluded from iCloud Backup."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fontsSection: some View {
        Section(L10n.tr("Fonts")) {
            if !isLoading && snapshot.entries.isEmpty {
                Text(L10n.tr("No cached system fonts"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.displayName)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(formattedSize(entry.sizeInBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.postScriptName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text(entry.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(updatedAtText(for: entry.modifiedAt))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(L10n.tr("Delete"), role: .destructive) {
                            Task { await delete(entry) }
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button(L10n.tr("Clear System Font Cache"), role: .destructive) {
                showingClearAllConfirmation = true
            }
            .disabled(isLoading || snapshot.entries.isEmpty)
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            let latestSnapshot = try await Task.detached(priority: .userInitiated) {
                try CoreTextFontMaterializer.persistentCacheSnapshot()
            }.value
            await MainActor.run {
                snapshot = latestSnapshot
                isLoading = false
            }
        } catch {
            await MainActor.run {
                cacheError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func delete(_ entry: MaterializedFontCacheEntry) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try CoreTextFontMaterializer.removeCachedFont(entry)
            }.value
            await refresh()
        } catch {
            await MainActor.run {
                cacheError = error.localizedDescription
            }
        }
    }

    private func clearAll() async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try CoreTextFontMaterializer.clearPersistentCache()
            }.value
            await refresh()
        } catch {
            await MainActor.run {
                cacheError = error.localizedDescription
            }
        }
    }

    private func updatedAtText(for date: Date) -> String {
        L10n.format("Updated %@", date.formatted(date: .abbreviated, time: .shortened))
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
