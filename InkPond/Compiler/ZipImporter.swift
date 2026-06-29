//
//  ZipImporter.swift
//  InkPond
//

import Foundation

enum ZipImporterError: LocalizedError {
    case invalidData
    case decompressionFailed(Int32)
    case unsupportedCompressionMethod(Int)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidData: return L10n.tr("error.zip.invalid_data")
        case .decompressionFailed(let code): return L10n.format("error.zip.decompression_failed", code)
        case .unsupportedCompressionMethod(let m): return L10n.format("error.zip.unsupported_method", m)
        case .unsafePath(let p): return L10n.format("error.zip.unsafe_path", p)
        }
    }
}

struct ZipImporter {
    nonisolated static let maxArchiveBytes = 256 * 1024 * 1024
    nonisolated static let maxEntryCount = 4_096
    nonisolated static let maxSingleEntryUncompressedBytes = 128 * 1024 * 1024
    nonisolated static let maxTotalUncompressedBytes = 512 * 1024 * 1024

    /// Extract a ZIP archive to `destDir`. Returns the relative paths of extracted files.
    @discardableResult
    nonisolated static func extract(from zipURL: URL, to destDir: URL) throws -> [String] {
        let data = try archiveData(from: zipURL)
        return try extract(data: data, to: destDir)
    }

    @discardableResult
    nonisolated static func extract(data: Data, to destDir: URL) throws -> [String] {
        guard data.count <= maxArchiveBytes else { throw ZipImporterError.invalidData }
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 22 else { throw ZipImporterError.invalidData }
        let root = destDir.standardizedFileURL
        let rootPath = root.path

        // 1. Find EOCD (search backwards for PK\x05\x06)
        var eocdOff = count - 22
        while eocdOff >= 0 {
            if bytes[eocdOff] == 0x50, bytes[eocdOff+1] == 0x4B,
               bytes[eocdOff+2] == 0x05, bytes[eocdOff+3] == 0x06 { break }
            eocdOff -= 1
        }
        guard eocdOff >= 0 else { throw ZipImporterError.invalidData }

        let cdCount  = Int(u16(bytes, eocdOff + 10))
        let cdOffset = Int(u32(bytes, eocdOff + 16))
        guard cdCount <= maxEntryCount,
              cdOffset >= 0,
              cdOffset < count else {
            throw ZipImporterError.invalidData
        }

        // 2. Parse central directory
        struct Entry {
            let name: String
            let method: Int
            let compressedSize: Int
            let uncompressedSize: Int
            let localHeaderOffset: Int
        }
        var entries: [Entry] = []
        var pos = cdOffset
        var totalUncompressedSize = 0
        for _ in 0..<cdCount {
            guard pos + 46 <= count,
                  bytes[pos] == 0x50, bytes[pos+1] == 0x4B,
                  bytes[pos+2] == 0x01, bytes[pos+3] == 0x02
            else { throw ZipImporterError.invalidData }

            let method          = Int(u16(bytes, pos + 10))
            let compressedSize  = Int(u32(bytes, pos + 20))
            let uncompressedSize = Int(u32(bytes, pos + 24))
            guard compressedSize <= maxArchiveBytes,
                  uncompressedSize <= maxSingleEntryUncompressedBytes,
                  totalUncompressedSize <= maxTotalUncompressedBytes - uncompressedSize else {
                throw ZipImporterError.invalidData
            }
            totalUncompressedSize += uncompressedSize
            let nameLen         = Int(u16(bytes, pos + 28))
            let extraLen        = Int(u16(bytes, pos + 30))
            let commentLen      = Int(u16(bytes, pos + 32))
            let localOff        = Int(u32(bytes, pos + 42))
            let nameStart = pos + 46
            let nameEnd   = nameStart + nameLen
            guard nameEnd <= count else { throw ZipImporterError.invalidData }
            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            entries.append(Entry(name: name, method: method,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localOff))
            pos += 46 + nameLen + extraLen + commentLen
        }

        // 3. Detect single top-level directory prefix
        let prefix = topLevelPrefix(entries.map { $0.name })

        // 4. Extract files
        let fm = FileManager.default
        var extracted: [String] = []

        for entry in entries {
            let rawName = entry.name
            if rawName.hasSuffix("/") { continue }           // directory entry
            if rawName.hasPrefix("__MACOSX/") { continue }  // macOS metadata

            var relativeName = rawName
            if let p = prefix, rawName.hasPrefix(p) {
                relativeName = String(rawName.dropFirst(p.count))
            }
            guard !relativeName.isEmpty else { continue }
            let safeRelative = try sanitizedRelativePath(relativeName)

            // Read local file header to find actual data offset
            let lhOff = entry.localHeaderOffset
            guard lhOff + 30 <= count else { throw ZipImporterError.invalidData }
            let lhNameLen  = Int(u16(bytes, lhOff + 26))
            let lhExtraLen = Int(u16(bytes, lhOff + 28))
            let dataStart  = lhOff + 30 + lhNameLen + lhExtraLen
            let dataEnd    = dataStart + entry.compressedSize
            guard dataEnd <= count else { throw ZipImporterError.invalidData }

            let destURL = root.appendingPathComponent(safeRelative).standardizedFileURL
            let destPath = destURL.path
            guard destPath == rootPath || destPath.hasPrefix(rootPath + "/") else {
                throw ZipImporterError.unsafePath(relativeName)
            }
            let parentDir = destURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let compressed = Data(bytes[dataStart..<dataEnd])
            let outData: Data
            switch entry.method {
            case 0:
                guard compressed.count == entry.uncompressedSize else {
                    throw ZipImporterError.invalidData
                }
                outData = compressed   // STORE
            case 8:  outData = try decompressDeflate(compressed, uncompressedSize: entry.uncompressedSize)
            default: throw ZipImporterError.unsupportedCompressionMethod(entry.method)
            }

            try outData.write(to: destURL)
            extracted.append(safeRelative)
        }

        return extracted
    }

