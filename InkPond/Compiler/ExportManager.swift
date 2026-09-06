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

    /// Compile document to PDF data on a background thread.
    /// Reads source from the entry file on disk.
    static func compilePDF(for document: InkPondDocument) async -> Result<Data, TypstBridgeError> {
        let source: String
        do {
            source = try ProjectFileManager.readTypFile(named: document.entryFileName, for: document)
        } catch {
            return .failure(.compilationFailed(error.localizedDescription))
        }
        let resolvedFonts: ResolvedCompileFonts
        do {
            resolvedFonts = try CompileFontResolver().resolveFonts(for: document)
        } catch {
            return .failure(.compilationFailed(error.localizedDescription))
        }
        let effectiveSource = CompileFontResolver.effectiveSource(for: source, resolvedFonts: resolvedFonts)
        let rootDir = ProjectFileManager.projectDirectory(for: document).path

        return await Task.detached(priority: TypstCompiler.taskPriority(for: .immediate)) {
            let materializedFontPaths = CoreTextFontMaterializer.materializePlannedFonts(in: resolvedFonts.fontPaths)
            return TypstBridge.compile(source: effectiveSource, fontPaths: materializedFontPaths, rootDir: rootDir)
        }.value
    }

    /// Write PDF data to a temporary file and return its URL.
    nonisolated static func temporaryPDFURL(data: Data, title: String) throws -> URL {
        let sanitized = title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).pdf")
        try data.write(to: url)
        return url
    }

    /// Write .typ source to a temporary file and return its URL.
    /// Uses `fileName` as the exported file name (e.g. "main.typ").
    static func temporaryTypURL(for document: InkPondDocument, fileName: String) throws -> URL {
        let sanitized = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitized)
        let source = try ProjectFileManager.readTypFile(named: fileName, for: document)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Zip the entire project directory and return a temporary URL.
    /// The zip file is named after the document title.
    static func zipProject(for document: InkPondDocument) throws -> URL {
        try zipProject(
            sourceDir: ProjectFileManager.projectDirectory(for: document),
            title: document.title
        )
    }

    /// Zip a project directory from Sendable values that can safely cross into
    /// detached export work.
    nonisolated static func zipProject(sourceDir projectDir: URL, title: String) throws -> URL {
        let sanitized = title.replacingOccurrences(of: "/", with: "-")
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).zip")

        // Remove any previous export at this path
        try? FileManager.default.removeItem(at: zipURL)

        // Use NSFileCoordinatorWritingForMerging to create a zip via a Process is unavailable on iOS.
        // Instead, use the built-in ZIP support via FileManager on iOS 16+ / coordinated copy.
        // We rely on the ZipFoundation-free approach: iterate files and write a zip manually,
        // or use the NSFileCoordinatorWritingOptions compress workaround.
        // The simplest supported approach on iOS is to use a URLSession background download trick,
        // but the most reliable approach is to use the system archiver via Process — unavailable on iOS.
        // We use a pure-Swift streaming zip writer below.
        try writeZip(sourceDir: projectDir, destinationURL: zipURL)
        return zipURL
    }

    // MARK: - Streaming ZIP writer (store method)

    nonisolated private static func writeZip(sourceDir: URL, destinationURL: URL) throws {
        var entries: [(relativePath: String, url: URL)] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles]) {
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
