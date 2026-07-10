import CryptoKit
import Foundation

private let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tools/M0/Fixtures", isDirectory: true)

private func fixedUTF16Text(count: Int) -> String {
    let header = "= InkPond M0 fixed UTF-16 corpus\n"
    let line = "The quick brown fox renders Typst line 000000.\n"
    var output = header
    var index = 0
    while output.utf16.count < count {
        let numbered = line.replacingOccurrences(
            of: "000000",
            with: String(format: "%06d", index)
        )
        output += numbered
        index += 1
    }
    return String(output.utf16.prefix(count))!
}

private func headingCorpus(count: Int) -> String {
    (1...count).map { index in
        "= Heading \(String(format: "%03d", index))\nParagraph for deterministic outline measurement.\n"
    }.joined()
}

private func projectsCorpus(count: Int) -> String {
    let records = (1...count).map { index in
        "  {\"id\":\"project-\(String(format: "%03d", index))\",\"modifiedOffset\":\(index),\"title\":\"Fixture Project \(String(format: "%03d", index))\"}"
    }
    return "[\n" + records.joined(separator: ",\n") + "\n]\n"
}

private func previewCorpus(pageCount: Int) -> String {
    let pages = (1...pageCount).map { index in
        "= Preview Page \(String(format: "%03d", index))\nPage \(index) of the fixed 300-page Preview and Slideshow corpus."
    }
    return "#set page(width: 320pt, height: 480pt)\n" + pages.joined(separator: "\n#pagebreak()\n") + "\n"
}

private let fixtures: [(name: String, contents: String)] = [
    ("source-020000-utf16.typ", fixedUTF16Text(count: 20_000)),
    ("source-100000-utf16.typ", fixedUTF16Text(count: 100_000)),
    ("source-500000-utf16.typ", fixedUTF16Text(count: 500_000)),
    ("headings-100.typ", headingCorpus(count: 100)),
    ("headings-500.typ", headingCorpus(count: 500)),
    ("projects-100.json", projectsCorpus(count: 100)),
    ("preview-300-pages.typ", previewCorpus(pageCount: 300)),
]

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func manifest() -> String {
    let entries = fixtures.map { fixture -> String in
        let data = Data(fixture.contents.utf8)
        return "    {\"bytes\":\(data.count),\"name\":\"\(fixture.name)\",\"sha256\":\"\(sha256(data))\",\"utf16CodeUnits\":\(fixture.contents.utf16.count)}"
    }
    return "{\n  \"generatorVersion\":1,\n  \"fixtures\":[\n"
        + entries.joined(separator: ",\n")
        + "\n  ]\n}\n"
}

private func writeFixtures() throws {
    try FileManager.default.createDirectory(
        at: fixtureDirectory,
        withIntermediateDirectories: true
    )
    for fixture in fixtures {
        try Data(fixture.contents.utf8).write(
            to: fixtureDirectory.appendingPathComponent(fixture.name),
            options: .atomic
        )
    }
    try Data(manifest().utf8).write(
        to: fixtureDirectory.appendingPathComponent("manifest.json"),
        options: .atomic
    )
}

private func checkFixtures() throws {
    for fixture in fixtures {
        let expected = Data(fixture.contents.utf8)
        let actual = try Data(contentsOf: fixtureDirectory.appendingPathComponent(fixture.name))
        guard expected == actual else {
            throw ValidationError.mismatch(fixture.name)
        }
    }
    let actualManifest = try String(
        contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"),
        encoding: .utf8
    )
    guard actualManifest == manifest() else {
        throw ValidationError.mismatch("manifest.json")
    }
}

private enum ValidationError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case let .mismatch(name):
            return "Fixture does not match deterministic generator: \(name)"
        }
    }
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "--write":
        try writeFixtures()
        print("Wrote \(fixtures.count) M0 fixtures")
    case "--check":
        try checkFixtures()
        print("Validated \(fixtures.count) M0 fixtures")
    default:
        fputs("usage: swift Tools/M0/FixtureGenerator.swift --write|--check\n", stderr)
        exit(64)
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
