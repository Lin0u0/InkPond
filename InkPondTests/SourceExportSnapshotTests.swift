import Foundation
import Testing
@testable import InkPond

@Suite(.serialized)
@MainActor
struct SourceExportSnapshotTests {
    @Test func invalidTypstSourceAndZipRemainNativeFree() throws {
        let document = InkPondDocument(title: "Invalid source", content: "#let broken = (")
        let root = ProjectFileManager.projectDirectory(for: document)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "#let broken = (\n#import \"@missing/not-installed:1.0.0\""
        let input = try ExportManager.snapshotInput(for: document,
            textOverlays: [document.entryFileName: source], includeFonts: false)
        #expect(input.fontPaths.isEmpty)
        #expect(input.localPackagesRoot == nil && input.packageCacheRoot == nil)
        let capture = try OperationSnapshot.capture(input)
        let typ = try ExportManager.temporaryTypURL(snapshot: capture, fileName: document.entryFileName)
        let zip = try ExportManager.zipProject(snapshot: capture)
        let extracted = root.appendingPathComponent("extracted")
        defer { try? FileManager.default.removeItem(at: typ); try? FileManager.default.removeItem(at: zip) }
        #expect(try String(contentsOf: typ, encoding: .utf8) == source)
        _ = try ZipImporter.extract(from: zip, to: extracted)
        #expect(try String(contentsOf: extracted.appendingPathComponent(document.entryFileName), encoding: .utf8) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: extracted.path) == [document.entryFileName])
    }

    @Test func sourceInputFreezesOnlyRequestedBufferBeforeSuspension() async throws {
        let document = InkPondDocument(title: "Original", content: "model is not a fallback")
        document.entryFileName = "missing-entry.typ"
        let input = try ExportManager.snapshotInput(for: document,
            textOverlays: ["chapter.typ": "accepted buffer", "ignored.typ": "unrelated"],
            sourceFileName: "chapter.typ")
        document.title = "Changed"
        document.content = "changed model"
        document.entryFileName = "changed.typ"
        #expect(input.title == "Original")
        #expect(input.entryFileName == "chapter.typ")
        #expect(input.projectRoot == nil)
        #expect(input.localPackagesRoot == nil)
        #expect(input.packageCacheRoot == nil)
        #expect(input.fontPaths.isEmpty)
        #expect(input.textOverlays == ["chapter.typ": "accepted buffer"])
        let snapshot = try await Task.detached { try OperationSnapshot.capture(input) }.value
        #expect(snapshot.title == "Original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshot.projectRoot.path) == ["chapter.typ"])
        let url = try ExportManager.temporaryTypURL(snapshot: snapshot, fileName: "chapter.typ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "accepted buffer")
        // Missing staged data must fail, never re-read the live document/project.
        try FileManager.default.removeItem(at: snapshot.projectRoot.appendingPathComponent("chapter.typ"))
        #expect(throws: (any Error).self) {
            try ExportManager.temporaryTypURL(snapshot: snapshot, fileName: "chapter.typ")
        }
    }

    @Test func singleFileGrantDoesNotCaptureParentOrUnrelatedFiles() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let sourceURL = parent.appendingPathComponent("draft.typ")
        try Data("disk source".utf8).write(to: sourceURL)
        let document = InkPondDocument(title: "External")
        document.entryFileName = "draft.typ"
        document.requiresExternalFolderLinkForPreview = true
        try ExternalTypFileSessionStore.register(url: sourceURL, projectID: document.projectID)
        defer { ExternalTypFileSessionStore.unregister(projectID: document.projectID) }
        // Either sibling would make a whole-parent snapshot fail.
        try fm.createSymbolicLink(at: parent.appendingPathComponent("inaccessible-link"),
            withDestinationURL: parent.appendingPathComponent("missing-target"))
        let huge = parent.appendingPathComponent("unrelated.bin")
        #expect(fm.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(SnapshotCaptureLimits().maximumFileBytes + 1))
        try handle.close()
        let input = try ExportManager.snapshotInput(for: document,
            textOverlays: ["draft.typ": "unsaved buffer"], includeFonts: false, sourceFileName: "draft.typ")
        try fm.removeItem(at: sourceURL)
        let snapshot = try await Task.detached { try OperationSnapshot.capture(input) }.value
        #expect(try fm.contentsOfDirectory(atPath: snapshot.projectRoot.path) == ["draft.typ"])
        let url = try ExportManager.temporaryTypURL(snapshot: snapshot, fileName: "draft.typ")
        defer { try? fm.removeItem(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "unsaved buffer")
        #expect(throws: (any Error).self) {
            try ExportManager.snapshotInput(for: document, includeFonts: false, sourceFileName: "draft.typ")
        }
        #expect(throws: (any Error).self) {
            try ExportManager.snapshotInput(for: document, includeFonts: false)
        }
    }

    @Test func diskSourceWrapperDoesNotReadMissingEntryAndZipExcludesCompilerInputs() throws {
        let document = InkPondDocument(title: "Original")
        let root = ProjectFileManager.projectDirectory(for: document)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = root.appendingPathComponent("chapter.typ")
        try Data("chapter on disk".utf8).write(to: chapter)
        // main.typ deliberately does not exist.
        let url = try ExportManager.temporaryTypURL(for: document, fileName: "chapter.typ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "chapter on disk")
        let input = try ExportManager.snapshotInput(for: document,
            textOverlays: ["main.typ": "entry"], includeFonts: false)
        #expect(input.projectRoot == root)
        #expect(input.localPackagesRoot == nil)
        #expect(input.packageCacheRoot == nil)
        #expect(input.fontPaths.isEmpty)
        let snapshot = try OperationSnapshot.capture(input)
        #expect(try String(contentsOf: snapshot.projectRoot.appendingPathComponent("chapter.typ"), encoding: .utf8) == "chapter on disk")
    }
}
