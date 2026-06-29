//
//  AcknowledgementsView.swift
//  InkPond
//

import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                creditRow(
                    name: "Typst",
                    detail: L10n.tr("The open-source typesetting system at the core of InkPond."),
                    license: "Apache 2.0",
                    url: "https://typst.app"
                )
                creditRow(
                    name: "Catppuccin",
                    detail: L10n.tr("Soothing pastel color palette powering the editor themes."),
                    license: "MIT",
                    url: "https://github.com/catppuccin/catppuccin"
                )
                creditRow(
                    name: "swift-bridge",
                    detail: L10n.tr("Reference implementation for Swift/Rust interop."),
                    license: "MIT or Apache-2.0",
                    url: "https://github.com/chinedufn/swift-bridge"
                )
            }
            Section(L10n.tr("Special Thanks")) {
                creditRow(
                    name: "Donut",
                    detail: L10n.tr("Thanks to everyone at Donut for support and inspiration."),
                    license: nil,
                    url: "https://donutblogs.com/"
                )
            }
            Section(L10n.tr("Contributors")) {
                creditRow(
                    name: "Ants-Aare",
                    detail: L10n.tr("Contributor"),
                    license: nil,
                    url: "https://github.com/Ants-Aare"
                )
                creditRow(
                    name: "mseidel42",
                    detail: L10n.tr("Contributor"),
                    license: nil,
                    url: "https://github.com/mseidel42"
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("Acknowledgements"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func creditRow(name: String, detail: String, license: String?, url: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.headline)
                Spacer()
                if let license {
                    Text(license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let link = URL(string: url) {
                Link(url, destination: link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
