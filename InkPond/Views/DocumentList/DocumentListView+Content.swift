//
//  DocumentListView+Content.swift
//  InkPond
//

import PDFKit
import SwiftUI
import SwiftData
import UIKit
import WebKit

extension DocumentListView {
    var guardedDocumentSelection: Binding<InkPondDocument?> {
        Binding(
            get: { selectedDocument },
            set: { selectDocumentIfAvailable($0) }
        )
    }

    var documentList: some View {
        ScrollView {
            LazyVGrid(columns: projectGridColumns, spacing: 16) {
                ForEach(sortedDocuments) { document in
                    documentRow(document)
                }
            }
            .padding(.horizontal, isIPad ? 24 : 16)
            .padding(.vertical, 16)
        }
        .softScrollEdgeEffect()
        .background(Color(uiColor: projectHomeChromeUIColor).ignoresSafeArea())
        .overlay {
            if isShowingLibraryEmptyState {
                libraryEmptyState
            } else if isShowingSearchEmptyState {
                searchEmptyState
            }
        }
        .task {
            startFilesystemMonitoring()
            refreshPreviewCacheSnapshot()
        }
        .onChange(of: storageManager.mode) { _, _ in
            guard !storageManager.isMigrating else { return }
            scheduleFilesystemMonitoringRestart()
        }
        .onChange(of: storageManager.isMigrating) { _, isMigrating in
            guard !isMigrating else { return }
            scheduleFilesystemMonitoringRestart()
        }
        .onChange(of: storageManager.iCloudAvailable) { _, _ in
            scheduleFilesystemMonitoringRestart()
        }
        .onChange(of: documents.map(\.projectID)) { _, _ in
            refreshPreviewCacheSnapshot()
        }
        .onDisappear {
            monitor.stop()
            syncTask?.cancel()
            syncTask = nil
            monitorRestartTask?.cancel()
            monitorRestartTask = nil
            documentOpenTask?.cancel()
            clearDocumentOpenProgress()
        }
    }

