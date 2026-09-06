//
//  ProjectFileManager.swift
//  InkPond
//

import Foundation
import os

// MARK: - Error type

enum InkPondFileError: LocalizedError {
    case cannotDeleteEntryFile
    case fileAlreadyExists(String)
    case fileNotFound(String)
    case invalidFileName(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .cannotDeleteEntryFile:
            return L10n.tr("error.file.cannot_delete_entry")
        case .fileAlreadyExists(let name):
            return L10n.format("error.file.already_exists", name)
        case .fileNotFound(let name):
            return L10n.format("error.file.not_found", name)
        case .invalidFileName(let name):
            return L10n.format("error.file.invalid_name", name)
        case .unsafePath(let path):
            return L10n.format("error.file.unsafe_path", path)
        }
    }
}

// MARK: - Project file listing

struct ProjectFiles {
    var typFiles: [String]
    var imageFiles: [String]
    var fontFiles: [String]
}

enum FileKind: String, CaseIterable, Sendable, Hashable {
    case directory
    case typ
    case text
    case bibliography
    case data
    case configuration
    case image
    case vector
    case pdf
    case font
    case archive
    case other

    var isDirectory: Bool { self == .directory }

    var canBecomeTab: Bool { !isDirectory }

    var isTextEditable: Bool {
        switch self {
        case .typ, .text, .bibliography, .data, .configuration:
            return true
        case .directory, .image, .vector, .pdf, .font, .archive, .other:
            return false
        }
    }

    var iconName: String {
        switch self {
        case .directory:
            return "folder"
        case .typ:
            return "doc.plaintext"
        case .text:
            return "doc.text"
        case .bibliography:
            return "book.closed"
        case .data:
            return "tablecells"
        case .configuration:
            return "slider.horizontal.3"
        case .image:
            return "photo"
        case .vector:
            return "scribble.variable"
        case .pdf:
            return "doc.richtext"
        case .font:
            return "character.textbox"
        case .archive:
            return "archivebox"
        case .other:
            return "doc"
        }
    }

    var localizedAccessibilityLabel: String {
        switch self {
        case .directory:
            return L10n.tr("a11y.project_files.kind.folder")
        case .typ:
            return L10n.tr("a11y.project_files.kind.typ")
        case .bibliography:
            return L10n.tr("a11y.project_files.kind.reference")
        case .image, .vector, .pdf:
            return L10n.tr("a11y.project_files.kind.image")
        case .font:
            return L10n.tr("a11y.project_files.kind.font")
        case .text, .data, .configuration, .archive, .other:
            return L10n.tr("a11y.project_files.kind.file")
        }
    }
}

struct ProjectTreeNode: Identifiable, Hashable {
    let relativePath: String
    let displayName: String
    let kind: FileKind
    let children: [ProjectTreeNode]

    var id: String { relativePath }
    var isDirectory: Bool { kind.isDirectory }
}

struct EntryFileResolution {
    let entryFileName: String?
    let requiresInitialSelection: Bool
}

struct LinkedFolderLoadProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case scanning
        case downloading
        case complete
    }

    let phase: Phase
    let scannedFileCount: Int
    let downloadedFileCount: Int
    let totalDownloadFileCount: Int

    var remainingDownloadFileCount: Int {
        max(totalDownloadFileCount - downloadedFileCount, 0)
    }

    var fractionCompleted: Double? {
        guard phase == .downloading, totalDownloadFileCount > 0 else { return nil }
        return min(max(Double(downloadedFileCount) / Double(totalDownloadFileCount), 0), 1)
    }
}

struct LinkedFolderLoadResult: Equatable, Sendable {
    let relativePaths: [String]
    let scannedFileCount: Int
    let downloadedFileCount: Int
}

