//
//  ProjectFileBrowserSheet.swift
//  InkPond
//

import SwiftUI
import ImageIO
import PDFKit
import QuickLook
import UniformTypeIdentifiers

struct ProjectFileBrowserSheet: View {
    @Bindable var document: InkPondProject
    var currentFileName: String
    var openFile: (String) -> Void

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
    @State private var previewItem: PreviewItem?
    @State private var cachedPreviewAspectRatios: [String: CGFloat] = [:]
    @State private var cloudSyncMonitor = CloudSyncMonitor()

    private static let imageExtensions = ProjectFileManager.supportedImageFileExtensions
    private static let fontExtensions: Set<String> = ["otf", "ttf", "woff", "woff2"]
    
    private var visibleRows: [VisibleProjectRow] {
        var rows: [VisibleProjectRow] = []
        appendVisibleRows(from: projectTree, depth: 0, into: &rows)
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                if projectTree.isEmpty {
                    Text("No files")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(visibleRows) { row in
                        rowView(for: row)
                    }
                }
            }
            .navigationTitle("Project Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        InteractionFeedback.impact(.light)
                        showingProjectSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L10n.a11yProjectFilesSettingsLabel)
                    .accessibilityHint(L10n.a11yProjectFilesSettingsHint)
                    .accessibilityIdentifier("project-files.settings")

