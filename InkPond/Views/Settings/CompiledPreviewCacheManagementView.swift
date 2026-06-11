//
//  CompiledPreviewCacheManagementView.swift
//  InkPond
//

import SwiftData
import SwiftUI

struct CompiledPreviewCacheManagementView: View {
    @Query(sort: \InkPondDocument.modifiedAt, order: .reverse) private var documents: [InkPondDocument]
    @State private var snapshot = CompiledPreviewCacheSnapshot(entries: [])
    @State private var isLoading = true
    @State private var cacheError: String?
    @State private var showingClearAllConfirmation = false

    private let store = CompiledPreviewCacheStore()

    var body: some View {
        List {
            overviewSection
            entriesSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Compile Cache")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .alert("Cache Error", isPresented: Binding(
            get: { cacheError != nil },
            set: { if !$0 { cacheError = nil } }
        )) {
            Button("OK") { cacheError = nil }
        } message: {
            Text(cacheError ?? "")
        }
        .alert("Clear All Compile Cache?", isPresented: $showingClearAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text("This removes all cached compiled previews. Documents will recompile the next time they open.")
        }
    }

    private var overviewSection: some View {
        Section("Overview") {
            HStack {
                Label("Total Size", systemImage: "internaldrive")
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Text(formattedSize(snapshot.totalSizeInBytes))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Cached Documents", systemImage: "doc.richtext")
                Spacer()
                Text(snapshot.entries.count, format: .number)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        Section("Documents") {
            if !isLoading && snapshot.entries.isEmpty {
                Text("No cached document previews")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(displayTitle(for: entry))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(formattedSize(totalSize(for: entry)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.entryFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(updatedAtText(for: entry.updatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            Task { await delete(entry) }
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Clear All Compile Cache", role: .destructive) {
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
                try CompiledPreviewCacheStore(rootURL: rootURL).snapshot()
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

    private func delete(_ entry: CompiledPreviewCacheEntry) async {
        do {
            let rootURL = store.rootURL
            try await Task.detached(priority: .userInitiated) {
                try CompiledPreviewCacheStore(rootURL: rootURL).remove(entry)
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
                try CompiledPreviewCacheStore(rootURL: rootURL).clearAll()
            }.value
            await refresh()
        } catch {
            await MainActor.run {
                cacheError = error.localizedDescription
            }
        }
    }

    private func displayTitle(for entry: CompiledPreviewCacheEntry) -> String {
        documents.first(where: { $0.projectID == entry.projectID })?.title ?? entry.documentTitle
    }

    private func updatedAtText(for date: Date) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("Updated %@", comment: "Compiled preview cache updated time"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func totalSize(for entry: CompiledPreviewCacheEntry) -> Int64 {
        entry.pdfSizeInBytes + entry.svgSizeInBytes + entry.sourceMapSizeInBytes
    }
}
