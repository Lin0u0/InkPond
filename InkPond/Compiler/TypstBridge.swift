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

    /// Parse Typst source and return syntax-highlight tokens in UTF-16 offsets.
    nonisolated static func syntaxHighlightTokens(source: String) -> [TypstSyntaxToken]? {
#if TYPST_FFI_AVAILABLE
        source.withCString { cSource in
            let result = typst_highlight(cSource)
            defer { typst_free_highlight_result(result) }

            guard result.success else { return nil }
            guard let ptr = result.tokens, result.token_len > 0 else { return [] }

            let buffer = UnsafeBufferPointer(start: ptr, count: Int(result.token_len))
            var tokens: [TypstSyntaxToken] = []
            tokens.reserveCapacity(buffer.count)

            for entry in buffer {
                guard let kind = TypstSyntaxToken.Kind(rawValue: entry.tag) else { continue }
                tokens.append(TypstSyntaxToken(
                    location: Int(entry.utf16_location),
                    length: Int(entry.utf16_length),
                    kind: kind
                ))
            }

            return tokens
        }
#else
        return nil
#endif
    }

    /// Parse Typst source and return heading outline entries in UTF-16 offsets.
    nonisolated static func outlineItems(source: String) -> [TypstOutlineEntry]? {
#if TYPST_FFI_AVAILABLE
        source.withCString { cSource in
            let result = typst_outline(cSource)
            defer { typst_free_outline_result(result) }

            guard result.success else { return nil }
            guard let ptr = result.items, result.item_len > 0 else { return [] }

            let buffer = UnsafeBufferPointer(start: ptr, count: Int(result.item_len))
            var items: [TypstOutlineEntry] = []
            items.reserveCapacity(buffer.count)

            for entry in buffer {
                guard let titlePtr = entry.title else { continue }
                let title = String(cString: titlePtr)
                guard !title.isEmpty else { continue }
                items.append(TypstOutlineEntry(
                    location: Int(entry.utf16_location),
                    level: Int(entry.level),
                    title: title
                ))
            }

            return items
        }
#else
        return nil
#endif
    }

    /// Return Typst-library completion symbols plus source-local bindings.
    nonisolated static func completionSymbols(source: String) -> [TypstCompletionSymbolInfo]? {
#if TYPST_FFI_AVAILABLE
        source.withCString { cSource in
            let result = typst_completion_symbols(cSource)
            defer { typst_free_completion_symbol_result(result) }

            guard result.success else { return nil }
            guard let ptr = result.symbols, result.symbol_len > 0 else { return [] }

            let buffer = UnsafeBufferPointer(start: ptr, count: Int(result.symbol_len))
            var symbols: [TypstCompletionSymbolInfo] = []
            symbols.reserveCapacity(buffer.count)

            for symbol in buffer {
                guard let namePtr = symbol.name,
                      let kind = TypstCompletionSymbolInfo.Kind(rawValue: symbol.kind) else { continue }

                let params: [TypstCompletionParamInfo]
                if let paramPtr = symbol.params, symbol.param_len > 0 {
                    let paramBuffer = UnsafeBufferPointer(start: paramPtr, count: Int(symbol.param_len))
                    params = paramBuffer.map { param in
                        let values: [TypstCompletionValueInfo]
                        if let valuePtr = param.values, param.value_len > 0 {
                            let valueBuffer = UnsafeBufferPointer(start: valuePtr, count: Int(param.value_len))
                            values = valueBuffer.compactMap { value in
                                guard let labelPtr = value.label,
                                      let insertPtr = value.insert_text else { return nil }
                                return TypstCompletionValueInfo(
                                    label: String(cString: labelPtr),
                                    insertText: String(cString: insertPtr),
                                    detail: Self.nonEmptyCString(value.detail)
                                )
                            }
                        } else {
                            values = []
                        }

                        return TypstCompletionParamInfo(
                            name: Self.nonEmptyCString(param.name) ?? "",
                            docs: Self.nonEmptyCString(param.docs),
                            input: Self.nonEmptyCString(param.input),
                            defaultValue: Self.nonEmptyCString(param.default_value),
                            values: values,
                            positional: param.positional,
                            named: param.named,
                            variadic: param.variadic,
                            required: param.required,
                            settable: param.settable
                        )
                    }
                } else {
                    params = []
                }

                let location = symbol.utf16_location == UInt32.max ? nil : Int(symbol.utf16_location)
                let scopeEnd = symbol.utf16_scope_end == UInt32.max ? nil : Int(symbol.utf16_scope_end)
                symbols.append(TypstCompletionSymbolInfo(
                    name: String(cString: namePtr),
                    kind: kind,
                    detail: Self.nonEmptyCString(symbol.detail),
                    utf16Location: location,
                    utf16ScopeEnd: scopeEnd,
                    params: params
                ))
            }

            return symbols
        }
#else
        return nil
#endif
    }

    /// Return Typst syntax context at a UTF-16 cursor offset.
    nonisolated static func contextAt(source: String, utf16Offset: Int) -> TypstCursorContext? {
#if TYPST_FFI_AVAILABLE
        let clampedOffset = max(0, min(utf16Offset, source.utf16.count))
        return source.withCString { cSource in
            let result = typst_context_at(cSource, UInt32(clampedOffset))
            defer { typst_free_context_result(result) }

            guard result.success else { return nil }
            let nodes: [TypstContextNodeInfo]
            if let ptr = result.items, result.item_len > 0 {
                let buffer = UnsafeBufferPointer(start: ptr, count: Int(result.item_len))
                nodes = buffer.compactMap { item in
                    guard let kindPtr = item.kind else { return nil }
                    return TypstContextNodeInfo(
                        kind: String(cString: kindPtr),
                        location: Int(item.utf16_location),
                        length: Int(item.utf16_length)
                    )
                }
            } else {
                nodes = []
            }

            return TypstCursorContext(
                nodes: nodes,
                functionName: Self.nonEmptyCString(result.function_name)
            )
        }
#else
        return nil
#endif
    }

#if TYPST_FFI_AVAILABLE
    nonisolated private static func nonEmptyCString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

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
