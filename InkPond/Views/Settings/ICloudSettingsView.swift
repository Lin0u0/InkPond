//
//  ICloudSettingsView.swift
//  InkPond
//

import SwiftUI
import SwiftData

struct ICloudSettingsView: View {
    @Environment(StorageManager.self) var storageManager
    @Environment(\.modelContext) private var modelContext

    @State private var cloudSyncMonitor = CloudSyncMonitor()

    var body: some View {
        List {
            syncTogglesSection
            if storageManager.mode == .iCloud {
                syncStatusSection
            }
            tipsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("icloud.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            storageManager.refreshICloudAvailability()
            if storageManager.isUsingiCloud {
                cloudSyncMonitor.startMonitoringAll()
            }
        }
        .onChange(of: storageManager.mode) { _, newMode in
            if newMode == .iCloud {
                cloudSyncMonitor.startMonitoringAll()
            } else {
                cloudSyncMonitor.stopMonitoring()
            }
        }
        .onDisappear {
            cloudSyncMonitor.stopMonitoring()
        }
    }

    // MARK: - Sync Toggles

    private var syncTogglesSection: some View {
        Section {
            if storageManager.isMigrating {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                        Text(L10n.tr("icloud.migrating"))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: storageManager.migrationProgress)
                        .tint(.accentColor)
                }
            } else {
                Toggle(isOn: projectSyncBinding) {
                    Label(L10n.tr("icloud.sync_toggle"), systemImage: "doc.text")
                }
                .disabled(!storageManager.iCloudAvailable && storageManager.mode != .iCloud)

                Toggle(isOn: fontSyncBinding) {
                    Label(L10n.tr("icloud.sync_fonts_toggle"), systemImage: "character.textbox")
                }

                Toggle(isOn: packageSyncBinding) {
                    Label(L10n.tr("icloud.sync_packages_toggle"), systemImage: "shippingbox")
                }

                Toggle(isOn: snippetSyncBinding) {
                    Label(L10n.tr("icloud.sync_snippets_toggle"), systemImage: "note.text")
                }
            }

            if let error = storageManager.migrationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if storageManager.canRetryMigration {
                Button {
                    let descriptor = FetchDescriptor<InkPondProject>()
                    let documents = (try? modelContext.fetch(descriptor)) ?? []
                    Task {
                        await storageManager.retryFailedMigration(documents: documents)
                    }
                } label: {
                    Label(
                        L10n.format("icloud.retry_migration", storageManager.failedProjectIDs.count),
                        systemImage: "arrow.clockwise"
                    )
                }
                .tint(.orange)
            }
        } footer: {
            Text(storageManager.mode == .iCloud
                 ? L10n.tr("icloud.sync_footer.on")
                 : L10n.tr("icloud.sync_footer.off"))
        }
    }

    // MARK: - Sync Status

    private var syncStatusSection: some View {
        Section(L10n.tr("icloud.status_section")) {
            syncStatusRow

            if cloudSyncMonitor.summary.errored > 0 {
                syncErrorDetailRow
            }
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        let summary = cloudSyncMonitor.summary
        let lightColor = syncLightColor(for: summary)

        Label {
            HStack {
                syncStatusText(for: summary)
                Spacer()
                if cloudSyncMonitor.isGathering || summary.hasActivity {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        } icon: {
            Circle()
                .fill(lightColor)
                .frame(width: 10, height: 10)
                .shadow(color: lightColor.opacity(0.5), radius: 3)
        }
    }

    private var syncErrorDetailRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(L10n.tr("icloud.error.sync_issues_title"))
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }

            Text(L10n.tr("icloud.error.sync_issues_body"))
                .font(.caption)
                .foregroundStyle(.secondary)

            let errorFiles = cloudSyncMonitor.fileStatuses.compactMap { key, status -> String? in
                if case .error = status { return key }
                return nil
            }.prefix(5)

            if !errorFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(errorFiles), id: \.self) { file in
                        Text(file)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                    }
                    if cloudSyncMonitor.summary.errored > errorFiles.count {
                        Text(L10n.format("icloud.error.and_more", cloudSyncMonitor.summary.errored - errorFiles.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tips

    private var tipsSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.min")
                    .foregroundStyle(.orange)
                Text(L10n.tr("icloud.keep_downloaded_tip"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    private func syncLightColor(for summary: CloudSyncMonitor.SyncSummary) -> Color {
        if cloudSyncMonitor.isGathering { return .yellow }
        if summary.errored > 0 { return .red }
        if summary.hasActivity || summary.notDownloaded > 0 { return .yellow }
        if summary.total == 0 { return .secondary }
        return .green
    }

    private func syncStatusText(for summary: CloudSyncMonitor.SyncSummary) -> some View {
        Group {
            if cloudSyncMonitor.isGathering {
                Text(L10n.tr("icloud.status.checking"))
            } else if summary.errored > 0 {
                Text(L10n.format("icloud.status.error", summary.errored))
            } else if summary.hasActivity {
                if summary.downloading > 0 && summary.uploading > 0 {
                    Text(L10n.format("icloud.status.syncing", summary.downloading + summary.uploading))
                } else if summary.downloading > 0 {
                    Text(L10n.format("icloud.status.downloading", summary.downloading))
                } else {
                    Text(L10n.format("icloud.status.uploading", summary.uploading))
                }
            } else if summary.notDownloaded > 0 {
                Text(L10n.format("icloud.status.not_downloaded", summary.notDownloaded))
            } else if summary.total == 0 {
                Text(L10n.tr("icloud.status.no_files"))
            } else {
                Text(L10n.format("icloud.status.synced", summary.total))
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Bindings

    private var projectSyncBinding: Binding<Bool> {
        Binding(
            get: { storageManager.mode == .iCloud },
            set: { newValue in
                let targetMode: StorageMode = newValue ? .iCloud : .local
                let descriptor = FetchDescriptor<InkPondProject>()
                let documents = (try? modelContext.fetch(descriptor)) ?? []
                Task {
                    await storageManager.setMode(targetMode, documents: documents)
                }
            }
        )
    }

    private var fontSyncBinding: Binding<Bool> {
        Binding(
            get: { storageManager.syncFontsInICloud },
            set: { newValue in
                Task { await storageManager.setSyncFontsInICloud(newValue) }
            }
        )
    }

    private var packageSyncBinding: Binding<Bool> {
        Binding(
            get: { storageManager.syncPackagesInICloud },
            set: { newValue in
                Task { await storageManager.setSyncPackagesInICloud(newValue) }
            }
        )
    }

    private var snippetSyncBinding: Binding<Bool> {
        Binding(
            get: { storageManager.syncSnippetsInICloud },
            set: { newValue in
                Task { await storageManager.setSyncSnippetsInICloud(newValue) }
            }
        )
    }
}
