import CryptoKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import InkPond

private final class TypstUpgradeFixtureBundleToken {}

/// Ordinary cases are current-schema reopen/version-key regressions. The opt-in
/// staged case creates a baseline store now; it is not a historical user backup.
@MainActor
struct TypstUpgradeRegressionTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypstUpgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openStore(at url: URL) throws -> ModelContainer {
        let schema = Schema([InkPondDocument.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    // Keep the writer's container/context/model out of the reader's lifetime.
    private func saveDocument(at url: URL, source: String) throws {
        let container = try openStore(at: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let document = InkPondDocument(title: "Saved project", content: source)
        document.projectID = "saved-project"
        document.stableProjectIDRawValue = "87460750-0000-4000-8000-000000000060"
        document.entryFileName = "main.typ"
        document.fontFileNames = ["texgyretermes-regular.otf"]
        document.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        document.modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        document.lastEditedFileName = "chapter.typ"
        document.lastCursorLocation = 17
        document.imageInsertMode = "figure"
        document.imageDirectoryName = "assets"
        context.insert(document)
        try context.save()
    }

    @Test func currentSchemaDiskStoreReopensAndCompilesSavedFilesWithVendoredPackageAndFont() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixtureZip = try #require(Bundle(for: TypstUpgradeFixtureBundleToken.self)
            .url(forResource: "ieee-example", withExtension: "zip"))
        _ = try ZipImporter.extract(from: fixtureZip, to: project)
        // A project-vendored local package avoids global LocalPackages/iCloud state
        // and network access. This tests a relative import, not @local resolution.
        let package = project.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "#let badge(body) = block(stroke: 0.5pt, inset: 4pt, body)".write(
            to: package.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        try "[package]\nname = \"upgrade-fixture\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n".write(
            to: package.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        try "Saved chapter marker".write(to: project.appendingPathComponent("chapter.typ"), atomically: true, encoding: .utf8)
        let source = """
        #import "vendor/lib.typ": badge
        #set page(width: 300pt, height: 180pt, margin: 16pt)
        #set text(font: "TeX Gyre Termes", size: 10pt)
        #badge[Saved package marker]
        #include "chapter.typ"
        #pagebreak()
        Saved second page marker
        """
        try source.write(to: project.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let storeURL = root.appendingPathComponent("documents.store")
        try saveDocument(at: storeURL, source: source)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        let reopened = try openStore(at: storeURL)
        let context = ModelContext(reopened)
        let documents = try context.fetch(FetchDescriptor<InkPondDocument>())
        #expect(documents.count == 1)
        let document = try #require(documents.first)
        #expect(document.title == "Saved project")
        #expect(document.projectID == "saved-project")
        #expect(document.stableProjectIDRawValue == "87460750-0000-4000-8000-000000000060")
        #expect(document.content == source)
        #expect(document.entryFileName == "main.typ")
        #expect(document.fontFileNames == ["texgyretermes-regular.otf"])
        #expect(document.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(document.modifiedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(document.lastEditedFileName == "chapter.typ")
        #expect(document.lastCursorLocation == 17)
        #expect(document.imageInsertMode == "figure")
        #expect(document.imageDirectoryName == "assets")
        let diskSource = try String(contentsOf: project.appendingPathComponent(document.entryFileName), encoding: .utf8)
        #expect(diskSource == document.content)
        let fontPaths = document.fontFileNames.map { project.appendingPathComponent("fonts/\($0)").path }
        let projectPath = project.path
        #expect(TypstBridge.runtimeVersion == "0.15.1")
        let artifact = try await Task.detached(priority: .utility) {
            try TypstBridge.compilePreview(source: diskSource, fontPaths: fontPaths, rootDir: projectPath).get()
        }.value
        let pdf = try #require(artifact.pdfData)
        let parsed = try #require(PDFDocument(data: pdf))
        #expect(parsed.pageCount == 2)
        #expect(parsed.page(at: 0)?.string?.contains("Saved package marker") == true)
        #expect(parsed.page(at: 0)?.string?.contains("Saved chapter marker") == true)
        #expect(parsed.page(at: 1)?.string?.contains("Saved second page marker") == true)
        #expect(String(decoding: pdf, as: UTF8.self).contains("TeXGyreTermes-Regular"))
        #expect(artifact.svgPages.count == 2)
        for page in artifact.svgPages {
            let svg = try page.loadSVG()
            #expect(svg.contains("<svg"))
            #expect(svg.contains("</svg>"))
            #expect(page.widthPoints == 300)
            #expect(page.heightPoints == 180)
        }
        let cache = CompiledPreviewCacheStore(rootURL: root.appendingPathComponent("cache"))
        let input = CompiledPreviewCacheInput(
            descriptor: .init(projectID: document.projectID, documentTitle: document.title, entryFileName: document.entryFileName),
            source: diskSource, fontPaths: fontPaths, rootDir: projectPath,
            localPackagesDir: nil, typstVersion: TypstBridge.runtimeVersion)
        try cache.save(artifact: artifact, for: input)
        let cachedArtifact = try cache.loadArtifactIfValid(for: input)
        let loaded = try #require(cachedArtifact)
        #expect(loaded.pdfData == pdf)
        #expect(loaded.svgPages.count == 2)
        for (saved, original) in zip(loaded.svgPages, artifact.svgPages) {
            #expect(try saved.loadSVG() == original.loadSVG())
        }
    }


    /// Invoke separately in two test processes on the SAME simulator and absolute
    /// fixture root. No phase means ordinary CI leaves persistent fixtures alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPST_UPGRADE_PHASE"] != nil))
    func stagedActualEngineStoreAndCacheUpgrade() async throws {
        let environment = ProcessInfo.processInfo.environment
        let phase = try #require(environment["TYPST_UPGRADE_PHASE"])
        try #require(!phase.isEmpty)
        let rootPath = try #require(environment["TYPST_UPGRADE_ROOT"])
        try #require(rootPath.hasPrefix("/") && rootPath != "/")
        try #require(phase == "baseline" || phase == "upgrade")
        let version = phase == "baseline" ? "0.15.0" : "0.15.1"
        try #require(TypstBridge.runtimeVersion == version)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let storeURL = root.appendingPathComponent("documents.store")
        let metadataURL = root.appendingPathComponent("baseline-metadata.json")
        let source = """
        #import "vendor/lib.typ": badge
        #set page(width: 300pt, height: 180pt, margin: 16pt)
        #set text(font: "TeX Gyre Termes", size: 10pt)
        #badge[Saved package marker]
        #include "chapter.typ"
        $ integral_0^1 x^2 dif x = 1/3 $
        #pagebreak()
        Saved second page marker
        中文升级测试
        """
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func resourceHashes() throws -> [String: String] {
            let names = ["main.typ", "chapter.typ", "vendor/lib.typ", "vendor/typst.toml",
                         "fonts/texgyretermes-regular.otf"]
            return try Dictionary(uniqueKeysWithValues: names.map {
                ($0, digest(try Data(contentsOf: project.appendingPathComponent($0))))
            })
        }
        if phase == "baseline" {
            // Refuse to overwrite any previous acceptance evidence.
            try #require(!FileManager.default.fileExists(atPath: root.path))
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let fixtureZip = try #require(Bundle(for: TypstUpgradeFixtureBundleToken.self)
                .url(forResource: "ieee-example", withExtension: "zip"))
            _ = try ZipImporter.extract(from: fixtureZip, to: project)
            let vendor = project.appendingPathComponent("vendor", isDirectory: true)
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            try "#let badge(body) = block(stroke: 0.5pt, inset: 4pt, body)".write(
                to: vendor.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
            try "[package]\nname = \"upgrade-fixture\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n".write(
                to: vendor.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
            try "Saved chapter marker".write(to: project.appendingPathComponent("chapter.typ"), atomically: true, encoding: .utf8)
            try source.write(to: project.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
            try saveDocument(at: storeURL, source: source)
        } else {
            try #require(FileManager.default.fileExists(atPath: metadataURL.path))
            try #require(FileManager.default.fileExists(atPath: storeURL.path))
        }
        let container = try openStore(at: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let documents = try context.fetch(FetchDescriptor<InkPondDocument>())
        try #require(documents.count == 1)
        let document = try #require(documents.first)
        #expect(document.title == "Saved project")
        #expect(document.projectID == "saved-project")
        #expect(document.stableProjectIDRawValue == "87460750-0000-4000-8000-000000000060")
        #expect(document.content == source)
        #expect(document.entryFileName == "main.typ")
        #expect(document.fontFileNames == ["texgyretermes-regular.otf"])
        #expect(document.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(document.modifiedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(document.lastEditedFileName == "chapter.typ")
        #expect(document.lastCursorLocation == 17)
        #expect(document.imageInsertMode == "figure")
        #expect(document.imageDirectoryName == "assets")
        let diskSource = try String(contentsOf: project.appendingPathComponent("main.typ"), encoding: .utf8)
        try #require(diskSource == document.content)
        let fonts = [project.appendingPathComponent("fonts/texgyretermes-regular.otf").path]
        let cache = CompiledPreviewCacheStore(rootURL: root.appendingPathComponent("baseline-cache"))
        func input(_ runtime: String) -> CompiledPreviewCacheInput {
            .init(descriptor: .init(projectID: document.projectID, documentTitle: document.title, entryFileName: document.entryFileName),
                  source: diskSource, fontPaths: fonts, rootDir: project.path, localPackagesDir: nil, typstVersion: runtime)
        }
        var baselineMetadata: [String: Any] = [:]
        if phase == "upgrade" {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
            baselineMetadata = try #require(json as? [String: Any])
            try #require(baselineMetadata["runtime"] as? String == "0.15.0")
            #expect(try baselineMetadata["resources"] as? [String: String] == resourceHashes())
            #expect(try baselineMetadata["fingerprint"] as? String == cache.inputFingerprint(for: input("0.15.0")))
            let priorResult = try cache.loadArtifactIfValid(for: input("0.15.0"))
            let prior = try #require(priorResult)
            let priorPDF = try #require(prior.pdfData)
            #expect(baselineMetadata["pdfSHA256"] as? String == digest(priorPDF))
            #expect(try cache.loadArtifactIfValid(for: input(version)) == nil)
            #expect(try cache.loadIfValid(for: input(version)) == nil)
        }
        let projectPath = project.path
        // Typst's own sys.version assertion verifies more than the wrapper label.
        let versionProbe = "#assert(repr(sys.version) == \"version(0, 15, \(phase == "baseline" ? "0" : "1"))\")\n#set page(width: 24pt, height: 24pt, margin: 0pt)\n#rect(width: 1pt, height: 1pt)"
        let artifact = try await Task.detached(priority: .utility) {
            _ = try TypstBridge.compile(source: versionProbe, fontPaths: []).get()
            return try TypstBridge.compilePreview(source: diskSource, fontPaths: fonts, rootDir: projectPath).get()
        }.value
        let pdf = try #require(artifact.pdfData)
        let parsed = try #require(PDFDocument(data: pdf))
        #expect(parsed.pageCount == 2)
        #expect(parsed.page(at: 0)?.string?.contains("Saved package marker") == true)
        #expect(parsed.page(at: 0)?.string?.contains("Saved chapter marker") == true)
        #expect(parsed.page(at: 1)?.string?.contains("Saved second page marker") == true)
        // CJK source exercises the engine but no CJK font fixture is supplied;
        // do not claim glyph fidelity from a successful compile alone.
        #expect(String(decoding: pdf, as: UTF8.self).contains("TeXGyreTermes-Regular"))
        #expect(artifact.svgPages.count == 2)
        for page in artifact.svgPages {
            #expect(try page.loadSVG().contains("<svg"))
            #expect(page.widthPoints == 300 && page.heightPoints == 180)
        }
        if phase == "baseline" {
            try cache.save(artifact: artifact, for: input(version))
            let metadata: [String: Any] = [
                "provenance": "Created now by baseline app and actual 0.15.0 engine; not historical user backup",
                "runtime": version, "resources": try resourceHashes(),
                "fingerprint": try cache.inputFingerprint(for: input(version)),
                "pdfSHA256": digest(pdf), "pageCount": parsed.pageCount,
                "pageText": (0..<parsed.pageCount).map { parsed.page(at: $0)?.string ?? "" }
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
                .write(to: metadataURL, options: .atomic)
        } else {
            #expect(baselineMetadata["pageCount"] as? Int == parsed.pageCount)
            #expect(baselineMetadata["pageText"] as? [String] == (0..<parsed.pageCount).map { parsed.page(at: $0)?.string ?? "" })
            // Preserve old cache and baseline metadata; write new evidence separately.
            let newCache = CompiledPreviewCacheStore(rootURL: root.appendingPathComponent("upgrade-cache"))
            try newCache.save(artifact: artifact, for: input(version))
            let metadata: [String: Any] = ["runtime": version, "pdfSHA256": digest(pdf),
                "fingerprint": try newCache.inputFingerprint(for: input(version)), "resources": try resourceHashes()]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("upgrade-metadata.json"), options: .atomic)
        }
    }

    @Test func referencedLocalPackageContentChangeInvalidatesCacheDespiteSameSizeAndTimestamp() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("packages", isDirectory: true)
        let package = packages.appendingPathComponent("local/upgrade-fixture/0.1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let module = package.appendingPathComponent("lib.typ")
        try "#let marker = [Old]".write(to: module, atomically: true, encoding: .utf8)
        try "[package]\nname = \"upgrade-fixture\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n".write(
            to: package.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: module.path)
        let cache = CompiledPreviewCacheStore(rootURL: root.appendingPathComponent("cache"))
        let input = CompiledPreviewCacheInput(
            descriptor: .init(projectID: "package-project", documentTitle: "Package", entryFileName: "main.typ"),
            source: "#import \"@local/upgrade-fixture:0.1.0\": marker\n#marker",
            fontPaths: [], rootDir: nil, localPackagesDir: packages.path, typstVersion: "0.15.1")
        let before = try cache.inputFingerprint(for: input)
        try cache.save(pdfData: Data("synthetic cache".utf8), for: input)
        #expect(try cache.loadIfValid(for: input) != nil)
        try "#let marker = [New]".write(to: module, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: module.path)
        #expect(try cache.inputFingerprint(for: input) != before)
        #expect(try cache.loadIfValid(for: input) == nil)
    }

    @Test(arguments: [false, true])
    func simulated0150CacheCannotSatisfy0151Request(svgCache: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompiledPreviewCacheStore(rootURL: root)
        func input(_ version: String?) -> CompiledPreviewCacheInput {
            .init(descriptor: .init(projectID: "unchanged-project", documentTitle: "Saved", entryFileName: "main.typ"),
                  source: "Saved source", fontPaths: [], rootDir: nil, localPackagesDir: nil, typstVersion: version)
        }
        // Deliberately synthetic bytes/manifest, not an old compiler's output.
        let bytes = Data("synthetic prior PDF cache".utf8)
        if svgCache {
            let artifact = TypstPreviewArtifact(svgPages: [TypstPreviewPage(
                svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", widthPoints: 100, heightPoints: 100)],
                pdfData: bytes, sourceMap: nil)
            try cache.save(artifact: artifact, for: input("0.15.0"))
            #expect(try cache.loadArtifactIfValid(for: input("0.15.0")) != nil)
        } else {
            try cache.save(pdfData: bytes, for: input("0.15.0"))
        }
        #expect(try cache.loadIfValid(for: input("0.15.0")) == bytes)
        let oldFingerprint = try cache.inputFingerprint(for: input("0.15.0"))
        #expect(try oldFingerprint != cache.inputFingerprint(for: input("0.15.1")))
        #expect(try oldFingerprint != cache.inputFingerprint(for: input(nil)))
        // Recreate the cache reader to prove these checks use persisted data.
        let reader = CompiledPreviewCacheStore(rootURL: root)
        #expect(try reader.loadIfValid(for: input("0.15.1")) == nil)
        #expect(try reader.loadArtifactIfValid(for: input("0.15.1")) == nil)
        #expect(try reader.snapshot().entries.first?.manifest.typstVersion == "0.15.0")
        try reader.save(pdfData: Data("new cache".utf8), for: input("0.15.1"))
        #expect(try reader.loadIfValid(for: input("0.15.1")) == Data("new cache".utf8))
        #expect(try reader.loadIfValid(for: input("0.15.0")) == nil)
    }
}
