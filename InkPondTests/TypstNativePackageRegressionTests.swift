import CryptoKit
import UIKit
import Foundation
import PDFKit
import Testing
@testable import InkPond

/// Direct FFI is intentional: TypstBridge fixes package roots to app-global
/// directories. These tests exercise the same native entry point with isolated
/// roots, no preview session and no compiled-artifact cache.
@MainActor
struct TypstNativePackageRegressionTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativePackages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func compile(_ source: String, cache: String, local: String, fontPath: String? = nil) throws -> (Data, [String]) {
        let fontPointer: UnsafeMutablePointer<CChar>? = fontPath.flatMap { strdup($0) }
        defer { if let fontPointer { free(fontPointer) } }
        let pointers: [UnsafePointer<CChar>?] = fontPointer.map { [UnsafePointer($0)] } ?? []
        return try pointers.withUnsafeBufferPointer { fonts in
        try source.withCString { sourcePointer in
            try cache.withCString { cachePointer in
                try local.withCString { localPointer in
                    var options = TypstOptions(font_paths: fonts.baseAddress, font_path_count: fonts.count,
                        cache_dir: cachePointer, root_dir: nil, local_packages_dir: localPointer)
                    let result = typst_compile_preview(sourcePointer, &options, nil)
                    defer { typst_free_preview_result(result) }
                    guard result.success, let pdf = result.pdf_data, let pages = result.svg_pages else {
                        throw TypstBridgeError.compilationFailed(result.error_message.map { String(cString: $0) } ?? "Missing native output")
                    }
                    let svgs = UnsafeBufferPointer(start: pages, count: Int(result.svg_page_len)).compactMap {
                        $0.svg.map { String(cString: $0) }
                    }
                    return (Data(bytes: pdf, count: Int(result.pdf_len)), svgs)
                }
            }
        }
        }
    }

    private func check(_ output: (Data, [String]), marker: String) throws {
        let pdf = try #require(PDFDocument(data: output.0))
        #expect(pdf.pageCount == 1)
        #expect(pdf.page(at: 0)?.string?.contains(marker) == true)
        // Native bundled Latin font really supplied glyphs, not just successful parsing.
        #expect(String(decoding: output.0, as: UTF8.self).contains("NewCM"))
        #expect(output.1.count == 1)
        let svg = try #require(output.1.first)
        #expect(svg.contains("<svg") && svg.contains("</svg>"))
        #expect(svg.contains("<path"))
        #expect(svg.contains("<use"))
    }

    /// Private simulator PingFangUI.ttc previously produced tofu/blank PDF despite
    /// valid CoreText metadata and extracted text. Those are NOT glyph acceptance.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPST_CJK_FONT"] != nil))
    func ordinaryCJKFontCompilesPaintedSVGAndPDF() async throws {
        try #require(TypstBridge.runtimeVersion == "0.15.1")
        let fontPath = try #require(ProcessInfo.processInfo.environment["TYPST_CJK_FONT"])
        try #require(fontPath.hasPrefix("/") && FileManager.default.isReadableFile(atPath: fontPath))
        let fontData = try Data(contentsOf: URL(fileURLWithPath: fontPath))
        let digest = SHA256.hash(data: fontData).map { String(format: "%02x", $0) }.joined()
        try #require(digest == "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b")
        let directory = try root()
        let source = """
        #assert(sys.version == version(0, 15, 1))
        #set page(width: 300pt, height: 180pt, margin: 16pt)
        #set text(font: "Noto Sans CJK SC", size: 18pt)
        中文升级测试
        """
        let cachePath = directory.appendingPathComponent("cache").path
        let localPath = directory.appendingPathComponent("local").path
        let output = try await Task.detached(priority: .utility) {
            try Self.compile(source, cache: cachePath, local: localPath, fontPath: fontPath)
        }.value
        let pdf = try #require(PDFDocument(data: output.0))
        #expect(pdf.pageCount == 1)
        #expect(pdf.page(at: 0)?.string?.contains("中文升级测试") == true)
        #expect(String(decoding: output.0, as: UTF8.self).contains("NotoSansCJKsc"))
        let svg = try #require(output.1.first)
        #expect(output.1.count == 1)
        #expect(svg.contains("<svg") && svg.contains("<path") && svg.contains("<use"))
        // Six characters must have six different complex outlines, not the
        // repeated hollow rectangle which fooled the former CoreText test.
        let pathRegex = try NSRegularExpression(pattern: "<path\\b[^>]*\\bd=\"([^\"]+)\"")
        let range = NSRange(svg.startIndex..<svg.endIndex, in: svg)
        let outlines = pathRegex.matches(in: svg, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: svg) else { return nil }
            return String(svg[range])
        }
        let complexOutlines = Set(outlines.filter { outline in
            outline.filter { $0.isLetter }.count > 12
        })
        try #require(complexOutlines.count >= 6)
        let page = try #require(pdf.page(at: 0))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = page.bounds(for: .mediaBox)
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 255, count: cgImage.width * cgImage.height * 4)
        let painted = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard let raster = CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            raster.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let buffer = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: buffer.count, by: 4).filter {
                Int(buffer[$0]) + Int(buffer[$0 + 1]) + Int(buffer[$0 + 2]) < 600
            }.count
        }
        try #require(painted > 150)
        // Preserve actual output for rasterized visual review. Never synthesize
        // glyph evidence or infer CJK fidelity from compilation success alone.
        let evidence: URL
        if let path = ProcessInfo.processInfo.environment["TYPST_PACKAGE_EVIDENCE_ROOT"] {
            try #require(path.hasPrefix("/") && path != "/")
            evidence = URL(fileURLWithPath: path).appendingPathComponent("cjk-\(UUID().uuidString)")
        } else {
            evidence = directory.appendingPathComponent("cjk-evidence")
        }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try output.0.write(to: evidence.appendingPathComponent("actual-cjk.pdf"))
        try svg.write(to: evidence.appendingPathComponent("actual-cjk.svg"), atomically: true, encoding: .utf8)
        try "Font SHA256: \(digest)\nFont file: \(fontPath)\nNative runtime: \(TypstBridge.runtimeVersion ?? "missing")\n".write(to: evidence.appendingPathComponent("font-provenance.txt"), atomically: true, encoding: .utf8)
        print("TYPST_CJK_EVIDENCE_ROOT=\(evidence.path)")
    }

    @Test func actualLocalPackageResolutionCompilesSVGAndPDF() async throws {
        try #require(TypstBridge.runtimeVersion == "0.15.1")
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("packages")
        let package = local.appendingPathComponent("local/native-regression/0.1.0")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "[package]\nname = \"native-regression\"\nversion = \"0.1.0\"\nentrypoint = \"lib.typ\"\n".write(to: package.appendingPathComponent("typst.toml"), atomically: true, encoding: .utf8)
        try "#let badge(body) = block(stroke: 1pt, inset: 4pt, body)".write(to: package.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        let source = """
        #assert(sys.version == version(0, 15, 1))
        #import "@local/native-regression:0.1.0": badge
        #set page(width: 300pt, height: 180pt, margin: 16pt)
        #set text(font: "New Computer Modern")
        #badge[Actual local package marker]
        """
        let cache = directory.appendingPathComponent("cache").path
        let localPath = local.path
        let output = try await Task.detached(priority: .utility) {
            try Self.compile(source, cache: cache, local: localPath)
        }.value
        try check(output, marker: "Actual local package marker")
        #expect(!FileManager.default.fileExists(atPath: cache))
    }

    /// Explicit opt-in is required. A disabled/skipped filtered run is NOT
    /// acceptance: the harness must check the nonzero passed-test count.
    /// The inner requirement also guards runner-environment propagation.
    /// Warm success is not an assertion that the native network is disabled.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPST_LIVE_PACKAGE_TESTS"] == "1"))
    func livePreviewCetzColdThenWarmCompilesSVGAndPDF() async throws {
        try #require(ProcessInfo.processInfo.environment["TYPST_LIVE_PACKAGE_TESTS"] == "1")
        try #require(TypstBridge.runtimeVersion == "0.15.1")
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        let localPath = directory.appendingPathComponent("empty-local").path
        let package = cache.appendingPathComponent("preview/cetz/0.3.4")
        try #require(!FileManager.default.fileExists(atPath: cache.path))
        let source = """
        #assert(sys.version == version(0, 15, 1))
        #import "@preview/cetz:0.3.4": canvas, draw
        #set page(width: 300pt, height: 180pt, margin: 16pt)
        #set text(font: "New Computer Modern")
        Actual preview package marker
        #canvas({
          import draw: *
          line((0, 0), (2, 1), stroke: red + 2pt)
          circle((1, 1), radius: 0.3, fill: blue)
        })
        """
        let cachePath = cache.path
        let cold = try await Task.detached(priority: .utility) {
            try Self.compile(source, cache: cachePath, local: localPath)
        }.value
        try check(cold, marker: "Actual preview package marker")
        let manifest = try Data(contentsOf: package.appendingPathComponent("typst.toml"))
        #expect(String(decoding: manifest, as: UTF8.self).contains("0.3.4"))
        // A fresh world (nil session), altered source, and real native output:
        // cannot be satisfied by replaying a compiled artifact.
        let warmSource = source.replacingOccurrences(of: "Actual preview package marker", with: "Warm preview package marker")
        let warm = try await Task.detached(priority: .utility) {
            try Self.compile(warmSource, cache: cachePath, local: localPath)
        }.value
        try check(warm, marker: "Warm preview package marker")
        #expect(try Data(contentsOf: package.appendingPathComponent("typst.toml")) == manifest)
        #expect(warm.0 != cold.0)
    }
}
