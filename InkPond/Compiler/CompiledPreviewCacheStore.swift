//
//  CompiledPreviewCacheStore.swift
//  InkPond
//

import CryptoKit
import Foundation

struct CompiledPreviewCacheDescriptor: Equatable, Sendable {
    nonisolated let projectID: String
    nonisolated let documentTitle: String
    nonisolated let entryFileName: String
}

struct CompiledPreviewCacheInput: Equatable, Sendable {
    nonisolated let descriptor: CompiledPreviewCacheDescriptor
    nonisolated let source: String
    nonisolated let fontPaths: [String]
    nonisolated let rootDir: String?
    nonisolated let localPackagesDir: String?
    nonisolated let typstVersion: String?
}

struct CompiledPreviewCacheSVGPageManifest: Equatable, Sendable {
    nonisolated let fileName: String
    nonisolated let widthPoints: Double
    nonisolated let heightPoints: Double
}

struct CompiledPreviewCacheManifest: Equatable, Sendable {
    nonisolated let projectID: String
    nonisolated let documentTitle: String
    nonisolated let entryFileName: String
    nonisolated let typstVersion: String?
    nonisolated let cacheSchemaVersion: Int
    nonisolated let inputFingerprint: String
    nonisolated let pdfByteSize: Int64?
    nonisolated let svgPages: [CompiledPreviewCacheSVGPageManifest]
    nonisolated let updatedAt: Date
}

struct CompiledPreviewCacheEntry: Identifiable, Equatable, Sendable {
    nonisolated let manifest: CompiledPreviewCacheManifest
    nonisolated let pdfURL: URL?
    nonisolated let manifestURL: URL
    nonisolated let pdfSizeInBytes: Int64
    nonisolated let svgSizeInBytes: Int64
    nonisolated let sourceMapSizeInBytes: Int64

    nonisolated var id: String { manifest.projectID }
    nonisolated var projectID: String { manifest.projectID }
    nonisolated var documentTitle: String { manifest.documentTitle }
    nonisolated var entryFileName: String { manifest.entryFileName }
    nonisolated var updatedAt: Date { manifest.updatedAt }
    nonisolated var firstSVGPageURL: URL? {
        guard let firstPage = manifest.svgPages.first else { return nil }
        return manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(CompiledPreviewCacheStore.svgPagesDirectoryName, isDirectory: true)
            .appendingPathComponent(firstPage.fileName)
    }
}

struct CompiledPreviewCacheSnapshot: Equatable, Sendable {
    nonisolated let entries: [CompiledPreviewCacheEntry]

    nonisolated var totalSizeInBytes: Int64 {
        entries.reduce(0) { $0 + $1.pdfSizeInBytes + $1.svgSizeInBytes + $1.sourceMapSizeInBytes }
    }
}

struct CompiledPreviewCacheStore: Sendable {
    nonisolated static let cacheSchemaVersion = 2
    nonisolated static let previewFileName = "preview.pdf"
    nonisolated static let sourceMapFileName = "source-map.json"
    nonisolated static let svgPagesDirectoryName = "svg-pages"
    nonisolated static let manifestFileName = "manifest.json"

    nonisolated let rootURL: URL?

    nonisolated init(rootURL: URL? = Self.defaultRootURL) {
        self.rootURL = rootURL
    }