    var projectGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: isIPad ? 220 : 155, maximum: 320),
                spacing: 16,
                alignment: .top
            )
        ]
    }

    func documentRow(_ document: InkPondDocument) -> some View {
        Button {
            selectDocumentIfAvailable(document)
        } label: {
            ProjectHomeCard(
                document: document,
                cacheEntry: previewCacheEntriesByProjectID[document.projectID],
                dateFormat: rowDateFormat,
                backgroundColor: projectHomeCardUIColor,
                thumbnailBackgroundColor: projectHomeThumbnailUIColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.a11yDocumentRowLabel(
                title: document.title,
                createdAt: document.createdAt.formatted(rowDateFormat),
                modifiedAt: document.modifiedAt.formatted(rowDateFormat)
            )
        )
        .accessibilityHint(L10n.a11yDocumentRowHint)
        .accessibilityValue(selectedDocument == document ? L10n.tr("a11y.state.selected") : "")
        .accessibilityIdentifier("project-home.card.\(document.projectID)")
        .accessibilityAction(named: Text(L10n.tr("a11y.document_row.action.rename"))) {
            renamingDocument = document
            newTitle = document.title
        }
        .accessibilityAction(named: Text(L10n.tr("a11y.document_row.action.share_pdf"))) {
            exporter.exportPDF(for: document)
        }
        .accessibilityAction(named: Text(L10n.tr("a11y.document_row.action.export_source"))) {
            exporter.exportTypSource(for: document, fileName: document.entryFileName)
        }
        .accessibilityAction(named: Text(document.isExternalFolder ? L10n.tr("a11y.document_row.action.unlink") : L10n.tr("a11y.document_row.action.delete"))) {
            InteractionFeedback.notify(.warning)
            documentToDelete = document
        }
        .contextMenu {
            Button {
                renamingDocument = document
                newTitle = document.title
            } label: {
                Label(L10n.tr("Rename"), systemImage: "pencil")
            }
            Divider()
            Button {
                exporter.exportPDF(for: document)
            } label: {
                Label(L10n.tr("Share PDF"), systemImage: "square.and.arrow.up")
            }
            Button {
                exporter.exportTypSource(for: document, fileName: document.entryFileName)
            } label: {
                Label(L10n.tr("Export .typ"), systemImage: "doc.text")
            }
            Divider()
            Button(role: .destructive) {
                InteractionFeedback.notify(.warning)
                documentToDelete = document
            } label: {
                if document.isExternalFolder {
                    Label(L10n.tr("Unlink"), systemImage: "personalhotspot.slash")
                } else {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                }
            }
        }
    }

    func refreshPreviewCacheSnapshot() {
        previewCacheEntriesByProjectID = Self.loadPreviewCacheEntriesByProjectID()
    }

    var libraryEmptyState: some View {
        ContentUnavailableView {
            Label(L10n.tr("doc.list.empty.title"), systemImage: "folder")
        } description: {
            Text(L10n.tr("doc.list.empty.message"))
        }
    }

    var searchEmptyState: some View {
        ContentUnavailableView.search(text: searchText)
    }

    /// Coalesces multiple rapid onChange triggers (e.g. mode + isMigrating
    /// changing in the same transaction) into a single monitoring restart.
    /// When the settings sheet is open, only restarts the directory monitor
    /// (re-points it at the new URL) and defers the filesystem sync until the
    /// sheet is dismissed — prevents SwiftData mutations from closing the sheet.
    func scheduleFilesystemMonitoringRestart() {
        monitorRestartTask?.cancel()
        monitorRestartTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            if showingSettings {
                restartDirectoryMonitorOnly()
                needsFilesystemSync = true
            } else {
                startFilesystemMonitoring()
            }
        }
    }

    /// Restarts the directory monitor without running an immediate filesystem
    /// sync. Used when the settings sheet is presented to avoid SwiftData
    /// mutations that would dismiss it.
    func restartDirectoryMonitorOnly() {
        monitor.stop()
        syncTask?.cancel()
        syncTask = nil

        guard let docs = ProjectFileManager.syncDocumentsURL else { return }
        monitor.onChange = { scheduleFilesystemSync() }
        monitor.start(url: docs)
    }

    func startFilesystemMonitoring() {
        monitor.stop()
        syncTask?.cancel()
        syncTask = nil

        let migrationAcknowledgements = ProjectFileManager.migrateLegacyStructure(documents: documents)
        if !migrationAcknowledgements.isEmpty {
            do {
                try modelContext.save()
                for acknowledgement in migrationAcknowledgements {
                    try ProjectRootMigrationJournal.acknowledge(
                        projectID: acknowledgement.projectID,
                        destinationURL: acknowledgement.destinationURL
                    )
                }
            } catch {
                projectActionError = error.localizedDescription
            }
        }
        syncWithFilesystem()

        guard let docs = ProjectFileManager.syncDocumentsURL else { return }
        monitor.onChange = { scheduleFilesystemSync() }
        monitor.start(url: docs)
    }

    @ToolbarContentBuilder
    var iPadToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                InteractionFeedback.impact(.light)
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .scaleEffect(0.8)
            }
            .accessibilityLabel(L10n.a11yDocumentListSettingsLabel)
            .accessibilityHint(L10n.a11yDocumentListSettingsHint)
            .accessibilityIdentifier("document-list.settings")
        }
        ToolbarItem(placement: .primaryAction) {
            sortMenu
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                addDocument()
            } label: {
                Image(systemName: "doc.badge.plus")
                    .scaleEffect(0.8)
            }
            .accessibilityLabel(L10n.a11yDocumentListAddLabel)
            .accessibilityHint(L10n.a11yDocumentListAddHint)
            .accessibilityIdentifier("document-list.add")
        }
    }

    @ToolbarContentBuilder
    var iPhoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            sortMenu
        }
        if #available(iOS 26, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                InteractionFeedback.impact(.light)
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(L10n.a11yDocumentListSettingsLabel)
            .accessibilityHint(L10n.a11yDocumentListSettingsHint)
            .accessibilityIdentifier("document-list.settings")
        }
        if #available(iOS 26, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                addDocument()
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .accessibilityLabel(L10n.a11yDocumentListAddLabel)
            .accessibilityHint(L10n.a11yDocumentListAddHint)
            .accessibilityIdentifier("document-list.add")
        }
    }

    var sortMenu: some View {
        Menu {
            Section {
                ForEach(SortField.allCases) { field in
                    Button {
                        selectSortField(field)
                    } label: {
                        sortMenuRow(title: field.label, isSelected: field == sortField)
                    }
                }
            } header: {
                Text(L10n.tr("sort.menu.sort_by"))
            }

            Section {
                ForEach(SortDirection.allCases) { direction in
                    Button {
                        selectSortDirection(direction)
                    } label: {
                        sortMenuRow(title: direction.label, isSelected: direction == sortDirection)
                    }
                }
            } header: {
                Text(L10n.tr("sort.menu.order"))
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .imageScale(.medium)
        }
        .accessibilityLabel(L10n.tr("sort.menu.button"))
        .accessibilityValue(L10n.a11ySortValue(field: sortField.label, direction: sortDirection.label))
        .accessibilityIdentifier("document-list.sort")
    }

    @ViewBuilder
    func sortMenuRow(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    func selectSortField(_ field: SortField) {
        guard field != sortField else { return }
        sortField = field
        announceSortChange()
    }

    func selectSortDirection(_ direction: SortDirection) {
        guard direction != sortDirection else { return }
        sortDirection = direction
        announceSortChange()
    }

    func announceSortChange() {
        InteractionFeedback.selection()
        AccessibilitySupport.announce(
            L10n.a11ySortChanged(
                L10n.a11ySortValue(field: sortField.label, direction: sortDirection.label)
            )
        )
    }
}

private struct ProjectHomeCard: View {
    let document: InkPondDocument
    let cacheEntry: CompiledPreviewCacheEntry?
    let dateFormat: Date.FormatStyle
    let backgroundColor: UIColor
    let thumbnailBackgroundColor: UIColor

    private let cardCornerRadius: CGFloat = 16
    private let thumbnailCornerRadius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProjectHomeThumbnail(cacheEntry: cacheEntry, backgroundColor: thumbnailBackgroundColor)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if document.isExternalFolder {
                        Image(systemName: "link")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(document.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(document.entryFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(L10n.format("doc.time.modified_value", document.modifiedAt.formatted(dateFormat)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: backgroundColor), in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ProjectHomeThumbnail: View {
    let cacheEntry: CompiledPreviewCacheEntry?
    let backgroundColor: UIColor
    @State private var thumbnail: UIImage?
    @State private var svgHTML: String?

    private var thumbnailID: String {
        guard let cacheEntry else { return "empty" }
        let sourcePath = cacheEntry.pdfURL?.path ?? cacheEntry.firstSVGPageURL?.path ?? "empty"
        return "\(sourcePath)-\(cacheEntry.updatedAt.timeIntervalSinceReferenceDate)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: backgroundColor))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            } else if let svgHTML {
                ProjectHomeSVGThumbnailView(html: svgHTML)
                    .padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Typst")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: thumbnailID) {
            await loadThumbnail()
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadThumbnail() async {
        guard cacheEntry != nil else {
            thumbnail = nil
            svgHTML = nil
            return
        }

        if let pdfURL = cacheEntry?.pdfURL,
           let document = PDFDocument(url: pdfURL),
           let page = document.page(at: 0) {
            guard !Task.isCancelled else { return }
            thumbnail = page.thumbnail(of: CGSize(width: 520, height: 680), for: .mediaBox)
            svgHTML = nil
            return
        }

        guard let svgURL = cacheEntry?.firstSVGPageURL else {
            thumbnail = nil
            svgHTML = nil
            return
        }

        let html = try? await Task.detached(priority: .utility) {
            let svg = try String(contentsOf: svgURL, encoding: .utf8)
            return ProjectHomeThumbnail.svgHTML(for: svg)
        }.value
        guard !Task.isCancelled else { return }
        thumbnail = nil
        svgHTML = html
    }

    nonisolated private static func svgHTML(for svg: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        html, body {
          margin: 0;
          padding: 0;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: transparent;
        }
        body {
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .page {
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: transparent;
        }
        .page > svg {
          display: block;
          width: 100%;
          height: 100%;
        }
        </style>
        </head>
        <body>
        <div class="page">
        \(svg)
        </div>
        </body>
        </html>
        """
    }
}

private struct ProjectHomeSVGThumbnailView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML: String?
    }
}
