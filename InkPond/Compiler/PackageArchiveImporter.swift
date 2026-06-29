//
//  PackageArchiveImporter.swift
//  InkPond
//

import Foundation

enum PackageArchiveKind: Sendable {
    case zip
    case tar
    case tarGz
}

struct PackageArchiveImporter {
    nonisolated static let maxArchiveBytes = 256 * 1024 * 1024
    nonisolated static let maxEntryCount = 4_096
    nonisolated static let maxSingleEntryUncompressedBytes = 128 * 1024 * 1024
    nonisolated static let maxTotalUncompressedBytes = 512 * 1024 * 1024

    @discardableResult
    nonisolated static func extract(from archiveURL: URL, to destDir: URL) throws -> [String] {
        guard let kind = archiveKind(for: archiveURL) else {
            throw LocalPackageError.unsupportedArchive
        }

        switch kind {
        case .zip:
            return try ZipImporter.extract(from: archiveURL, to: destDir)
        case .tar:
            let data = try archiveData(from: archiveURL)
            return try extractTar(data: data, to: destDir)
        case .tarGz:
            let data = try archiveData(from: archiveURL)
            let tarData = try gunzip(data)
            return try extractTar(data: tarData, to: destDir)
        }
    }

    nonisolated static func archiveKind(for url: URL) -> PackageArchiveKind? {
        let fileName = url.lastPathComponent.lowercased()
        if fileName.hasSuffix(".tar.gz") || fileName.hasSuffix(".tgz") {
            return .tarGz
        }
        if fileName.hasSuffix(".tar") {
            return .tar
        }
        if fileName.hasSuffix(".zip") {
            return .zip
        }
        return nil
    }

    nonisolated static func locatePackageRoot(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let rootManifest = directory.appendingPathComponent("typst.toml")
        var roots: Set<URL> = []

        if fileManager.fileExists(atPath: rootManifest.path) {
            roots.insert(directory.standardizedFileURL)
        }

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "typst.toml" {
                roots.insert(fileURL.deletingLastPathComponent().standardizedFileURL)
            }
        }

