import Foundation
import PDFKit
import UIKit
import Testing
@testable import InkPond

/// Native integration coverage: no injected workers and no fabricated PDF/font bytes.
/// Mutable external fonts use the original issue fixture, not font-fix production code.
@Suite(.serialized)
@MainActor
struct OperationSnapshotNativeTests {
    @Test(arguments: ["source", "image", "package"])
    func nativeOutputsRemainFrozenAfterReplacementAndDeletion(changed: String) async throws {
        // A missing native library must fail, not silently turn this into mock coverage.
        _ = try #require(TypstBridge.runtimeVersion, "Native Typst FFI must be linked")
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install()
        var input = fixture.input
        let accepted = try await seal(fixture.capture(input))
        let baseline = try await outputs(accepted)
        expectMarkers(baseline.text, source: "SourceBefore", image: "ImageBefore", package: "PackageBefore")
        #expect(baseline.svg.contains("<image"), "Native preview must actually render the SVG resource")

        // Replace just one dependency so each case independently proves output sensitivity.
        switch changed {
        case "source":
            input.source = Fixture.source.replacingOccurrences(of: "SourceBefore", with: "SourceAfter")
            try fixture.write("project/main.typ", input.source)
        case "image":
            try fixture.write("project/image.svg", Fixture.image(after: true))
        default:
            try fixture.write("local/local/snapshot-native/1.0.0/lib.typ", "#let marker = [PackageAfter]")
        }
        let afterReplacement = try await outputs(accepted)
        #expect(afterReplacement.svg == baseline.svg)
        #expect(afterReplacement.text == baseline.text)
        #expect(afterReplacement.renderedPDF == baseline.renderedPDF)

        let next = try await seal(fixture.capture(input))
        #expect(next.rootURL != accepted.rootURL)
        // Delete every live project/package input before either operation runs again.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("project"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("local"))
        let afterDeletion = try await outputs(accepted)
        #expect(afterDeletion.svg == baseline.svg)
        #expect(afterDeletion.text == baseline.text)
        #expect(afterDeletion.renderedPDF == baseline.renderedPDF)
        let updated = try await outputs(next)
        expectMarkers(updated.text,
            source: changed == "source" ? "SourceAfter" : "SourceBefore",
            image: changed == "image" ? "ImageAfter" : "ImageBefore",
            package: changed == "package" ? "PackageAfter" : "PackageBefore")
        #expect(updated.svg != baseline.svg)
        #expect(updated.renderedPDF != baseline.renderedPDF)
        #expect(updated.text != baseline.text)
        print("[snapshot-native] dependency=\(changed) replacement+deletion stable; next capture changed native SVG/PDF; resource native output verified")
    }

