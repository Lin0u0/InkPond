//
//  ProjectFileTreeView.swift
//  InkPond
//

import SwiftUI
import UniformTypeIdentifiers

struct ProjectFileTreeView: View {
    @Bindable var document: InkPondDocument
    var activePath: String?
    var canMutate: Bool = true
    var openNode: (ProjectTreeNode) async -> Void
    var setEntryFile: (String) async -> Bool
    var createFile: (String) async throws -> Void
    var importFile: (URL, String) async throws -> String
    var deleteNode: (ProjectTreeNode) async throws -> Void
    var onNodeDeleted: (ProjectTreeNode) -> Void
    var closeAfterOpen: Bool = false
    var usesNavigationToolbar: Bool = true
    var topContentInset: CGFloat = 0
    var refreshToken: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(StorageManager.self) private var storageManager
    @State private var projectTree: [ProjectTreeNode] = []
    @State private var expandedNodes: Set<String> = []
    @State private var showingProjectSettings = false
    @State private var showingNewFileAlert = false
    @State private var newFileName = ""
    @State private var showingImporter = false
    @State private var actionError: String?
    @State private var showingActionError = false
    @State private var cloudSyncMonitor = CloudSyncMonitor()

    private var visibleRows: [VisibleProjectFileRow] {
        var rows: [VisibleProjectFileRow] = []
        appendVisibleRows(from: projectTree, depth: 0, into: &rows)
        return rows
    }

    private var hasNotDownloadedFiles: Bool {
        cloudSyncMonitor.fileStatuses.values.contains { status in
            if case .notDownloaded = status { return true }
            return false
        }
    }

    private var primaryTextColor: Color { .primary }

    private var secondaryTextColor: Color { .secondary }

    private var entryBadgeColor: Color { .accentColor }

