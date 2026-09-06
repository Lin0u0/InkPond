import Foundation
import Testing
@testable import InkPond

@MainActor
@Suite(.serialized)
struct LinkedFolderReliabilityIntegrationTests {
    @Test(arguments: [false, true])
    func linkedFolderWritesUseCoordinationRegardlessOfManagedCloudSetting(cloudEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = InkPondDocument(title: "Linked integration")
        defer { BookmarkManager.removeBookmark(projectID: document.projectID) }
        try BookmarkManager.saveBookmark(for: root, projectID: document.projectID)

        let kind = ProjectFileManager.reliabilityBackendKind(
            for: document, coordinatingManagedFiles: cloudEnabled
        )
        #expect(kind == .linkedExternal)
        let backend = try ProjectStorageBackendFactory.make(
            kind: kind, rootURL: root,
            securityScopeLease: BookmarkManager.acquireLease(projectID: document.projectID)
        )
        #expect(backend is CoordinatedProjectStorageBackend)
        try await backend.writeStaged(Data("new".utf8), at: ".inkpond/staging/test.stage")
        try await backend.replace("main.typ", withStaged: ".inkpond/staging/test.stage")
        #expect(try await backend.read("main.typ") == Data("new".utf8))
    }

    @Test func refreshKeepsUnsavedTextAndReliableWriterTracksNewAssetsWithoutFollowingSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("initial".utf8).write(to: root.appendingPathComponent("main.typ"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.typ"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )
        let document = InkPondDocument(title: "Refresh and save")
        let projectID = document.stableProjectID
        let metadataRoot = try ProjectReliabilityPaths.privateMetadataRoot(projectID: projectID)
        defer {
            BookmarkManager.removeBookmark(projectID: document.projectID)
            try? FileManager.default.removeItem(at: metadataRoot)
        }
        try BookmarkManager.saveBookmark(for: root, projectID: document.projectID)
        let registry = ProjectReliabilityWriterRegistry()
        func request(_ text: String) -> ProjectReliabilityWriteRequest {
            ProjectReliabilityWriteRequest(
                rootURL: root,
                backendKind: ProjectFileManager.reliabilityBackendKind(
                    for: document, coordinatingManagedFiles: false
                ),
                projectID: projectID, displayName: document.title,
                entryRelativePath: "main.typ", relativePath: "main.typ",
                data: Data(text.utf8),
                securityScopeLease: BookmarkManager.acquireLease(projectID: document.projectID)
            )
        }
        try await registry.write(request("saved before refresh"))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("new.png"))
        let refreshed = try await ProjectFileManager.refreshLinkedFolderContents(
            at: root, projectID: document.projectID, maxDownloadWait: 120
        ) { _ in }
        #expect(Set(refreshed.relativePaths) == ["main.typ", "new.png"])
        #expect(refreshed.scannedFileCount == 2)
        #expect(refreshed.downloadedFileCount == 0)
        let workspace = LinkedFolderRefreshCoordinator.WorkspaceRefresh(
            projectID: document.projectID, result: refreshed,
            targets: [.fileTree, .referenceCompletions, .fonts],
            compileRequest: .bypassCacheOnce,
            completionProgress: .init(
                phase: .complete, scannedFileCount: 2,
                downloadedFileCount: 0, totalDownloadFileCount: 0
            )
        )
        let current = LinkedFolderRefreshCoordinator.WorkspaceEditorState(
            editorText: "newer unsaved text", entrySource: "newer unsaved entry", fontFileNames: []
        )
        let applied = workspace.applying(to: current)
        #expect(applied.editorText == current.editorText)
        #expect(applied.entrySource == current.entrySource)
        try await registry.write(request(applied.editorText))
        await registry.close(projectID: projectID, rootURL: root)

        #expect(try String(contentsOf: root.appendingPathComponent("main.typ"), encoding: .utf8) == current.editorText)
        #expect(try String(contentsOf: outside.appendingPathComponent("secret.typ"), encoding: .utf8) == "outside")
        let manifest = try JSONDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: metadataRoot.appendingPathComponent("project-manifest-v1.json"))
        )
        #expect(manifest.file(relativePath: "main.typ")?.revision == RevisionID(rawValue: 3))
        #expect(manifest.file(relativePath: "new.png") != nil)
        #expect(!manifest.files.contains { $0.relativePath.hasPrefix("escape/") })
    }
}
