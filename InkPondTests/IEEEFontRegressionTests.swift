import Foundation
import PDFKit
import Testing
@testable import InkPond

private final class IEEEFontFixtureBundleToken {}

@Suite(.serialized)
@MainActor
struct IEEEFontRegressionTests {
    @Test func listedMissingOrCorruptProjectFontCannotProduceSuccessfulExport() async throws {
        let document = InkPondDocument(title: "Missing font regression", content: "")
        document.projectID = "font-missing-\(UUID().uuidString)"
        document.entryFileName = "main.typ"
        try ProjectFileManager.createProjectRoot(for: document)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }
        let root = ProjectFileManager.projectDirectory(for: document)
        try "= Font failure".write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        document.fontFileNames = ["missing.otf"]
        if case .success = await ExportManager.compilePDF(for: document) {
            Issue.record("Missing listed font incorrectly exported a substitute PDF")
        }
        ProjectFileManager.ensureFontsDirectory(for: document)
        try Data("not a font".utf8).write(to: ProjectFileManager.fontsDirectory(for: document).appendingPathComponent("missing.otf"))
        if case .success = await ExportManager.compilePDF(for: document) {
            Issue.record("Corrupt listed font incorrectly exported a substitute PDF")
        }
    }

    @Test(arguments: [CompileFontSource.project, .app])
    func originalIEEEPreviewAndExportMatchDesktopFontsAndLayout(fontSource: CompileFontSource) async throws {
        let bundle = Bundle(for: IEEEFontFixtureBundleToken.self)
        let zip = try #require(bundle.url(forResource: "ieee-example", withExtension: "zip"))
        let referenceURL = try #require(bundle.url(forResource: "ieee-desktop-reference", withExtension: "pdf"))
        let reference = try #require(PDFDocument(url: referenceURL))
        print("FONT_VERSIONS: typst=\(TypstBridge.runtimeVersion ?? "unknown") package=charged-ieee:0.1.4")
        let document = InkPondDocument(title: "IEEE font regression", content: "")
        document.projectID = "font-regression-\(UUID().uuidString)"
        document.entryFileName = "main.typ"
        try ProjectFileManager.createProjectRoot(for: document)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }
        let root = ProjectFileManager.projectDirectory(for: document)
        _ = try ZipImporter.extract(from: zip, to: root)
        var appFontURLs: [URL] = []
        defer { for url in appFontURLs { try? FileManager.default.removeItem(at: url) } }
        if fontSource == .project {
            #expect(ProjectFileManager.importFontFiles(from: "fonts", for: document).count == 8)
        } else {
            try FontManager.createAppFontsDirectory()
            for input in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("fonts"), includingPropertiesForKeys: nil) {
                let destination = FontManager.appFontsDirectory().appendingPathComponent(UUID().uuidString + ".otf")
                try FileManager.default.copyItem(at: input, to: destination)
                appFontURLs.append(destination)
            }
            #expect(appFontURLs.count == 8)
            #expect(document.fontFileNames.isEmpty)
        }
        let source = try ProjectFileManager.readTypFile(named: "main.typ", for: document)
        let resolved = try CompileFontResolver().resolveFonts(for: document)
        #expect(CompileFontResolver.effectiveSource(for: source, resolvedFonts: resolved) == source)
        let preview = try TypstBridge.compilePreviewSVG(
            source: source, fontPaths: resolved.fontPaths, rootDir: root.path
        ).get()
        #expect(preview.svgPages.count == 2)
        let data = try await ExportManager.compilePDF(for: document).get()
        let exported = try #require(PDFDocument(data: data))
        #expect(exported.pageCount == reference.pageCount)
        #expect(exported.pageCount == 2)
        for pageIndex in 0..<min(exported.pageCount, reference.pageCount) {
            let actualPage = try #require(exported.page(at: pageIndex))
            let referencePage = try #require(reference.page(at: pageIndex))
            #expect(actualPage.bounds(for: .mediaBox) == referencePage.bounds(for: .mediaBox))
            #expect(actualPage.string == referencePage.string)
        }
        // Inspect actual embedded PDF font names, not the resolver's path list.
        let pdfBytes = String(decoding: data, as: UTF8.self)
        for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
            #expect(pdfBytes.contains("TeXGyreTermes-\(face)"))
        }
        #expect(!pdfBytes.contains("LibertinusSerif"))
        print("IEEE_EXPORT_PDF_BASE64:\(data.base64EncodedString())")
        print("IEEE_VERIFIED: source=\(fontSource) preview=\(preview.svgPages.count) export=\(exported.pageCount) reference=\(reference.pageCount)")
    }

    @Test(arguments: [CompileFontSource.project, .app])
    func samePathReplacementChangesRealPreviewAndExport(fontSource: CompileFontSource) async throws {
        let zip = try #require(Bundle(for: IEEEFontFixtureBundleToken.self).url(forResource: "ieee-example", withExtension: "zip"))
        let document = InkPondDocument(title: "Font replacement", content: "")
        document.projectID = "font-replace-\(UUID().uuidString)"
        document.entryFileName = "main.typ"
        try ProjectFileManager.createProjectRoot(for: document)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }
        let root = ProjectFileManager.projectDirectory(for: document)
        _ = try ZipImporter.extract(from: zip, to: root)
        let source = "#set text(font: \"TeX Gyre Termes\")\nFont replacement ABC xyz 012345"
        try source.write(to: root.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)
        let regular = try Data(contentsOf: root.appendingPathComponent("fonts/texgyretermes-regular.otf"))
        let bold = try Data(contentsOf: root.appendingPathComponent("fonts/texgyretermes-bold.otf"))
        let target: URL
        if fontSource == .project {
            ProjectFileManager.ensureFontsDirectory(for: document)
            target = ProjectFileManager.fontsDirectory(for: document).appendingPathComponent("replace.otf")
            document.fontFileNames = ["replace.otf"]
        } else {
            try FontManager.createAppFontsDirectory()
            target = FontManager.appFontsDirectory().appendingPathComponent(UUID().uuidString + ".otf")
        }
        defer { try? FileManager.default.removeItem(at: target) }
        let compiler = TypstCompiler()
        let descriptor = CompiledPreviewCacheDescriptor(projectID: document.projectID, documentTitle: document.title, entryFileName: "main.typ")
        var previews: [[TypstPreviewPage]] = []
        for (bytes, face) in [(regular, "Regular"), (bold, "Bold")] {
            try bytes.write(to: target, options: .atomic)
            let resolved = try CompileFontResolver().resolveFonts(for: document)
            compiler.compileNow(source: source, fontPaths: resolved.fontPaths, rootDir: root.path,
                                previewCachePolicy: .bypassCache, previewCacheDescriptor: descriptor)
            for _ in 0..<2_000 {
                if !compiler.isCompiling && !compiler.isCompileQueued { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!compiler.isCompiling && !compiler.isCompileQueued)
            #expect(compiler.errorMessage == nil)
            let artifact = try #require(compiler.previewArtifact)
            #expect(artifact.svgPages.count == 1)
            previews.append(artifact.svgPages)
            let pdf = try await ExportManager.compilePDF(for: document).get()
            let pdfText = String(decoding: pdf, as: UTF8.self)
            #expect(pdfText.contains("TeXGyreTermes-\(face)"))
            if face == "Bold" { #expect(!pdfText.contains("TeXGyreTermes-Regular")) }
            print("FONT_REPLACEMENT_PDF_BASE64: source=\(fontSource) face=\(face) data=\(pdf.base64EncodedString())")
        }
        #expect(previews.count == 2)
        #expect(previews[0] != previews[1])
        try FileManager.default.removeItem(at: target)
        if case .success = await ExportManager.compilePDF(for: document) {
            Issue.record("Deleted font reused the successful prior export")
        }
        compiler.compileNow(source: source, fontPaths: [target.path], rootDir: root.path)
        for _ in 0..<2_000 {
            if !compiler.isCompiling && !compiler.isCompileQueued { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(compiler.errorMessage != nil)
        print("FONT_REPLACEMENT_VERIFIED: source=\(fontSource) realPreviewChanged=true exportRegularThenBold=true deletionAfterSuccessFails=true")
    }

}