    private var editingBadgeColor: Color { .green }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if projectTree.isEmpty {
                        Text(L10n.tr("No files"))
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(visibleRows) { row in
                            rowView(for: row)
                        }
                    }
                }
                .padding(.horizontal, usesNavigationToolbar ? 8 : 12)
                .padding(.top, 8 + topContentInset)
                .padding(.bottom, 8)
            }
            .softScrollEdgeEffect()
            .background(Color.clear)
        }
        .accessibilityIdentifier("project-file-tree")
        .toolbar {
            if usesNavigationToolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    projectSettingsButton
                    downloadAllButtonIfNeeded
                    addFileMenu
                }
            }
        }
        .alert(L10n.tr("New Source File"), isPresented: $showingNewFileAlert) {
            TextField(L10n.tr("filename.typ"), text: $newFileName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L10n.tr("Create")) { createNewFile() }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Enter a name for the new .typ file."))
        }
        .alert(L10n.tr("Error"), isPresented: $showingActionError) {
            Button(L10n.tr("OK")) {}
        } message: {
            Text(actionError ?? "")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .onAppear {
            refreshProjectState()
            startCloudMonitoringIfNeeded()
        }
        .onDisappear {
            cloudSyncMonitor.stopMonitoring()
        }
        .onChange(of: document.imageDirectoryName) { _, _ in
            refreshProjectState()
        }
        .onChange(of: refreshToken) { _, _ in
            refreshProjectState()
            startCloudMonitoringIfNeeded()
        }
        .onChange(of: actionError) { _, newValue in
            guard newValue != nil else { return }
            InteractionFeedback.notify(.error)
            AccessibilitySupport.announce(newValue)
        }
        .sheet(isPresented: $showingProjectSettings, onDismiss: refreshProjectState) {
            ProjectSettingsSheet(document: document) { path in
                Task {
                    await openNode(ProjectTreeNode(
                        relativePath: path,
                        displayName: (path as NSString).lastPathComponent,
                        kind: ProjectFileManager.fileKind(for: path, imageDirectoryName: document.imageDirectoryName),
                        children: []
                    ))
                    if closeAfterOpen { dismiss() }
                }
            }
        }
    }

    private var inlineProjectControls: some View {
        HStack {
            Spacer(minLength: 0)
            inlineProjectActionControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.clear)
        .accessibilityLabel(L10n.tr("Project Files"))
    }

    private var inlineProjectActionControls: some View {
        HStack(spacing: 2) {
            projectSettingsButton
            downloadAllButtonIfNeeded
            addFileMenu
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .projectSidebarControlCapsuleSurface()
    }

    private var projectSettingsButton: some View {
        Button {
            guard canMutate else { return }
            InteractionFeedback.impact(.light)
            showingProjectSettings = true
        } label: {
            projectControlIcon("gearshape")
        }
        .disabled(!canMutate)
        .modifier(ProjectFileToolbarControlStyleModifier(usesNavigationToolbar: usesNavigationToolbar))
        .accessibilityLabel(L10n.a11yProjectFilesSettingsLabel)
        .accessibilityHint(L10n.a11yProjectFilesSettingsHint)
        .accessibilityIdentifier("project-files.settings")
    }

    @ViewBuilder
    private var downloadAllButtonIfNeeded: some View {
        if storageManager.isUsingiCloud && hasNotDownloadedFiles {
            Button {
                cloudSyncMonitor.downloadAll()
                InteractionFeedback.impact(.light)
            } label: {
                projectControlIcon("icloud.and.arrow.down")
            }
            .modifier(ProjectFileToolbarControlStyleModifier(usesNavigationToolbar: usesNavigationToolbar))
            .accessibilityLabel(L10n.tr("icloud.download_all"))
            .accessibilityIdentifier("project-files.download-all")
        }
    }

    private var addFileMenu: some View {
        Menu {
            Button {
                newFileName = ""
                showingNewFileAlert = true
            } label: {
                Label(L10n.tr("New .typ File"), systemImage: "doc.badge.plus")
            }
            Button {
                showingImporter = true
            } label: {
                Label(L10n.tr("Import File"), systemImage: "square.and.arrow.down")
            }
        } label: {
            projectControlIcon("plus")
        }
        .modifier(ProjectFileToolbarControlStyleModifier(usesNavigationToolbar: usesNavigationToolbar))
        .accessibilityLabel(L10n.a11yProjectFilesAddLabel)
        .accessibilityHint(L10n.a11yProjectFilesAddHint)
        .accessibilityIdentifier("project-files.add-menu")
    }

    @ViewBuilder
    private func projectControlIcon(_ systemName: String) -> some View {
        if usesNavigationToolbar {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
    }

    private func rowView(for row: VisibleProjectFileRow) -> some View {
        let node = row.node
        let isActive = node.relativePath == activePath

        return Button {
            if node.isDirectory {
                toggleExpansion(for: node.relativePath)
            } else {
                Task {
                    await openNode(node)
                    if closeAfterOpen { dismiss() }
                }
            }
        } label: {
            rowLabel(for: row)
        }
        .buttonStyle(ProjectFileRowButtonStyle(isActive: isActive))
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !node.isDirectory {
                if node.kind == .typ, node.relativePath != document.entryFileName {
                    Button {
                        Task {
                            if await setEntryFile(node.relativePath) {
                                refreshProjectState()
                            }
                        }
                    } label: {
                        Label(L10n.tr("Set Entry"), systemImage: "target")
                    }
                }

                Button(role: .destructive) {
                    deleteFile(node)
                } label: {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                }
                .disabled(node.relativePath == document.entryFileName)
            }
        }
        .contextMenu {
            if !node.isDirectory {
                Button {
                    Task {
                        await openNode(node)
                        if closeAfterOpen { dismiss() }
                    }
                } label: {
                    Label(L10n.tr(node.kind.isTextEditable ? "Open" : "Preview"), systemImage: node.kind.iconName)
                }

                if node.kind == .typ, node.relativePath != document.entryFileName {
                    Button {
                        Task {
                            if await setEntryFile(node.relativePath) {
                                refreshProjectState()
                            }
                        }
                    } label: {
                        Label(L10n.tr("Set Entry"), systemImage: "target")
                    }
                }

                Button(role: .destructive) {
                    deleteFile(node)
                } label: {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                }
                .disabled(node.relativePath == document.entryFileName)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(for: row))
        .accessibilityHint(node.isDirectory ? L10n.a11yProjectFilesExpandHint : L10n.a11yProjectFilesOpenHint)
        .accessibilityValue(rowAccessibilityValue(for: row))
        .accessibilityIdentifier("project-files.row.\(node.relativePath)")
        .accessibilityAddTraits(.isButton)
    }

    private func rowLabel(for row: VisibleProjectFileRow) -> some View {
        let node = row.node
        let isActive = node.relativePath == activePath
        return HStack(alignment: .center, spacing: 8) {
            if node.isDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? primaryTextColor.opacity(0.72) : secondaryTextColor.opacity(0.74))
                    .frame(width: 14, height: 20, alignment: .center)
            } else {
                Color.clear
                    .frame(width: 14, height: 20)
            }

            Image(systemName: node.kind.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? primaryTextColor : secondaryTextColor)
                .frame(width: 22, height: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.displayName)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? primaryTextColor : primaryTextColor.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if hasBadges(for: node.relativePath) {
                    badges(for: node.relativePath)
                }
            }

            if storageManager.isUsingiCloud, !node.isDirectory {
                cloudStatusIndicator(for: node.relativePath)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cloudStatusIndicator(for relativePath: String) -> some View {
        switch cloudSyncMonitor.fileStatuses[relativePath] {
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .onTapGesture {
                    let url = ProjectFileManager.projectDirectory(for: document)
                        .appendingPathComponent(relativePath)
                    cloudSyncMonitor.startDownloading(at: url)
                    InteractionFeedback.impact(.light)
                }
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
        case .uploading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
                .tint(.orange)
        case .error:
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .current, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func badges(for path: String) -> some View {
        HStack(spacing: 4) {
            if path == document.entryFileName {
                Text(L10n.tr("Entry"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entryBadgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(entryBadgeColor)
            }
            if path == activePath {
                Text(L10n.tr("Editing"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(editingBadgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(editingBadgeColor)
            }
        }
    }

    private func hasBadges(for path: String) -> Bool {
        path == document.entryFileName || path == activePath
    }

    private func appendVisibleRows(from nodes: [ProjectTreeNode], depth: Int, into rows: inout [VisibleProjectFileRow]) {
        for node in nodes {
            let isExpanded = expandedNodes.contains(node.relativePath)
            rows.append(VisibleProjectFileRow(node: node, depth: depth, isExpanded: isExpanded))
            if node.isDirectory, isExpanded {
                appendVisibleRows(from: node.children, depth: depth + 1, into: &rows)
            }
        }
    }

    private func toggleExpansion(for path: String) {
        InteractionFeedback.selection()
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
            if expandedNodes.contains(path) {
                expandedNodes.remove(path)
            } else {
                expandedNodes.insert(path)
            }
        }
    }

    private func refreshProjectState() {
        projectTree = ProjectFileManager.projectTree(for: document)
    }

    private func startCloudMonitoringIfNeeded() {
        guard storageManager.isUsingiCloud else { return }
        let projectDir = ProjectFileManager.projectDirectory(for: document)
        cloudSyncMonitor.startMonitoring(projectURL: projectDir)
    }

    private func createNewFile() {
        guard canMutate else { return }
        var name = newFileName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && !name.hasSuffix(".typ") {
            name += ".typ"
        }
        guard !name.isEmpty else { return }
        Task {
            do {
                try await createFile(name)
                refreshProjectState()
                await openNode(ProjectTreeNode(relativePath: name, displayName: (name as NSString).lastPathComponent, kind: .typ, children: []))
                InteractionFeedback.notify(.success)
                if closeAfterOpen { dismiss() }
            } catch {
                present(error)
            }
        }
    }

    private func deleteFile(_ node: ProjectTreeNode) {
        guard canMutate else { return }
        Task {
            do {
                try await deleteNode(node)
                if node.kind == .font {
                    ProjectFileManager.removeFontReference(relativePath: node.relativePath, from: document)
                }
                onNodeDeleted(node)
                refreshProjectState()
                InteractionFeedback.notify(.warning)
            } catch {
                present(error)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard canMutate else { return }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                present(error)
            }
            return
        }

        Task {
            var firstError: Error?
            for url in urls {
            let ext = url.pathExtension.lowercased()
            let subdir: String
            if ProjectFileManager.supportedImageFileExtensions.contains(ext) {
                subdir = document.imageDirectoryName
            } else if ProjectFileManager.fontFileExtensions.contains(ext) {
                subdir = "fonts"
            } else {
                subdir = ""
            }

            do {
                let importedPath = try await importFile(url, subdir)
                if ProjectFileManager.fontFileExtensions.contains(ext) {
                    let name = url.lastPathComponent
                    if !document.fontFileNames.contains(name) {
                        document.fontFileNames.append(name)
                    }
                }
                if urls.count == 1 {
                    let node = ProjectTreeNode(
                        relativePath: importedPath,
                        displayName: (importedPath as NSString).lastPathComponent,
                        kind: ProjectFileManager.fileKind(for: importedPath, imageDirectoryName: document.imageDirectoryName),
                        children: []
                    )
                    await openNode(node)
                    if closeAfterOpen { dismiss() }
                }
            } catch {
                firstError = firstError ?? error
            }
            }
            refreshProjectState()
            InteractionFeedback.notify(.success)
            if let firstError {
                present(firstError)
            }
        }
    }

    private func present(_ error: Error) {
        actionError = error.localizedDescription
        showingActionError = true
    }

    private func rowAccessibilityLabel(for row: VisibleProjectFileRow) -> String {
        let node = row.node
        if node.isDirectory {
            return L10n.a11yProjectFilesFolderLabel(node.displayName)
        }
        return L10n.a11yProjectFilesFileLabel(kind: node.kind.localizedAccessibilityLabel, name: node.displayName)
    }

    private func rowAccessibilityValue(for row: VisibleProjectFileRow) -> String {
        var values: [String] = []
        if row.node.isDirectory {
            values.append(row.isExpanded ? L10n.a11yStateExpanded : L10n.a11yStateCollapsed)
        }
        if row.node.relativePath == document.entryFileName {
            values.append(L10n.tr("Entry"))
        }
        if row.node.relativePath == activePath {
            values.append(L10n.tr("Editing"))
        }
        return values.joined(separator: ", ")
    }
}

private struct VisibleProjectFileRow: Identifiable, Hashable {
    let node: ProjectTreeNode
    let depth: Int
    let isExpanded: Bool

    var id: String { node.id }
}

private struct ProjectFileRowButtonStyle: ButtonStyle {
    let isActive: Bool

    private var activeColor: Color { .primary }

    private var pressedColor: Color { .secondary }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background { rowBackground(isPressed: configuration.isPressed) }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    @ViewBuilder
    private func rowBackground(isPressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let activeFill = activeColor.opacity(isPressed ? 0.11 : 0.075)
        let activeBorder = activeColor.opacity(0.16)
        let inactivePressedFill = pressedColor.opacity(0.12)
        if isActive {
            if #available(iOS 26, *) {
                shape
                    .fill(activeFill)
                    .lockedLiquidGlassRect(cornerRadius: 13, isInteractive: true)
                    .overlay {
                        shape.strokeBorder(activeBorder, lineWidth: 1)
                    }
            } else {
                shape
                    .fill(activeFill)
                    .overlay {
                        shape.strokeBorder(activeBorder, lineWidth: 1)
                    }
            }
        } else if isPressed {
            shape.fill(inactivePressedFill)
        } else {
            Color.clear
        }
    }
}

private struct ProjectFileToolbarControlStyleModifier: ViewModifier {
    let usesNavigationToolbar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesNavigationToolbar {
            content
        } else {
            content.buttonStyle(.plain)
        }
    }
}

private extension View {
    @ViewBuilder
    func projectSidebarControlCapsuleSurface() -> some View {
        if #available(iOS 26, *) {
            self.lockedLiquidGlassRect(cornerRadius: 22, isInteractive: true)
        } else {
            self.systemFloatingSurface(cornerRadius: 22)
        }
    }
}
