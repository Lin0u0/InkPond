//
//  DocumentListView+Content.swift
//  InkPond
//

import SwiftUI
import SwiftData

extension DocumentListView {
    var documentList: some View {
        List(selection: $selectedDocument) {
            ForEach(sortedDocuments) { document in
                documentRow(document)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isShowingLibraryEmptyState {
                libraryEmptyState
            } else if isShowingSearchEmptyState {
                searchEmptyState
            }
        }
        .task {
            startFilesystemMonitoring()
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
        .onDisappear {
            monitor.stop()
            syncTask?.cancel()
            syncTask = nil
            monitorRestartTask?.cancel()
            monitorRestartTask = nil
        }
    }

    func documentRow(_ document: InkPondDocument) -> some View {
        NavigationLink(value: document) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if document.isExternalFolder {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                    }
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L10n.tr("doc.time.created")): \(document.createdAt.formatted(rowDateFormat))")
                    Text("\(L10n.tr("doc.time.modified")): \(document.modifiedAt.formatted(rowDateFormat))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
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
        .accessibilityIdentifier("document-list.row.\(document.projectID)")
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
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button {
                exporter.exportPDF(for: document)
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
            }
            Button {
                exporter.exportTypSource(for: document, fileName: document.entryFileName)
            } label: {
                Label("Export .typ", systemImage: "doc.text")
            }
            Divider()
            Button(role: .destructive) {
                InteractionFeedback.notify(.warning)
                documentToDelete = document
            } label: {
                if document.isExternalFolder {
                    Label("Unlink", systemImage: "personalhotspot.slash")
                } else {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
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

        ProjectFileManager.migrateLegacyStructure(documents: documents)
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
            Menu {
                Button(action: addDocument) {
                    Label(L10n.docListNewDocument, systemImage: "doc.badge.plus")
                }
                Button {
                    showingFolderImporter = true
                } label: {
                    Label(L10n.docListLinkExternalFolder, systemImage: "link.badge.plus")
                }
            } label: {
                Image(systemName: "folder.badge.plus")
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
            Menu {
                Button(action: addDocument) {
                    Label(L10n.docListNewDocument, systemImage: "doc.badge.plus")
                }
                Button {
                    showingFolderImporter = true
                } label: {
                    Label(L10n.docListLinkExternalFolder, systemImage: "link")
                }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel(L10n.a11yDocumentListAddLabel)
            .accessibilityHint(L10n.a11yDocumentListAddHint)
            .accessibilityIdentifier("document-list.add")
        }
    }

    var sortMenu: some View {
        Button {
            InteractionFeedback.impact(.light)
            showingSortPopover = true
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .scaleEffect(0.8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("sort.menu.button"))
        .accessibilityValue(L10n.a11ySortValue(field: sortField.label, direction: sortDirection.label))
        .accessibilityIdentifier("document-list.sort")
        .popover(
            isPresented: $showingSortPopover,
            attachmentAnchor: .point(.bottom),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 14) {
                sortSection(title: L10n.tr("sort.menu.sort_by")) {
                    ForEach(SortField.allCases) { field in
                        sortSelectionRow(
                            title: field.label,
                            isSelected: field == sortField
                        ) {
                            sortField = field
                        }
                    }
                }

                Divider()

                sortSection(title: L10n.tr("sort.menu.order")) {
                    ForEach(SortDirection.allCases) { direction in
                        sortSelectionRow(
                            title: direction.label,
                            isSelected: direction == sortDirection
                        ) {
                            sortDirection = direction
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 240)
            .systemFloatingSurface(cornerRadius: 16)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    func sortSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
        }
    }

    func sortSelectionRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showingSortPopover = false
            InteractionFeedback.selection()
            AccessibilitySupport.announce(
                L10n.a11ySortChanged(
                    L10n.a11ySortValue(field: sortField.label, direction: sortDirection.label)
                )
            )
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 12)

                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.primary)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
