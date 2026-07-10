import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor ProjectManifestRepository {
    private let rootURL: URL
    private let manifestURL: URL
    private let projectID: ProjectID
    private var displayName: String
    private var entryRelativePath: String
    private let limitsManifestToEntryFile: Bool
    private var manifest: ProjectManifest?
    private var reservedRevisions: [String: RevisionID] = [:]

    init(
        rootURL: URL,
        metadataRootURL: URL,
        projectID: ProjectID,
        displayName: String,
        entryRelativePath: String,
        limitsManifestToEntryFile: Bool = false
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.projectID = projectID
        self.displayName = displayName
        self.entryRelativePath = entryRelativePath
        self.limitsManifestToEntryFile = limitsManifestToEntryFile
        try FileManager.default.createDirectory(at: metadataRootURL, withIntermediateDirectories: true)
        self.manifestURL = try ProjectPathPolicy(rootURL: metadataRootURL).resolve("project-manifest-v1.json")
    }

    func reserveSnapshot(relativePath: String, data: Data) throws -> DocumentSnapshot {
        let manifest = try refreshFileSet(in: loadOrBootstrap())
        let record = manifest.file(relativePath: relativePath)
        let current = max(record?.revision ?? RevisionID(rawValue: 0), reservedRevisions[relativePath] ?? RevisionID(rawValue: 0))
        let revision = try current.advanced()
        reservedRevisions[relativePath] = revision
        return DocumentSnapshot(
            projectID: projectID,
            fileID: record?.fileID ?? FileID(),
            revision: revision,
            relativePath: relativePath,
            data: data
        )
    }

    func updateConfiguration(displayName: String, entryRelativePath: String) throws {
        self.displayName = displayName
        let current = try refreshFileSet(in: loadOrBootstrap())
        guard let entry = current.file(relativePath: entryRelativePath) else {
            throw ProjectManifestRepositoryError.entryFileMissing(entryRelativePath)
        }
        self.entryRelativePath = entryRelativePath
        guard current.displayName != displayName || current.entryFileID != entry.fileID else { return }
        let updated = try ProjectManifest(
            projectID: current.projectID,
            displayName: displayName,
            entryFileID: entry.fileID,
            files: current.files
        )
        try persist(updated)
        manifest = updated
    }

    func reconcileFileSet() throws {
        _ = try refreshFileSet(in: loadOrBootstrap())
    }

    func commit(_ snapshot: DocumentSnapshot) throws {
        let current = try loadOrBootstrap()
        let updated = try current.applying(snapshot)
        try persist(updated)
        manifest = updated
        reservedRevisions[snapshot.relativePath] = snapshot.revision
    }

    func reconcile(_ entries: [ProjectOperationJournalEntry]) throws {
        var current = try loadOrBootstrap()
        for entry in entries.sorted(by: { $0.snapshot.revision < $1.snapshot.revision }) {
            let snapshot = entry.snapshot
            if let existing = current.file(relativePath: snapshot.relativePath), existing.revision >= snapshot.revision {
                continue
            }
            current = try current.applying(snapshot)
        }
        try persist(current)
        manifest = current
    }

    private func loadOrBootstrap() throws -> ProjectManifest {
        if let manifest { return manifest }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let decoded = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            guard decoded.projectID == projectID else { throw ProjectManifestRepositoryError.projectIdentityMismatch }
            manifest = decoded
            return decoded
        }

        let policy = ProjectPathPolicy(rootURL: rootURL)
        let entryURL = try policy.resolve(entryRelativePath)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw ProjectManifestRepositoryError.entryFileMissing(entryRelativePath)
        }
        let paths = limitsManifestToEntryFile ? [entryRelativePath] : projectFilePaths()
        var records: [ProjectFileRecord] = []
        var entryFileID: FileID?
        for path in paths {
            let data = try Data(contentsOf: policy.resolve(path))
            let fileID = FileID()
            if path == entryRelativePath { entryFileID = fileID }
            records.append(ProjectFileRecord(
                fileID: fileID,
                relativePath: path,
                revision: .initial,
                contentDigest: ContentDigest(data: data)
            ))
        }
        guard let entryFileID else { throw ProjectManifestRepositoryError.entryFileMissing(entryRelativePath) }
        let created = try ProjectManifest(
            projectID: projectID,
            displayName: displayName,
            entryFileID: entryFileID,
            files: records
        )
        try persist(created)
        manifest = created
        return created
    }

    private func refreshFileSet(in current: ProjectManifest) throws -> ProjectManifest {
        let policy = ProjectPathPolicy(rootURL: rootURL)
        let paths = Set(limitsManifestToEntryFile ? [entryRelativePath] : projectFilePaths())
        var records = current.files.filter { paths.contains($0.relativePath) }
        let knownPaths = Set(records.map(\.relativePath))
        for path in paths.subtracting(knownPaths).sorted() {
            let data = try Data(contentsOf: policy.resolve(path))
            records.append(ProjectFileRecord(
                fileID: FileID(),
                relativePath: path,
                revision: .initial,
                contentDigest: ContentDigest(data: data)
            ))
        }
        guard let entry = records.first(where: { $0.relativePath == entryRelativePath }) else {
            throw ProjectManifestRepositoryError.entryFileMissing(entryRelativePath)
        }
        guard records.sorted(by: { $0.relativePath < $1.relativePath }) != current.files else { return current }
        let refreshed = try ProjectManifest(
            projectID: current.projectID,
            displayName: displayName,
            entryFileID: entry.fileID,
            files: records
        )
        try persist(refreshed)
        manifest = refreshed
        return refreshed
    }

    private func projectFilePaths() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let rootComponents = rootURL.pathComponents
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else { continue }
            paths.append(components.dropFirst(rootComponents.count).joined(separator: "/"))
        }
        return paths.sorted()
    }

    private func persist(_ manifest: ProjectManifest) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic])
#if canImport(Darwin)
        try synchronize(manifestURL)
        try synchronize(manifestURL.deletingLastPathComponent())
#endif
    }

#if canImport(Darwin)
    private func synchronize(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
#endif
}

nonisolated enum ProjectManifestRepositoryError: Error, Equatable {
    case projectIdentityMismatch
    case entryFileMissing(String)
}
