//
//  LinkedFolderLoadProgressView.swift
//  InkPond
//

import SwiftUI

struct LinkedFolderLoadProgressView: View {
    let title: String
    let progress: LinkedFolderLoadProgress
    let cancel: () -> Void

    private var message: String {
        progress.localizedStatusMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                progressAccessory

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 8)

                Button(L10n.tr("Cancel"), action: cancel)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel(Text(message))
                    .animation(.smooth(duration: 0.2), value: fraction)
                    .accessibilityValue(Text(progressAccessibilityValue(fraction)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
    }

    @ViewBuilder
    private var progressAccessory: some View {
        if progress.fractionCompleted == nil {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    private func progressAccessibilityValue(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension LinkedFolderLoadProgress {
    var localizedStatusMessage: String {
        switch phase {
        case .scanning:
            L10n.tr("icloud.status.checking")
        case .downloading:
            if totalDownloadFileCount == 0 || remainingDownloadFileCount == 0 {
                L10n.format("icloud.status.synced", scannedFileCount)
            } else {
                L10n.format("icloud.status.downloading", remainingDownloadFileCount)
            }
        }
    }
}