                    if storageManager.isUsingiCloud && hasNotDownloadedFiles {
                        Button {
                            cloudSyncMonitor.downloadAll()
                            InteractionFeedback.impact(.light)
                        } label: {
                            Image(systemName: "icloud.and.arrow.down")
                        }
                        .accessibilityLabel(L10n.tr("icloud.download_all"))
                        .accessibilityIdentifier("project-files.download-all")
                    }

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
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.a11yProjectFilesAddLabel)
                    .accessibilityHint(L10n.a11yProjectFilesAddHint)
                    .accessibilityIdentifier("project-files.add-menu")
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
        }
        .overlay {
            if let previewItem {
                ProjectFileCenteredPreviewOverlay(item: previewItem) {
                    closePreview()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .presentationDetents([.medium, .large])
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
        .onChange(of: actionError) { _, newValue in
            guard newValue != nil else { return }
            InteractionFeedback.notify(.error)
            AccessibilitySupport.announce(newValue)
        }
        .sheet(isPresented: $showingProjectSettings, onDismiss: refreshProjectState) {
            ProjectSettingsSheet(document: document, openFile: openFile)
        }
    }

    private func rowView(for row: VisibleProjectRow) -> AnyView {
        let node = row.node
        if node.kind == .directory {
            return AnyView(Button {
                toggleExpansion(for: node.relativePath)
            } label: {
                rowLabel(for: row)
            }
            .buttonStyle(ProjectFileRowButtonStyle())
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(for: row))
            .accessibilityHint(L10n.a11yProjectFilesExpandHint)
            .accessibilityValue(rowAccessibilityValue(for: row))
            .accessibilityIdentifier("project-files.row.\(node.relativePath)")
            .accessibilityAddTraits(.isButton))
        } else if node.kind == .typ {
            return AnyView(Button {
                openFile(node.relativePath)
                dismiss()
            } label: {
                rowLabel(for: row)
            }
            .buttonStyle(ProjectFileRowButtonStyle())
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteTypFile(node.relativePath)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(node.relativePath == document.entryFileName)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(for: row))
            .accessibilityHint(L10n.a11yProjectFilesOpenHint)
            .accessibilityValue(rowAccessibilityValue(for: row))
            .accessibilityIdentifier("project-files.row.\(node.relativePath)")
            .accessibilityAction(named: Text(L10n.tr("Delete"))) {
                deleteTypFile(node.relativePath)
            })
        } else if node.kind == .reference {
            return AnyView(Button {
                openFile(node.relativePath)
                dismiss()
            } label: {
                rowLabel(for: row)
            }
            .buttonStyle(ProjectFileRowButtonStyle())
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteFile(at: node.relativePath, kind: node.kind)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(for: row))
            .accessibilityHint(L10n.a11yProjectFilesOpenHint)
            .accessibilityValue(rowAccessibilityValue(for: row))
            .accessibilityIdentifier("project-files.row.\(node.relativePath)")
            .accessibilityAction(named: Text(L10n.tr("Delete"))) {
                deleteFile(at: node.relativePath, kind: node.kind)
            })
        } else if node.kind == .image {
            return AnyView(Button {
                previewFile(node.relativePath)
            } label: {
                rowLabel(for: row)
            }
            .buttonStyle(ProjectFileRowButtonStyle())
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteFile(at: node.relativePath, kind: node.kind)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(for: row))
            .accessibilityHint(L10n.a11yProjectFilesPreviewHint)
            .accessibilityValue(rowAccessibilityValue(for: row))
            .accessibilityIdentifier("project-files.row.\(node.relativePath)")
            .accessibilityAction(named: Text(L10n.tr("Delete"))) {
                deleteFile(at: node.relativePath, kind: node.kind)
            })
        } else {
            return AnyView(Button {
                previewFile(node.relativePath)
            } label: {
                rowLabel(for: row)
            }
            .buttonStyle(ProjectFileRowButtonStyle())
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteFile(at: node.relativePath, kind: node.kind)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowAccessibilityLabel(for: row))
            .accessibilityHint(L10n.a11yProjectFilesPreviewHint)
            .accessibilityValue(rowAccessibilityValue(for: row))
            .accessibilityIdentifier("project-files.row.\(node.relativePath)")
            .accessibilityAction(named: Text(L10n.tr("Delete"))) {
                deleteFile(at: node.relativePath, kind: node.kind)
            })
        }
    }

    private func rowLabel(for row: VisibleProjectRow) -> some View {
        let node = row.node
        return HStack(spacing: 10) {
            if node.kind == .directory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 18, alignment: .center)
            } else {
                Color.clear
                    .frame(width: 12, height: 18)
            }
            Image(systemName: node.kind.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18, alignment: .center)
            Text(node.displayName)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if storageManager.isUsingiCloud, node.kind != .directory {
                cloudStatusIndicator(for: node.relativePath)
            }
            Spacer()
            if node.kind == .typ || node.kind == .reference {
                badges(for: node.relativePath)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cloudStatusIndicator(for relativePath: String) -> some View {
        switch cloudSyncMonitor.fileStatuses[relativePath] {
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
                Text("Entry")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            if path == currentFileName {
                Text("Editing")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.16), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
    }

    private func appendVisibleRows(from nodes: [ProjectTreeNode], depth: Int, into rows: inout [VisibleProjectRow]) {
        for node in nodes {
            let isExpanded = expandedNodes.contains(node.relativePath)
            rows.append(VisibleProjectRow(node: node, depth: depth, isExpanded: isExpanded))
            if node.kind == .directory, isExpanded {
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

    private var hasNotDownloadedFiles: Bool {
        cloudSyncMonitor.fileStatuses.values.contains { status in
            if case .notDownloaded = status { return true }
            return false
        }
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
            openFile(name)
            InteractionFeedback.notify(.success)
            dismiss()
        } catch {
            present(error)
        }
    }

    private func deleteTypFile(_ path: String) {
        do {
            try ProjectFileManager.deleteTypFile(named: path, for: document)
            refreshProjectState()
            InteractionFeedback.notify(.warning)
        } catch {
            present(error)
        }
    }

    private func deleteFile(at relativePath: String, kind: FileKind) {
        do {
            try ProjectFileManager.deleteProjectFile(relativePath: relativePath, for: document)
            if kind == .font {
                document.fontFileNames.removeAll { $0 == (relativePath as NSString).lastPathComponent }
            }
            refreshProjectState()
            InteractionFeedback.notify(.warning)
        } catch {
            present(error)
        }
    }

    private func previewFile(_ relativePath: String) {
        do {
            let url = try ProjectFileManager.projectFileURL(relativePath: relativePath, for: document)
            let item = PreviewItem(
                id: relativePath,
                displayName: (relativePath as NSString).lastPathComponent,
                url: url,
                preferredAspectRatio: cachedPreviewAspectRatios[relativePath]
            )
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                previewItem = item
            }
            InteractionFeedback.impact(.light)
            resolvePreviewAspectRatioIfNeeded(for: relativePath, url: url)
        } catch {
            present(error)
        }
    }

    private func closePreview() {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
            previewItem = nil
        }
    }

    private func resolvePreviewAspectRatioIfNeeded(for relativePath: String, url: URL) {
        guard cachedPreviewAspectRatios[relativePath] == nil else { return }

        Task.detached(priority: .userInitiated) {
            let ratio = PreviewItem.preferredAspectRatio(for: url)
            guard let ratio else { return }

            await MainActor.run {
                cachedPreviewAspectRatios[relativePath] = ratio
            }
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
            if Self.imageExtensions.contains(ext) {
                subdir = document.imageDirectoryName
            } else if Self.fontExtensions.contains(ext) {
                subdir = "fonts"
            } else {
                subdir = ""
            }

            do {
                _ = try ProjectFileManager.importFile(from: url, to: subdir, for: document)
                if Self.fontExtensions.contains(ext) {
                    let name = url.lastPathComponent
                    if !document.fontFileNames.contains(name) {
                        document.fontFileNames.append(name)
                    }
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

    private func rowAccessibilityLabel(for row: VisibleProjectRow) -> String {
        let node = row.node
        if node.kind == .directory {
            return L10n.a11yProjectFilesFolderLabel(node.displayName)
        }
        return L10n.a11yProjectFilesFileLabel(kind: accessibilityKindLabel(for: node.kind), name: node.displayName)
    }

    private func rowAccessibilityValue(for row: VisibleProjectRow) -> String {
        var values: [String] = []
        if row.node.kind == .directory {
            values.append(row.isExpanded ? L10n.a11yStateExpanded : L10n.a11yStateCollapsed)
        }
        if row.node.relativePath == document.entryFileName {
            values.append(L10n.tr("Entry"))
        }
        if row.node.relativePath == currentFileName {
            values.append(L10n.tr("Editing"))
        }
        return values.joined(separator: ", ")
    }

    private func accessibilityKindLabel(for kind: FileKind) -> String {
        return switch kind {
        case .directory:
            L10n.tr("a11y.project_files.kind.folder")
        case .typ:
            L10n.tr("a11y.project_files.kind.typ")
        case .image:
            L10n.tr("a11y.project_files.kind.image")
        case .font:
            L10n.tr("a11y.project_files.kind.font")
        case .table:
            L10n.tr("a11y.project_files.kind.table")
        case .other:
            L10n.tr("a11y.project_files.kind.file")
        case .vector:
            L10n.tr("a11y.project_files.kind.image")
        case .pdf:
            L10n.tr("a11y.project_files.kind.file")
        case .bibliography:
            L10n.tr("a11y.project_files.kind.file")
        case .configuration:
            L10n.tr("a11y.project_files.kind.file")
        }
    }

    fileprivate struct PreviewItem: Identifiable, Equatable {
        let id: String
        let displayName: String
        let url: URL
        var preferredAspectRatio: CGFloat?

        nonisolated static func preferredAspectRatio(for url: URL) -> CGFloat? {
            if let imageRatio = imageAspectRatio(for: url) {
                return imageRatio
            }
            if let pdfRatio = pdfAspectRatio(for: url) {
                return pdfRatio
            }
            return nil
        }

        private nonisolated static func imageAspectRatio(for url: URL) -> CGFloat? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                  width > 0,
                  height > 0 else {
                return nil
            }
            return width / height
        }

        private nonisolated static func pdfAspectRatio(for url: URL) -> CGFloat? {
            guard url.pathExtension.lowercased() == "pdf",
                  let document = PDFDocument(url: url),
                  let page = document.page(at: 0) else {
                return nil
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return bounds.width / bounds.height
        }
    }
}

private struct VisibleProjectRow: Identifiable, Hashable {
    let node: ProjectTreeNode
    let depth: Int
    let isExpanded: Bool

    var id: String { node.id }
}

private struct ProjectFileRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowBackground(Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ProjectFileCenteredPreviewOverlay: View {
    let item: ProjectFileBrowserSheet.PreviewItem
    let close: () -> Void

    private let cornerRadius: CGFloat = 28
    private let chromeHeight: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(max(proxy.size.width * 0.84, 360), 920)
            let contentAspectRatio = item.preferredAspectRatio ?? 1.18
            let maxHeight = min(proxy.size.height * 0.9, 860)
            let minHeight = min(max(proxy.size.height * 0.42, 300), maxHeight)
            let idealHeight = panelWidth / max(contentAspectRatio, 0.33) + chromeHeight
            let panelHeight = min(max(idealHeight, minHeight), maxHeight)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.12))
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                VStack(spacing: 18) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text(item.displayName)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.clear)

                        Divider()

                        ProjectFileQuickLookPreview(url: item.url)
                    }
                    .frame(
                        width: panelWidth,
                        height: panelHeight
                    )
                    .projectPreviewGlassCard(cornerRadius: cornerRadius)
                    .clipShape(shape)
                    .overlay(
                        shape
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.14), radius: 30, y: 18)

                    PreviewCloseButton(action: close)
                }
                .padding(20)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension View {
    @ViewBuilder
    func projectPreviewGlassCard(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct PreviewCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                Button(action: action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .clipShape(Circle())
            }
            .accessibilityLabel(L10n.a11yClosePreview)
            .accessibilityIdentifier("project-files.preview.close")
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.a11yClosePreview)
            .accessibilityIdentifier("project-files.preview.close")
        }
    }
}

private struct ProjectFileQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
