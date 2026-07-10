import Foundation
import Testing
@testable import InkPond

private final class M0FixtureBundleToken {}

private struct M0ProjectFixture: Decodable {
    let id: String
    let modifiedOffset: Int
    let title: String
}

private enum M0FixtureError: Error {
    case missing(String)
}

private func m0Fixture(named name: String, extension fileExtension: String) throws -> String {
    let bundle = Bundle(for: M0FixtureBundleToken.self)
    guard let url = bundle.url(
        forResource: name,
        withExtension: fileExtension
    ) else {
        throw M0FixtureError.missing("\(name).\(fileExtension)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func measuredMilliseconds<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try operation()
    let components = start.duration(to: clock.now).components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return (result, milliseconds)
}

@Suite(.serialized)
@MainActor
struct M0ProductBenchmarkTests {
    @Test func fixedCorpusExercisesProductParsingAndPreviewSeams() throws {
        for size in ["020000", "100000", "500000"] {
            let source = try m0Fixture(named: "source-\(size)-utf16", extension: "typ")
            let (tokens, elapsed) = measuredMilliseconds {
                TypstBridge.syntaxHighlightTokens(source: source)
            }
            #expect(tokens != nil)
            print("M0_PERF,syntax-\(size),\(String(format: "%.3f", elapsed)),ms")
        }

        for count in [100, 500] {
            let source = try m0Fixture(named: "headings-\(count)", extension: "typ")
            let (items, elapsed) = measuredMilliseconds {
                TypstBridge.outlineItems(source: source)
            }
            #expect(items?.count == count)
            print("M0_PERF,outline-\(count),\(String(format: "%.3f", elapsed)),ms")
        }

        let projectsJSON = try m0Fixture(named: "projects-100", extension: "json")
        let (projects, projectElapsed) = try measuredMilliseconds {
            try JSONDecoder().decode([M0ProjectFixture].self, from: Data(projectsJSON.utf8))
        }
        #expect(projects.count == 100)
        #expect(projects.first?.id == "project-001")
        #expect(projects.last?.modifiedOffset == 100)
        #expect(projects.last?.title == "Fixture Project 100")
        print("M0_PERF,projects-100-decode,\(String(format: "%.3f", projectElapsed)),ms")

        let previewSource = try m0Fixture(named: "preview-300-pages", extension: "typ")
        let sessionKey = "m0-preview-\(UUID().uuidString)"
        defer { TypstBridge.clearAllPreviewSessions() }
        let (previewResult, previewElapsed) = measuredMilliseconds {
            TypstBridge.compilePreviewSVG(
                source: previewSource,
                fontPaths: [],
                rootDir: nil,
                sessionKey: sessionKey
            )
        }
        guard case let .success(artifact) = previewResult else {
            Issue.record("300-page Preview fixture failed to compile")
            return
        }
        #expect(artifact.svgPages.count == 300)
        print("M0_PERF,preview-300-pages,\(String(format: "%.3f", previewElapsed)),ms")
    }
}
