//
//  BetaDiagnosticsView.swift
//  InkPond
//

import SwiftUI
import UIKit

struct BetaDiagnosticsView: View {
    @Environment(StorageManager.self) private var storageManager
    @State private var cloudSyncMonitor = CloudSyncMonitor()
    @State private var copiedSummary = false
    @State private var refreshToken = UUID()

    private var snapshot: BetaDiagnosticsSnapshot {
        _ = refreshToken
        return BetaDiagnosticsSnapshot.current(
            storageMode: storageManager.mode.rawValue,
            iCloudSummary: iCloudSummaryText
        )
    }

    private var iCloudSummaryText: String {
        guard storageManager.isUsingiCloud else {
            return L10n.tr("beta_diagnostics.icloud.local")
        }
        let summary = cloudSyncMonitor.summary
        if summary.total == 0 {
            return L10n.tr("beta_diagnostics.icloud.no_items")
        }
        return L10n.format(
            "beta_diagnostics.icloud.summary_format",
            summary.current,
            summary.downloading,
            summary.uploading,
            summary.notDownloaded,
            summary.errored
        )
    }

    var body: some View {
        List {
            overviewSection
            actionsSection
            metricKitSection
            recentEventsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("beta_diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.tr("Refresh"))
            }
        }
        .onAppear {
            startCloudMonitoringIfNeeded()
            refresh()
        }
        .onDisappear {
            cloudSyncMonitor.stopMonitoring()
        }
        .onChange(of: storageManager.mode) { _, _ in
            startCloudMonitoringIfNeeded()
            refresh()
        }
    }

    private var overviewSection: some View {
        Section(L10n.tr("beta_diagnostics.overview")) {
            diagnosticRow(
                icon: "number",
                title: L10n.tr("beta_diagnostics.version"),
                value: "\(snapshot.appVersion) (\(snapshot.buildNumber))"
            )
            diagnosticRow(
                icon: "testtube.2",
                title: L10n.tr("beta_diagnostics.distribution"),
                value: snapshot.distribution
            )
            diagnosticRow(
                icon: "internaldrive",
                title: L10n.tr("beta_diagnostics.available_storage"),
                value: BetaDiagnosticsSnapshot.formattedBytes(snapshot.storage.bestAvailableBytes)
            )
            diagnosticRow(
                icon: "icloud",
                title: L10n.tr("beta_diagnostics.icloud"),
                value: iCloudSummaryText
            )
            diagnosticRow(
                icon: "doc.text.magnifyingglass",
                title: L10n.tr("beta_diagnostics.last_open_session"),
                value: snapshot.lastDocumentOpenSessionID ?? L10n.tr("beta_diagnostics.none")
            )
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = snapshot.feedbackSummary
                copiedSummary = true
                InteractionFeedback.impact(.light)
                Diagnostics.record(.appLifecycle, "beta_diagnostics.copy_summary")
            } label: {
                Label(L10n.tr("beta_diagnostics.copy_summary"), systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("settings.beta-diagnostics.copy-summary")

            if copiedSummary {
                Label(L10n.tr("beta_diagnostics.copied"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.tr("beta_diagnostics.footer"))
        }
    }

    private var metricKitSection: some View {
        Section(L10n.tr("beta_diagnostics.metrickit")) {
            if snapshot.recentMetricSummaries.isEmpty {
                Text(L10n.tr("beta_diagnostics.metrickit.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.recentMetricSummaries.prefix(8)) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.kind)
                            .font(.headline)
                        Text(summary.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let appVersion = summary.appVersion {
                            Text(appVersion)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var recentEventsSection: some View {
        Section(L10n.tr("beta_diagnostics.recent_events")) {
            if snapshot.recentEvents.isEmpty {
                Text(L10n.tr("beta_diagnostics.recent_events.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.recentEvents.prefix(12)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.category.rawValue)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if let sessionID = event.sessionID {
                                Text(sessionID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(event.name)
                            .font(.subheadline)
                        if !event.metadata.isEmpty {
                            Text(event.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func diagnosticRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func startCloudMonitoringIfNeeded() {
        cloudSyncMonitor.stopMonitoring()
        if storageManager.isUsingiCloud {
            cloudSyncMonitor.startMonitoringAll()
        }
    }

    private func refresh() {
        copiedSummary = false
        refreshToken = UUID()
        Diagnostics.recordStorageSnapshot(reason: "beta_diagnostics_refresh")
    }
}
