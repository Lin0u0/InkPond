import Foundation
import PDFKit
import Testing
@testable import InkPond

struct TypstPreviewStackTests {
    @Test func runtimeVersionIsTypst0151() {
        #expect(TypstBridge.runtimeVersion == "0.15.1")
    }

    @Test func compiledSysVersionIsTypst0151AndProducesPDF() async throws {
        // Check Typst's own dependency version, not just the FFI version label.
        let source = """
        #set page(width: 240pt, height: 120pt, margin: 12pt)
        #assert(repr(sys.version) == "version(0, 15, 1)")
        #repr(sys.version)
        """
        let result = await Task.detached(priority: .utility) {
            TypstBridge.compile(source: source, fontPaths: [])
        }.value
        let data = try result.get()
        #expect(data.starts(with: Data("%PDF-".utf8)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let text = try #require(document.string)
        #expect(text.contains("version(0, 15, 1)"))
    }

    @Test func basicSVGPreviewProducesOnePageWithoutPDF() async throws {
        // Geometry avoids font, package, and filesystem fixtures.
        let source = """
        #set page(width: 120pt, height: 120pt, margin: 12pt)
        #rect(width: 24pt, height: 24pt, fill: red)
        """
        let result = await Task.detached(priority: .utility) {
            TypstBridge.compilePreviewSVG(source: source, fontPaths: [])
        }.value
        let artifact = try result.get()
        #expect(artifact.pageCount == 1)
        #expect(artifact.svgPages.count == 1)
        let page = try #require(artifact.svgPages.first)
        #expect(page.svg.contains("<svg"))
        #expect(page.svg.contains("</svg>"))
        #expect(artifact.pdfData == nil)
    }

    @Test(arguments: [false, true])
    func invalidSourceReturnsCompilationErrorForPDFAndSVG(previewSVG: Bool) async {
        let result: Result<Void, TypstBridgeError> = await Task.detached(priority: .utility) {
            let source = "#let broken = ("
            if previewSVG {
                return TypstBridge.compilePreviewSVG(source: source, fontPaths: []).map { _ in () }
            }
            return TypstBridge.compile(source: source, fontPaths: []).map { _ in () }
        }.value
        switch result {
        case .success:
            Issue.record("Invalid Typst source unexpectedly compiled")
        case let .failure(.compilationFailed(message)):
            #expect(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .failure(.compilerNotLinked):
            Issue.record("The native Typst compiler must be linked for this regression test")
        }
    }

    @Test func previewFFICompilesNestedLayoutFromConcurrencyWorker() async throws {
        let nestedLayout = (0..<32).reduce("stack-safe") { inner, _ in
            "#block[\(inner)]"
        }
        let source = """
        #set page(width: 240pt, height: 240pt)
        \(nestedLayout)
        """

        let result = await Task.detached(priority: .utility) {
            TypstBridge.compilePreviewSVG(
                source: source,
                fontPaths: [],
                sessionKey: "preview-stack-regression"
            )
        }.value

        switch result {
        case let .success(artifact):
            #expect(artifact.pageCount == 1)
            #expect(artifact.svgPages.first?.svg.contains("<svg") == true)
        case let .failure(error):
            Issue.record("Preview FFI compilation failed: \(error.localizedDescription)")
        }
    }
}
