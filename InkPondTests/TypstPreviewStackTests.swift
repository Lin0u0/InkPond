import Foundation
import Testing
@testable import InkPond

struct TypstPreviewStackTests {
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
