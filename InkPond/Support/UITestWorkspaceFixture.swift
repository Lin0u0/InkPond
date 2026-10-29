import Foundation

/// Data-only fixture for the existing UI-test launch seam; no alternate UI.
enum UITestWorkspaceFixture {
    static let fileNames = (1...8).map {
        String(format: "workspace-verification-long-similar-chapter-%02d.typ", $0)
    }

    static func content(fileIndex: Int) -> String {
        var lines = [
            "#set page(paper: \"a4\", margin: 24mm)",
            "#set text(size: 12pt)",
            "// fixture-file-\(fileIndex)",
            "= Workspace verification chapter \(fileIndex)",
            ""
        ]
        for page in 1...3 {
            if page > 1 { lines.append("#pagebreak()") }
            lines.append("== Deterministic page \(page)")
            for paragraph in 1...6 {
                lines.append("Page \(page), paragraph \(paragraph): Reliable saved source for keyboard and tab verification.")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
