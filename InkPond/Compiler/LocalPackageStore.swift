//
//  LocalPackageStore.swift
//  InkPond
//

import Foundation

struct LocalPackageEntry: Identifiable, Equatable, Sendable {
    let namespace: String
    let name: String
    let version: String
    let sizeInBytes: Int64
    let url: URL

    var id: String { "\(namespace)/\(name)/\(version)" }
    var displayName: String { "@\(namespace)/\(name)" }
    var spec: String { "@\(namespace)/\(name):\(version)" }
}

struct LocalPackageSnapshot: Equatable, Sendable {
    let entries: [LocalPackageEntry]

    var totalSizeInBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeInBytes }
    }
}

struct LocalPackageImportResult: Equatable, Sendable {
    let spec: String
    let downloadedItemCount: Int
    let importedFromArchive: Bool
}

struct LocalPackageStore: Sendable {
    nonisolated static let defaultNamespaceDefaultsKey = "localPackageDefaultNamespace"

    let rootURL: URL?

    nonisolated init(rootURL: URL? = TypstBridge.localPackagesDirectoryURL) {
        self.rootURL = rootURL
    }

    nonisolated func snapshot() throws -> LocalPackageSnapshot {
        let fileManager = FileManager.default
        guard let rootURL else {
            return LocalPackageSnapshot(entries: [])
        }

        try ensureRootDirectory()
        try integrateLooseRootItems(defaultNamespace: Self.storedDefaultNamespace)

        let namespaceURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [LocalPackageEntry] = []

        for namespaceURL in namespaceURLs where try isDirectory(namespaceURL) {
            guard let namespace = try? validatedNamespace(namespaceURL.lastPathComponent) else { continue }
            let packageURLs = try fileManager.contentsOfDirectory(
                at: namespaceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for packageURL in packageURLs where try isDirectory(packageURL) {
                guard let name = try? validatedPackagePathComponent(packageURL.lastPathComponent, field: "package name") else { continue }
                let versionURLs = try fileManager.contentsOfDirectory(
                    at: packageURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for versionURL in versionURLs where try isDirectory(versionURL) {
                    guard let version = try? validatedPackagePathComponent(versionURL.lastPathComponent, field: "package version") else { continue }
                    // Only list directories that contain a typst.toml
                    let manifest = versionURL.appendingPathComponent("typst.toml")
                    guard fileManager.fileExists(atPath: manifest.path) else { continue }

                    entries.append(
                        LocalPackageEntry(
                            namespace: namespace,
                            name: name,
                            version: version,
                            sizeInBytes: try directorySize(at: versionURL),
                            url: versionURL
                        )
                    )
                }
            }
        }

        entries.sort {
            ($0.namespace, $0.name, $0.version) < ($1.namespace, $1.name, $1.version)
        }
        return LocalPackageSnapshot(entries: entries)
    }

    /// Import a folder as a local package. The folder must contain a `typst.toml`
    /// with `[package]` metadata (name, version). Returns the imported entry spec.
    /// If `defaultNamespace` is provided, it overrides the fallback when `typst.toml`
    /// does not contain a `namespace` field.
    nonisolated func importFolder(at sourceURL: URL, defaultNamespace: String = "local") throws -> String {
        try importItem(at: sourceURL, defaultNamespace: defaultNamespace).spec
    }

    nonisolated func importItem(at sourceURL: URL, defaultNamespace: String = "local") throws -> LocalPackageImportResult {
        let startedAt = Date()
        Diagnostics.record(
            .importExport,
            "local_package.import_item.start",
            metadata: ["sourceHash": Diagnostics.hashIdentifier(sourceURL.standardizedFileURL.path)]
        )
        guard let rootURL else {
            Diagnostics.record(
                .importExport,
                "local_package.import_item.failure",
                level: .error,
                metadata: ["reason": "storageUnavailable"]
            )
            throw LocalPackageError.storageUnavailable
        }

        let securedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if securedAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let preparation = try CloudItemAvailability.prepareForAccess(at: sourceURL)
        Diagnostics.record(
            .importExport,
            "local_package.import_item.cloud_prepared",
            metadata: ["downloadedItemCount": String(preparation.downloadedItemCount)]
        )
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])

        if sourceValues.isDirectory == true {
            let spec = try importResolvedFolder(
                at: sourceURL,
                rootURL: rootURL,
                defaultNamespace: defaultNamespace
            )
            Diagnostics.record(
                .importExport,
                "local_package.import_item.success",
                metadata: [
                    "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "downloadedItemCount": String(preparation.downloadedItemCount),
                    "importedFromArchive": "false"
                ]
            )
            return LocalPackageImportResult(
                spec: spec,
                downloadedItemCount: preparation.downloadedItemCount,
                importedFromArchive: false
            )
        }

        guard PackageArchiveImporter.archiveKind(for: sourceURL) != nil else {
            Diagnostics.record(
                .importExport,
                "local_package.import_item.failure",
                level: .error,
                metadata: ["reason": "unsupportedArchive"]
            )
            throw LocalPackageError.unsupportedArchive
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPackageImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        _ = try PackageArchiveImporter.extract(from: sourceURL, to: temporaryRoot)
        let packageRoot = try PackageArchiveImporter.locatePackageRoot(in: temporaryRoot)
        let spec = try importResolvedFolder(
            at: packageRoot,
            rootURL: rootURL,
            defaultNamespace: defaultNamespace
        )

        Diagnostics.record(
            .importExport,
            "local_package.import_item.success",
            metadata: [
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "downloadedItemCount": String(preparation.downloadedItemCount),
                "importedFromArchive": "true"
            ]
        )
        return LocalPackageImportResult(
            spec: spec,
            downloadedItemCount: preparation.downloadedItemCount,
            importedFromArchive: true
        )
    }

    nonisolated func importContents(
        of sourceDirectoryURL: URL,
        defaultNamespace: String = "local"
    ) throws -> [LocalPackageImportResult] {
        let startedAt = Date()
        Diagnostics.record(
            .importExport,
            "local_package.import_contents.start",
            metadata: ["sourceHash": Diagnostics.hashIdentifier(sourceDirectoryURL.standardizedFileURL.path)]
        )
        guard let rootURL else {
            Diagnostics.record(
                .importExport,
                "local_package.import_contents.failure",
                level: .error,
                metadata: ["reason": "storageUnavailable"]
            )
            throw LocalPackageError.storageUnavailable
        }

        let securedAccess = sourceDirectoryURL.startAccessingSecurityScopedResource()
        defer { if securedAccess { sourceDirectoryURL.stopAccessingSecurityScopedResource() } }

        _ = try CloudItemAvailability.prepareForAccess(at: sourceDirectoryURL)
        let values = try sourceDirectoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            return [try LocalPackageStore(rootURL: rootURL).importItem(at: sourceDirectoryURL, defaultNamespace: defaultNamespace)]
        }

        let candidates = try discoverImportableItems(in: sourceDirectoryURL, maxDepth: 3)
        guard !candidates.isEmpty else {
            Diagnostics.record(
                .importExport,
                "local_package.import_contents.failure",
                level: .error,
                metadata: ["reason": "noImportableItems"]
            )
            throw LocalPackageError.noImportableItems
        }

        let results = try candidates.map {
            try LocalPackageStore(rootURL: rootURL).importItem(at: $0, defaultNamespace: defaultNamespace)
        }
        Diagnostics.record(
            .importExport,
            "local_package.import_contents.success",
            metadata: [
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "candidateCount": String(candidates.count),
                "resultCount": String(results.count)
            ]
        )
        return results
    }