    nonisolated static var defaultRootURL: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("compiled-previews", isDirectory: true)
    }

    nonisolated func snapshot() throws -> CompiledPreviewCacheSnapshot {
        let fileManager = FileManager.default
        guard let rootURL else {
            return CompiledPreviewCacheSnapshot(entries: [])
        }

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return CompiledPreviewCacheSnapshot(entries: [])
        }

        let directoryURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [CompiledPreviewCacheEntry] = []
        for directoryURL in directoryURLs where try isDirectory(directoryURL) {
            let manifestURL = directoryURL.appendingPathComponent(Self.manifestFileName)
            let pdfURL = directoryURL.appendingPathComponent(Self.previewFileName)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }

            let manifest = try decodeManifest(at: manifestURL)
            let hasPDF = fileManager.fileExists(atPath: pdfURL.path)
            let pdfSize = hasPDF ? try fileSize(at: pdfURL) : 0
            let svgSize = try svgDirectorySize(for: manifest, cacheDirectory: directoryURL)
            let sourceMapURL = directoryURL.appendingPathComponent(Self.sourceMapFileName)
            let sourceMapSize = fileManager.fileExists(atPath: sourceMapURL.path)
                ? try fileSize(at: sourceMapURL)
                : 0
            entries.append(
                CompiledPreviewCacheEntry(
                    manifest: manifest,
                    pdfURL: hasPDF ? pdfURL : nil,
                    manifestURL: manifestURL,
                    pdfSizeInBytes: pdfSize,
                    svgSizeInBytes: svgSize,
                    sourceMapSizeInBytes: sourceMapSize
                )
            )
        }

        entries.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.projectID.localizedCaseInsensitiveCompare($1.projectID) == .orderedAscending
        }
        return CompiledPreviewCacheSnapshot(entries: entries)
    }

    nonisolated func loadIfValid(for input: CompiledPreviewCacheInput) throws -> Data? {
        guard let rootURL else { return nil }

        let cacheDirectory = cacheDirectory(for: input.descriptor.projectID, rootURL: rootURL)
        let manifestURL = cacheDirectory.appendingPathComponent(Self.manifestFileName)
        let pdfURL = cacheDirectory.appendingPathComponent(Self.previewFileName)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: pdfURL.path) else {
            return nil
        }

        let manifest = try decodeManifest(at: manifestURL)
        let fingerprint = try inputFingerprint(for: input)
        guard manifest.projectID == input.descriptor.projectID,
              manifest.entryFileName == input.descriptor.entryFileName,
              (manifest.cacheSchemaVersion == 1 || manifest.cacheSchemaVersion == Self.cacheSchemaVersion),
              manifest.inputFingerprint == fingerprint else {
            return nil
        }

        guard let pdfByteSize = manifest.pdfByteSize else {
            return nil
        }
        let pdfData = try Data(contentsOf: pdfURL)
        guard Int64(pdfData.count) == pdfByteSize else {
            return nil
        }
        return pdfData
    }

    nonisolated func loadArtifactIfValid(for input: CompiledPreviewCacheInput) throws -> TypstPreviewArtifact? {
        guard let rootURL else { return nil }

        let cacheDirectory = cacheDirectory(for: input.descriptor.projectID, rootURL: rootURL)
        let manifestURL = cacheDirectory.appendingPathComponent(Self.manifestFileName)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest = try decodeManifest(at: manifestURL)
        let fingerprint = try inputFingerprint(for: input)
        guard manifest.projectID == input.descriptor.projectID,
              manifest.entryFileName == input.descriptor.entryFileName,
              manifest.cacheSchemaVersion == Self.cacheSchemaVersion,
              manifest.inputFingerprint == fingerprint,
              !manifest.svgPages.isEmpty else {
            return nil
        }

        let pdfURL = cacheDirectory.appendingPathComponent(Self.previewFileName)
        var pdfData: Data?
        if let pdfByteSize = manifest.pdfByteSize {
            guard fileManager.fileExists(atPath: pdfURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: pdfURL)
            guard Int64(data.count) == pdfByteSize else {
                return nil
            }
            pdfData = data
        }

        let svgDirectory = cacheDirectory.appendingPathComponent(Self.svgPagesDirectoryName, isDirectory: true)
        var pages: [TypstPreviewPage] = []
        pages.reserveCapacity(manifest.svgPages.count)
        for page in manifest.svgPages {
            let fileURL = svgDirectory.appendingPathComponent(page.fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let svg = try String(contentsOf: fileURL, encoding: .utf8)
            pages.append(TypstPreviewPage(
                svg: svg,
                widthPoints: page.widthPoints,
                heightPoints: page.heightPoints
            ))
        }

        return TypstPreviewArtifact(
            svgPages: pages,
            pdfData: pdfData,
            sourceMap: try loadSourceMapIfPresent(in: cacheDirectory)
        )
    }

    nonisolated func save(pdfData: Data, for input: CompiledPreviewCacheInput) throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let cacheDirectory = cacheDirectory(for: input.descriptor.projectID, rootURL: rootURL)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let svgDirectory = cacheDirectory.appendingPathComponent(Self.svgPagesDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: svgDirectory.path) {
            try fileManager.removeItem(at: svgDirectory)
        }
        let sourceMapURL = cacheDirectory.appendingPathComponent(Self.sourceMapFileName)
        if fileManager.fileExists(atPath: sourceMapURL.path) {
            try fileManager.removeItem(at: sourceMapURL)
        }

        let manifest = CompiledPreviewCacheManifest(
            projectID: input.descriptor.projectID,
            documentTitle: input.descriptor.documentTitle,
            entryFileName: input.descriptor.entryFileName,
            typstVersion: input.typstVersion,
            cacheSchemaVersion: 1,
            inputFingerprint: try inputFingerprint(for: input),
            pdfByteSize: Int64(pdfData.count),
            svgPages: [],
            updatedAt: Date()
        )

        try pdfData.write(to: cacheDirectory.appendingPathComponent(Self.previewFileName), options: .atomic)
        try encodeManifest(manifest, to: cacheDirectory.appendingPathComponent(Self.manifestFileName))
    }

    nonisolated func save(artifact: TypstPreviewArtifact, for input: CompiledPreviewCacheInput) throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let cacheDirectory = cacheDirectory(for: input.descriptor.projectID, rootURL: rootURL)
        let svgDirectory = cacheDirectory.appendingPathComponent(Self.svgPagesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: svgDirectory.path) {
            try fileManager.removeItem(at: svgDirectory)
        }
        try fileManager.createDirectory(at: svgDirectory, withIntermediateDirectories: true)

        var svgPageManifests: [CompiledPreviewCacheSVGPageManifest] = []
        svgPageManifests.reserveCapacity(artifact.svgPages.count)
        for (index, page) in artifact.svgPages.enumerated() {
            let fileName = String(format: "page-%04d.svg", index + 1)
            let fileURL = svgDirectory.appendingPathComponent(fileName)
            try page.svg.write(to: fileURL, atomically: true, encoding: .utf8)
            svgPageManifests.append(CompiledPreviewCacheSVGPageManifest(
                fileName: fileName,
                widthPoints: page.widthPoints,
                heightPoints: page.heightPoints
            ))
        }

        let manifest = CompiledPreviewCacheManifest(
            projectID: input.descriptor.projectID,
            documentTitle: input.descriptor.documentTitle,
            entryFileName: input.descriptor.entryFileName,
            typstVersion: input.typstVersion,
            cacheSchemaVersion: Self.cacheSchemaVersion,
            inputFingerprint: try inputFingerprint(for: input),
            pdfByteSize: artifact.pdfData.map { Int64($0.count) },
            svgPages: svgPageManifests,
            updatedAt: Date()
        )

        let pdfURL = cacheDirectory.appendingPathComponent(Self.previewFileName)
        if let pdfData = artifact.pdfData {
            try pdfData.write(to: pdfURL, options: .atomic)
        } else if fileManager.fileExists(atPath: pdfURL.path) {
            try fileManager.removeItem(at: pdfURL)
        }
        try saveSourceMap(artifact.sourceMap, in: cacheDirectory)
        try encodeManifest(manifest, to: cacheDirectory.appendingPathComponent(Self.manifestFileName))
    }

    nonisolated func remove(_ entry: CompiledPreviewCacheEntry) throws {
        try remove(projectID: entry.projectID)
    }

    nonisolated func remove(projectID: String) throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }
        let directoryURL = cacheDirectory(for: projectID, rootURL: rootURL)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    nonisolated func clearAll() throws {
        let fileManager = FileManager.default
        guard let rootURL else { return }

        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    nonisolated func moveCache(
        from oldProjectID: String,
        to newProjectID: String,
        documentTitle: String? = nil
    ) throws {
        guard oldProjectID != newProjectID else { return }

        let fileManager = FileManager.default
        guard let rootURL else { return }

        let oldDirectory = cacheDirectory(for: oldProjectID, rootURL: rootURL)
        guard fileManager.fileExists(atPath: oldDirectory.path) else { return }

        let newDirectory = cacheDirectory(for: newProjectID, rootURL: rootURL)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: newDirectory.path) {
            try fileManager.removeItem(at: newDirectory)
        }
        try fileManager.moveItem(at: oldDirectory, to: newDirectory)

        let manifestURL = newDirectory.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }

        var manifest = try decodeManifest(at: manifestURL)
        manifest = CompiledPreviewCacheManifest(
            projectID: newProjectID,
            documentTitle: documentTitle ?? manifest.documentTitle,
            entryFileName: manifest.entryFileName,
            typstVersion: manifest.typstVersion,
            cacheSchemaVersion: manifest.cacheSchemaVersion,
            inputFingerprint: manifest.inputFingerprint,
            pdfByteSize: manifest.pdfByteSize,
            svgPages: manifest.svgPages,
            updatedAt: manifest.updatedAt
        )
        try encodeManifest(manifest, to: manifestURL)
    }

    nonisolated func inputFingerprint(for input: CompiledPreviewCacheInput) throws -> String {
        let payload = FingerprintPayload(
            source: input.source,
            entryFileName: input.descriptor.entryFileName,
            rootDir: input.rootDir,
            typstVersion: input.typstVersion,
            fontFiles: try input.fontPaths.map(resourceFingerprint(forFontPath:)),
            projectFiles: try directoryFileFingerprints(rootDir: input.rootDir),
            localPackageFiles: try localPackageFingerprints(
                source: input.source,
                projectRootDir: input.rootDir,
                localPackagesRootDir: input.localPackagesDir
            )
        )

        let data = try JSONSerialization.data(withJSONObject: payload.jsonObject, options: [.sortedKeys])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func cacheDirectory(for projectID: String, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(projectID, isDirectory: true)
    }

    private nonisolated func resourceFingerprint(forFontPath path: String) throws -> ResourceFingerprint {
        try resourceFingerprint(
            url: URL(fileURLWithPath: path),
            path: path
        )
    }

    private nonisolated func directoryFileFingerprints(rootDir: String?) throws -> [ResourceFingerprint] {
        guard let rootDir else { return [] }

        let rootURL = URL(fileURLWithPath: rootDir, isDirectory: true).standardizedFileURL
        return try directoryFileFingerprints(rootURL: rootURL)
    }

    private nonisolated func directoryFileFingerprints(rootURL: URL, pathPrefix: String? = nil) throws -> [ResourceFingerprint] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [ResourceFingerprint] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }

            var relativePath = String(fileURL.standardizedFileURL.path.dropFirst(rootURL.path.count + 1))
            if let pathPrefix {
                relativePath = "\(pathPrefix)/\(relativePath)"
            }
            items.append(try resourceFingerprint(url: fileURL, path: relativePath))
        }

        items.sort { $0.path < $1.path }
        return items
    }

    private nonisolated func localPackageFingerprints(
        source: String,
        projectRootDir: String?,
        localPackagesRootDir: String?
    ) throws -> [ResourceFingerprint] {
        guard let localPackagesRootDir else { return [] }

        let rootURL = URL(fileURLWithPath: localPackagesRootDir, isDirectory: true).standardizedFileURL
        var pendingReferences = try Self.localPackageReferences(
            in: referenceSources(source: source, projectRootDir: projectRootDir)
        )
        guard !pendingReferences.isEmpty else { return [] }

        var items: [ResourceFingerprint] = []
        var processedReferences = Set<String>()
        while !pendingReferences.isEmpty {
            let reference = pendingReferences.removeFirst()
            let referenceKey = "\(reference.namespace)/\(reference.name)/\(reference.version)"
            guard processedReferences.insert(referenceKey).inserted else { continue }

            let relativePackagePath = "\(reference.namespace)/\(reference.name)/\(reference.version)"
            let packageURL = rootURL
                .appendingPathComponent(reference.namespace, isDirectory: true)
                .appendingPathComponent(reference.name, isDirectory: true)
                .appendingPathComponent(reference.version, isDirectory: true)
            if FileManager.default.fileExists(atPath: packageURL.path) {
                items.append(contentsOf: try directoryFileFingerprints(
                    rootURL: packageURL.standardizedFileURL,
                    pathPrefix: relativePackagePath
                ))
                pendingReferences.append(contentsOf: try Self.localPackageReferences(
                    in: packageReferenceSources(packageURL: packageURL.standardizedFileURL)
                ))
            } else {
                items.append(ResourceFingerprint(
                    path: relativePackagePath,
                    exists: false,
                    sizeInBytes: nil,
                    modifiedAt: nil,
                    contentHash: nil
                ))
            }
        }

        items.sort { $0.path < $1.path }
        return items
    }

    private nonisolated func referenceSources(source: String, projectRootDir: String?) throws -> [String] {
        var sources = [source]
        guard let projectRootDir else { return sources }

        let projectRootURL = URL(fileURLWithPath: projectRootDir, isDirectory: true).standardizedFileURL
        sources.append(contentsOf: try packageReferenceSources(packageURL: projectRootURL))
        return sources
    }

    private nonisolated func packageReferenceSources(packageURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: packageURL.path),
              let enumerator = fileManager.enumerator(
                at: packageURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var sources: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "typ" || ext == "toml" else { continue }
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                sources.append(text)
            }
        }
        return sources
    }

    private nonisolated static func localPackageReferences(in sources: [String]) -> [(namespace: String, name: String, version: String)] {
        var references: [(namespace: String, name: String, version: String)] = []
        var seen = Set<String>()
        for source in sources {
            for reference in localPackageReferences(in: source) {
                let key = "\(reference.namespace)/\(reference.name)/\(reference.version)"
                if seen.insert(key).inserted {
                    references.append(reference)
                }
            }
        }
        return references
    }

    private nonisolated static func localPackageReferences(in source: String) -> [(namespace: String, name: String, version: String)] {
        let pattern = #"@([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+):([A-Za-z0-9_.+\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var references: [(namespace: String, name: String, version: String)] = []
        var seen = Set<String>()
        for match in matches {
            guard let namespaceRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source),
                  let versionRange = Range(match.range(at: 3), in: source) else {
                continue
            }

            let namespace = String(source[namespaceRange])
            let name = String(source[nameRange])
            let version = String(source[versionRange])
            let key = "\(namespace)/\(name)/\(version)"
            if seen.insert(key).inserted {
                references.append((namespace, name, version))
            }
        }
        return references
    }

    private nonisolated func resourceFingerprint(url: URL, path: String) throws -> ResourceFingerprint {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return ResourceFingerprint(path: path, exists: false, sizeInBytes: nil, modifiedAt: nil, contentHash: nil)
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ResourceFingerprint(
            path: path,
            exists: true,
            sizeInBytes: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970,
            contentHash: try contentHash(for: url)
        )
    }

    private nonisolated func contentHash(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func decodeManifest(at url: URL) throws -> CompiledPreviewCacheManifest {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }

        let updatedAtString = object["updatedAt"] as? String
        let cacheSchemaNumber = object["cacheSchemaVersion"] as? NSNumber
        let pdfByteSizeNumber = object["pdfByteSize"] as? NSNumber
        let svgPages = decodeSVGPageManifests(object["svgPages"])
        guard let projectID = object["projectID"] as? String,
              let documentTitle = object["documentTitle"] as? String,
              let entryFileName = object["entryFileName"] as? String,
              let cacheSchemaNumber,
              let inputFingerprint = object["inputFingerprint"] as? String,
              let updatedAtString,
              let updatedAt = Self.makeISO8601Formatter().date(from: updatedAtString) else {
            throw CocoaError(.coderReadCorrupt)
        }
        if cacheSchemaNumber.intValue == 1, pdfByteSizeNumber == nil {
            throw CocoaError(.coderReadCorrupt)
        }

        return CompiledPreviewCacheManifest(
            projectID: projectID,
            documentTitle: documentTitle,
            entryFileName: entryFileName,
            typstVersion: object["typstVersion"] as? String,
            cacheSchemaVersion: cacheSchemaNumber.intValue,
            inputFingerprint: inputFingerprint,
            pdfByteSize: pdfByteSizeNumber?.int64Value,
            svgPages: svgPages,
            updatedAt: updatedAt
        )
    }

    private nonisolated func loadSourceMapIfPresent(in cacheDirectory: URL) throws -> SourceMap? {
        let sourceMapURL = cacheDirectory.appendingPathComponent(Self.sourceMapFileName)
        guard FileManager.default.fileExists(atPath: sourceMapURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: sourceMapURL)
        return try JSONDecoder().decode(SourceMap.self, from: data)
    }

    private nonisolated func saveSourceMap(_ sourceMap: SourceMap?, in cacheDirectory: URL) throws {
        let sourceMapURL = cacheDirectory.appendingPathComponent(Self.sourceMapFileName)
        let fileManager = FileManager.default
        if let sourceMap {
            let data = try JSONEncoder().encode(sourceMap)
            try data.write(to: sourceMapURL, options: .atomic)
        } else if fileManager.fileExists(atPath: sourceMapURL.path) {
            try fileManager.removeItem(at: sourceMapURL)
        }
    }

    private nonisolated func encodeManifest(_ manifest: CompiledPreviewCacheManifest, to url: URL) throws {
        let jsonObject: [String: Any?] = [
            "projectID": manifest.projectID,
            "documentTitle": manifest.documentTitle,
            "entryFileName": manifest.entryFileName,
            "typstVersion": manifest.typstVersion,
            "cacheSchemaVersion": manifest.cacheSchemaVersion,
            "inputFingerprint": manifest.inputFingerprint,
            "pdfByteSize": manifest.pdfByteSize,
            "svgPages": manifest.svgPages.map { page in
                [
                    "fileName": page.fileName,
                    "widthPoints": page.widthPoints,
                    "heightPoints": page.heightPoints
                ]
            },
            "updatedAt": Self.makeISO8601Formatter().string(from: manifest.updatedAt)
        ]
        let sanitizedObject = jsonObject.reduce(into: [String: Any]()) { partialResult, item in
            if let value = item.value {
                partialResult[item.key] = value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: sanitizedObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private nonisolated func decodeSVGPageManifests(_ value: Any?) -> [CompiledPreviewCacheSVGPageManifest] {
        guard let array = value as? [[String: Any]] else { return [] }

        return array.compactMap { object in
            guard let fileName = object["fileName"] as? String,
                  let widthNumber = object["widthPoints"] as? NSNumber,
                  let heightNumber = object["heightPoints"] as? NSNumber else {
                return nil
            }
            return CompiledPreviewCacheSVGPageManifest(
                fileName: fileName,
                widthPoints: widthNumber.doubleValue,
                heightPoints: heightNumber.doubleValue
            )
        }
    }

    private nonisolated func svgDirectorySize(
        for manifest: CompiledPreviewCacheManifest,
        cacheDirectory: URL
    ) throws -> Int64 {
        guard !manifest.svgPages.isEmpty else { return 0 }

        let svgDirectory = cacheDirectory.appendingPathComponent(Self.svgPagesDirectoryName, isDirectory: true)
        var total: Int64 = 0
        for page in manifest.svgPages {
            let fileURL = svgDirectory.appendingPathComponent(page.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            total += try fileSize(at: fileURL)
        }
        return total
    }

    private nonisolated func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private nonisolated func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    nonisolated private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

private struct FingerprintPayload {
    nonisolated let source: String
    nonisolated let entryFileName: String
    nonisolated let rootDir: String?
    nonisolated let typstVersion: String?
    nonisolated let fontFiles: [ResourceFingerprint]
    nonisolated let projectFiles: [ResourceFingerprint]
    nonisolated let localPackageFiles: [ResourceFingerprint]

    nonisolated var jsonObject: [String: Any] {
        [
            "source": source,
            "entryFileName": entryFileName,
            "rootDir": rootDir ?? NSNull(),
            "typstVersion": typstVersion ?? NSNull(),
            "fontFiles": fontFiles.map(\.jsonObject),
            "projectFiles": projectFiles.map(\.jsonObject),
            "localPackageFiles": localPackageFiles.map(\.jsonObject)
        ]
    }
}

private struct ResourceFingerprint {
    nonisolated let path: String
    nonisolated let exists: Bool
    nonisolated let sizeInBytes: Int64?
    nonisolated let modifiedAt: TimeInterval?
    nonisolated let contentHash: String?

    nonisolated var jsonObject: [String: Any] {
        [
            "path": path,
            "exists": exists,
            "sizeInBytes": sizeInBytes ?? NSNull(),
            "modifiedAt": modifiedAt ?? NSNull(),
            "contentHash": contentHash ?? NSNull()
        ]
    }
}
