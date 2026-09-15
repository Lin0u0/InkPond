import Foundation
import Testing
import os
@testable import InkPond

struct CompileFontSnapshotTests {
    @Test func replacementUsesNewIdentityAndRetainsOldBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let font = root.appendingPathComponent("font.ttf")
        let alias = root.appendingPathComponent("alias.otf")
        let first = Data("first-font".utf8)
        let second = Data("other-font".utf8) // Same size; timestamps are not an identity.
        try first.write(to: font)
        let date = try font.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let oldPaths = try CompileFontSnapshot.prepare(paths: [font.path])
        #expect(try CompileFontSnapshot.prepare(paths: [font.path]) == oldPaths)
        try first.write(to: alias)
        #expect(try CompileFontSnapshot.prepare(paths: [alias.path]) == oldPaths)
        try second.write(to: font)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: font.path)
        let newPaths = try CompileFontSnapshot.prepare(paths: [font.path])
        #expect(newPaths != oldPaths)
        #expect(try Data(contentsOf: URL(fileURLWithPath: oldPaths[0])) == first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: newPaths[0])) == second)

        let store = CompiledPreviewCacheStore(rootURL: root.appendingPathComponent("preview-cache"))
        let descriptor = CompiledPreviewCacheDescriptor(projectID: "project", documentTitle: "Test", entryFileName: "main.typ")
        func input(_ paths: [String]) -> CompiledPreviewCacheInput {
            CompiledPreviewCacheInput(descriptor: descriptor, source: "Hello", fontPaths: paths,
                                      rootDir: nil, localPackagesDir: nil, typstVersion: "test")
        }
        #expect(try store.inputFingerprint(for: input(oldPaths)) != store.inputFingerprint(for: input(newPaths)))
        try FileManager.default.removeItem(at: font)
        #expect(throws: (any Error).self) { try CompileFontSnapshot.prepare(paths: [font.path]) }
        // A directory is present but cannot be read as a font; it must not be skipped.
        #expect(throws: (any Error).self) { try CompileFontSnapshot.prepare(paths: [root.path]) }
    }

    @Test func metadataTracksBytesRatherThanPathOrTimestamp() throws {
        let font = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        defer { try? FileManager.default.removeItem(at: font) }
        try nameOnlyFont(family: "First").write(to: font)
        let date = try font.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        #expect(FontManager.typstFamilyName(forFontAtPath: font.path) == "First")
        try nameOnlyFont(family: "Other").write(to: font)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: font.path)
        #expect(FontManager.typstFamilyName(forFontAtPath: font.path) == "Other")
        try FileManager.default.removeItem(at: font)
        #expect(FontManager.typstFamilyName(forFontAtPath: font.path) == nil)
        try Data("invalid".utf8).write(to: font)
        #expect(FontManager.typstFamilyName(forFontAtPath: font.path) == nil)
    }

    @MainActor
    @Test func compilerChangesSessionIdentityAndFailsBeforeWorkerForMissingFont() async throws {
        let font = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        defer { try? FileManager.default.removeItem(at: font) }
        let calls = OSAllocatedUnfairLock<[(paths: [String], key: String?)]>(initialState: [])
        let compiler = TypstCompiler(
            compileWorker: { _, paths, _, key in
                calls.withLock { $0.append((paths, key)) }
                return .success(TypstPreviewArtifact(svgPages: [], pdfData: Data("pdf".utf8), sourceMap: nil))
            },
            documentBuilder: { _ in nil },
            sleep: { _ in },
            typstVersionProvider: { "test" }
        )
        let descriptor = CompiledPreviewCacheDescriptor(projectID: UUID().uuidString, documentTitle: "Test", entryFileName: "main.typ")
        func compile() async throws {
            compiler.compile(source: "Hello", fontPaths: [font.path], mode: .debounced,
                             previewCachePolicy: .bypassCache, previewCacheDescriptor: descriptor)
            for _ in 0..<1_000 {
                if !compiler.isCompiling && !compiler.isCompileQueued { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Compiler did not finish")
        }
        try Data("font-one".utf8).write(to: font)
        try await compile()
        try Data("font-two".utf8).write(to: font)
        try await compile()
        let captured = calls.withLock { $0 }
        #expect(captured.count == 2)
        if captured.count == 2 {
            #expect(captured[0].paths != captured[1].paths)
            #expect(captured[0].key != captured[1].key)
            #expect(captured[0].key != nil)
        }
        try FileManager.default.removeItem(at: font)
        // Immediate mode reports failures synchronously with completion rather than
        // the debounced preview's delayed error banner.
        compiler.compileNow(source: "Hello", fontPaths: [font.path])
        for _ in 0..<1_000 {
            if !compiler.isCompiling && !compiler.isCompileQueued { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(compiler.errorMessage != nil)
        #expect(calls.withLock { $0.count } == 2)
    }

    /// Minimal sfnt/name table fixture for the metadata reader, not a renderable font.
    private func nameOnlyFont(family: String) -> Data {
        var result = Data()
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { result.append(contentsOf: $0) } }
        let name = family.data(using: .utf16BigEndian)!
        u32(0x00010000); u16(1); u16(16); u16(0); u16(0)
        u32(0x6E616D65); u32(0); u32(28); u32(UInt32(18 + name.count))
        u16(0); u16(1); u16(18)
        u16(3); u16(1); u16(0x0409); u16(1); u16(UInt16(name.count)); u16(0)
        result.append(name)
        return result
    }
}
