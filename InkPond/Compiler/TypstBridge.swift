//
//  TypstBridge.swift
//  InkPond
//

import Foundation
import os.log

enum TypstBridgeError: Error, LocalizedError, Sendable {
    case compilerNotLinked
    case compilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .compilerNotLinked:
            return L10n.tr("error.typst.compiler_not_linked")
        case .compilationFailed(let msg):
            return msg
        }
    }
}

struct TypstBridge {
    nonisolated static var packageCacheDirectoryURL: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("typst-packages", isDirectory: true)
    }

    private nonisolated static var localDocumentsURL: URL? {
        ExposedAuxiliaryDirectory.localDocumentsURL
    }

    nonisolated static var localPackagesRootURL: URL? {
        localDocumentsURL
    }

    private nonisolated static var legacyLocalPackagesRootURL: URL? {
        ExposedAuxiliaryDirectory.applicationSupportURL
    }

    private nonisolated static var defaultLocalPackagesRootURL: URL? {
        guard StorageSyncPreferences.syncPackages,
              let ubiquityDocumentsURL = FileManager.default
                .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
                .appendingPathComponent("Documents", isDirectory: true) else {
            return localPackagesRootURL
        }
        return ubiquityDocumentsURL
    }

    nonisolated static func packagesDirectory(rootURL: URL) -> URL {
        rootURL.appendingPathComponent("LocalPackages", isDirectory: true)
    }

    nonisolated static var localPackagesDirectoryURL: URL? {
        guard let rootURL = defaultLocalPackagesRootURL else { return nil }
        if rootURL.standardizedFileURL == localPackagesRootURL?.standardizedFileURL {
            ExposedAuxiliaryDirectory.migrateLegacyDirectoryIfNeeded(
                named: "LocalPackages",
                from: legacyLocalPackagesRootURL,
                to: localPackagesRootURL
            )
        }
        return packagesDirectory(rootURL: rootURL)
    }

    nonisolated static var runtimeVersion: String? {
#if TYPST_FFI_AVAILABLE
        guard let cVersion = typst_version() else { return nil }
        return String(cString: cVersion)
#else
        return nil
#endif
    }

    /// Compile Typst source to PDF data.
    ///
    /// - Parameters:
    ///   - source: Typst markup source string.
    ///   - fontPaths: File paths to font files (bundled + user-imported).
    ///
    /// `nonisolated` so it can be called from `Task.detached` without
    /// crossing the MainActor boundary (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).
    nonisolated static func compile(source: String, fontPaths: [String], rootDir: String? = nil) -> Result<Data, TypstBridgeError> {
#if TYPST_FFI_AVAILABLE
        let effectiveFontPaths = CoreTextFontMaterializer.materializePlannedFonts(in: fontPaths)
        os_log(.debug, "TypstBridge: passing %d font paths to Rust", effectiveFontPaths.count)
        for (i, p) in effectiveFontPaths.prefix(5).enumerated() {
            os_log(.debug, "TypstBridge: font[%d] = %{public}@", i, p as NSString)
        }

        // App caches directory for @preview package downloads.
        let cacheDir = packageCacheDirectoryURL?.path
        if let localPackagesDirectoryURL {
            let store = LocalPackageStore(rootURL: localPackagesDirectoryURL)
            try? store.ensureRootDirectory()
            _ = try? store.snapshot()
        }
        let localPkgDir = localPackagesDirectoryURL?.path

        // Hold C strings alive for the duration of the FFI call.
        return source.withCString { cSource in
            let mutablePtrs: [UnsafeMutablePointer<CChar>?] = effectiveFontPaths.map { strdup($0) }
            defer { mutablePtrs.forEach { free($0) } }

            return mutablePtrs.withUnsafeBufferPointer { buf in
                let constBuf = UnsafeRawBufferPointer(buf)
                    .bindMemory(to: UnsafePointer<CChar>?.self)

                return (cacheDir ?? "").withCString { cCacheDir in
                  return (rootDir ?? "").withCString { cRootDir in
                    return (localPkgDir ?? "").withCString { cLocalPkgDir in
                      var opts = TypstOptions(
                          font_paths: constBuf.baseAddress,
                          font_path_count: buf.count,
                          cache_dir: cCacheDir,
                          root_dir: rootDir != nil ? cRootDir : nil,
                          local_packages_dir: localPkgDir != nil ? cLocalPkgDir : nil
                      )
                      let result = typst_compile(cSource, &opts)
                      defer { typst_free_result(result) }

                      if result.success, let ptr = result.pdf_data {
                          return .success(Data(bytes: ptr, count: Int(result.pdf_len)))
                      } else if let errPtr = result.error_message {
                          return .failure(.compilationFailed(String(cString: errPtr)))
                      } else {
                          return .failure(.compilationFailed(L10n.tr("error.typst.unknown_compilation")))
                      }
                    }
                  }
                }
            }
        }
#else
        return .failure(.compilerNotLinked)
#endif
    }

    /// Compile Typst source to PDF data and extract a source map for
    /// bidirectional editor ↔ preview sync.
    nonisolated static func compileWithSourceMap(source: String, fontPaths: [String], rootDir: String? = nil) -> Result<(Data, SourceMap), TypstBridgeError> {
#if TYPST_FFI_AVAILABLE
        let effectiveFontPaths = CoreTextFontMaterializer.materializePlannedFonts(in: fontPaths)
        let cacheDir = packageCacheDirectoryURL?.path
        if let localPackagesDirectoryURL {
            let store = LocalPackageStore(rootURL: localPackagesDirectoryURL)
            try? store.ensureRootDirectory()
            _ = try? store.snapshot()
        }
        let localPkgDir = localPackagesDirectoryURL?.path

        return source.withCString { cSource in
            let mutablePtrs: [UnsafeMutablePointer<CChar>?] = effectiveFontPaths.map { strdup($0) }
            defer { mutablePtrs.forEach { free($0) } }

            return mutablePtrs.withUnsafeBufferPointer { buf in
                let constBuf = UnsafeRawBufferPointer(buf)
                    .bindMemory(to: UnsafePointer<CChar>?.self)

                return (cacheDir ?? "").withCString { cCacheDir in
                  return (rootDir ?? "").withCString { cRootDir in
                    return (localPkgDir ?? "").withCString { cLocalPkgDir in
                      var opts = TypstOptions(
                          font_paths: constBuf.baseAddress,
                          font_path_count: buf.count,
                          cache_dir: cCacheDir,
                          root_dir: rootDir != nil ? cRootDir : nil,
                          local_packages_dir: localPkgDir != nil ? cLocalPkgDir : nil
                      )
                      let result = typst_compile_with_source_map(cSource, &opts)
                      defer { typst_free_result_with_map(result) }

                      if result.success, let pdfPtr = result.pdf_data {
                          let pdfData = Data(bytes: pdfPtr, count: Int(result.pdf_len))
                          let sourceMap = Self.parseSourceMap(result)
                          return .success((pdfData, sourceMap))
                      } else if let errPtr = result.error_message {
                          return .failure(.compilationFailed(String(cString: errPtr)))
                      } else {
                          return .failure(.compilationFailed(L10n.tr("error.typst.unknown_compilation")))
                      }
                    }
                  }
                }
            }
        }
#else
        return .failure(.compilerNotLinked)
#endif
    }

#if TYPST_FFI_AVAILABLE
    nonisolated private static func parseSourceMap(_ result: TypstResultWithMap) -> SourceMap {
        guard let ptr = result.source_map, result.source_map_len > 0 else {
            return SourceMap(byOffset: [], byPosition: [])
        }

        let buffer = UnsafeBufferPointer(start: ptr, count: Int(result.source_map_len))
        var entries: [SourceMapLocation] = []
        entries.reserveCapacity(buffer.count)

        for entry in buffer {
            entries.append(SourceMapLocation(
                page: Int(entry.page),
                yPoints: entry.y_pt,
                xPoints: entry.x_pt,
                line: Int(entry.line),
                column: Int(entry.column),
                sourceOffset: Int(entry.source_offset),
                sourceLength: Int(entry.source_length)
            ))
        }

        // byOffset is already sorted by source_offset from Rust.
        let byPosition = entries.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            return a.yPoints < b.yPoints
        }

        return SourceMap(byOffset: entries, byPosition: byPosition)
    }
#endif
}