struct LinkedFolderLoadEnvironment: Sendable {
    let downloadingStatus: @Sendable (URL) throws -> URLUbiquitousItemDownloadingStatus?
    let startDownloading: @Sendable (URL) throws -> Void
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    nonisolated static let live = LinkedFolderLoadEnvironment(
        downloadingStatus: { url in
            try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
        },
        startDownloading: { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        },
        now: Date.init,
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

struct AsyncOperationGeneration: Equatable, Sendable {
    private(set) var current: UUID?

    @discardableResult
    mutating func begin() -> UUID {
        let operationID = UUID()
        current = operationID
        return operationID
    }

    func isCurrent(_ operationID: UUID) -> Bool {
        current == operationID
    }

    @discardableResult
    mutating func finish(_ operationID: UUID) -> Bool {
        guard current == operationID else { return false }
        current = nil
        return true
    }

}

struct ProjectReferenceCompletionSnapshot: Sendable {
    let bibEntries: [TypstBibliographyEntry]
    let externalLabels: [(name: String, kind: String)]
    let imageFiles: [String]
}

// MARK: - ProjectFileManager

enum ProjectFileManager {
    nonisolated static let bitmapImageFileExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"
    ]
    nonisolated static let vectorFileExtensions: Set<String> = ["eps", "svg"]
    nonisolated static let pdfFileExtensions: Set<String> = ["pdf"]
    nonisolated static let supportedImageFileExtensions: Set<String> =
        bitmapImageFileExtensions.union(vectorFileExtensions).union(pdfFileExtensions)
    nonisolated static let fontFileExtensions: Set<String> = ["otf", "ttf", "woff", "woff2"]
    nonisolated static let textFileExtensions: Set<String> = ["md", "markdown", "txt"]
    nonisolated static let bibliographyFileExtensions: Set<String> = ["bib", "yaml", "yml"]
    nonisolated static let dataFileExtensions: Set<String> = ["csv", "json", "xml"]
    nonisolated static let configurationFileExtensions: Set<String> = ["ini", "plist", "toml"]
    nonisolated static let archiveFileExtensions: Set<String> = ["zip", "tar", "gz", "tgz"]
    nonisolated static let referenceFileExtensions: Set<String> =
        bibliographyFileExtensions.union(dataFileExtensions).union(configurationFileExtensions).union(textFileExtensions)

    /// Shared StorageManager reference — set at app launch from InkPondApp.
    /// Protected by a lock for thread-safe access from any actor context.
    private nonisolated static let _storageManagerLock = OSAllocatedUnfairLock<StorageManager?>(initialState: nil)
    nonisolated static var storageManager: StorageManager? {
        get { _storageManagerLock.withLock { $0 } }
        set { _storageManagerLock.withLock { $0 = newValue } }
    }

    private nonisolated static var localDocumentsURL: URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("DocumentDirectory unavailable — this should never happen in a sandboxed app")
        }
        return docs
    }

    private nonisolated static var ubiquityDocumentsURL: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    nonisolated static var documentsURL: URL {
        if storageManager?.isUsingiCloud == true, let ubiquityDocumentsURL {
            return ubiquityDocumentsURL
        }
        // Fallback to local Documents if StorageManager is not initialized or
        // iCloud is unavailable.
        return localDocumentsURL
    }

    nonisolated static var syncDocumentsURL: URL? {
        if storageManager?.isUsingiCloud == true {
            return ubiquityDocumentsURL
        }
        return localDocumentsURL
    }

    nonisolated static func externalSingleFileURL(for document: InkPondDocument) -> URL? {
        ExternalTypFileSessionStore.fileURL(projectID: document.projectID)
    }

    nonisolated static func projectDirectory(for document: InkPondDocument) -> URL {
        if let externalFileURL = externalSingleFileURL(for: document) {
            return externalFileURL.deletingLastPathComponent()
        }
        if let bookmarkURL = BookmarkManager.loadBookmark(projectID: document.projectID) {
            return bookmarkURL
        }
        return documentsURL.appendingPathComponent(document.projectID, isDirectory: true)
    }

    nonisolated static func projectDirectory(folderName: String) -> URL {
        if let bookmarkURL = BookmarkManager.loadBookmark(projectID: folderName) {
            return bookmarkURL
        }
        return documentsURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static func sanitizeFolderName(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsafe = CharacterSet(charactersIn: "/:\\*?\"<>|")
        name = name.components(separatedBy: unsafe).joined(separator: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty { name = L10n.untitledBase }
        return String(name.prefix(200))
    }

    static func uniqueFolderName(for title: String) -> String {
        let fm = FileManager.default
        let base = sanitizeFolderName(title)
        if !fm.fileExists(atPath: documentsURL.appendingPathComponent(base).path) && !BookmarkManager.hasBookmark(projectID: base) { return base }
        var i = 2
        while fm.fileExists(atPath: documentsURL.appendingPathComponent("\(base) \(i)").path) || BookmarkManager.hasBookmark(projectID: "\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Whether file operations should use NSFileCoordinator (iCloud mode).
    /// Nonisolated because it reads from the lock-protected storageManager
    /// and must be callable from any actor context (e.g. BackgroundDocumentFileWriter).
    nonisolated static var useCoordination: Bool {
        storageManager?.isUsingiCloud ?? false
    }

    @discardableResult
    static func renameProjectDirectory(for document: InkPondDocument, to newTitle: String) throws -> String {
        let desiredFolderName = sanitizeFolderName(newTitle)
        if desiredFolderName == document.projectID {
            return document.projectID
        }
        let newFolderName = uniqueFolderName(for: newTitle)
        let oldDir = projectDirectory(for: document)
        let newDir = documentsURL.appendingPathComponent(newFolderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: oldDir.path) else {
            throw InkPondFileError.fileNotFound(document.projectID)
        }
        if useCoordination {
            try CloudFileCoordinator.moveItem(from: oldDir, to: newDir)
        } else {
            try FileManager.default.moveItem(at: oldDir, to: newDir)
        }
        return newFolderName
    }

    nonisolated static func imagesDirectory(for document: InkPondDocument) -> URL {
        let imageDirName = safeImageDirectoryName(from: document.imageDirectoryName)
        if imageDirName.isEmpty {
            return projectDirectory(for: document)
        }
        return projectDirectory(for: document)
            .appendingPathComponent(imageDirName, isDirectory: true)
    }

    nonisolated static func fontsDirectory(for document: InkPondDocument) -> URL {
        projectDirectory(for: document)
            .appendingPathComponent("fonts", isDirectory: true)
    }

    static func createProjectRoot(for document: InkPondDocument) throws {
        if externalSingleFileURL(for: document) != nil { return }
        let url = projectDirectory(for: document)
        if useCoordination {
            try CloudFileCoordinator.createDirectory(at: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func createImageDirectory(for document: InkPondDocument) throws {
        if externalSingleFileURL(for: document) != nil { return }
        try createProjectRoot(for: document)
        let imageDirectory = imagesDirectory(for: document)
        if imageDirectory.standardizedFileURL != projectDirectory(for: document).standardizedFileURL {
            if useCoordination {
                try CloudFileCoordinator.createDirectory(at: imageDirectory)
            } else {
                try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            }
        }
    }

    static func createFontsDirectory(for document: InkPondDocument) throws {
        if externalSingleFileURL(for: document) != nil { return }
        try createProjectRoot(for: document)
        let url = fontsDirectory(for: document)
        if useCoordination {
            try CloudFileCoordinator.createDirectory(at: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func createDefaultAssetDirectories(for document: InkPondDocument) throws {
        try createImageDirectory(for: document)
        try createFontsDirectory(for: document)
    }

    static func createInitialProject(for document: InkPondDocument) throws {
        try createProjectRoot(for: document)
        try createDefaultAssetDirectories(for: document)
        try writeTypFile(named: document.entryFileName, content: "", for: document)
    }

    static func ensureProjectRoot(for document: InkPondDocument) {
        try? createProjectRoot(for: document)
    }

    static func ensureImageDirectory(for document: InkPondDocument) {
        try? createImageDirectory(for: document)
    }

    static func ensureFontsDirectory(for document: InkPondDocument) {
        try? createFontsDirectory(for: document)
    }

    static func ensureDefaultAssetDirectories(for document: InkPondDocument) {
        ensureImageDirectory(for: document)
        ensureFontsDirectory(for: document)
    }

    static func ensureProjectStructure(for document: InkPondDocument) {
        ensureProjectRoot(for: document)
        ensureDefaultAssetDirectories(for: document)
    }

    static func deleteProjectDirectory(for document: InkPondDocument) throws {
        if externalSingleFileURL(for: document) != nil {
            ExternalTypFileSessionStore.unregister(projectID: document.projectID)
            return
        }
        if BookmarkManager.hasBookmark(projectID: document.projectID) {
            BookmarkManager.removeBookmark(projectID: document.projectID)
            os_log(.info, "ProjectFileManager: removed bookmark for %{public}@", document.projectID)
            return
        }
        let dir = projectDirectory(for: document)
        if FileManager.default.fileExists(atPath: dir.path) {
            if useCoordination {
                try CloudFileCoordinator.removeItem(at: dir)
            } else {
                try FileManager.default.removeItem(at: dir)
            }
        }
        os_log(.info, "ProjectFileManager: deleted project dir for %{public}@", document.projectID)
    }

    static func entryFileURL(for document: InkPondDocument) -> URL {
        if let externalFileURL = externalSingleFileURL(for: document) {
            return externalFileURL
        }
        return projectDirectory(for: document).appendingPathComponent(document.entryFileName)
    }

    static func typFileURL(named name: String, for document: InkPondDocument) -> URL {
        if let externalFileURL = externalSingleFileURL(for: document), name == document.entryFileName {
            return externalFileURL
        }
        return projectDirectory(for: document).appendingPathComponent(name)
    }

    static func projectFileURL(relativePath: String, for document: InkPondDocument) throws -> URL {
        try validatedProjectPath(relativePath: relativePath, for: document)
    }

    static func validateFileName(_ name: String) throws {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != "..",
              !name.hasPrefix("../"),
              !name.contains("/../") else {
            throw InkPondFileError.invalidFileName(name)
        }
    }

    static func validatedProjectPath(relativePath: String,
                                     for document: InkPondDocument,
                                     allowEmpty: Bool = false) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowEmpty { return projectDirectory(for: document) }
            throw InkPondFileError.invalidFileName(relativePath)
        }

        if let externalFileURL = externalSingleFileURL(for: document) {
            guard trimmed == document.entryFileName else {
                throw InkPondFileError.fileNotFound(relativePath)
            }
            return externalFileURL
        }

        guard !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("~") else {
            throw InkPondFileError.unsafePath(relativePath)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw InkPondFileError.unsafePath(relativePath) }
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                throw InkPondFileError.unsafePath(relativePath)
            }
        }

        let normalized = components.map(String.init).joined(separator: "/")
        let root = projectDirectory(for: document).standardizedFileURL
        let target = root.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        let rootPath = root.path
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw InkPondFileError.unsafePath(relativePath)
        }
        return target
    }

    nonisolated static func relativePath(of fileURL: URL, in directoryURL: URL) -> String? {
        let directory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let directoryComponents = directory.pathComponents
        let fileComponents = file.pathComponents

        guard fileComponents.count > directoryComponents.count,
              fileComponents.starts(with: directoryComponents) else {
            return nil
        }

        return fileComponents.dropFirst(directoryComponents.count).joined(separator: "/")
    }

    nonisolated static func safeImageDirectoryName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            return "images"
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.count <= 8,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return "images"
        }

        return components
            .map { String($0.prefix(80)) }
            .joined(separator: "/")
    }

    static func relevantDirectoryCandidates(from relativePaths: [String], matching extensions: Set<String>) -> [String] {
        var directories: Set<String> = []

        for path in relativePaths {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let ext = (normalized as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            directories.insert("")
            let components = normalized.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                continue
            }

            for depth in 1..<(components.count) {
                let directory = components.prefix(depth).joined(separator: "/")
                directories.insert(directory)
            }
        }

        return directories.sorted {
            let lhsIsRoot = $0.isEmpty
            let rhsIsRoot = $1.isEmpty
            if lhsIsRoot != rhsIsRoot {
                return lhsIsRoot
            }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func normalizedImportDirectoryOptions(_ directories: [String]) -> [String] {
        Array(Set(directories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.contains("\\") }
            .sorted {
                let lhsIsRoot = $0.isEmpty
                let rhsIsRoot = $1.isEmpty
                if lhsIsRoot != rhsIsRoot {
                    return lhsIsRoot
                }
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
    }

    static func listFiles(in relativeDirectory: String, for document: InkPondDocument, matching extensions: Set<String>) -> [URL] {
        let directoryURL = (try? validatedProjectPath(relativePath: relativeDirectory, for: document, allowEmpty: true))
            ?? projectDirectory(for: document)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return extensions.contains(ext)
        }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func buildProjectTree(
        in directory: URL,
        relativePrefix: String,
        imageDirectoryName: String
    ) -> [ProjectTreeNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let nodes = contents.compactMap { url -> ProjectTreeNode? in
            let name = url.lastPathComponent
            let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])

            if values?.isDirectory == true {
                return ProjectTreeNode(
                    relativePath: relativePath,
                    displayName: name,
                    kind: .directory,
                    children: buildProjectTree(
                        in: url,
                        relativePrefix: relativePath,
                        imageDirectoryName: imageDirectoryName
                    )
                )
            }

            return ProjectTreeNode(
                relativePath: relativePath,
                displayName: name,
                kind: fileKind(for: relativePath, imageDirectoryName: imageDirectoryName),
                children: []
            )
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func fileKind(for relativePath: String, imageDirectoryName: String) -> FileKind {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if ext == "typ" { return .typ }

        // The dedicated fonts directory is owned by font imports; classify its
        // contents as fonts before falling back to extension-based detection.
        if relativePath.hasPrefix("fonts/") { return .font }
        if !imageDirectoryName.isEmpty,
           relativePath.hasPrefix(imageDirectoryName + "/"),
           supportedImageFileExtensions.contains(ext) {
            return imageOrDocumentKind(forExtension: ext)
        }
        if bibliographyFileExtensions.contains(ext) { return .bibliography }
        if dataFileExtensions.contains(ext) { return .data }
        if configurationFileExtensions.contains(ext) { return .configuration }
        if textFileExtensions.contains(ext) { return .text }
        if bitmapImageFileExtensions.contains(ext) { return .image }
        if vectorFileExtensions.contains(ext) { return .vector }
        if pdfFileExtensions.contains(ext) { return .pdf }
        if fontFileExtensions.contains(ext) { return .font }
        if archiveFileExtensions.contains(ext) { return .archive }
        return .other
    }

    private static func imageOrDocumentKind(forExtension ext: String) -> FileKind {
        if bitmapImageFileExtensions.contains(ext) { return .image }
        if vectorFileExtensions.contains(ext) { return .vector }
        if pdfFileExtensions.contains(ext) { return .pdf }
        return .image
    }

    static func removeFontReference(relativePath: String, from document: InkPondDocument) {
        let fileName = (relativePath as NSString).lastPathComponent
        document.fontFileNames.removeAll { $0 == fileName || $0 == relativePath }
    }
}
