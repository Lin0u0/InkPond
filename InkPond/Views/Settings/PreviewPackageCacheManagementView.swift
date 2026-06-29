//
//  PreviewPackageCacheManagementView.swift
//  InkPond
//

import SwiftUI

struct PreviewPackageCacheManagementView: View {
    @State private var snapshot = PreviewPackageCacheSnapshot(entries: [])
    @State private var isLoading = true
    @State private var cacheError: String?
    @State private var showingClearAllConfirmation = false

    private let store = PreviewPackageCacheStore()

    var body: some View {
        List {
            overviewSection
            packagesSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("Package Cache"))
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
        .alert(L10n.tr("Clear All Package Cache?"), isPresented: $showingClearAllConfirmation) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Clear All"), role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text(L10n.tr("This removes all downloaded @preview packages. They will be downloaded again on the next compile."))
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
                Label(L10n.tr("Cached Packages"), systemImage: "shippingbox")
                Spacer()
                Text(snapshot.entries.count, format: .number)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var packagesSection: some View {
        Section(L10n.tr("Packages")) {
            if !isLoading && snapshot.entries.isEmpty {
                Text(L10n.tr("No cached @preview packages"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayName)
                                .font(.body.weight(.medium))
                            Text(entry.version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formattedSize(entry.sizeInBytes))
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
            Button(L10n.tr("Clear All Package Cache"), role: .destructive) {
                showingClearAllConfirmation = true
            }
            .disabled(isLoading || snapshot.entries.isEmpty)
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            let rootURL = store.rootURL
            let latestSnapshot = try await Task.detached(priority: .userInitiated) {
                try PreviewPackageCacheStore(rootURL: rootURL).snapshot()
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

    private func delete(_ entry: PreviewPackageCacheEntry) async {
        do {
            let rootURL = store.rootURL
            try await Task.detached(priority: .userInitiated) {
                try PreviewPackageCacheStore(rootURL: rootURL).remove(entry)
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
            let rootURL = store.rootURL
            try await Task.detached(priority: .userInitiated) {
                try PreviewPackageCacheStore(rootURL: rootURL).clearAll()
            }.value
            await refresh()
        } catch {
            await MainActor.run {
                cacheError = error.localizedDescription
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
