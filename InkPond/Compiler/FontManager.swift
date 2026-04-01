//
//  FontManager.swift
//  InkPond
//

import Foundation
import CoreGraphics
import CoreText
import UIKit
import os.log

enum FontManager {
    private struct FontNameRecord {
        let platformID: UInt16
        let encodingID: UInt16
        let nameID: UInt16
        let value: String
    }

    /// Cache parsed font name records to avoid re-reading OTF binaries on every call.
    private static var fontNameRecordCache: [String: [FontNameRecord]] = [:]

    private static let cachedBundledCJKFontPaths: [String] = [
        Bundle.main.path(forResource: "SourceHanSansSC-Regular", ofType: "otf"),
        Bundle.main.path(forResource: "SourceHanSerifSC-Regular", ofType: "otf"),
        Bundle.main.path(forResource: "SourceHanSansSC-Bold", ofType: "otf"),
        Bundle.main.path(forResource: "SourceHanSerifSC-Bold", ofType: "otf"),
    ].compactMap { $0 }
    private static var registeredPreviewFontPaths: Set<String> = []

    // MARK: - Bundled fonts

    /// Paths to bundled CJK fonts (思源黑体 + 思源宋体) used as fallbacks.
    static var bundledCJKFontPaths: [String] {
        cachedBundledCJKFontPaths
    }

    /// Returns the Typst-usable font family name (OTF name record #1) for a bundled font path.
    static func typstFamilyName(forBundledPath path: String) -> String? {
        fontNameRecords(forFontAtPath: path)
            .first(where: { $0.platformID == 3 && $0.encodingID == 1 && $0.nameID == 1 })?
            .value
    }

    static func typstFaceName(forFontAtPath path: String) -> String? {
        fontNameRecords(forFontAtPath: path)
            .first(where: { $0.platformID == 3 && $0.encodingID == 1 && $0.nameID == 2 })?
            .value
    }

    static func previewUIFont(forFontAtPath path: String, size: CGFloat) -> UIFont? {
        registerPreviewFontIfNeeded(at: path)

        if let postScriptName = postScriptName(forFontAtPath: path),
           let font = UIFont(name: postScriptName, size: size) {
            return font
        }

        if let familyName = typstFamilyName(forBundledPath: path),
           let fontName = UIFont.fontNames(forFamilyName: familyName).first,
           let font = UIFont(name: fontName, size: size) {
            return font
        }

        return nil
    }