    nonisolated func remove(_ entry: LocalPackageEntry) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: entry.url.path) else { return }
        try removeItem(at: entry.url)
        // Clean up empty parent directories
        try removeIfEmpty(entry.url.deletingLastPathComponent())
        try removeIfEmpty(entry.url.deletingLastPathComponent().deletingLastPathComponent())
    }

    nonisolated func clearAll() throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }
        if fileManager.fileExists(atPath: rootURL.path) {
            try removeItem(at: rootURL)
        }
        try createDirectory(at: rootURL)
    }

    nonisolated func ensureRootDirectory() throws {
        guard let rootURL else { return }
        try validateNoSymbolicLinkAncestors(for: rootURL.standardizedFileURL, under: rootURL.standardizedFileURL)
        guard !FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try createDirectory(at: rootURL)
    }

    nonisolated func changeNamespace(
        of entry: LocalPackageEntry,
        to requestedNamespace: String
    ) throws -> LocalPackageEntry {
        guard let rootURL else {
            throw LocalPackageError.storageUnavailable
        }

        let namespace = try validatedNamespace(requestedNamespace)
        guard namespace != entry.namespace else { return entry }

        let manifestURL = entry.url.appendingPathComponent("typst.toml")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LocalPackageError.missingManifest
        }

        let manifest = try readString(at: manifestURL)
        let updatedManifest = try updatingManifestNamespace(in: manifest, to: namespace)
        let packageName = try validatedPackagePathComponent(entry.name, field: "package name")
        let packageVersion = try validatedPackagePathComponent(entry.version, field: "package version")
        let destinationDirectory = try validatedPackageDestination(rootURL
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
            .appendingPathComponent(packageVersion, isDirectory: true), under: rootURL)

        guard entry.url.standardizedFileURL != destinationDirectory.standardizedFileURL else {
            return entry
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw LocalPackageError.packageExists("@\(namespace)/\(entry.name):\(entry.version)")
        }

        let usesCoordination = isUsingICloudStorage(at: destinationDirectory)
        try createDirectory(at: destinationDirectory)

        do {
            try validateNoSymbolicLinks(in: entry.url)
            let contents = try fileManager.contentsOfDirectory(
                at: entry.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in contents {
                let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
                if item.lastPathComponent == "typst.toml" {
                    try writeString(updatedManifest, to: destination)
                } else {
                    try copyItemReplacingSafely(from: item, to: destination, usesCoordination: usesCoordination)
                }
            }
        } catch {
            try? removeItem(at: destinationDirectory)
            try? removeIfEmpty(destinationDirectory.deletingLastPathComponent())
            try? removeIfEmpty(destinationDirectory.deletingLastPathComponent().deletingLastPathComponent())
            throw error
        }

        try removeItem(at: entry.url)
        try removeIfEmpty(entry.url.deletingLastPathComponent())
        try removeIfEmpty(entry.url.deletingLastPathComponent().deletingLastPathComponent())

        return LocalPackageEntry(
            namespace: namespace,
            name: entry.name,
            version: entry.version,
            sizeInBytes: try directorySize(at: destinationDirectory),
            url: destinationDirectory
        )
    }

    // MARK: - Private

    private nonisolated func importResolvedFolder(
        at sourceURL: URL,
        rootURL: URL,
        defaultNamespace: String
    ) throws -> String {
        let fileManager = FileManager.default
        let manifestURL = sourceURL.appendingPathComponent("typst.toml")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LocalPackageError.missingManifest
        }
        try validateNoSymbolicLinks(in: sourceURL)

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let (name, version, namespace) = try parseManifest(manifest, defaultNamespace: defaultNamespace)
        let destinationDirectory = try validatedPackageDestination(rootURL
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true), under: rootURL)
        let usesCoordination = isUsingICloudStorage(at: destinationDirectory)

        if fileManager.fileExists(atPath: destinationDirectory.path) {
            try removeItem(at: destinationDirectory)
        }
        try createDirectory(at: destinationDirectory)

        let contents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            try copyItemReplacingSafely(from: item, to: destination, usesCoordination: usesCoordination)
        }

        return "@\(namespace)/\(name):\(version)"
    }

    private nonisolated func parseManifest(_ content: String, defaultNamespace: String = "local") throws -> (name: String, version: String, namespace: String) {
        // Minimal TOML parsing for [package] section
        var name: String?
        var version: String?
        var namespace = try validatedNamespace(defaultNamespace)
        var inPackageSection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[package]" {
                inPackageSection = true
                continue
            }
            if trimmed.hasPrefix("[") {
                inPackageSection = false
                continue
            }
            guard inPackageSection else { continue }

            if let value = extractTomlValue(from: trimmed, key: "name") {
                name = value
            } else if let value = extractTomlValue(from: trimmed, key: "version") {
                version = value
            } else if let value = extractTomlValue(from: trimmed, key: "namespace") {
                namespace = try validatedNamespace(value)
            }
        }

        guard let rawName = name, !rawName.isEmpty else {
            throw LocalPackageError.invalidManifest("missing package name")
        }
        guard let rawVersion = version, !rawVersion.isEmpty else {
            throw LocalPackageError.invalidManifest("missing package version")
        }
        let pkgName = try validatedPackagePathComponent(rawName, field: "package name")
        let pkgVersion = try validatedPackagePathComponent(rawVersion, field: "package version")

        return (pkgName, pkgVersion, namespace)
    }

    private nonisolated func extractTomlValue(from line: String, key: String) -> String? {
        let pattern = key + "\\s*=\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private nonisolated static var storedDefaultNamespace: String {
        let defaults = UserDefaults.standard
        let configured = defaults.string(forKey: defaultNamespaceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : "local"
    }

    private nonisolated func updatingManifestNamespace(in content: String, to namespace: String) throws -> String {
        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []
        var foundPackageSection = false
        var inPackageSection = false
        var insertedNamespace = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "[package]" {
                if inPackageSection && !insertedNamespace {
                    updatedLines.append("namespace = \"\(namespace)\"")
                    insertedNamespace = true
                }
                foundPackageSection = true
                inPackageSection = true
                updatedLines.append(line)
                continue
            }

            if trimmed.hasPrefix("[") {
                if inPackageSection && !insertedNamespace {
                    updatedLines.append("namespace = \"\(namespace)\"")
                    insertedNamespace = true
                }
                inPackageSection = false
                updatedLines.append(line)
                continue
            }

            guard inPackageSection else {
                updatedLines.append(line)
                continue
            }

            if extractTomlValue(from: trimmed, key: "namespace") != nil {
                let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                updatedLines.append("\(indentation)namespace = \"\(namespace)\"")
                insertedNamespace = true
            } else {
                updatedLines.append(line)
            }
        }

        guard foundPackageSection else {
            throw LocalPackageError.invalidManifest("missing [package] section")
        }

        if !insertedNamespace {
            updatedLines.append("namespace = \"\(namespace)\"")
        }

        return updatedLines.joined(separator: "\n")
    }

    private nonisolated func validatedNamespace(_ value: String) throws -> String {
        do {
            return try validatedPathComponent(value)
        } catch {
            throw LocalPackageError.invalidNamespace
        }
    }

    private nonisolated func validatedPackagePathComponent(_ value: String, field: String) throws -> String {
        do {
            return try validatedPathComponent(value)
        } catch {
            throw LocalPackageError.invalidManifest("invalid \(field)")
        }
    }

    private nonisolated func validatedPathComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalPackageError.invalidNamespace
        }
        guard trimmed != ".", trimmed != ".." else {
            throw LocalPackageError.invalidNamespace
        }
        guard !trimmed.hasPrefix("~"),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalPackageError.invalidNamespace
        }
        return trimmed
    }

    private nonisolated func validatedPackageDestination(_ url: URL, under rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        let destination = url.standardizedFileURL
        let rootPath = root.path
        let destinationPath = destination.path
        guard destinationPath.hasPrefix(rootPath + "/") else {
            throw LocalPackageError.invalidManifest("invalid package destination")
        }
        try validateNoSymbolicLinkAncestors(for: destination, under: root)
        return destination
    }

    private nonisolated func validateNoSymbolicLinkAncestors(for url: URL, under rootURL: URL) throws {
        let fileManager = FileManager.default
        let stopURL = rootURL.deletingLastPathComponent().standardizedFileURL
        var currentURL = url.standardizedFileURL

        while true {
            if (try? fileManager.destinationOfSymbolicLink(atPath: currentURL.path)) != nil {
                throw LocalPackageError.invalidManifest("symbolic links are not supported")
            }

            if currentURL == stopURL {
                break
            }

            let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
            if parentURL == currentURL {
                break
            }
            currentURL = parentURL
        }
    }

    private nonisolated func validateNoSymbolicLinks(in rootURL: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        if try rootURL.resourceValues(forKeys: keys).isSymbolicLink == true {
            throw LocalPackageError.invalidManifest("symbolic links are not supported")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }

        for case let itemURL as URL in enumerator {
            if try itemURL.resourceValues(forKeys: keys).isSymbolicLink == true {
                throw LocalPackageError.invalidManifest("symbolic links are not supported")
            }
        }
    }

    private nonisolated func integrateLooseRootItems(defaultNamespace: String) throws {
        guard let rootURL else { return }

        let fileManager = FileManager.default

        // Phase 1: Ingest loose items at the root level (folders with typst.toml or archives).
        let rootCandidates = try looseImportableItems(in: rootURL)
        for candidate in rootCandidates {
            do {
                _ = try importItem(at: candidate, defaultNamespace: defaultNamespace)
                if fileManager.fileExists(atPath: candidate.path) {
                    try removeItem(at: candidate)
                }
            } catch {
                continue
            }
        }

        // Phase 2: Scan inside existing namespace directories for misplaced packages.
        // A properly structured package lives at namespace/name/version/typst.toml.
        // A misplaced package lives at namespace/<folder>/typst.toml (missing name/version split).
        let namespaceDirs = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for nsDir in namespaceDirs {
            guard (try? isDirectory(nsDir)) == true else { continue }
            let namespace = nsDir.lastPathComponent
            let misplaced = try looseImportableItems(in: nsDir)
            for candidate in misplaced {
                do {
                    _ = try importItem(at: candidate, defaultNamespace: namespace)
                    if fileManager.fileExists(atPath: candidate.path) {
                        try removeItem(at: candidate)
                    }
                    try removeIfEmpty(nsDir)
                } catch {
                    continue
                }
            }
        }
    }

    /// Returns importable items (folders with `typst.toml` or archives) that sit
    /// directly inside the given directory — i.e. not yet in the proper
    /// `namespace/name/version/` hierarchy.
    private nonisolated func looseImportableItems(in directoryURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.filter { candidate in
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                return fileManager.fileExists(
                    atPath: candidate.appendingPathComponent("typst.toml").path
                )
            }
            return PackageArchiveImporter.archiveKind(for: candidate) != nil
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private nonisolated func discoverImportableItems(in directoryURL: URL, maxDepth: Int) throws -> [URL] {
        var results: [URL] = []
        var seenPaths: Set<String> = []

        func visit(_ url: URL, depth: Int) throws {
            let standardized = url.standardizedFileURL
            let standardizedPath = standardized.path
            guard !seenPaths.contains(standardizedPath) else { return }

            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                return
            }
            if values.isDirectory == true {
                let manifestURL = standardized.appendingPathComponent("typst.toml")
                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    seenPaths.insert(standardizedPath)
                    results.append(standardized)
                    return
                }

                guard depth < maxDepth else { return }

                let children = try FileManager.default.contentsOfDirectory(
                    at: standardized,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for child in children.sorted(by: {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }) {
                    try visit(child, depth: depth + 1)
                }
            } else if PackageArchiveImporter.archiveKind(for: standardized) != nil {
                seenPaths.insert(standardizedPath)
                results.append(standardized)
            }
        }

        try visit(directoryURL, depth: 0)
        return results
    }

    private nonisolated func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isSymbolicLink != true && values.isDirectory == true
    }

    private nonisolated func directorySize(at url: URL) throws -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            totalSize += Int64(values.fileSize ?? 0)
        }
        return totalSize
    }

    private nonisolated func removeIfEmpty(_ url: URL) throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }
        guard url.path.hasPrefix(rootURL.path), url != rootURL else { return }
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        if contents.isEmpty {
            try removeItem(at: url)
        }
    }

    private nonisolated func createDirectory(at url: URL) throws {
        if let rootURL {
            try validateNoSymbolicLinkAncestors(for: url.standardizedFileURL, under: rootURL.standardizedFileURL)
        }
        if isUsingICloudStorage(at: url) {
            try CloudFileCoordinator.createDirectory(at: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private nonisolated func removeItem(at url: URL) throws {
        if isUsingICloudStorage(at: url) {
            try CloudFileCoordinator.removeItem(at: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated func readString(at url: URL) throws -> String {
        if isUsingICloudStorage(at: url) {
            return try CloudFileCoordinator.readString(from: url)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private nonisolated func writeString(_ string: String, to url: URL) throws {
        if let rootURL {
            try validateNoSymbolicLinkAncestors(for: url.standardizedFileURL, under: rootURL.standardizedFileURL)
        }
        if isUsingICloudStorage(at: url) {
            try CloudFileCoordinator.writeString(string, to: url)
        } else {
            try string.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated func copyItemReplacingSafely(from sourceURL: URL, to destinationURL: URL, usesCoordination: Bool) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }
        if let rootURL {
            try validateNoSymbolicLinkAncestors(for: destinationURL.standardizedFileURL, under: rootURL.standardizedFileURL)
        }

        if usesCoordination {
            try CloudFileCoordinator.copyItem(from: sourceURL, to: destinationURL)
            return
        }

        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".replace-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private nonisolated func isUsingICloudStorage(at url: URL) -> Bool {
        guard let documentsURL = FileManager.default
            .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL else {
            return false
        }

        let candidatePath = url.standardizedFileURL.path
        let documentsPath = documentsURL.path
        return candidatePath == documentsPath || candidatePath.hasPrefix(documentsPath + "/")
    }
}

enum LocalPackageError: Error, LocalizedError {
    case storageUnavailable
    case missingManifest
    case invalidManifest(String)
    case invalidNamespace
    case noImportableItems
    case unsupportedArchive
    case invalidArchive
    case multiplePackageRoots
    case packageExists(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return L10n.tr("error.local_package.storage_unavailable")
        case .missingManifest:
            return L10n.tr("error.local_package.missing_manifest")
        case .invalidManifest(let detail):
            return L10n.format("error.local_package.invalid_manifest", detail)
        case .invalidNamespace:
            return L10n.tr("error.local_package.invalid_namespace")
        case .noImportableItems:
            return L10n.tr("error.local_package.no_importable_items")
        case .unsupportedArchive:
            return L10n.tr("error.local_package.unsupported_archive")
        case .invalidArchive:
            return L10n.tr("error.local_package.invalid_archive")
        case .multiplePackageRoots:
            return L10n.tr("error.local_package.multiple_package_roots")
        case .packageExists(let spec):
            return L10n.format("error.local_package.package_exists", spec)
        }
    }
}
