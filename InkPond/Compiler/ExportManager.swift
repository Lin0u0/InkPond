//
//  ExportManager.swift
//  InkPond
//

import Foundation
import UIKit

enum ExportManager {

    /// Remove stale exported files from the temporary directory.
    /// Call periodically (e.g. at app launch) to reclaim disk space.
    static func cleanupTemporaryExports() {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let exportExtensions: Set<String> = ["pdf", "typ", "zip"]
        guard let items = try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-3600) // older than 1 hour
        for url in items {
            guard exportExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modDate < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Reads mutable document state synchronously. Editor callers should supply
    /// all retained session overlays BEFORE their first await.
    static func snapshotInput(
        for document: InkPondDocument,
        textOverlays: [String: String] = [:],
        includeFonts: Bool = true,
        sourceFileName: String? = nil
    ) throws -> OperationSnapshotInput {
        // A source export is a value capture, not a project/compiler capture.
        // In particular, a single-file grant never authorizes its parent tree.
        if let sourceFileName {
            _ = try OperationSnapshot.safeURL(sourceFileName, under: FileManager.default.temporaryDirectory)
            let source: String
            if let overlay = textOverlays[sourceFileName] { source = overlay }
            else { source = try ProjectFileManager.readTypFile(named: sourceFileName, for: document) }
            return OperationSnapshotInput(
                projectID: document.projectID, title: document.title, entryFileName: sourceFileName,
                source: source, projectRoot: nil, fontPaths: [],
                textOverlays: [sourceFileName: source], localPackagesRoot: nil, packageCacheRoot: nil)
        }
        guard ProjectFileManager.externalSingleFileURL(for: document) == nil else {
            throw SnapshotCaptureError.unsupportedInput
        }
        let entry = document.entryFileName
        let source: String
        if let overlay = textOverlays[entry] { source = overlay }
        else { source = try ProjectFileManager.readTypFile(named: entry, for: document) }
        let fonts = includeFonts ? try CompileFontResolver().resolveFonts(for: document, entrySourceOverride: source) : nil
        var overlays = textOverlays
        overlays[entry] = source
        return OperationSnapshotInput(
            projectID: document.projectID, title: document.title, entryFileName: entry,
            source: fonts.map { CompileFontResolver.effectiveSource(for: source, resolvedFonts: $0) } ?? source,
            projectRoot: ProjectFileManager.projectDirectory(for: document), fontPaths: fonts?.fontPaths ?? [],
            textOverlays: overlays,
            settings: ["entryFileName": entry, "fontFileNames": document.fontFileNames.joined(separator: "\u{1F}")],
            localPackagesRoot: includeFonts ? TypstBridge.localPackagesDirectoryURL : nil,
            packageCacheRoot: includeFonts ? TypstBridge.packageCacheDirectoryURL : nil
        )
    }

    static func compilePDF(for document: InkPondDocument) async -> Result<Data, TypstBridgeError> {
        do {
            let input = try snapshotInput(for: document)
            let snapshot = try await Task.detached { try OperationSnapshot.capture(input) }.value
            return await compilePDF(snapshot: snapshot)
        } catch { return .failure(.compilationFailed(error.localizedDescription)) }
    }

    nonisolated static func compilePDF(snapshot: OperationSnapshot) async -> Result<Data, TypstBridgeError> {
        await Task.detached(priority: .userInitiated) {
            do {
                let sealed = try SealedCompileSnapshot.prepare(snapshot)
                return pdfResult(TypstBridge.compile(snapshot: sealed, output: .pdf))
            } catch let error as TypstBridgeError { return .failure(error) }
            catch { return .failure(.compilationFailed(error.localizedDescription)) }
        }.value
    }

    nonisolated static func compilePDF(snapshot: SealedCompileSnapshot) async -> Result<Data, TypstBridgeError> {
        await Task.detached(priority: .userInitiated) {
            pdfResult(TypstBridge.compile(snapshot: snapshot, output: .pdf))
        }.value
    }

    nonisolated private static func pdfResult(_ result: Result<TypstPreviewArtifact, TypstBridgeError>) -> Result<Data, TypstBridgeError> {
        result.flatMap { artifact in
            guard let data = artifact.pdfData else {
                return .failure(.snapshotFailed(.stageInvalid, L10n.tr("error.typst.unknown_compilation")))
            }
            return .success(data)
        }
    }

    /// Write PDF data to a temporary file and return its URL.
    nonisolated static func temporaryPDFURL(data: Data, title: String) throws -> URL {
        let sanitized = title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(sanitized).pdf")
        try data.write(to: url)
        return url
    }

    /// Write .typ source to a temporary file and return its URL.
    /// Uses `fileName` as the exported file name (e.g. "main.typ").
    static func temporaryTypURL(for document: InkPondDocument, fileName: String) throws -> URL {
        let snapshot = try OperationSnapshot.capture(snapshotInput(for: document, includeFonts: false, sourceFileName: fileName))
        return try temporaryTypURL(snapshot: snapshot, fileName: fileName)
    }

    nonisolated static func temporaryTypURL(snapshot: OperationSnapshot, fileName: String) throws -> URL {
        try withExtendedLifetime(snapshot) {
            let source = try OperationSnapshot.safeURL(fileName, under: snapshot.projectRoot)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(UUID().uuidString)-\(fileName.replacingOccurrences(of: "/", with: "-"))")
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            return destination
        }
    }

    static func zipProject(for document: InkPondDocument) throws -> URL {
        let snapshot = try OperationSnapshot.capture(snapshotInput(for: document, includeFonts: false))
        return try zipProject(snapshot: snapshot)
    }

    nonisolated static func zipProject(snapshot: OperationSnapshot) throws -> URL {
        try withExtendedLifetime(snapshot) {
            try writeProjectZip(sourceDir: snapshot.projectRoot, title: snapshot.title)
        }
    }

    /// Compatibility wrapper: freeze the directory rather than stream live files.
    nonisolated static func zipProject(sourceDir projectDir: URL, title: String) throws -> URL {
        let snapshot = try OperationSnapshot.capture(OperationSnapshotInput(
            projectID: "", title: title, entryFileName: "main.typ", source: "",
            projectRoot: projectDir, fontPaths: [], localPackagesRoot: nil, packageCacheRoot: nil))
        return try zipProject(snapshot: snapshot)
    }

    nonisolated private static func writeProjectZip(sourceDir projectDir: URL, title: String) throws -> URL {
        let sanitized = title.replacingOccurrences(of: "/", with: "-")
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(sanitized).zip")
        do { try writeZip(sourceDir: projectDir, destinationURL: zipURL) }
        catch { try? FileManager.default.removeItem(at: zipURL); throw error }
        return zipURL
    }

    // MARK: - Streaming ZIP writer (store method)

    nonisolated private static func writeZip(sourceDir: URL, destinationURL: URL) throws {
        var entries: [(relativePath: String, url: URL)] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: []) {
            for case let fileURL as URL in enumerator {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { continue }
                let relative = String(fileURL.path.dropFirst(sourceDir.path.count + 1))
                entries.append((relativePath: relative, url: fileURL))
            }
        }
        try writeZipEntries(entries, to: destinationURL)
    }

