//
//  ProjectFileTreeView.swift
//  InkPond
//

import SwiftUI
import UniformTypeIdentifiers

struct ProjectFileTreeView: View {
    @Bindable var document: InkPondDocument
    var activePath: String?
    var openNode: (ProjectTreeNode) -> Void
    var setEntryFile: (String) -> Bool
    var onNodeDeleted: (ProjectTreeNode) -> Void
    var editorTheme: EditorTheme = .system
    var closeAfterOpen: Bool = false
    var usesNavigationToolbar: Bool = true
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

    private var editorTextColor: Color {
        Color(uiColor: editorTheme.text)
    }

    private var editorSecondaryTextColor: Color {
        Color(uiColor: editorTheme.gutterForeground)
    }

    private var editorAccentColor: Color {
        editorTextColor
    }

    private var editorStringColor: Color {
        Color(uiColor: editorTheme.string)
    }

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
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
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
        .alert("New Source File", isPresented: $showingNewFileAlert) {
            TextField("filename.typ", text: $newFileName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") { createNewFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new .typ file.")
        }
        .alert("Error", isPresented: $showingActionError) {
            Button("OK") {}
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
                openNode(ProjectTreeNode(
                    relativePath: path,
                    displayName: (path as NSString).lastPathComponent,
                    kind: ProjectFileManager.fileKind(for: path, imageDirectoryName: document.imageDirectoryName),
                    children: []
                ))
                if closeAfterOpen { dismiss() }
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
            InteractionFeedback.impact(.light)
            showingProjectSettings = true
        } label: {
            projectControlIcon("gearshape")
        }
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
                Label("New .typ File", systemImage: "doc.badge.plus")
            }
            Button {
                showingImporter = true
            } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
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
                openNode(node)
                if closeAfterOpen { dismiss() }
            }
        } label: {
            rowLabel(for: row)
        }
        .buttonStyle(ProjectFileRowButtonStyle(isActive: isActive, editorTheme: editorTheme))
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !node.isDirectory {
                if node.kind == .typ, node.relativePath != document.entryFileName {
                    Button {
                        if setEntryFile(node.relativePath) {
                            refreshProjectState()
                        }
                    } label: {
                        Label("Set Entry", systemImage: "target")
                    }
                }

                Button(role: .destructive) {
                    deleteFile(node)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(node.relativePath == document.entryFileName)
            }
        }
        .contextMenu {
            if !node.isDirectory {
                Button {
                    openNode(node)
                    if closeAfterOpen { dismiss() }
                } label: {
                    Label(node.kind.isTextEditable ? "Open" : "Preview", systemImage: node.kind.iconName)
                }

                if node.kind == .typ, node.relativePath != document.entryFileName {
                    Button {
                        if setEntryFile(node.relativePath) {
                            refreshProjectState()
                        }
                    } label: {
                        Label("Set Entry", systemImage: "target")
                    }
                }

                Button(role: .destructive) {
                    deleteFile(node)
                } label: {
                    Label("Delete", systemImage: "trash")
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
                    .foregroundStyle(isActive ? editorTextColor.opacity(0.72) : editorSecondaryTextColor.opacity(0.74))
                    .frame(width: 14, height: 20, alignment: .center)
            } else {
                Color.clear
                    .frame(width: 14, height: 20)
            }

            Image(systemName: node.kind.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? editorTextColor : editorSecondaryTextColor)
                .frame(width: 22, height: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.displayName)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? editorTextColor : editorTextColor.opacity(0.88))
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
                .foregroundStyle(editorSecondaryTextColor)
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
                    .background(editorAccentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(editorAccentColor)
            }
            if path == activePath {
                Text(L10n.tr("Editing"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(editorStringColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(editorStringColor)
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
        var name = newFileName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && !name.hasSuffix(".typ") {
            name += ".typ"
        }
        guard !name.isEmpty else { return }
        do {
            try ProjectFileManager.createTypFile(named: name, for: document)
            refreshProjectState()
            openNode(ProjectTreeNode(relativePath: name, displayName: (name as NSString).lastPathComponent, kind: .typ, children: []))
            InteractionFeedback.notify(.success)
            if closeAfterOpen { dismiss() }
        } catch {
            present(error)
        }
    }

    private func deleteFile(_ node: ProjectTreeNode) {
        do {
            if node.kind == .typ {
                try ProjectFileManager.deleteTypFile(named: node.relativePath, for: document)
            } else {
                try ProjectFileManager.deleteProjectFile(relativePath: node.relativePath, for: document)
            }
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

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                present(error)
            }
            return
        }

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
                let importedPath = try ProjectFileManager.importFile(from: url, to: subdir, for: document)
                if ProjectFileManager.fontFileExtensions.contains(ext) {
                    let name = url.lastPathComponent
                    if !document.fontFileNames.contains(name) {
                        document.fontFileNames.append(name)
                    }
                }
                if urls.count == 1 {
                    openNode(ProjectTreeNode(
                        relativePath: importedPath,
                        displayName: (importedPath as NSString).lastPathComponent,
                        kind: ProjectFileManager.fileKind(for: importedPath, imageDirectoryName: document.imageDirectoryName),
                        children: []
                    ))
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
    let editorTheme: EditorTheme

    private var editorTextColor: Color {
        Color(uiColor: editorTheme.text)
    }

    private var editorBorderColor: Color {
        Color(uiColor: editorTheme.gutterForeground)
    }

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
        let activeFill = editorTextColor.opacity(isPressed ? 0.12 : 0.08)
        let activeBorder = editorTextColor.opacity(0.18)
        let inactivePressedFill = editorBorderColor.opacity(0.14)
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