    // MARK: - Helpers

    private nonisolated static func archiveData(from zipURL: URL) throws -> Data {
        if let fileSize = try zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maxArchiveBytes {
            throw ZipImporterError.invalidData
        }
        let data = try Data(contentsOf: zipURL)
        guard data.count <= maxArchiveBytes else { throw ZipImporterError.invalidData }
        return data
    }

    private nonisolated static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i+1]) << 8)
    }
    private nonisolated static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
    }

    /// Returns the common single top-level directory prefix if all non-MACOSX names share one.
    private nonisolated static func topLevelPrefix(_ names: [String]) -> String? {
        let relevant = names.filter { !$0.hasPrefix("__MACOSX/") && !$0.isEmpty }
        guard !relevant.isEmpty else { return nil }

        let firstComponents = Set(relevant.map { name -> String in
            if let slashIdx = name.firstIndex(of: "/") {
                return String(name[name.startIndex..<slashIdx])
            }
            return name
        })
        guard firstComponents.count == 1, let dir = firstComponents.first else { return nil }
        guard !dir.isEmpty,
              dir != ".",
              dir != "..",
              !dir.contains("\\") else {
            return nil
        }
        let prefix = dir + "/"
        guard relevant.allSatisfy({ $0.hasPrefix(prefix) }) else { return nil }
        return prefix
    }

    /// Ensure a ZIP entry path is relative and cannot escape destination root.
    private nonisolated static func sanitizedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("~") else {
            throw ZipImporterError.unsafePath(path)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw ZipImporterError.unsafePath(path) }
        for c in components {
            if c.isEmpty || c == "." || c == ".." {
                throw ZipImporterError.unsafePath(path)
            }
        }
        return components.map(String.init).joined(separator: "/")
    }

    /// Decompress raw DEFLATE data (no zlib wrapper) using zlib.
    private nonisolated static func decompressDeflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize <= maxSingleEntryUncompressedBytes else {
            throw ZipImporterError.invalidData
        }
        let bufSize = max(uncompressedSize, 1)
        var result = Data(count: bufSize)
        var stream = z_stream()

        let initRC = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                   Int32(MemoryLayout<z_stream>.size))
        guard initRC == Z_OK else { throw ZipImporterError.decompressionFailed(initRC) }
        defer { inflateEnd(&stream) }

        let compressedCount = compressed.count
        let inflateRC: Int32 = compressed.withUnsafeBytes { inBuf in
            result.withUnsafeMutableBytes { outBuf in
                stream.next_in  = UnsafeMutableRawPointer(mutating: inBuf.baseAddress!)
                    .assumingMemoryBound(to: Bytef.self)
                stream.avail_in = uInt(compressedCount)
                stream.next_out = outBuf.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(bufSize)
                return inflate(&stream, Z_FINISH)
            }
        }

        guard inflateRC == Z_STREAM_END else { throw ZipImporterError.decompressionFailed(inflateRC) }
        let produced = Int(stream.total_out)
        guard produced == uncompressedSize else { throw ZipImporterError.invalidData }
        return Data(result.prefix(produced))
    }
}