    private static func fontNameRecords(forFontAtPath path: String) -> [FontNameRecord] {
        if let cached = fontNameRecordCache[path] { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > 12 else { return [] }
        // Read sfnt offset table to find the 'name' table.
        let numTables = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self).bigEndian }
        var nameTableOffset: Int?
        for i in 0..<Int(numTables) {
            let base = 12 + i * 16
            guard base + 16 <= data.count else { break }
            let tag = data[base..<base+4]
            if tag == Data([0x6E, 0x61, 0x6D, 0x65]) { // 'name'
                nameTableOffset = Int(data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self).bigEndian
                })
                break
            }
        }
        guard let nOff = nameTableOffset, nOff + 6 <= data.count else { return [] }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: nOff + 2, as: UInt16.self).bigEndian })
        let strOff = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: nOff + 4, as: UInt16.self).bigEndian })
        var records: [FontNameRecord] = []
        for i in 0..<count {
            let rec = nOff + 6 + i * 12
            guard rec + 12 <= data.count else { break }
            let pid  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: rec,     as: UInt16.self).bigEndian }
            let enc  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: rec + 2, as: UInt16.self).bigEndian }
            let nid  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: rec + 6, as: UInt16.self).bigEndian }
            let slen = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: rec + 8, as: UInt16.self).bigEndian })
            let soff = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: rec + 10, as: UInt16.self).bigEndian })
            let strStart = nOff + strOff + soff
            guard strStart + slen <= data.count else { continue }
            let strData = data[strStart..<strStart+slen]
            guard let value = String(bytes: strData, encoding: .utf16BigEndian) else { continue }
            records.append(FontNameRecord(platformID: pid, encodingID: enc, nameID: nid, value: value))
        }
        fontNameRecordCache[path] = records
        return records
    }

    private static func registerPreviewFontIfNeeded(at path: String) {
        guard !registeredPreviewFontPaths.contains(path) else { return }

        var error: Unmanaged<CFError>?
        let url = URL(fileURLWithPath: path) as CFURL
        let registered = CTFontManagerRegisterFontsForURL(url, .process, &error)
        if registered || isAlreadyRegistered(error?.takeRetainedValue()) {
            registeredPreviewFontPaths.insert(path)
        }
    }

    private static func isAlreadyRegistered(_ error: CFError?) -> Bool {
        guard let error else { return false }
        let code = CFErrorGetCode(error)
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }

    /// Remove entries from the registration cache whose files no longer exist on disk.
    static func pruneRegistrationCache() {
        let stale = registeredPreviewFontPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in stale {
            let url = URL(fileURLWithPath: path) as CFURL
            CTFontManagerUnregisterFontsForURL(url, .process, nil)
            registeredPreviewFontPaths.remove(path)
        }
    }

    private static func postScriptName(forFontAtPath path: String) -> String? {
        if let record = fontNameRecords(forFontAtPath: path)
            .first(where: { $0.platformID == 3 && $0.encodingID == 1 && $0.nameID == 6 })?
            .value,
           !record.isEmpty {
            return record
        }

        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let cgFont = CGFont(provider),
              let name = cgFont.postScriptName as String? else {
            return nil
        }
        return name
    }

    // MARK: - App-level fonts

    private nonisolated static var documentsURL: URL {
        guard let documentsURL = ExposedAuxiliaryDirectory.localDocumentsURL else {
            fatalError("DocumentDirectory unavailable — this should never happen in a sandboxed app")
        }
        return documentsURL
    }

    nonisolated static var localAppFontsRootURL: URL {
        documentsURL
    }

    private nonisolated static var legacyLocalAppFontsRootURL: URL? {
        ExposedAuxiliaryDirectory.applicationSupportURL
    }

    private nonisolated static var defaultAppFontsRootURL: URL {
        guard StorageSyncPreferences.syncFonts,
              let ubiquityDocumentsURL = FileManager.default
                .url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)?
                .appendingPathComponent("Documents", isDirectory: true) else {
            return localAppFontsRootURL
        }
        return ubiquityDocumentsURL
    }

    nonisolated static func appFontsDirectory(rootURL: URL? = nil) -> URL {
        let resolvedRootURL = rootURL ?? defaultAppFontsRootURL
        if resolvedRootURL.standardizedFileURL == localAppFontsRootURL.standardizedFileURL {
            ExposedAuxiliaryDirectory.migrateLegacyDirectoryIfNeeded(
                named: "AppFonts",
                from: legacyLocalAppFontsRootURL,
                to: localAppFontsRootURL
            )
        }
        return resolvedRootURL.appendingPathComponent("AppFonts", isDirectory: true)
    }

    static func createAppFontsDirectory(rootURL: URL? = nil) throws {
        let directoryURL = appFontsDirectory(rootURL: rootURL)
        if ProjectFileManager.useCoordination {
            try CloudFileCoordinator.createDirectory(at: directoryURL)
        } else {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    static func ensureAppFontsDirectory(rootURL: URL? = nil) {
        try? createAppFontsDirectory(rootURL: rootURL)
    }

    static func appFontFileNames(rootURL: URL? = nil) -> [String] {
        let directory = appFontsDirectory(rootURL: rootURL)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        return items
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func appImportedFontPaths(rootURL: URL? = nil) -> [String] {
        let directory = appFontsDirectory(rootURL: rootURL)
        return appFontFileNames(rootURL: rootURL).compactMap { fileName in
            let path = directory.appendingPathComponent(fileName).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }

    static func appFontItems(rootURL: URL? = nil) -> [AppFontItem] {
        let builtInItems = bundledCJKFontPaths.map { path in
            AppFontItem(
                displayName: typstFamilyName(forBundledPath: path)
                    ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                fileName: URL(fileURLWithPath: path).lastPathComponent,
                isBuiltIn: true
            )
        }

        let importedItems = appImportedFontPaths(rootURL: rootURL).map { path in
            let fileURL = URL(fileURLWithPath: path)
            return AppFontItem(
                displayName: typstFamilyName(forBundledPath: path)
                    ?? fileURL.deletingPathExtension().lastPathComponent,
                path: path,
                fileName: fileURL.lastPathComponent,
                isBuiltIn: false
            )
        }

        return builtInItems + importedItems
    }

    /// Copy a font file into the App font directory.
    /// Returns the destination file name on success.
    @discardableResult
    static func importAppFont(from sourceURL: URL, rootURL: URL? = nil) throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        ensureAppFontsDirectory(rootURL: rootURL)
        let fileName = sourceURL.lastPathComponent
        let destination = appFontsDirectory(rootURL: rootURL)
            .appendingPathComponent(fileName)

        try ProjectFileManager.copyItemReplacingSafely(from: sourceURL, to: destination)
        os_log(.info, "FontManager: imported %{public}@ into App font library", fileName)
        return fileName
    }

    /// Delete a custom App font file.
    static func deleteAppFont(fileName: String, rootURL: URL? = nil) {
        let url = appFontsDirectory(rootURL: rootURL)
            .appendingPathComponent(fileName)
        do {
            if ProjectFileManager.useCoordination {
                try CloudFileCoordinator.removeItem(at: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            os_log(.info, "FontManager: deleted %{public}@ from App font library", fileName)
        } catch {
            os_log(.error, "FontManager: failed to delete %{public}@: %{public}@", fileName, error.localizedDescription)
        }
    }

    // MARK: - Import / Delete (per-project)

    /// Copy a font file into the project's fonts directory.
    /// Returns the destination file name on success.
    @discardableResult
    static func importFont(from sourceURL: URL, for document: InkPondProject) throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        ProjectFileManager.ensureFontsDirectory(for: document)
        let fileName = sourceURL.lastPathComponent
        let destination = ProjectFileManager.fontsDirectory(for: document)
            .appendingPathComponent(fileName)

        try ProjectFileManager.copyItemReplacingSafely(from: sourceURL, to: destination)
        os_log(.info, "FontManager: imported %{public}@ into project %{public}@", fileName, document.projectID)
        return fileName
    }

    /// Full path for a font file in a document's project, or nil if missing.
    static func fontFilePath(for fileName: String, in document: InkPondProject) -> String? {
        let path = ProjectFileManager.fontsDirectory(for: document)
            .appendingPathComponent(fileName).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Delete a font file from the document's project directory.
    static func deleteFont(fileName: String, from document: InkPondProject) throws {
        let url = ProjectFileManager.fontsDirectory(for: document)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log(.info, "FontManager: font %{public}@ already missing from project %{public}@", fileName, document.projectID)
            return
        }
        do {
            if ProjectFileManager.useCoordination {
                try CloudFileCoordinator.removeItem(at: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            os_log(.info, "FontManager: deleted %{public}@ from project %{public}@", fileName, document.projectID)
        } catch {
            os_log(.error, "FontManager: failed to delete %{public}@ from project %{public}@: %{public}@",
                   fileName, document.projectID, error.localizedDescription)
            throw error
        }
    }

    // MARK: - Resolve paths for compilation

    /// Returns all font file paths in precedence order:
    /// bundled CJK fonts, project fonts, then imported App fonts.
    static func allFontPaths(for document: InkPondProject, appRootURL: URL? = nil) -> [String] {
        var paths: [String] = bundledCJKFontPaths
        for name in document.fontFileNames {
            if let path = fontFilePath(for: name, in: document) {
                paths.append(path)
            }
        }
        paths.append(contentsOf: appImportedFontPaths(rootURL: appRootURL))
        return paths
    }

    static func completionFamilyNames(
        from fontPaths: [String],
        resolveFamilyName: (String) -> String? = { path in
            typstFamilyName(forBundledPath: path)
        }
    ) -> [String] {
        var seen = Set<String>()
        var families: [String] = []

        for path in fontPaths {
            guard let name = resolveFamilyName(path), seen.insert(name).inserted else { continue }
            families.append(name)
        }

        return families
    }

}