    @Test func nativeFontReplacementIsFrozenUntilNextCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install()
        let archive = try #require(Bundle(for: SnapshotFontBundleToken.self).url(forResource: "ieee-example", withExtension: "zip"))
        let extraction = fixture.root.appendingPathComponent("font-fixture")
        _ = try ZipImporter.extract(from: archive, to: extraction)
        let regular = try Data(contentsOf: extraction.appendingPathComponent("fonts/texgyretermes-regular.otf"))
        let bold = try Data(contentsOf: extraction.appendingPathComponent("fonts/texgyretermes-bold.otf"))
        let font = fixture.root.appendingPathComponent("chosen.otf")
        try regular.write(to: font)
        var input = fixture.input
        input.source = "#set page(width: 240pt, height: 240pt)\n#set text(font: \"TeX Gyre Termes\")\nSnapshot font ABC xyz 012345"
        input.fontPaths = [font.path]
        let accepted = try await seal(fixture.capture(input))
        let baseline = try await outputs(accepted)
        let regularPDF = try await ExportManager.compilePDF(snapshot: accepted).get()
        #expect(String(decoding: regularPDF, as: UTF8.self).contains("TeXGyreTermes-Regular"))
        try bold.write(to: font, options: .atomic)
        let next = try await seal(fixture.capture(input))
        try FileManager.default.removeItem(at: font)
        let frozen = try await outputs(accepted)
        let updated = try await outputs(next)
        #expect(frozen.svg == baseline.svg)
        #expect(frozen.renderedPDF == baseline.renderedPDF)
        #expect(updated.svg != baseline.svg)
        #expect(updated.renderedPDF != baseline.renderedPDF)
        let boldPDF = try await ExportManager.compilePDF(snapshot: next).get()
        #expect(String(decoding: boldPDF, as: UTF8.self).contains("TeXGyreTermes-Bold"))
        #expect(!String(decoding: boldPDF, as: UTF8.self).contains("TeXGyreTermes-Regular"))
        print("[snapshot-native] real external font replacement+deletion: accepted Regular fixed; next Bold")
    }

    @Test func moderateCaptureTimingAndLeaseCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install()
        // 256 real files / 2 MiB, spread across directories; timing is observational,
        // not a device-dependent performance threshold.
        let payload = String(repeating: "x", count: 8192)
        for index in 0..<256 {
            try fixture.write("project/assets/group-\(index / 16)/file-\(index).txt", payload)
        }
        for sample in 1...3 {
            var snapshot: OperationSnapshot? = try fixture.capture(fixture.input)
            let path = try #require(snapshot?.rootURL.path)
            let bytes = try #require(snapshot?.capturedBytes)
            let entries = try #require(snapshot?.capturedEntries)
            let seconds = try #require(snapshot?.captureSeconds)
            #expect(bytes >= 256 * 8192)
            #expect(entries >= 256)
            #expect(seconds >= 0)
            snapshot = nil
            let removed = !FileManager.default.fileExists(atPath: path)
            #expect(removed)
            print("[snapshot-native] sample=\(sample) payloadFiles=256 capturedEntries=\(entries) bytes=\(bytes) captureMs=\(seconds * 1000) leaseRemoved=\(removed)")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path)
        #expect(remaining.isEmpty)
        print("[snapshot-native] cleanup remainingStagingEntries=\(remaining.count)")
    }

    @Test(arguments: [false, true])
    func nearLimitCaptureAllowsSealedCopiesButBoundsNewPackages(package: Bool) async throws {
        _ = try #require(TypstBridge.runtimeVersion)
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install()
        var input = fixture.input
        input.projectRoot = nil
        input.source = package
            ? "#import \"@local/budget:1.0.0\": value\n#value"
            : "Budget"
        let library = "#let value = [Budget]"
        try fixture.write("local/local/budget/1.0.0/typst.toml",
            "[package]\nname = \"budget\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"")
        try fixture.write("local/local/budget/1.0.0/lib.typ", library)
        let packageManifestBytes = try Data(contentsOf: fixture.root.appendingPathComponent("local/local/budget/1.0.0/typst.toml")).count
        var limits = SnapshotCaptureLimits()
        limits.maximumBytes = input.source.utf8.count
        limits.maximumEntries = 1
        // Exact physical payload: source in capture, source blob, then new package.
        limits.maximumPhysicalBytes = 2 * input.source.utf8.count + (package ? library.utf8.count + packageManifestBytes : 0)
        limits.maximumPhysicalEntries = package ? 4 : 2
        limits.maximumFileBytes = 1024 // Must NOT be clamped to remaining total.
        let accepted = try OperationSnapshot.capture(input, limits: limits)
        _ = try await seal(accepted)
        if package {
            limits.maximumPhysicalBytes -= 1
            let rejected = try OperationSnapshot.capture(input, limits: limits)
            let result = await Task.detached { TypstBridge.prepareSnapshot(rejected) }.value
            if case .success = result { Issue.record("Package exceeded physical capture budget") }
        }
    }

    private func seal(_ capture: OperationSnapshot) async throws -> SealedCompileSnapshot {
        try await Task.detached { try SealedCompileSnapshot.prepare(capture) }.value
    }

    private struct Output {
        let svg: String
        let text: String
        let renderedPDF: Data
    }

    private func outputs(_ snapshot: SealedCompileSnapshot) async throws -> Output {
        // Exercise the actual scheduler's snapshot overload and default FFI worker.
        // A fresh instance prevents a prior successful artifact masking a failure.
        let compiler = TypstCompiler()
        compiler.compile(snapshot: snapshot, mode: .immediate)
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while compiler.isCompiling || compiler.isCompileQueued {
            guard ContinuousClock.now < deadline else {
                compiler.cancel()
                Issue.record("Native snapshot preview did not finish within 40 seconds")
                throw NativeTestError.previewTimeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(compiler.errorMessage == nil)
        let artifact = try #require(compiler.previewArtifact)
        #expect(artifact.pdfData == nil, "Production preview uses SVG-only FFI")
        #expect(artifact.svgPages.count == 1)
        let svg = try artifact.svgPages.map { try $0.loadSVG() }.joined(separator: "\n")
        #expect(svg.contains("<svg"))
        #expect(svg.contains("<path") || svg.contains("<use"), "Expected native glyph geometry")

        let result = await ExportManager.compilePDF(snapshot: snapshot)
        let data = try result.get()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        let text = try #require(pdf.string)
        // PDF metadata/IDs can change between runs. Compare rendered pixels instead
        // of whole PDF bytes, alongside PDFKit-extracted semantic markers.
        let rendered = try #require(page.thumbnail(of: CGSize(width: 480, height: 480), for: .mediaBox).pngData())
        return Output(svg: svg, text: text, renderedPDF: rendered)
    }

    private func expectMarkers(_ text: String, source: String, image: String, package: String) {
        for marker in [source, image, package] { #expect(text.contains(marker)) }
        for pair in [("SourceBefore", "SourceAfter"), ("ImageBefore", "ImageAfter"), ("PackageBefore", "PackageAfter")] {
            let absent = [source, image, package].contains(pair.0) ? pair.1 : pair.0
            #expect(!text.contains(absent))
        }
    }

    private enum NativeTestError: Error { case previewTimeout }

    private struct Fixture {
        let root: URL
        let staging: URL
        static let source = """
        #set page(width: 240pt, height: 240pt, margin: 16pt)
        #set text(size: 12pt)
        #let dependency = json("dependency.json")
        #import dependency.package: marker
        SourceBefore
        #parbreak()
        #marker
        #parbreak()
        #if read("image.svg").contains("ImageBefore") [ImageBefore] else [ImageAfter]
        #parbreak()
        #image("image.svg", width: 80pt)
        """
        static func image(after: Bool) -> String {
            // The title is a textual resource marker; the rectangle also changes
            // actual rendered geometry/color (not merely metadata).
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40" viewBox="0 0 80 40"><title>\(after ? "ImageAfter" : "ImageBefore")</title><rect width="\(after ? 30 : 80)" height="40" fill="\(after ? "#0000ff" : "#ff0000")"/></svg>
            """
        }
        var input: OperationSnapshotInput {
            OperationSnapshotInput(projectID: "native-snapshot", title: "Native snapshot", entryFileName: "main.typ",
                source: Self.source, projectRoot: root.appendingPathComponent("project"), fontPaths: [],
                localPackagesRoot: root.appendingPathComponent("local"), packageCacheRoot: root.appendingPathComponent("cache"))
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("snapshot-native-\(UUID().uuidString)")
            staging = root.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        func install() throws {
            try write("project/main.typ", Self.source)
            try write("project/image.svg", Self.image(after: false))
            try write("project/dependency.json", #"{"package":"@local/snapshot-native:1.0.0"}"#)
            try write("local/local/snapshot-native/1.0.0/typst.toml", """
                [package]
                name = "snapshot-native"
                version = "1.0.0"
                entrypoint = "lib.typ"
                """)
            try write("local/local/snapshot-native/1.0.0/lib.typ", "#import \"@custom/snapshot-transitive:1.0.0\": value\n#let marker = value")
            try write("local/custom/snapshot-transitive/1.0.0/typst.toml", "[package]\nname = \"snapshot-transitive\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"")
            try write("local/custom/snapshot-transitive/1.0.0/lib.typ", "#let value = [PackageBefore]")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        }
        func capture(_ input: OperationSnapshotInput) throws -> OperationSnapshot {
            try OperationSnapshot.capture(input, stagingParent: staging)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class SnapshotFontBundleToken: NSObject {}