        guard !roots.isEmpty else {
            throw LocalPackageError.missingManifest
        }
        guard roots.count == 1, let root = roots.first else {
            throw LocalPackageError.multiplePackageRoots
        }
        return root
    }

    // MARK: - TAR

    @discardableResult
    private nonisolated static func extractTar(data: Data, to destDir: URL) throws -> [String] {
        guard data.count <= maxTotalUncompressedBytes else {
            throw LocalPackageError.invalidArchive
        }
        let bytes = [UInt8](data)
        let root = destDir.standardizedFileURL
        let rootPath = root.path
        let entries = try parseTarEntries(bytes)
        let prefix = topLevelPrefix(entries.map(\.name))
        let fileManager = FileManager.default
        var extracted: [String] = []

        for entry in entries where !entry.isDirectory {
            var relativeName = entry.name
            if let prefix, relativeName.hasPrefix(prefix) {
                relativeName = String(relativeName.dropFirst(prefix.count))
            }
            guard !relativeName.isEmpty else { continue }

            let safeRelativePath = try sanitizedRelativePath(relativeName)
            let destinationURL = root.appendingPathComponent(safeRelativePath).standardizedFileURL
            let destinationPath = destinationURL.path
            guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
                throw LocalPackageError.invalidArchive
            }

            let parentDirectory = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDirectory.path) {
                try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            }

            try data.subdata(in: entry.dataRange).write(to: destinationURL)
            extracted.append(safeRelativePath)
        }

        return extracted
    }

    private nonisolated static func parseTarEntries(_ bytes: [UInt8]) throws -> [TarEntry] {
        guard !bytes.isEmpty else {
            throw LocalPackageError.invalidArchive
        }

        var entries: [TarEntry] = []
        var offset = 0
        var pendingPathOverride: String?
        var totalFileSize = 0

        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<(offset + 512)])
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            let size = try parseOctal(header[124..<136])
            guard size <= maxSingleEntryUncompressedBytes,
                  totalFileSize <= maxTotalUncompressedBytes - size else {
                throw LocalPackageError.invalidArchive
            }
            let typeFlag = header[156]
            let dataStart = offset + 512
            let dataEnd = dataStart + size
            guard dataEnd <= bytes.count else {
                throw LocalPackageError.invalidArchive
            }

            let headerName = try fullEntryName(from: header)
            let entryName = pendingPathOverride ?? headerName
            pendingPathOverride = nil

            switch typeFlag {
            case 0, 48, 53:
                guard entries.count < maxEntryCount else {
                    throw LocalPackageError.invalidArchive
                }
                if typeFlag != 53 {
                    totalFileSize += size
                }
                entries.append(
                    TarEntry(
                        name: entryName,
                        isDirectory: typeFlag == 53 || entryName.hasSuffix("/"),
                        dataRange: dataStart..<dataEnd
                    )
                )
            case 76:
                pendingPathOverride = parseString(bytes[dataStart..<dataEnd])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n"))
            case 120, 103:
                let attributes = parseString(bytes[dataStart..<dataEnd])
                if let path = parsePaxPath(from: attributes), !path.isEmpty {
                    pendingPathOverride = path
                }
            default:
                break
            }

            offset = dataStart + alignedBlockSize(for: size)
        }

        return entries
    }

    private nonisolated static func fullEntryName(from header: [UInt8]) throws -> String {
        let name = parseString(header[0..<100])
        let prefix = parseString(header[345..<500])

        if prefix.isEmpty { return name }
        if name.isEmpty { return prefix }
        return "\(prefix)/\(name)"
    }

    private nonisolated static func parseString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let array = Array(bytes.prefix { $0 != 0 })
        return String(decoding: array, as: UTF8.self)
    }

    private nonisolated static func parseOctal<S: Sequence>(_ bytes: S) throws -> Int where S.Element == UInt8 {
        let raw = parseString(bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return 0 }
        guard let value = Int(raw, radix: 8) else {
            throw LocalPackageError.invalidArchive
        }
        return value
    }

    private nonisolated static func parsePaxPath(from attributes: String) -> String? {
        for line in attributes.split(separator: "\n") {
            guard let attributeRange = line.firstIndex(of: " ") else { continue }
            let payload = line[line.index(after: attributeRange)...]
            if payload.hasPrefix("path=") {
                return String(payload.dropFirst("path=".count))
            }
        }
        return nil
    }

    private nonisolated static func alignedBlockSize(for size: Int) -> Int {
        let remainder = size % 512
        return remainder == 0 ? size : size + (512 - remainder)
    }

    // MARK: - GZIP

    private nonisolated static func archiveData(from archiveURL: URL) throws -> Data {
        if let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maxArchiveBytes {
            throw LocalPackageError.invalidArchive
        }
        let data = try Data(contentsOf: archiveURL)
        guard data.count <= maxArchiveBytes else {
            throw LocalPackageError.invalidArchive
        }
        return data
    }

    private nonisolated static func gunzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw LocalPackageError.invalidArchive
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 16_384
        var output = Data()
        var input = [UInt8](data)
        let inputCount = input.count

        let inflateResult: Int32 = input.withUnsafeMutableBytes { inputBuffer in
            guard let inputBaseAddress = inputBuffer.baseAddress else {
                return Z_DATA_ERROR
            }

            stream.next_in = inputBaseAddress.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(inputCount)

            var status: Int32 = Z_OK

            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let chunkCount = chunk.count
                status = chunk.withUnsafeMutableBytes { outputBuffer in
                    guard let outputBaseAddress = outputBuffer.baseAddress else {
                        return Z_BUF_ERROR
                    }

                    stream.next_out = outputBaseAddress.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkCount)

                    let result = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkCount - Int(stream.avail_out)
                    if produced > 0 {
                        guard output.count <= maxTotalUncompressedBytes - produced else {
                            return Z_MEM_ERROR
                        }
                        let producedBytes = UnsafeBufferPointer(
                            start: outputBaseAddress.assumingMemoryBound(to: UInt8.self),
                            count: produced
                        )
                        output.append(contentsOf: producedBytes)
                    }
                    return result
                }
            } while status == Z_OK

            return status
        }

        guard inflateResult == Z_STREAM_END else {
            throw LocalPackageError.invalidArchive
        }

        return output
    }

    // MARK: - Path Helpers

    private nonisolated static func topLevelPrefix(_ names: [String]) -> String? {
        let relevant = names.filter { !$0.isEmpty && !$0.hasPrefix("__MACOSX/") }
        guard !relevant.isEmpty else { return nil }

        let firstComponents = Set(relevant.map { name -> String in
            if let slash = name.firstIndex(of: "/") {
                return String(name[..<slash])
            }
            return name
        })

        guard firstComponents.count == 1, let directory = firstComponents.first else {
            return nil
        }
        guard !directory.isEmpty,
              directory != ".",
              directory != "..",
              !directory.contains("\\") else {
            return nil
        }

        let prefix = directory + "/"
        guard relevant.allSatisfy({ $0.hasPrefix(prefix) }) else { return nil }
        return prefix
    }

    private nonisolated static func sanitizedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            throw LocalPackageError.invalidArchive
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw LocalPackageError.invalidArchive
        }

        for component in components where component.isEmpty || component == "." || component == ".." {
            throw LocalPackageError.invalidArchive
        }

        return components.map(String.init).joined(separator: "/")
    }
}

private struct TarEntry {
    let name: String
    let isDirectory: Bool
    let dataRange: Range<Int>
}