    nonisolated private static func writeZipEntries(_ entries: [(relativePath: String, url: URL)], to destinationURL: URL) throws {
        struct CentralRecord {
            let nameData: Data
            let crc: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? handle.close()
        }

        var offset: UInt64 = 0
        var centralRecords: [CentralRecord] = []

        for entry in entries {
            let nameData = Data(entry.relativePath.utf8)
            guard !nameData.isEmpty, nameData.count <= Int(UInt16.max) else { continue }
            let fileSize = try fileSizeUInt32(at: entry.url)
            let crc = try crc32ForFile(at: entry.url)

            guard offset <= UInt64(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let localHeaderOffset = UInt32(offset)

            // Local file header (STORE only, no compression).
            var local = Data()
            local += uint32LE(0x04034b50)             // signature
            local += uint16LE(20)                     // version needed
            local += uint16LE(0)                      // flags
            local += uint16LE(0)                      // method: store
            local += uint16LE(0)                      // mod time
            local += uint16LE(0)                      // mod date
            local += uint32LE(crc)                    // crc-32
            local += uint32LE(fileSize)               // compressed size
            local += uint32LE(fileSize)               // uncompressed size
            local += uint16LE(UInt16(nameData.count)) // file name length
            local += uint16LE(0)                      // extra field length

            try write(local, to: handle, offset: &offset)
            try write(nameData, to: handle, offset: &offset)
            try streamFile(from: entry.url, to: handle, offset: &offset)

            centralRecords.append(
                CentralRecord(
                    nameData: nameData,
                    crc: crc,
                    size: fileSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        guard offset <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let centralOffset = UInt32(offset)
        var centralSize: UInt32 = 0

        for record in centralRecords {
            var central = Data()
            central += uint32LE(0x02014b50)                 // signature
            central += uint16LE(20)                         // version made by
            central += uint16LE(20)                         // version needed
            central += uint16LE(0)                          // flags
            central += uint16LE(0)                          // method: store
            central += uint16LE(0)                          // mod time
            central += uint16LE(0)                          // mod date
            central += uint32LE(record.crc)
            central += uint32LE(record.size)
            central += uint32LE(record.size)
            central += uint16LE(UInt16(record.nameData.count))
            central += uint16LE(0)                          // extra field length
            central += uint16LE(0)                          // comment length
            central += uint16LE(0)                          // disk number start
            central += uint16LE(0)                          // internal attrs
            central += uint32LE(0)                          // external attrs
            central += uint32LE(record.localHeaderOffset)
            central += record.nameData

            try write(central, to: handle, offset: &offset)
            centralSize &+= UInt32(central.count)
        }

        // End of central directory record
        var eocd = Data()
        eocd += uint32LE(0x06054b50)
        eocd += uint16LE(0)                               // disk number
        eocd += uint16LE(0)                               // disk with central dir
        eocd += uint16LE(UInt16(clamping: centralRecords.count))
        eocd += uint16LE(UInt16(clamping: centralRecords.count))
        eocd += uint32LE(centralSize)
        eocd += uint32LE(centralOffset)
        eocd += uint16LE(0)                               // comment length
        try write(eocd, to: handle, offset: &offset)
    }

    nonisolated private static func write(_ data: Data, to handle: FileHandle, offset: inout UInt64) throws {
        try handle.write(contentsOf: data)
        offset &+= UInt64(data.count)
    }

    nonisolated private static func fileSizeUInt32(at url: URL) throws -> UInt32 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        let size = number.uint64Value
        guard size <= UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
        return UInt32(size)
    }

    nonisolated private static func streamFile(from url: URL, to handle: FileHandle, offset: inout UInt64) throws {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: chunkSize)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 { break }
            let data = Data(bytes: buffer, count: count)
            try write(data, to: handle, offset: &offset)
        }
    }

    nonisolated private static func crc32ForFile(at url: URL) throws -> UInt32 {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var crc: UInt32 = 0xFFFFFFFF

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: chunkSize)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 { break }
            crc = crc32Update(crc, buffer: buffer, count: count)
        }
        return crc ^ 0xFFFFFFFF
    }

    nonisolated private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian; return Data(bytes: &x, count: 2)
    }
    nonisolated private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian; return Data(bytes: &x, count: 4)
    }

    nonisolated private static func crc32Update(_ crc: UInt32,
                                                buffer: UnsafePointer<UInt8>,
                                                count: Int) -> UInt32 {
        var crc = crc
        for i in 0..<count {
            crc ^= UInt32(buffer[i])
            for _ in 0..<8 {
                if crc & 1 == 1 { crc = (crc >> 1) ^ 0xEDB88320 }
                else { crc >>= 1 }
            }
        }
        return crc
    }

    /// Present the system print dialog for PDF data.
    static func printPDF(data: Data, jobName: String) {
        let controller = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = jobName
        printInfo.outputType = .general
        controller.printInfo = printInfo
        controller.printingItem = data
        controller.present(animated: true)
    }
}
