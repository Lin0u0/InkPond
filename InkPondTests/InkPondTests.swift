//
//  InkPondTests.swift
//  InkPondTests
//
//  Created by Lin Qidi on 2026/3/2.
//

import Foundation
import PDFKit
import SwiftUI
import Testing
import UIKit
@testable import InkPond

private func makePreviewArtifact(
    pdfData: Data? = Data("pdf".utf8),
    sourceMap: SourceMap? = nil,
    svgPages: [TypstPreviewPage] = [
        TypstPreviewPage(svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", widthPoints: 100, heightPoints: 100)
    ]
) -> TypstPreviewArtifact {
    TypstPreviewArtifact(svgPages: svgPages, pdfData: pdfData, sourceMap: sourceMap)
}

@Suite(.serialized)
@MainActor
struct InkPondTests {
    private let appAppearanceDefaultsKey = "appAppearanceMode"
    private let editorThemeDefaultsKey = "editorThemeID"
    private let editorFontIDDefaultsKey = "editorFontID"
    private let editorFontSizeDefaultsKey = "editorFontSize"

    @Test func zipImporterRejectsParentTraversalPath() throws {
        let zip = makeStoredZip(entries: [
            ("../evil.txt", Data("x".utf8))
        ])
        let dest = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        var gotUnsafePath = false
        do {
            _ = try ZipImporter.extract(data: zip, to: dest)
        } catch let error as ZipImporterError {
            if case .unsafePath = error {
                gotUnsafePath = true
            }
        } catch {}
        #expect(gotUnsafePath)
    }

    @Test func zipImporterExtractsSingleTopLevelDirectory() throws {
        let zip = makeStoredZip(entries: [
            ("project/main.typ", Data("Hello".utf8)),
            ("project/images/a.png", Data([0x01, 0x02, 0x03]))
        ])
        let dest = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let extracted = try ZipImporter.extract(data: zip, to: dest).sorted()
        #expect(extracted == ["images/a.png", "main.typ"])

        let main = dest.appendingPathComponent("main.typ")
        let image = dest.appendingPathComponent("images/a.png")
        #expect(FileManager.default.fileExists(atPath: main.path))
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func localPackageStoreImportsZipArchiveWithConfiguredNamespaceFallback() throws {
        let root = makeTempDirectory()
        let archiveRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: archiveRoot)
        }

        let archiveURL = archiveRoot.appendingPathComponent("kit.zip")
        let zip = makeStoredZip(entries: [
            ("kit/typst.toml", Data("[package]\nname = \"kit\"\nversion = \"0.1.0\"\n".utf8)),
            ("kit/lib.typ", Data("#let answer = 42".utf8))
        ])
        try zip.write(to: archiveURL)

        let result = try LocalPackageStore(rootURL: root).importItem(at: archiveURL, defaultNamespace: "community")

        #expect(result.spec == "@community/kit:0.1.0")
        #expect(result.importedFromArchive)
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("community/kit/0.1.0/lib.typ")
                    .path
            )
        )
    }

    @Test func localPackageStoreImportsTarGzArchiveAndKeepsManifestNamespace() throws {
        let root = makeTempDirectory()
        let archiveRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: archiveRoot)
        }

        let archiveURL = archiveRoot.appendingPathComponent("poster.tar.gz")
        let tarGz = try makeTarGz(entries: [
            ("poster/typst.toml", Data("[package]\nname = \"poster\"\nversion = \"1.2.3\"\nnamespace = \"team\"\n".utf8)),
            ("poster/src/lib.typ", Data("#let banner = true".utf8))
        ])
        try tarGz.write(to: archiveURL)

        let result = try LocalPackageStore(rootURL: root).importItem(at: archiveURL, defaultNamespace: "community")

        #expect(result.spec == "@team/poster:1.2.3")
        #expect(result.importedFromArchive)
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("team/poster/1.2.3/src/lib.typ")
                    .path
            )
        )
    }

    @Test func localPackageStoreChangesNamespaceAfterImport() throws {
        let root = makeTempDirectory()
        let packageRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let source = packageRoot.appendingPathComponent("kit", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("[package]\nname = \"kit\"\nversion = \"0.1.0\"\n".utf8)
            .write(to: source.appendingPathComponent("typst.toml"))
        try Data("#let answer = 42".utf8)
            .write(to: source.appendingPathComponent("lib.typ"))

        let store = LocalPackageStore(rootURL: root)
        _ = try store.importItem(at: source, defaultNamespace: "local")

        let importedEntry = try #require(store.snapshot().entries.first)
        let updatedEntry = try store.changeNamespace(of: importedEntry, to: "community")

        #expect(updatedEntry.spec == "@community/kit:0.1.0")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("local/kit/0.1.0").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("community/kit/0.1.0/lib.typ").path))

        let manifest = try String(
            contentsOf: root.appendingPathComponent("community/kit/0.1.0/typst.toml"),
            encoding: .utf8
        )
        #expect(manifest.contains("namespace = \"community\""))
    }

    @Test func localPackageStoreImportsAllPackagesInsideChosenFolder() throws {
        let root = makeTempDirectory()
        let importRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: importRoot)
        }

        let folderPackage = importRoot.appendingPathComponent("kit", isDirectory: true)
        try FileManager.default.createDirectory(at: folderPackage, withIntermediateDirectories: true)
        try Data("[package]\nname = \"kit\"\nversion = \"0.1.0\"\n".utf8)
            .write(to: folderPackage.appendingPathComponent("typst.toml"))
        try Data("#let answer = 42".utf8)
            .write(to: folderPackage.appendingPathComponent("lib.typ"))

        let archiveURL = importRoot.appendingPathComponent("poster.zip")
        let zip = makeStoredZip(entries: [
            ("poster/typst.toml", Data("[package]\nname = \"poster\"\nversion = \"1.2.3\"\n".utf8)),
            ("poster/src/lib.typ", Data("#let banner = true".utf8))
        ])
        try zip.write(to: archiveURL)

        let results = try LocalPackageStore(rootURL: root).importContents(of: importRoot, defaultNamespace: "community")

        #expect(results.map(\.spec).sorted() == ["@community/kit:0.1.0", "@community/poster:1.2.3"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("community/kit/0.1.0/lib.typ").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("community/poster/1.2.3/src/lib.typ").path))
    }

    @Test func localPackageStoreSnapshotIngestsLooseDroppedPackageFromRoot() throws {
        let root = makeTempDirectory()
        let originalNamespace = UserDefaults.standard.object(forKey: LocalPackageStore.defaultNamespaceDefaultsKey)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let originalNamespace {
                UserDefaults.standard.set(originalNamespace, forKey: LocalPackageStore.defaultNamespaceDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalPackageStore.defaultNamespaceDefaultsKey)
            }
        }

        UserDefaults.standard.set("community", forKey: LocalPackageStore.defaultNamespaceDefaultsKey)

        let droppedPackage = root.appendingPathComponent("kit", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedPackage, withIntermediateDirectories: true)
        try Data("[package]\nname = \"kit\"\nversion = \"0.1.0\"\n".utf8)
            .write(to: droppedPackage.appendingPathComponent("typst.toml"))
        try Data("#let answer = 42".utf8)
            .write(to: droppedPackage.appendingPathComponent("lib.typ"))

        let entries = try LocalPackageStore(rootURL: root).snapshot().entries

        #expect(entries.map(\.spec) == ["@community/kit:0.1.0"])
        #expect(!FileManager.default.fileExists(atPath: droppedPackage.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("community/kit/0.1.0/lib.typ").path))
    }

    @Test func projectFileManagerRejectsUnsafeRelativePaths() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        var deleteUnsafe = false
        do {
            try ProjectFileManager.deleteProjectFile(relativePath: "../oops.txt", for: doc)
        } catch let error as InkPondFileError {
            if case .unsafePath = error {
                deleteUnsafe = true
            }
        } catch {}
        #expect(deleteUnsafe)

        var createInvalidName = false
        do {
            try ProjectFileManager.createTypFile(named: "../bad.typ", for: doc)
        } catch let error as InkPondFileError {
            if case .invalidFileName = error {
                createInvalidName = true
            }
        } catch {}
        #expect(createInvalidName)
    }

    @Test func projectFileManagerImportFileAllowsEmptySubdirAndReturnsFileName() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let src = srcDir.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: src)

        let importedPath = try ProjectFileManager.importFile(from: src, to: "", for: doc)
        #expect(importedPath == "hello.txt")

        let dest = ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("hello.txt")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func externalTypFileImporterCreatesSingleFileProjectWithoutEntryPicker() throws {
        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let src = srcDir.appendingPathComponent("draft.typ")
        try Data("= Draft\n\nOpened from Files.".utf8).write(to: src)

        let document = try ExternalTypFileImporter.importFile(from: src)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }

        #expect(document.title == "draft")
        #expect(document.entryFileName == "draft.typ")
        #expect(document.lastEditedFileName == "draft.typ")
        #expect(document.requiresExternalFolderLinkForPreview)
        #expect(document.needsExternalFolderLinkForPreview)
        #expect(!document.requiresInitialEntrySelection)
        #expect(!document.requiresImportConfiguration)
        #expect(document.importEntryFileOptions.isEmpty)

        let importedSource = try ProjectFileManager.readTypFile(named: "draft.typ", for: document)
        #expect(importedSource == "= Draft\n\nOpened from Files.")
        #expect(ProjectFileManager.listAllTypFiles(for: document) == ["draft.typ"])
        #expect(!FileManager.default.fileExists(
            atPath: ProjectFileManager.documentsURL.appendingPathComponent(document.projectID).path
        ))

        try ProjectFileManager.writeTypFile(named: "draft.typ", content: "= Edited", for: document)
        let originalSource = try String(contentsOf: src, encoding: .utf8)
        #expect(originalSource == "= Edited")
    }

    @MainActor
    @Test func externalTypFileImporterOpensNestedFileAsEditorOnlySingleFile() async throws {
        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let chapterDir = srcDir.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try Data("= Root Main".utf8)
            .write(to: srcDir.appendingPathComponent("main.typ"))
        try Data("= Chapter Main".utf8)
            .write(to: chapterDir.appendingPathComponent("main.typ"))
        let openedFile = chapterDir.appendingPathComponent("intro.typ")
        try Data("= Intro".utf8).write(to: openedFile)

        let result = try await ExternalTypFileImporter.importFile(from: openedFile)
        let document = result.document
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }

        #expect(result.mode == .singleFile)
        #expect(!document.isExternalFolder)
        #expect(document.entryFileName == "intro.typ")
        #expect(document.lastEditedFileName == "intro.typ")
        #expect(document.requiresExternalFolderLinkForPreview)
        #expect(ProjectFileManager.listAllTypFiles(for: document) == ["intro.typ"])
        #expect(!FileManager.default.fileExists(
            atPath: ProjectFileManager.documentsURL.appendingPathComponent(document.projectID).path
        ))
        let source = try ProjectFileManager.readTypFile(named: "intro.typ", for: document)
        #expect(source == "= Intro")
    }

    @Test func bookmarkManagerLoadsReachableFolderBookmark() throws {
        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let projectID = "bookmark-\(UUID().uuidString)"
        try BookmarkManager.saveBookmark(for: srcDir, projectID: projectID)
        defer { BookmarkManager.removeBookmark(projectID: projectID) }

        let resolved = try #require(BookmarkManager.loadBookmark(projectID: projectID))
        defer { BookmarkManager.stopAccessing(projectID) }

        #expect(resolved.standardizedFileURL == srcDir.standardizedFileURL)
    }

    @Test func externalFolderBookmarkAllowsPreviewEvenIfDocumentWasSingleFile() throws {
        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let document = makeDocument(projectID: "bookmark-\(UUID().uuidString)")
        document.requiresExternalFolderLinkForPreview = true
        try BookmarkManager.saveBookmark(for: srcDir, projectID: document.projectID)
        defer { BookmarkManager.removeBookmark(projectID: document.projectID) }

        #expect(document.isExternalFolder)
        #expect(!document.needsExternalFolderLinkForPreview)
    }

    @MainActor
    @Test func externalTypFileImporterDoesNotCopyDependenciesForEditorOnlyOpen() async throws {
        let srcDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let templateDir = srcDir.appendingPathComponent("templates", isDirectory: true)
        let imageDir = srcDir.appendingPathComponent("images", isDirectory: true)
        let fontsDir = srcDir.appendingPathComponent("fonts", isDirectory: true)
        let hiddenCacheDir = srcDir.appendingPathComponent(".typst", isDirectory: true)
        try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenCacheDir, withIntermediateDirectories: true)

        let src = srcDir.appendingPathComponent("draft.typ")
        try Data(#"#import "templates/style.typ": *\n#bibliography("refs.bib")\n#image("images/logo.png")"#.utf8)
            .write(to: src)
        try Data("= Main should not be selected".utf8)
            .write(to: srcDir.appendingPathComponent("main.typ"))
        try Data("#let heading(body) = body".utf8)
            .write(to: templateDir.appendingPathComponent("style.typ"))
        try Data("@book{demo,title={Demo}}".utf8)
            .write(to: srcDir.appendingPathComponent("refs.bib"))
        try Data([0x89, 0x50, 0x4E, 0x47])
            .write(to: imageDir.appendingPathComponent("logo.png"))
        try Data("font".utf8)
            .write(to: fontsDir.appendingPathComponent("Demo.ttf"))
        try Data("cache".utf8)
            .write(to: hiddenCacheDir.appendingPathComponent("package.typ"))

        let result = try await ExternalTypFileImporter.importFile(from: src, preferLinkedFolder: false)
        let document = result.document
        defer { try? ProjectFileManager.deleteProjectDirectory(for: document) }

        #expect(result.mode == .singleFile)
        #expect(!document.isExternalFolder)
        #expect(document.entryFileName == "draft.typ")
        #expect(document.lastEditedFileName == "draft.typ")
        #expect(document.requiresExternalFolderLinkForPreview)
        #expect(!document.requiresImportConfiguration)

        #expect(ProjectFileManager.listAllTypFiles(for: document) == ["draft.typ"])
        #expect(!FileManager.default.fileExists(
            atPath: ProjectFileManager.documentsURL.appendingPathComponent(document.projectID).path
        ))
    }

    @Test func externalTypFileImporterResolvesManagedProjectLocation() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        try ProjectFileManager.writeTypFile(named: "main.typ", content: "= Main", for: doc)
        let chapterDir = ProjectFileManager.projectDirectory(for: doc)
            .appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try ProjectFileManager.writeTypFile(named: "chapters/intro.typ", content: "= Intro", for: doc)

        let managedURL = ProjectFileManager.projectDirectory(for: doc)
            .appendingPathComponent("chapters/intro.typ")
        let location = try #require(ExternalTypFileImporter.managedProjectLocation(for: managedURL))
        #expect(location.projectID == doc.projectID)
        #expect(location.relativeFileName == "chapters/intro.typ")

        let externalDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalURL = externalDir.appendingPathComponent("draft.typ")
        try Data("= Draft".utf8).write(to: externalURL)

        #expect(ExternalTypFileImporter.managedProjectLocation(for: externalURL) == nil)

        let inboxDir = ProjectFileManager.documentsURL.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let inboxURL = inboxDir.appendingPathComponent("opened-\(UUID().uuidString).typ")
        try Data("= Inbox copy".utf8).write(to: inboxURL)
        defer { try? FileManager.default.removeItem(at: inboxURL) }

        #expect(ExternalTypFileImporter.managedProjectLocation(for: inboxURL) == nil)
    }

    @Test func projectFileManagerImportFilePreservesExistingDestinationWhenReplacementCopyFails() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let destination = ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("hello.txt")
        try Data("existing".utf8).write(to: destination)

        let missingSourceRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: missingSourceRoot) }
        let missingSource = missingSourceRoot.appendingPathComponent("hello.txt")

        do {
            try ProjectFileManager.importFile(from: missingSource, to: "", for: doc)
            Issue.record("Expected import to fail for a missing source file")
        } catch {}

        let preserved = try String(contentsOf: destination, encoding: .utf8)
        #expect(preserved == "existing")
    }

    @Test func resolveImportedEntryFileRequiresSelectionWhenMainTypIsMissing() {
        let resolution = ProjectFileManager.resolveImportedEntryFile(from: ["chapter.typ", "appendix.typ"])

        #expect(resolution.entryFileName == "appendix.typ")
        #expect(resolution.requiresInitialSelection)
    }

    @Test func migrateContentIfNeededSkipsEmptyContent() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        ProjectFileManager.migrateContentIfNeeded(for: doc)

        let entryURL = ProjectFileManager.entryFileURL(for: doc)
        #expect(!FileManager.default.fileExists(atPath: entryURL.path))
    }

    @Test func validateDocumentCanOpenRejectsMissingEntryWithoutCreatingIt() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        try ProjectFileManager.createProjectRoot(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let entryURL = ProjectFileManager.entryFileURL(for: doc)
        #expect(!FileManager.default.fileExists(atPath: entryURL.path))

        do {
            try ProjectFileManager.validateDocumentCanOpen(doc)
            Issue.record("Expected missing entry validation to fail")
        } catch let error as InkPondFileError {
            guard case .fileNotFound = error else {
                Issue.record("Expected fileNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected InkPondFileError.fileNotFound, got \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: entryURL.path))
    }

    @Test func validateDocumentCanOpenAllowsLegacyStoredContentMigration() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        doc.content = "= Legacy"
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let projectRoot = ProjectFileManager.projectDirectory(for: doc)
        #expect(!FileManager.default.fileExists(atPath: projectRoot.path))

        try ProjectFileManager.validateDocumentCanOpen(doc)
        #expect(!FileManager.default.fileExists(atPath: projectRoot.path))
    }

    @Test func projectFileManagerSupportsNestedTypPaths() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let nestedDir = ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        try ProjectFileManager.writeTypFile(named: "chapters/intro.typ", content: "Hello", for: doc)

        let loaded = try ProjectFileManager.readTypFile(named: "chapters/intro.typ", for: doc)
        #expect(loaded == "Hello")

        try ProjectFileManager.deleteTypFile(named: "chapters/intro.typ", for: doc)
        #expect(!FileManager.default.fileExists(atPath: nestedDir.appendingPathComponent("intro.typ").path))
    }

    @Test func projectFileManagerBuildsProjectTreeFromRoot() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        try ProjectFileManager.writeTypFile(named: "main.typ", content: "", for: doc)
        let chapterDir = ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try ProjectFileManager.writeTypFile(named: "chapters/intro.typ", content: "", for: doc)

        let imageURL = ProjectFileManager.imagesDirectory(for: doc).appendingPathComponent("cover.png")
        try Data([0x01]).write(to: imageURL)

        let tree = ProjectFileManager.projectTree(for: doc)

        #expect(tree.map(\.displayName) == ["chapters", "fonts", "images", "main.typ"])
        let chapters = try #require(tree.first(where: { $0.relativePath == "chapters" }))
        #expect(chapters.kind == .directory)
        #expect(chapters.children.map(\.relativePath) == ["chapters/intro.typ"])
        let images = try #require(tree.first(where: { $0.relativePath == "images" }))
        #expect(images.children.map(\.relativePath) == ["images/cover.png"])
    }

    @Test func fileKindClassifiesSupportedWorkspaceTypes() {
        let cases: [(String, FileKind)] = [
            ("main.typ", .typ),
            ("notes.txt", .text),
            ("refs.bib", .bibliography),
            ("refs.yaml", .bibliography),
            ("data.json", .data),
            ("table.csv", .data),
            ("typst.toml", .configuration),
            ("cover.png", .image),
            ("diagram.svg", .vector),
            ("attachment.pdf", .pdf),
            ("fonts/Inter-Regular.otf", .font),
            ("archive.zip", .archive),
            ("unknown.bin", .other)
        ]

        for (path, expected) in cases {
            #expect(ProjectFileManager.fileKind(for: path, imageDirectoryName: "images") == expected)
        }
    }

    @Test func projectFileManagerListsAllFilesRecursively() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        try ProjectFileManager.writeTypFile(named: "main.typ", content: "", for: doc)
        let nestedImage = ProjectFileManager.projectDirectory(for: doc)
            .appendingPathComponent("assets/icons", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedImage, withIntermediateDirectories: true)
        try Data([0x01]).write(to: nestedImage.appendingPathComponent("logo.png"))

        let files = ProjectFileManager.listAllFiles(in: ProjectFileManager.projectDirectory(for: doc))
        #expect(files == ["assets/icons/logo.png", "main.typ"])
    }

    @Test func linkedFolderLoaderScansFullFolderAndReportsProgress() async throws {
        let folder = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("= Main".utf8).write(to: folder.appendingPathComponent("main.typ"))
        let chapterDir = folder.appendingPathComponent("chapters", isDirectory: true)
        let assetDir = folder.appendingPathComponent("assets/icons", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
        try Data("= Intro".utf8).write(to: chapterDir.appendingPathComponent("intro.typ"))
        try Data([0x01]).write(to: assetDir.appendingPathComponent("logo.png"))
        for index in 0..<125 {
            try Data("note \(index)".utf8).write(to: folder.appendingPathComponent("note-\(index).txt"))
        }

        var updates: [LinkedFolderLoadProgress] = []
        let result = try await ProjectFileManager.loadLinkedFolderContents(at: folder) { progress in
            await MainActor.run {
                updates.append(progress)
            }
        }

        #expect(result.scannedFileCount == 128)
        #expect(result.downloadedFileCount == 0)
        #expect(result.relativePaths.contains("main.typ"))
        #expect(result.relativePaths.contains("chapters/intro.typ"))
        #expect(result.relativePaths.contains("assets/icons/logo.png"))
        #expect(result.relativePaths.contains("note-124.txt"))
        #expect(updates.contains { $0.phase == .scanning && $0.scannedFileCount >= 50 })
        #expect(updates.contains { $0.phase == .downloading })
    }

    @Test func linkedFolderLoaderScansLargeLocalFolderWithoutDownloadWait() async throws {
        let folder = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        for index in 0..<600 {
            let bucket = folder.appendingPathComponent("bucket-\(index / 100)", isDirectory: true)
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
            try Data("note \(index)".utf8).write(to: bucket.appendingPathComponent("note-\(index).typ"))
        }

        var progressEvents: [LinkedFolderLoadProgress] = []
        let result = try await ProjectFileManager.loadLinkedFolderContents(
            at: folder,
            maxDownloadWait: 1
        ) { progress in
            await MainActor.run {
                progressEvents.append(progress)
            }
        }

        #expect(result.scannedFileCount == 600)
        #expect(result.downloadedFileCount == 0)
        #expect(result.relativePaths.first == "bucket-0/note-0.typ")
        #expect(result.relativePaths.last == "bucket-5/note-599.typ")
        #expect(progressEvents.contains { $0.phase == .scanning && $0.scannedFileCount >= 500 })
        #expect(progressEvents.last?.phase == .downloading)
    }

    @Test func projectFileManagerFindsImportDirectoryCandidates() {
        let files = [
            "main.typ",
            "assets/cover.png",
            "assets/diagram.svg",
            "assets/reference.pdf",
            "fonts/Inter-Regular.otf",
            "illustration.eps",
            "vendor/fonts/Mono.ttf",
            "vendor/fonts/nested/Mono-Bold.ttf",
            "logo.jpg",
            "scans/scan.tiff",
            "thumb.bmp"
        ]

        #expect(ProjectFileManager.imageDirectoryCandidates(from: files) == ["", "assets", "scans"])
        #expect(ProjectFileManager.fontDirectoryCandidates(from: files) == ["", "fonts", "vendor", "vendor/fonts", "vendor/fonts/nested"])
    }

    @Test func projectFileManagerTreatsPDFEPSBitmapAndTIFFAsImages() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let projectDir = ProjectFileManager.projectDirectory(for: doc)
        try Data([0x01]).write(to: projectDir.appendingPathComponent("attachment.pdf"))
        try Data([0x02]).write(to: projectDir.appendingPathComponent("vector.eps"))
        try Data([0x03]).write(to: projectDir.appendingPathComponent("bitmap.bmp"))
        try Data([0x04]).write(to: ProjectFileManager.imagesDirectory(for: doc).appendingPathComponent("scan.tiff"))

        let tree = ProjectFileManager.projectTree(for: doc)

        #expect(isImageKind(tree.first(where: { $0.relativePath == "attachment.pdf" })?.kind))
        #expect(isImageKind(tree.first(where: { $0.relativePath == "vector.eps" })?.kind))
        #expect(isImageKind(tree.first(where: { $0.relativePath == "bitmap.bmp" })?.kind))
        let images = try #require(tree.first(where: { $0.relativePath == "images" }))
        #expect(isImageKind(images.children.first(where: { $0.relativePath == "images/scan.tiff" })?.kind))
    }

    @Test func projectFileManagerRemovesFontReferencesByPathOrFileName() {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        doc.fontFileNames = ["Inter-Regular.otf", "fonts/Mono.ttf", "Keep.ttf"]

        ProjectFileManager.removeFontReference(relativePath: "fonts/Inter-Regular.otf", from: doc)
        ProjectFileManager.removeFontReference(relativePath: "fonts/Mono.ttf", from: doc)

        #expect(doc.fontFileNames == ["Keep.ttf"])
    }

    @Test func projectFileManagerRecognizesOnlyRealImportChoices() {
        #expect(!ProjectFileManager.requiresImportDirectorySelection([""]))
        #expect(!ProjectFileManager.requiresImportDirectorySelection(["images"]))
        #expect(ProjectFileManager.requiresImportDirectorySelection(["", "images"]))
        #expect(ProjectFileManager.defaultImportDirectory(from: [""]) == String?.some(""))
        #expect(ProjectFileManager.defaultImportDirectory(from: ["images"]) == String?.some("images"))
        #expect(ProjectFileManager.defaultImportDirectory(from: ["", "images"]) == nil)
        #expect(ProjectFileManager.defaultImportDirectory(from: []) == nil)
    }

    @Test func projectFileManagerRenameThrowsWhenProjectDirectoryIsMissing() {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")

        var gotMissingProject = false
        do {
            _ = try ProjectFileManager.renameProjectDirectory(for: doc, to: "Renamed")
        } catch let error as InkPondFileError {
            if case .fileNotFound(let name) = error {
                gotMissingProject = (name == doc.projectID)
            }
        } catch {}

        #expect(gotMissingProject)
    }

    @Test func projectFileManagerAllowsRootImageDirectory() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        doc.imageDirectoryName = ""
        ProjectFileManager.ensureProjectStructure(for: doc)
        defer { try? ProjectFileManager.deleteProjectDirectory(for: doc) }

        let relativePath = try ProjectFileManager.saveImage(data: Data([0x01]), fileName: "cover.png", for: doc)

        #expect(relativePath == "cover.png")
        #expect(FileManager.default.fileExists(atPath: ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("cover.png").path))
    }

    @Test func themeManagerPersistsEditorThemeSelection() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("latte", forKey: editorThemeDefaultsKey)

        let initialManager = ThemeManager(defaults: defaults)
        #expect(initialManager.themeID == "latte")
        #expect(initialManager.currentTheme.id == "latte")

        initialManager.themeID = "mocha"

        let reloadedManager = ThemeManager(defaults: defaults)
        #expect(reloadedManager.themeID == "mocha")
        #expect(reloadedManager.currentTheme.id == "mocha")
    }

    @Test func themeManagerFallsBackToSystemThemeForUnknownValue() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("nord", forKey: editorThemeDefaultsKey)

        let manager = ThemeManager(defaults: defaults)
        #expect(manager.themeID == "nord")
        #expect(manager.currentTheme.id == "system")
    }

    @Test func editorFontSettingsPersistsFontAndSizeSelection() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let alternateFontID = EditorFontSettings.availableFontOptions
            .first { $0.id != EditorFontSettings.systemMonospacedFontID }?
            .id ?? EditorFontSettings.systemMonospacedFontID

        let initialSettings = EditorFontSettings(defaults: defaults)
        initialSettings.fontID = alternateFontID
        initialSettings.fontSize = 21

        let reloadedSettings = EditorFontSettings(defaults: defaults)
        #expect(reloadedSettings.fontID == alternateFontID)
        #expect(reloadedSettings.fontSize == 21)
        #expect(abs(reloadedSettings.uiFont.pointSize - 21) < 0.1)
    }

    @Test func editorFontSettingsClampsPersistedSizeAndFallsBackForUnknownFont() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("MissingEditorFontName", forKey: editorFontIDDefaultsKey)
        defaults.set(EditorFontSettings.maximumFontSize + 20, forKey: editorFontSizeDefaultsKey)

        let settings = EditorFontSettings(defaults: defaults)

        #expect(settings.fontID == "MissingEditorFontName")
        #expect(settings.fontSize == EditorFontSettings.maximumFontSize)
        #expect(settings.uiFont.fontName == EditorFontSettings.defaultUIFont.fontName)
    }

    @Test func editorFontSettingsGroupsFacesByFamily() {
        let families = EditorFontSettings.availableFontFamilies
        let familyIDs = families.map(\.id)
        let flattenedFaces = families.flatMap(\.faces)

        #expect(families.first?.id == EditorFontSettings.systemMonospacedFontID)
        #expect(Set(familyIDs).count == familyIDs.count)
        #expect(families.allSatisfy { !$0.faces.isEmpty })
        #expect(EditorFontSettings.availableFontOptions.count == flattenedFaces.count)
    }

    @Test func editorFontSettingsKeepsSystemMonospacedNameVerbatim() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = EditorFontSettings(defaults: defaults)

        #expect(settings.fontDisplayName == EditorFontSettings.systemMonospacedDisplayName)
        #expect(settings.familyDisplayName == EditorFontSettings.systemMonospacedDisplayName)
        #expect(EditorFontSettings.availableFontFamilies.first?.displayName == EditorFontSettings.systemMonospacedDisplayName)
    }

    @Test func editorFontSettingsScalesLineSpacingAndLineNumberFont() {
        let smallFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let largeFont = UIFont.monospacedSystemFont(ofSize: 24, weight: .regular)

        #expect(EditorFontSettings.lineSpacing(for: largeFont) > EditorFontSettings.lineSpacing(for: smallFont))
        #expect(EditorFontSettings.lineNumberFont(for: largeFont).pointSize > EditorFontSettings.lineNumberFont(for: smallFont).pointSize)
    }

    @Test func appAppearanceManagerPersistsAppearanceSelection() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppAppearanceMode.light.rawValue, forKey: appAppearanceDefaultsKey)

        let initialManager = AppAppearanceManager(defaults: defaults)
        #expect(initialManager.mode == AppAppearanceMode.light.rawValue)
        #expect(initialManager.currentMode == .light)
        #expect(initialManager.colorScheme == .light)
        #expect(initialManager.userInterfaceStyle == .light)

        initialManager.mode = AppAppearanceMode.dark.rawValue

        let reloadedManager = AppAppearanceManager(defaults: defaults)
        #expect(reloadedManager.mode == AppAppearanceMode.dark.rawValue)
        #expect(reloadedManager.currentMode == .dark)
        #expect(reloadedManager.colorScheme == .dark)
        #expect(reloadedManager.userInterfaceStyle == .dark)
    }

    @Test func appAppearanceManagerFallsBackToSystemForUnknownValue() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("sepia", forKey: appAppearanceDefaultsKey)

        let manager = AppAppearanceManager(defaults: defaults)
        #expect(manager.mode == "sepia")
        #expect(manager.currentMode == .system)
        #expect(manager.colorScheme == nil)
        #expect(manager.userInterfaceStyle == .unspecified)
    }

    @Test func typstCompilerUsesLowerQoSForPreviewThanExplicitCompile() {
        #expect(TypstCompiler.taskPriority(for: .debounced) == .utility)
        #expect(TypstCompiler.taskPriority(for: .immediate) == .medium)
    }

    @MainActor
    @Test func highlightSchedulerCoalescesBurstUpdates() async {
        let counter = LockedCounter()
        let scheduler = HighlightScheduler(sleep: { _ in }) {
            counter.increment()
        }

        scheduler.schedule(.debounced)
        scheduler.schedule(.debounced)
        scheduler.schedule(.debounced)

        await waitUntil {
            counter.value == 1
        }
        #expect(counter.value == 1)
    }

    @MainActor
    @Test func highlightSchedulerImmediateUpdateCancelsPendingDebounce() async {
        let counter = LockedCounter()
        let scheduler = HighlightScheduler(
            sleep: { _ in try await Task.sleep(for: .seconds(1)) }
        ) {
            counter.increment()
        }

        scheduler.schedule(.debounced)
        scheduler.schedule(.immediate)

        await waitUntil {
            counter.value == 1
        }
        #expect(counter.value == 1)
    }

    @Test func jumpHighlightTimelineFadesInAndOut() {
        #expect(JumpHighlightTimeline.opacity(at: -0.01) == 0)
        #expect(JumpHighlightTimeline.opacity(at: 0) == 0)

        let midFadeIn = JumpHighlightTimeline.opacity(at: JumpHighlightTimeline.fadeInDuration / 2)
        #expect(midFadeIn > 0)
        #expect(midFadeIn < 1)

        let holdSample = JumpHighlightTimeline.opacity(
            at: JumpHighlightTimeline.fadeInDuration + JumpHighlightTimeline.holdDuration / 2
        )
        #expect(holdSample == 1)

        let midFadeOut = JumpHighlightTimeline.opacity(
            at: JumpHighlightTimeline.fadeInDuration
                + JumpHighlightTimeline.holdDuration
                + JumpHighlightTimeline.fadeOutDuration / 2
        )
        #expect(midFadeOut > 0)
        #expect(midFadeOut < 1)

        #expect(JumpHighlightTimeline.opacity(at: JumpHighlightTimeline.totalDuration + 0.01) == 0)
    }

    @Test func syntaxHighlighterRefreshJumpHighlightRestoresErrorBackground() {
        let textStorage = NSTextStorage(string: "ok\n  broken\n")
        let highlighter = SyntaxHighlighter()
        highlighter.errorLines = [2]
        highlighter.highlight(textStorage)

        let nsText = textStorage.string as NSString
        let firstLineRange = nsText.range(of: "ok")
        let errorRange = nsText.range(of: "broken")
        let errorColorBefore = textStorage.attribute(.backgroundColor, at: errorRange.location, effectiveRange: nil) as? UIColor

        #expect(abs((errorColorBefore?.cgColor.alpha ?? 0) - 0.08) < 0.001)

        highlighter.refreshJumpHighlight(
            in: textStorage,
            previousLine: nil,
            line: 1,
            opacity: 1
        )

        let jumpColor = textStorage.attribute(.backgroundColor, at: firstLineRange.location, effectiveRange: nil) as? UIColor
        let errorColorDuringJump = textStorage.attribute(.backgroundColor, at: errorRange.location, effectiveRange: nil) as? UIColor

        #expect(abs((jumpColor?.cgColor.alpha ?? 0) - 0.14) < 0.001)
        #expect(abs((errorColorDuringJump?.cgColor.alpha ?? 0) - 0.08) < 0.001)

        highlighter.refreshJumpHighlight(
            in: textStorage,
            previousLine: 1,
            line: nil,
            opacity: 0
        )

        let clearedJumpColor = textStorage.attribute(.backgroundColor, at: firstLineRange.location, effectiveRange: nil) as? UIColor
        let restoredErrorColor = textStorage.attribute(.backgroundColor, at: errorRange.location, effectiveRange: nil) as? UIColor

        #expect(clearedJumpColor == nil)
        #expect(abs((restoredErrorColor?.cgColor.alpha ?? 0) - 0.08) < 0.001)
    }

    @Test func syntaxHighlighterDoesNotFallbackWhenTypstReturnsNoTokens() {
        let textStorage = NSTextStorage(string: "bread and butter")
        let theme = EditorTheme.latte
        let highlighter = SyntaxHighlighter(theme: theme, tokenProvider: { _ in [] })

        highlighter.highlight(textStorage)

        let nsText = textStorage.string as NSString
        let andRange = nsText.range(of: "and")
        let color = textStorage.attribute(
            .foregroundColor,
            at: andRange.location,
            effectiveRange: nil
        ) as? UIColor

        #expect(color?.isEqual(theme.text) == true)
    }

    @Test func syntaxHighlighterPreservesEditorParagraphStyle() {
        let font = UIFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        let textStorage = NSTextStorage(string: "first\nsecond")
        let highlighter = SyntaxHighlighter(font: font, tokenProvider: { _ in [] })

        highlighter.highlight(textStorage)

        let paragraphStyle = textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(abs((paragraphStyle?.lineSpacing ?? 0) - EditorFontSettings.lineSpacing(for: font)) < 0.001)
    }

    @Test func syntaxHighlighterAppliesTypstTokensWithUTF16Offsets() {
        let textStorage = NSTextStorage(string: "你好 #let x = 1")
        let theme = EditorTheme.latte
        let highlighter = SyntaxHighlighter(theme: theme) { _ in
            [
                TypstSyntaxToken(location: 3, length: 1, kind: .keyword),
                TypstSyntaxToken(location: 4, length: 3, kind: .keyword),
                TypstSyntaxToken(location: 12, length: 1, kind: .number),
            ]
        }

        highlighter.highlight(textStorage)

        let hashColor = textStorage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? UIColor
        let letColor = textStorage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor
        let numberColor = textStorage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? UIColor

        #expect(hashColor?.isEqual(theme.keyword) == true)
        #expect(letColor?.isEqual(theme.keyword) == true)
        #expect(numberColor?.isEqual(theme.number) == true)
    }

#if TYPST_FFI_AVAILABLE
    @Test func outlineParserUsesTypstParserContext() throws {
        let source = """
        = Real <intro>

        ```typ
        = Not outline
        ```

        == Next
        """

        let entries = try #require(TypstBridge.outlineItems(source: source))
        #expect(entries.map(\.title) == ["Real", "Next"])
        #expect(entries.map(\.level) == [1, 2])

        let items = OutlineView.parseHeadings(from: source)
        #expect(items.map(\.title) == ["Real", "Next"])
        #expect(items.map(\.level) == [1, 2])
    }

    @Test func outlineParserReturnsUTF16Offsets() throws {
        let entries = try #require(TypstBridge.outlineItems(source: "你好\n= 标题"))
        let first = try #require(entries.first)

        #expect(first.location == 3)
        #expect(first.title == "标题")
    }

    @Test func labelParserUsesTypstParserContext() throws {
        let source = """
        = Real <intro>

        ```typ
        = Not a heading <fake-heading>
        #figure("not real") <fake-figure>
        ```

        #let literal = <not-a-definition>

        #figure(table(columns: 1, [Nested])) <fig>
        #table(columns: 1, [Cell]) <tbl>
        $x + y$ <eq>
        """

        let labels = try #require(TypstBridge.labels(source: source))

        #expect(labels == [
            TypstLabelEntry(name: "intro", kind: "heading"),
            TypstLabelEntry(name: "fig", kind: "figure"),
            TypstLabelEntry(name: "tbl", kind: "table"),
            TypstLabelEntry(name: "eq", kind: "equation")
        ])
    }

    @Test func bibliographyParserUsesHayagrivaForBiblatexAndYaml() throws {
        let biblatex = """
        @string{journal_name = {Journal of Tests}}
        @article{smith2020,
          title = {Nested {Brace} Title},
          journaltitle = journal_name
        }
        """

        let bibEntries = try #require(TypstBridge.bibliographyEntries(source: biblatex, fileName: "refs.bib"))
        #expect(bibEntries == [
            TypstBibliographyEntry(key: "smith2020", type: "article", title: "Nested Brace Title")
        ])

        let yaml = """
        yaml-key:
          type: Book
          title: Hayagriva YAML Works
        """

        let yamlEntries = try #require(TypstBridge.bibliographyEntries(source: yaml, fileName: "refs.yaml"))
        #expect(yamlEntries == [
            TypstBibliographyEntry(key: "yaml-key", type: "book", title: "Hayagriva YAML Works")
        ])
    }
#endif

    @MainActor
    @Test func editorFocusCoordinatorRestoresFocusAfterSuppressedLoss() async {
        let coordinator = EditorFocusCoordinator()
        let (window, textView) = makeHostedTextView()
        defer { window.isHidden = true }
        coordinator.register(textView)
        #expect(!coordinator.isEditorFocused)
        _ = textView.becomeFirstResponder()
        await waitUntil { textView.isFirstResponder }
        #expect(coordinator.isEditorFocused)

        coordinator.setResignSuppressed(true)
        #expect(textView.suppressResignFirstResponder)

        textView.suppressResignFirstResponder = false
        _ = textView.resignFirstResponder()
        #expect(!textView.isFirstResponder)
        coordinator.setResignSuppressed(false)
        await waitUntil { textView.isFirstResponder }

        #expect(textView.isFirstResponder)
        #expect(!textView.suppressResignFirstResponder)
    }

    @MainActor
    @Test func editorCoordinatorIgnoresSelectionChangesDuringProgrammaticTextUpdate() {
        var text = "First line\nSecond line"
        var insertionRequest: EditorInsertionRequest?
        var findRequested = false
        var viewState = EditorViewState()
        var cursorJumpOffset: Int?
        let parent = EditorView(
            text: Binding(get: { text }, set: { text = $0 }),
            insertionRequest: Binding(get: { insertionRequest }, set: { insertionRequest = $0 }),
            findRequested: Binding(get: { findRequested }, set: { findRequested = $0 }),
            viewState: Binding(get: { viewState }, set: { viewState = $0 }),
            cursorJumpOffset: Binding(get: { cursorJumpOffset }, set: { cursorJumpOffset = $0 })
        )
        let coordinator = EditorView.Coordinator(parent)
        let (window, textView) = makeHostedTextView()
        defer { window.isHidden = true }
        textView.delegate = coordinator
        coordinator.textView = textView

        coordinator.performProgrammaticUpdate {
            textView.text = text
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            coordinator.textViewDidChangeSelection(textView)
        }

        #expect(viewState.selectedLocation == 0)

        textView.selectedRange = NSRange(location: 2, length: 0)
        coordinator.textViewDidChangeSelection(textView)

        #expect(viewState.selectedLocation == 2)
    }

    @MainActor
    @Test func autoPairWrapsSelectedTextAndUndoRestoresOriginalSelection() {
        let (window, textView) = makeHostedTextView()
        defer { window.isHidden = true }
        textView.text = "alpha beta"
        textView.selectedRange = NSRange(location: 6, length: 4)

        #expect(AutoPairEngine.handleInsert("(", in: textView))
        #expect(textView.text == "alpha (beta)")
        #expect(textView.selectedRange.location == 7)
        #expect(textView.selectedRange.length == 4)

        textView.undoManager?.undo()
        #expect(textView.text == "alpha beta")
        #expect(textView.selectedRange.location == 6)
        #expect(textView.selectedRange.length == 4)
    }

    @MainActor
    @Test func autoPairWrapsSelectionWithMathAndAnglePairs() {
        let (window, textView) = makeHostedTextView()
        defer { window.isHidden = true }
        textView.text = "label equation"
        textView.selectedRange = NSRange(location: 0, length: 5)

        #expect(AutoPairEngine.handleInsert("<", in: textView))
        #expect(textView.text == "<label> equation")
        #expect(textView.selectedRange.location == 1)
        #expect(textView.selectedRange.length == 5)

        textView.selectedRange = NSRange(location: 8, length: 8)
        #expect(AutoPairEngine.handleInsert("$", in: textView))
        #expect(textView.text == "<label> $equation$")
        #expect(textView.selectedRange.location == 9)
        #expect(textView.selectedRange.length == 8)
    }

    @MainActor
    @Test func editorFocusCoordinatorWaitsForAllSuppressionScopesBeforeRestoringFocus() async {
        let coordinator = EditorFocusCoordinator()
        let (window, textView) = makeHostedTextView()
        defer { window.isHidden = true }
        coordinator.register(textView)
        _ = textView.becomeFirstResponder()
        await waitUntil { textView.isFirstResponder }

        coordinator.setResignSuppressed(true)
        coordinator.setResignSuppressed(true)
        textView.suppressResignFirstResponder = false
        _ = textView.resignFirstResponder()
        #expect(!textView.isFirstResponder)

        coordinator.setResignSuppressed(false)
        await Task.yield()
        #expect(!textView.isFirstResponder)
        #expect(textView.suppressResignFirstResponder)

        coordinator.setResignSuppressed(false)
        await waitUntil { textView.isFirstResponder }
        #expect(textView.isFirstResponder)
        #expect(!textView.suppressResignFirstResponder)
    }

    @MainActor
    @Test func typstCompilerDropsIntermediateDebouncedRequests() async {
        let probe = CompileProbe()
        probe.block("first")

        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in probe.compile(source: source) },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in }
        )

        compiler.compile(source: "first", fontPaths: [], rootDir: nil)
        await waitUntil {
            probe.startedSources == ["first"]
        }

        compiler.compile(source: "second", fontPaths: [], rootDir: nil)
        compiler.compile(source: "third", fontPaths: [], rootDir: nil)

        probe.release("first")

        await waitUntil {
            probe.startedSources.count == 2 && !compiler.isCompiling
        }

        #expect(probe.startedSources == ["first", "third"])
        #expect(probe.maxConcurrent == 1)
    }

    @MainActor
    @Test func typstCompilerCompileNowReplacesPendingRequestWithoutParallelism() async {
        let probe = CompileProbe()
        probe.block("first")

        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in probe.compile(source: source) },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in }
        )

        compiler.compileNow(source: "first", fontPaths: [], rootDir: nil)
        await waitUntil {
            probe.startedSources == ["first"]
        }

        compiler.compile(source: "second", fontPaths: [], rootDir: nil)
        compiler.compileNow(source: "third", fontPaths: [], rootDir: nil)

        probe.release("first")

        await waitUntil {
            probe.startedSources.count == 2 && !compiler.isCompiling
        }

        #expect(probe.startedSources == ["first", "third"])
        #expect(probe.maxConcurrent == 1)
    }

    @MainActor
    @Test func typstCompilerCancelPreventsInFlightResultFromApplying() async {
        let probe = CompileProbe()
        probe.block("first")

        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in probe.compile(source: source) },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in }
        )

        compiler.compileNow(source: "first", fontPaths: [], rootDir: nil)
        await waitUntil {
            probe.startedSources == ["first"]
        }

        compiler.cancel()
        probe.release("first")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(!compiler.isCompiling)
        #expect(compiler.pdfData == nil)
        #expect(!compiler.compiledOnce)
    }

    @MainActor
    @Test func typstCompilerAppliesSVGPreviewWithoutRequiringPDFDocument() async {
        let compiler = TypstCompiler(
            compileWorker: { _, _, _, _ in
                .success(makePreviewArtifact(
                    pdfData: nil,
                    svgPages: [
                        TypstPreviewPage(
                            svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Preview</text></svg>",
                            widthPoints: 200,
                            heightPoints: 300
                        )
                    ]
                ))
            },
            documentBuilder: { _ in nil },
            sleep: { _ in }
        )

        compiler.compileNow(source: "= Preview", fontPaths: [], rootDir: nil)

        await waitUntil {
            compiler.compiledOnce && !compiler.isCompiling
        }

        #expect(compiler.previewArtifact?.svgPages.count == 1)
        #expect(compiler.pdfData == nil)
        #expect(compiler.pdfDocument == nil)
        #expect(compiler.pageCount == 1)
    }

    @MainActor
    @Test func typstCompilerDelaysDebouncedErrorVisibility() async {
        let compileCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { _, _, _, _ in
                compileCounter.increment()
                return .failure(.compilationFailed("temporary syntax error"))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { duration in
                if duration == Duration.seconds(1) {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        )

        compiler.compile(source: "$", fontPaths: [], rootDir: nil)

        await waitUntil {
            compileCounter.value == 1 && !compiler.isCompiling
        }
        #expect(compiler.errorMessage == nil)

        await waitUntil(timeout: .seconds(1)) {
            compiler.errorMessage == "temporary syntax error"
        }
        #expect(compiler.errorMessage == "temporary syntax error")
    }

    @MainActor
    @Test func typstCompilerSuccessfulDebouncedCompileCancelsPendingError() async {
        let compileCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in
                compileCounter.increment()
                if source == "bad" {
                    return .failure(.compilationFailed("stale error"))
                }
                return .success(makePreviewArtifact(pdfData: Data(source.utf8)))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { duration in
                if duration == Duration.seconds(1) {
                    try await Task.sleep(for: .milliseconds(400))
                }
            }
        )

        compiler.compile(source: "bad", fontPaths: [], rootDir: nil)
        await waitUntil {
            compileCounter.value == 1 && !compiler.isCompiling
        }
        #expect(compiler.errorMessage == nil)

        compiler.compile(source: "good", fontPaths: [], rootDir: nil)
        await waitUntil {
            compileCounter.value == 2 && compiler.compiledOnce && !compiler.isCompiling
        }
        try? await Task.sleep(for: .milliseconds(500))

        #expect(compiler.errorMessage == nil)
        #expect(compiler.pdfData == Data("good".utf8))
    }

    @Test func typstCompilerUsesDefaultTimeoutForSourcesWithoutUncachedPreviewPackages() throws {
        let cacheRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cachedPackage = cacheRoot
            .appendingPathComponent("preview", isDirectory: true)
            .appendingPathComponent("cetz", isDirectory: true)
            .appendingPathComponent("0.3.4", isDirectory: true)
        try FileManager.default.createDirectory(at: cachedPackage, withIntermediateDirectories: true)

        #expect(TypstCompiler.timeout(forSource: "= Plain", packageCacheDirectory: cacheRoot) == Duration.seconds(30))
        #expect(
            TypstCompiler.timeout(
                forSource: #"#import "@preview/cetz:0.3.4": canvas"#,
                packageCacheDirectory: cacheRoot
            ) == Duration.seconds(30)
        )
        #expect(
            TypstCompiler.timeout(
                forSource: #"#import "@local/cetz:0.3.4": canvas"#,
                packageCacheDirectory: cacheRoot
            ) == Duration.seconds(30)
        )
    }

    @Test func typstCompilerExtendsTimeoutForUncachedPreviewPackages() {
        let cacheRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        #expect(
            TypstCompiler.timeout(
                forSource: #"#import "@preview/cetz:0.3.4": canvas"#,
                packageCacheDirectory: cacheRoot
            ) == Duration.seconds(120)
        )
    }

    @Test func typstCompilerFindsUncachedPreviewPackagesForPrefetch() throws {
        let cacheRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let cachedPackage = cacheRoot
            .appendingPathComponent("preview", isDirectory: true)
            .appendingPathComponent("cached", isDirectory: true)
            .appendingPathComponent("1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: cachedPackage, withIntermediateDirectories: true)

        let source = """
        #import "@preview/cached:1.0.0": *
        #import "@preview/missing:2.0.0": *
        #import "@local/private:1.0.0": *
        """

        let specs = TypstCompiler.uncachedPreviewPackageSpecs(forSource: source, packageCacheDirectory: cacheRoot)
        #expect(specs == ["@preview/missing:2.0.0"])
    }

    @MainActor
    @Test func typstCompilerPrefetchFailurePreventsCompilation() async {
        let cacheRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let compileCounter = LockedCounter()
        let prefetchCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { _, _, _, _ in
                compileCounter.increment()
                return .success(makePreviewArtifact(pdfData: Data("compiled".utf8)))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in },
            packageCacheDirectory: cacheRoot,
            previewPackagePrefetcher: { specs in
                if specs == ["@preview/missing:2.0.0"] {
                    prefetchCounter.increment()
                }
                return .failure(.compilationFailed("prefetch failed"))
            }
        )

        compiler.compileNow(
            source: #"#import "@preview/missing:2.0.0": *"#,
            fontPaths: [],
            rootDir: nil
        )

        await waitUntil {
            compiler.errorMessage == "prefetch failed" && !compiler.isCompiling
        }

        #expect(prefetchCounter.value == 1)
        #expect(compileCounter.value == 0)
    }

    @MainActor
    @Test func typstCompilerUsesCompiledPreviewCacheWhenFingerprintMatches() async throws {
        let doc = makeDocument(projectID: "compiler-cache-hit")
        let cacheRoot = makeTempDirectory()
        let source = "= Cached"
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let descriptor = CompiledPreviewCacheDescriptor(
            projectID: doc.projectID,
            documentTitle: doc.title,
            entryFileName: doc.entryFileName
        )
        let store = CompiledPreviewCacheStore(rootURL: cacheRoot)
        try store.save(
            artifact: makePreviewArtifact(pdfData: Data("cached-pdf".utf8)),
            for: makeCompiledPreviewCacheInput(for: doc, source: source)
        )

        let compileCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { _, _, _, _ in
                compileCounter.increment()
                return .success(makePreviewArtifact(pdfData: Data("compiled".utf8)))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in },
            previewCacheStore: store,
            typstVersionProvider: { "1.0" }
        )

        compiler.compileNow(
            source: source,
            fontPaths: [],
            rootDir: ProjectFileManager.projectDirectory(for: doc).path,
            previewCachePolicy: .useCacheIfValid,
            previewCacheDescriptor: descriptor
        )

        await waitUntil {
            compiler.compiledOnce && !compiler.isCompiling
        }

        #expect(compileCounter.value == 0)
        #expect(compiler.pdfData == Data("cached-pdf".utf8))
    }

    @MainActor
    @Test func typstCompilerMissesCacheWhenSourceChanges() async throws {
        let doc = makeDocument(projectID: "compiler-cache-miss")
        let cacheRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= Original", for: doc)

        let descriptor = CompiledPreviewCacheDescriptor(
            projectID: doc.projectID,
            documentTitle: doc.title,
            entryFileName: doc.entryFileName
        )
        let store = CompiledPreviewCacheStore(rootURL: cacheRoot)
        try store.save(
            pdfData: Data("cached-pdf".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: "= Original")
        )

        let compileCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in
                compileCounter.increment()
                return .success(makePreviewArtifact(pdfData: Data(source.utf8)))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in },
            previewCacheStore: store,
            typstVersionProvider: { "1.0" }
        )

        compiler.compileNow(
            source: "= Updated",
            fontPaths: [],
            rootDir: ProjectFileManager.projectDirectory(for: doc).path,
            previewCachePolicy: .useCacheIfValid,
            previewCacheDescriptor: descriptor
        )

        await waitUntil {
            compiler.compiledOnce && !compiler.isCompiling
        }

        #expect(compileCounter.value == 1)
        #expect(compiler.pdfData == Data("= Updated".utf8))
    }

    @MainActor
    @Test func typstCompilerCompileNowBypassesCacheAndOverwritesStoredPreview() async throws {
        let doc = makeDocument(projectID: "compiler-bypass")
        let cacheRoot = makeTempDirectory()
        let source = "= Fresh"
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let descriptor = CompiledPreviewCacheDescriptor(
            projectID: doc.projectID,
            documentTitle: doc.title,
            entryFileName: doc.entryFileName
        )
        let store = CompiledPreviewCacheStore(rootURL: cacheRoot)
        try store.save(
            pdfData: Data("stale".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: source)
        )

        let compileCounter = LockedCounter()
        let compiler = TypstCompiler(
            compileWorker: { source, _, _, _ in
                compileCounter.increment()
                return .success(makePreviewArtifact(pdfData: Data(source.utf8)))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in },
            previewCacheStore: store,
            typstVersionProvider: { "1.0" }
        )

        compiler.compileNow(
            source: source,
            fontPaths: [],
            rootDir: ProjectFileManager.projectDirectory(for: doc).path,
            previewCachePolicy: .bypassCache,
            previewCacheDescriptor: descriptor
        )

        await waitUntil {
            compiler.compiledOnce && !compiler.isCompiling
        }

        #expect(compileCounter.value == 1)
        #expect(compiler.pdfData == Data(source.utf8))
        let cachedData = try store.loadIfValid(for: makeCompiledPreviewCacheInput(for: doc, source: source))
        #expect(cachedData == Data(source.utf8))
    }

    @MainActor
    @Test func typstCompilerFailureDoesNotOverwriteExistingCompiledPreviewCache() async throws {
        let doc = makeDocument(projectID: "compiler-failure")
        let cacheRoot = makeTempDirectory()
        let source = "= Stable"
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let descriptor = CompiledPreviewCacheDescriptor(
            projectID: doc.projectID,
            documentTitle: doc.title,
            entryFileName: doc.entryFileName
        )
        let store = CompiledPreviewCacheStore(rootURL: cacheRoot)
        try store.save(
            pdfData: Data("stable-cache".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: source)
        )

        let compiler = TypstCompiler(
            compileWorker: { _, _, _, _ in
                .failure(.compilationFailed("boom"))
            },
            documentBuilder: { _ in PDFDocument() },
            sleep: { _ in },
            previewCacheStore: store,
            typstVersionProvider: { "1.0" }
        )

        compiler.compileNow(
            source: source,
            fontPaths: [],
            rootDir: ProjectFileManager.projectDirectory(for: doc).path,
            previewCachePolicy: .bypassCache,
            previewCacheDescriptor: descriptor
        )

        await waitUntil {
            !compiler.isCompiling && compiler.errorMessage != nil
        }

        let cachedData = try store.loadIfValid(for: makeCompiledPreviewCacheInput(for: doc, source: source))
        #expect(cachedData == Data("stable-cache".utf8))
    }

    @Test func appFontLibraryImportsDeletesAndReloadsCustomFonts() throws {
        let appRoot = makeTempDirectory()
        let sourceRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let inter = sourceRoot.appendingPathComponent("Inter-Regular.otf")
        let mono = sourceRoot.appendingPathComponent("Mono.ttf")
        try Data("inter".utf8).write(to: inter)
        try Data("mono".utf8).write(to: mono)

        let library = AppFontLibrary(rootURL: appRoot)
        #expect(library.isEmpty)

        try library.importFonts(from: [mono, inter])

        #expect(library.fileNames == ["Inter-Regular.otf", "Mono.ttf"])
        #expect(FileManager.default.fileExists(atPath: FontManager.appFontsDirectory(rootURL: appRoot).appendingPathComponent("Inter-Regular.otf").path))

        library.delete(fileName: "Inter-Regular.otf")

        #expect(library.fileNames == ["Mono.ttf"])

        let reloaded = AppFontLibrary(rootURL: appRoot)
        #expect(reloaded.fileNames == ["Mono.ttf"])
        #expect(!reloaded.isEmpty)
    }

    @Test func compileFontResolverResolvesOnlyExplicitFamiliesAndPrefersProjectBeforeExternalSources() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "Alpha Sans",
                        faceName: "Regular",
                        postScriptName: "AlphaSans-Regular",
                        path: "/system/AlphaSans-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "Beta Serif",
                        faceName: "Regular",
                        postScriptName: "BetaSerif-Regular",
                        path: "/installed/BetaSerif-Regular.ttf",
                        source: .installed
                    ),
                ]
            }),
            projectFontProvider: { _ in
                [
                    AvailableCompileFont(
                        familyName: "Alpha Sans",
                        faceName: "Bold",
                        postScriptName: "AlphaSans-Bold",
                        path: "/project/AlphaSans-Bold.ttf",
                        source: .project
                    )
                ]
            },
            appFontProvider: { _ in
                [
                    AvailableCompileFont(
                        familyName: "Beta Serif",
                        faceName: "Regular",
                        postScriptName: "BetaSerif-Regular",
                        path: "/app/BetaSerif-Regular.ttf",
                        source: .app
                    )
                ]
            },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: (\"Alpha Sans\", \"Beta Serif\"))"]
            }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.families == ["Alpha Sans", "Beta Serif"])
        #expect(resolved.fontPaths == [
            "/project/AlphaSans-Bold.ttf",
            "/app/BetaSerif-Regular.ttf",
        ])
        #expect(resolved.sourcesByFamily["Alpha Sans"] == .project)
        #expect(resolved.sourcesByFamily["Beta Serif"] == .app)
    }

    @Test func compileFontResolverPrefersInstalledFontsBeforeSystemFonts() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Regular",
                        postScriptName: "PingFangSC-Regular",
                        path: "/system/PingFangSC-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Installed",
                        postScriptName: "PingFangSC-Installed",
                        path: "/installed/PingFangSC-Installed.ttf",
                        source: .installed
                    ),
                ]
            }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: \"PingFang SC\")"]
            }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.fontPaths == ["/installed/PingFangSC-Installed.ttf"])
        #expect(resolved.sourcesByFamily["PingFang SC"] == .installed)
    }

    @Test func fontManagerCompletionFamiliesOnlyUseCompileFonts() {
        let fontPaths = ["/fonts/A.otf", "/fonts/B.otf", "/fonts/C.otf", "/fonts/A-dup.otf"]
        let families = FontManager.completionFamilyNames(from: fontPaths) { path in
            switch path {
            case "/fonts/A.otf", "/fonts/A-dup.otf":
                return "Alpha Sans"
            case "/fonts/B.otf":
                return "Beta Serif"
            case "/fonts/C.otf":
                return nil
            default:
                return nil
            }
        }

        #expect(families == ["Alpha Sans", "Beta Serif"])
    }

    @Test func compileFontResolverAvailableFamiliesMergeProjectAppAndSystemCatalog() {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Regular",
                        postScriptName: "PingFangSC-Regular",
                        path: "/system/PingFangSC-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "System UI",
                        faceName: "Regular",
                        postScriptName: "SystemUI-Regular",
                        path: "/system/SystemUI-Regular.ttf",
                        source: .system
                    ),
                ]
            }),
            projectFontProvider: { _ in
                [
                    AvailableCompileFont(
                        familyName: "Project Sans",
                        faceName: "Regular",
                        postScriptName: "ProjectSans-Regular",
                        path: "/project/ProjectSans-Regular.ttf",
                        source: .project
                    )
                ]
            },
            appFontProvider: { _ in
                [
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "App Override",
                        postScriptName: "PingFangSC-App",
                        path: "/app/PingFangSC-App.ttf",
                        source: .app
                    ),
                    AvailableCompileFont(
                        familyName: "App Serif",
                        faceName: "Regular",
                        postScriptName: "AppSerif-Regular",
                        path: "/app/AppSerif-Regular.ttf",
                        source: .app
                    ),
                ]
            },
            sourceReader: { _, _ in [:] }
        )

        let families = resolver.availableFontFamilies(for: doc)

        #expect(families == ["App Serif", "PingFang SC", "Project Sans", "System UI"])
    }

    @Test func requiredFontFamilyScannerFlagsNonLiteralExpressions() {
        let scanner = RequiredFontFamilyScanner()

        let result = scanner.scan(fileContents: [
            "main.typ": """
            #let body-font = "PingFang SC"
            #set text(font: body-font)
            """
        ])

        #expect(result.families.isEmpty)
        #expect(result.unresolvedExpressions == [
            RequiredFontFamilyScanner.UnresolvedExpression(
                fileName: "main.typ",
                expression: "body-font"
            )
        ])
    }

    @Test func compileFontResolverFailsWhenExplicitFamilyCannotBeResolved() {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: { [] }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: \"Missing CJK\")"]
            }
        )

        do {
            _ = try resolver.resolveFonts(for: doc)
            Issue.record("Expected missing font resolution failure")
        } catch {
            #expect(error.localizedDescription.contains("Missing CJK"))
        }
    }

    @Test func compileFontResolverUsesImplicitSystemCJKFallbackWhenNoFontIsSpecified() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "Hiragino Sans GB",
                        faceName: "W3",
                        postScriptName: "HiraginoSansGB-W3",
                        path: "/System/Library/Fonts/Hiragino Sans GB.ttc",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Regular",
                        postScriptName: "PingFangSC-Regular",
                        path: "/system/PingFangSC-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Bold",
                        postScriptName: "PingFangSC-Semibold",
                        path: "/system/PingFangSC-Semibold.ttf",
                        source: .system
                    ),
                ]
            }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "= 标题\n没有指定字体也应该正常显示中文。"]
            },
            preferredLanguagesProvider: { ["zh-Hans"] }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.families == ["PingFang SC"])
        #expect(resolved.fontPaths.count == 2)
        #expect(resolved.fontPaths.allSatisfy { $0.contains("PingFangSC") || $0.hasPrefix("/system/") })
        #expect(resolved.sourcesByFamily["PingFang SC"] == .system)
        #expect(resolved.warnings.map(\.message).contains { $0.contains("PingFang SC") })
    }

    @Test func compileFontResolverAddsEmojiFallbackAndWarning() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Regular",
                        postScriptName: "PingFangSC-Regular",
                        path: "/system/PingFangSC-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "Apple Color Emoji",
                        faceName: "Regular",
                        postScriptName: "AppleColorEmoji",
                        path: "/system/AppleColorEmoji.ttc",
                        source: .system
                    ),
                ]
            }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: \"PingFang SC\")\nHello 😀"]
            },
            preferredLanguagesProvider: { ["zh-Hans"] }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.families == ["PingFang SC"])
        #expect(resolved.fallbackFamilies == ["Apple Color Emoji"])
        #expect(resolved.sourcesByFamily["Apple Color Emoji"] == .system)
        #expect(resolved.warnings.map(\.message).contains { $0.contains("Apple Color Emoji") })
    }

    @Test func compileFontResolverDoesNotAddLatinFallbackWhenRequestedFamilyCoversLatin() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "PingFang SC",
                        faceName: "Regular",
                        postScriptName: "PingFangSC-Regular",
                        path: "/system/PingFangSC-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "Helvetica Neue",
                        faceName: "Regular",
                        postScriptName: "HelveticaNeue",
                        path: "/system/HelveticaNeue.ttf",
                        source: .system
                    ),
                ]
            }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: \"PingFang SC\")\nHello 中文"]
            },
            preferredLanguagesProvider: { ["zh-Hans"] }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.families == ["PingFang SC"])
        #expect(!resolved.fallbackFamilies.contains("Helvetica Neue"))
        #expect(!resolved.fontPaths.contains("/system/HelveticaNeue.ttf"))
        #expect(!resolved.warnings.map(\.message).contains { $0.contains("Helvetica Neue") })
    }

    @Test func compileFontResolverAddsLatinFallbackWhenRequestedFamilyDoesNotCoverLatin() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let resolver = CompileFontResolver(
            systemCatalog: SystemFontCatalog(loader: {
                [
                    AvailableCompileFont(
                        familyName: "Fake CJK Only",
                        faceName: "Regular",
                        postScriptName: "FakeCJKOnly-Regular",
                        path: "/system/FakeCJKOnly-Regular.ttf",
                        source: .system
                    ),
                    AvailableCompileFont(
                        familyName: "Helvetica Neue",
                        faceName: "Regular",
                        postScriptName: "HelveticaNeue",
                        path: "/system/HelveticaNeue.ttf",
                        source: .system
                    ),
                ]
            }),
            projectFontProvider: { _ in [] },
            appFontProvider: { _ in [] },
            sourceReader: { _, _ in
                ["main.typ": "#set text(font: \"Fake CJK Only\")\nHello"]
            },
            preferredLanguagesProvider: { ["zh-Hans"] }
        )

        let resolved = try resolver.resolveFonts(for: doc)

        #expect(resolved.families == ["Fake CJK Only"])
        #expect(resolved.fallbackFamilies == ["Helvetica Neue"])
        #expect(resolved.fontPaths.contains { $0.contains("HelveticaNeue") })
        #expect(resolved.warnings.map(\.message).contains { $0.contains("Helvetica Neue") })
    }

    @Test func typstBridgeCompilesChineseWithRealSystemFallbackFonts() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        defer {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        let source = "= 标题\n没有指定字体也应该正常显示中文。"
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let resolver = CompileFontResolver()
        let resolved = try resolver.resolveFonts(for: doc)
        let effectiveSource = CompileFontResolver.effectiveSource(for: source, resolvedFonts: resolved)
        let result = TypstBridge.compile(
            source: effectiveSource,
            fontPaths: resolved.fontPaths,
            rootDir: ProjectFileManager.projectDirectory(for: doc).path
        )

        switch result {
        case .success(let data):
            let pdf = try #require(PDFDocument(data: data))
            #expect(pdf.pageCount > 0)
            let text = pdf.string ?? ""
            #expect(text.contains("标题"))
            #expect(text.contains("中文"))
        case .failure(let error):
            Issue.record("Expected successful Chinese compile, got: \(error.localizedDescription)")
        }
    }

    @Test func typstBridgeKeepsExplicitPingFangAheadOfBundledLatinFonts() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        defer {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        let source = "#set text(font: \"PingFang SC\")\nHello 中文"
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let resolver = CompileFontResolver(preferredLanguagesProvider: { ["zh-Hans"] })
        let resolved = try resolver.resolveFonts(for: doc)
        guard resolved.families.contains("PingFang SC") else {
            Issue.record("PingFang SC is not available on this simulator")
            return
        }

        let result = TypstBridge.compile(
            source: source,
            fontPaths: resolved.fontPaths,
            rootDir: ProjectFileManager.projectDirectory(for: doc).path
        )

        switch result {
        case .success(let data):
            let pdf = try #require(PDFDocument(data: data))
            #expect(pdf.pageCount > 0)
            let rawPDF = String(data: data, encoding: .isoLatin1) ?? ""
            #expect(rawPDF.localizedCaseInsensitiveContains("PingFang"))
            #expect(!rawPDF.localizedCaseInsensitiveContains("Libertinus"))
            #expect(!rawPDF.localizedCaseInsensitiveContains("Helvetica"))
        case .failure(let error):
            Issue.record("Expected successful PingFang compile, got: \(error.localizedDescription)")
        }
    }

    @Test func typstBridgeRendersEmojiWithAppleColorEmojiFallback() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        defer {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        let source = """
        #set page(width: 120pt, height: 120pt, margin: 12pt)
        #set text(size: 72pt)
        😀
        """
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: source, for: doc)

        let resolver = CompileFontResolver()
        let resolved = try resolver.resolveFonts(for: doc)
        guard resolved.fallbackFamilies.contains("Apple Color Emoji") else {
            Issue.record("Apple Color Emoji fallback is not available on this simulator")
            return
        }

        let result = TypstBridge.compile(
            source: source,
            fontPaths: resolved.fontPaths,
            rootDir: ProjectFileManager.projectDirectory(for: doc).path
        )

        switch result {
        case .success(let data):
            let pdf = try #require(PDFDocument(data: data))
            #expect(pdf.pageCount > 0)
            let rawPDF = String(data: data, encoding: .isoLatin1) ?? ""
            #expect(
                rawPDF.localizedCaseInsensitiveContains("AppleColorEmoji")
                    || rawPDF.localizedCaseInsensitiveContains("Apple Color Emoji")
            )
            #expect(
                rawPDF.contains("/Subtype /Image"),
                "Apple Color Emoji sbix glyphs should be emitted as image XObjects, not invisible outline text"
            )
        case .failure(let error):
            Issue.record("Expected successful emoji compile, got: \(error.localizedDescription)")
        }
    }

    @Test func completionEngineFontValuesRemainInsertable() {
        let engine = CompletionEngine()
        engine.fontFamilies = ["PingFang SC"]

        let text = "#text(font: Pi"
        let result = engine.completions(for: text, cursorOffset: text.count)

        guard case .value(_, let isQuoted, let items)? = result else {
            Issue.record("Expected font value completion")
            return
        }

        #expect(!isQuoted)
        #expect(items.map(\.label) == ["PingFang SC"])
        #expect(items.allSatisfy { $0.isInsertable })
    }

    @Test func completionEngineSupportsUtf16CursorOffsetsWhenEmojiPrecedesCursor() {
        let engine = CompletionEngine()
        engine.fontFamilies = ["PingFang SC"]
        let text = "😀 #text(font: Pi"
        let cursorOffset = (text as NSString).length

        let result = engine.completions(for: text, cursorOffset: cursorOffset)

        guard case .value(_, let isQuoted, let items)? = result else {
            Issue.record("Expected font value completion for UTF-16 cursor offsets")
            return
        }

        #expect(!isQuoted)
        #expect(items.map(\.label) == ["PingFang SC"])
    }

    @Test func completionEngineSemanticValuesRemainInsertable() throws {
        let engine = CompletionEngine()

        let result = engine.completions(for: "#text(weight: bo", cursorOffset: 16)

        guard case .value(_, _, let items)? = result else {
            Issue.record("Expected weight value completion")
            return
        }

        let bold = try #require(items.first(where: { $0.label == "bold" }))
        #expect(bold.isInsertable)
        #expect(bold.insertText == "\"bold\"")
    }

    @Test func completionEngineBibliographyStyleUsesBibliographyHints() {
        let engine = CompletionEngine()
        let text = "#bibliography(\"refs.bib\", style: ap"

        let result = engine.completions(for: text, cursorOffset: text.count)

        guard case .value(_, _, let items)? = result else {
            Issue.record("Expected bibliography style completion")
            return
        }

        #expect(items.contains(where: { $0.label == "apa" }))
        #expect(!items.contains(where: { $0.label == "italic" }))
    }

    @Test func completionEngineLoremWordsIsHintOnly() throws {
        let engine = CompletionEngine()

        let result = engine.completions(for: "#lorem(w", cursorOffset: 8)

        guard case .parameter(_, let items)? = result else {
            Issue.record("Expected lorem parameter completion")
            return
        }

        let words = try #require(items.first(where: { $0.label == "words" }))
        #expect(!words.isInsertable)
        #expect(words.insertText == nil)
    }

    @Test func zipProjectDoesNotIncludeAppFonts() throws {
        let doc = makeDocument(projectID: "tests-\(UUID().uuidString)")
        let appRoot = makeTempDirectory()
        let sourceRoot = makeTempDirectory()
        defer {
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: "main.typ", content: "= Hello", for: doc)

        let appFontSource = sourceRoot.appendingPathComponent("GlobalOnly.otf")
        try Data("global".utf8).write(to: appFontSource)
        try FontManager.importAppFont(from: appFontSource, rootURL: appRoot)

        let zipURL = try ExportManager.zipProject(for: doc)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let extractRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: extractRoot) }

        let extracted = try ZipImporter.extract(from: zipURL, to: extractRoot)

        #expect(!extracted.contains("GlobalOnly.otf"))
        #expect(FileManager.default.fileExists(atPath: extractRoot.appendingPathComponent("main.typ").path))
    }

    @Test func previewPackageCacheSnapshotListsPackagesAndTotalSize() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCachePackage(root: root, namespace: "preview", name: "touying", version: "0.6.2", files: [
            ("package.typ", Data("hello".utf8)),
            ("assets/icon.bin", Data([0x00, 0x01, 0x02]))
        ])
        try makeCachePackage(root: root, namespace: "preview", name: "charged-ieee", version: "0.1.4", files: [
            ("template.typ", Data("abc".utf8))
        ])

        let snapshot = try PreviewPackageCacheStore(rootURL: root).snapshot()

        #expect(snapshot.entries.map(\.id) == [
            "preview/charged-ieee/0.1.4",
            "preview/touying/0.6.2"
        ])
        #expect(snapshot.totalSizeInBytes == 11)
    }

    @Test func previewPackageCacheRemoveDeletesPackageAndCleansEmptyParents() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCachePackage(root: root, namespace: "preview", name: "touying", version: "0.6.2", files: [
            ("package.typ", Data("hello".utf8))
        ])

        let store = PreviewPackageCacheStore(rootURL: root)
        let entry = try #require(store.snapshot().entries.first)

        try store.remove(entry)

        let remainingSnapshot = try store.snapshot()
        #expect(remainingSnapshot.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preview").path))
    }

    @Test func previewPackageCacheClearAllLeavesEmptyRootDirectory() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCachePackage(root: root, namespace: "preview", name: "touying", version: "0.6.2", files: [
            ("package.typ", Data("hello".utf8))
        ])

        let store = PreviewPackageCacheStore(rootURL: root)
        try store.clearAll()

        #expect(FileManager.default.fileExists(atPath: root.path))
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test func compiledPreviewCacheSnapshotListsDocumentsAndTotalSize() throws {
        let root = makeTempDirectory()
        let docA = makeDocument(projectID: "cached-a")
        let docB = makeDocument(projectID: "cached-b")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: docA)
            try? ProjectFileManager.deleteProjectDirectory(for: docB)
        }

        try ProjectFileManager.createInitialProject(for: docA)
        try ProjectFileManager.createInitialProject(for: docB)
        try ProjectFileManager.writeTypFile(named: docA.entryFileName, content: "= A", for: docA)
        try ProjectFileManager.writeTypFile(named: docB.entryFileName, content: "= B", for: docB)

        let store = CompiledPreviewCacheStore(rootURL: root)
        try store.save(
            pdfData: Data("alpha".utf8),
            for: makeCompiledPreviewCacheInput(for: docA, source: "= A")
        )
        try store.save(
            pdfData: Data("beta12".utf8),
            for: makeCompiledPreviewCacheInput(for: docB, source: "= B")
        )

        let snapshot = try store.snapshot()

        #expect(Set(snapshot.entries.map(\.projectID)) == ["cached-a", "cached-b"])
        #expect(snapshot.totalSizeInBytes == 11)
    }

    @Test func compiledPreviewCacheV1PDFOnlyEntryRemainsReadableButNotLivePreviewArtifact() throws {
        let root = makeTempDirectory()
        let doc = makeDocument(projectID: "cached-v1")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= V1", for: doc)

        let store = CompiledPreviewCacheStore(rootURL: root)
        let input = makeCompiledPreviewCacheInput(for: doc, source: "= V1")
        try store.save(pdfData: Data("pdf-v1".utf8), for: input)

        #expect(try store.loadIfValid(for: input) == Data("pdf-v1".utf8))
        #expect(try store.loadArtifactIfValid(for: input) == nil)
    }

    @Test func compiledPreviewCacheV2RoundTripsPDFAndSVGPages() throws {
        let root = makeTempDirectory()
        let doc = makeDocument(projectID: "cached-v2")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= V2", for: doc)

        let store = CompiledPreviewCacheStore(rootURL: root)
        let input = makeCompiledPreviewCacheInput(for: doc, source: "= V2")
        let artifact = makePreviewArtifact(
            pdfData: Data("pdf-v2".utf8),
            svgPages: [
                TypstPreviewPage(svg: "<svg><text>1</text></svg>", widthPoints: 100, heightPoints: 120),
                TypstPreviewPage(svg: "<svg><text>2</text></svg>", widthPoints: 200, heightPoints: 240)
            ]
        )
        try store.save(artifact: artifact, for: input)

        let loaded = try #require(try store.loadArtifactIfValid(for: input))

        #expect(loaded.pdfData == artifact.pdfData)
        #expect(loaded.svgPages == artifact.svgPages)
        #expect(loaded.sourceMap == nil)
    }

    @Test func compiledPreviewCacheRemoveDeletesSingleDocumentCache() throws {
        let root = makeTempDirectory()
        let doc = makeDocument(projectID: "cached-remove")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= Remove", for: doc)

        let store = CompiledPreviewCacheStore(rootURL: root)
        try store.save(
            pdfData: Data("pdf".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: "= Remove")
        )

        let entry = try #require(store.snapshot().entries.first)
        try store.remove(entry)

        #expect(try store.snapshot().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(doc.projectID).path))
    }

    @Test func compiledPreviewCacheClearAllLeavesEmptyRootDirectory() throws {
        let root = makeTempDirectory()
        let doc = makeDocument(projectID: "cached-clear")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= Clear", for: doc)

        let store = CompiledPreviewCacheStore(rootURL: root)
        try store.save(
            pdfData: Data("pdf".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: "= Clear")
        )

        try store.clearAll()

        #expect(FileManager.default.fileExists(atPath: root.path))
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test func compiledPreviewCacheMoveUpdatesProjectIDAndTitle() throws {
        let root = makeTempDirectory()
        let doc = makeDocument(projectID: "cached-old")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= Move", for: doc)

        let store = CompiledPreviewCacheStore(rootURL: root)
        try store.save(
            pdfData: Data("pdf".utf8),
            for: makeCompiledPreviewCacheInput(for: doc, source: "= Move")
        )

        try store.moveCache(from: "cached-old", to: "cached-new", documentTitle: "Renamed")

        let entry = try #require(store.snapshot().entries.first)
        #expect(entry.projectID == "cached-new")
        #expect(entry.documentTitle == "Renamed")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cached-old").path))
    }

    @Test func compiledPreviewCacheFingerprintChangesWhenInputsChange() throws {
        let doc = makeDocument(projectID: "cached-fingerprint")
        let extraRoot = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: extraRoot)
            try? ProjectFileManager.deleteProjectDirectory(for: doc)
        }

        try ProjectFileManager.createInitialProject(for: doc)
        try ProjectFileManager.writeTypFile(named: doc.entryFileName, content: "= Fingerprint", for: doc)

        let fontURL = extraRoot.appendingPathComponent("Font.otf")
        try Data("font-data".utf8).write(to: fontURL)
        let assetURL = ProjectFileManager.projectDirectory(for: doc).appendingPathComponent("images/cover.png")
        try Data([0x01]).write(to: assetURL)

        let store = CompiledPreviewCacheStore(rootURL: makeTempDirectory())
        defer { try? FileManager.default.removeItem(at: store.rootURL!) }

        let base = try store.inputFingerprint(for: makeCompiledPreviewCacheInput(
            for: doc,
            source: "= Fingerprint",
            fontPaths: [fontURL.path],
            typstVersion: "1.0"
        ))

        let sourceChanged = try store.inputFingerprint(for: makeCompiledPreviewCacheInput(
            for: doc,
            source: "= Fingerprint changed",
            fontPaths: [fontURL.path],
            typstVersion: "1.0"
        ))
        #expect(sourceChanged != base)

        try Data([0x01, 0x02]).write(to: assetURL, options: .atomic)
        let projectChanged = try store.inputFingerprint(for: makeCompiledPreviewCacheInput(
            for: doc,
            source: "= Fingerprint",
            fontPaths: [fontURL.path],
            typstVersion: "1.0"
        ))
        #expect(projectChanged != base)

        let fontChanged = try store.inputFingerprint(for: makeCompiledPreviewCacheInput(
            for: doc,
            source: "= Fingerprint",
            fontPaths: [],
            typstVersion: "1.0"
        ))
        #expect(fontChanged != projectChanged)

        let versionChanged = try store.inputFingerprint(for: makeCompiledPreviewCacheInput(
            for: doc,
            source: "= Fingerprint",
            fontPaths: [fontURL.path],
            typstVersion: "2.0"
        ))
        #expect(versionChanged != projectChanged)
    }

    private func makeDocument(projectID: String) -> InkPondDocument {
        let doc = InkPondDocument(title: "Test", content: "")
        doc.projectID = projectID
        doc.entryFileName = "main.typ"
        doc.imageDirectoryName = "images"
        return doc
    }

    private func makeCompiledPreviewCacheInput(
        for document: InkPondDocument,
        source: String,
        fontPaths: [String] = [],
        typstVersion: String? = "1.0"
    ) -> CompiledPreviewCacheInput {
        CompiledPreviewCacheInput(
            descriptor: CompiledPreviewCacheDescriptor(
                projectID: document.projectID,
                documentTitle: document.title,
                entryFileName: document.entryFileName
            ),
            source: source,
            fontPaths: fontPaths,
            rootDir: ProjectFileManager.projectDirectory(for: document).path,
            typstVersion: typstVersion
        )
    }

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkPondTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeIsolatedDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "InkPondTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    private func makeCachePackage(
        root: URL,
        namespace: String,
        name: String,
        version: String,
        files: [(path: String, data: Data)]
    ) throws {
        let versionDir = root
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        for file in files {
            let fileURL = versionDir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: fileURL)
        }
    }

    /// Build a minimal ZIP containing STORE entries only. Sufficient for parser regression tests.
    private func makeStoredZip(entries: [(name: String, data: Data)]) -> Data {
        var localSection = Data()
        var centralSection = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let dataBytes = [UInt8](entry.data)
            offsets.append(UInt32(localSection.count))

            localSection.appendU32LE(0x0403_4B50)
            localSection.appendU16LE(20)
            localSection.appendU16LE(0)
            localSection.appendU16LE(0)
            localSection.appendU16LE(0)
            localSection.appendU16LE(0)
            localSection.appendU32LE(0)
            localSection.appendU32LE(UInt32(dataBytes.count))
            localSection.appendU32LE(UInt32(dataBytes.count))
            localSection.appendU16LE(UInt16(nameBytes.count))
            localSection.appendU16LE(0)
            localSection.append(contentsOf: nameBytes)
            localSection.append(contentsOf: dataBytes)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            let dataCount = UInt32(entry.data.count)

            centralSection.appendU32LE(0x0201_4B50)
            centralSection.appendU16LE(20)
            centralSection.appendU16LE(20)
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU32LE(0)
            centralSection.appendU32LE(dataCount)
            centralSection.appendU32LE(dataCount)
            centralSection.appendU16LE(UInt16(nameBytes.count))
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU16LE(0)
            centralSection.appendU32LE(0)
            centralSection.appendU32LE(offsets[index])
            centralSection.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(localSection.count)
        let centralSize = UInt32(centralSection.count)
        var eocd = Data()
        eocd.appendU32LE(0x0605_4B50)
        eocd.appendU16LE(0)
        eocd.appendU16LE(0)
        eocd.appendU16LE(UInt16(entries.count))
        eocd.appendU16LE(UInt16(entries.count))
        eocd.appendU32LE(centralSize)
        eocd.appendU32LE(centralOffset)
        eocd.appendU16LE(0)

        return localSection + centralSection + eocd
    }

    private func makeTarGz(entries: [(name: String, data: Data)]) throws -> Data {
        try gzip(makeTar(entries: entries))
    }

    private func makeTar(entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()

        for entry in entries {
            let dataBytes = [UInt8](entry.data)
            var header = [UInt8](repeating: 0, count: 512)

            writeTarString(entry.name, to: &header, offset: 0, length: 100)
            writeTarOctal(0o644, to: &header, offset: 100, length: 8)
            writeTarOctal(0, to: &header, offset: 108, length: 8)
            writeTarOctal(0, to: &header, offset: 116, length: 8)
            writeTarOctal(dataBytes.count, to: &header, offset: 124, length: 12)
            writeTarOctal(0, to: &header, offset: 136, length: 12)
            header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
            header[156] = 48
            writeTarString("ustar", to: &header, offset: 257, length: 6)
            writeTarString("00", to: &header, offset: 263, length: 2)

            let checksum = header.reduce(0) { $0 + Int($1) }
            writeTarChecksum(checksum, to: &header, offset: 148, length: 8)

            archive.append(contentsOf: header)
            archive.append(contentsOf: dataBytes)

            let remainder = dataBytes.count % 512
            if remainder != 0 {
                archive.append(Data(repeating: 0, count: 512 - remainder))
            }
        }

        archive.append(Data(repeating: 0, count: 1024))
        return archive
    }

    private func gzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunkSize = 16_384
        let inputCount = input.count

        let deflateResult: Int32 = input.withUnsafeMutableBytes { inputBuffer in
            guard let inputBaseAddress = inputBuffer.baseAddress else {
                return Z_BUF_ERROR
            }

            stream.next_in = inputBaseAddress.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(inputCount)

            var status: Int32 = Z_OK

            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let chunkCount = chunk.count
                status = chunk.withUnsafeMutableBytes { outputBuffer in
                    guard let outputBaseAddress = outputBuffer.baseAddress else {
                        return Z_BUF_ERROR
                    }

                    stream.next_out = outputBaseAddress.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkCount)

                    let result = deflate(&stream, Z_FINISH)
                    let produced = chunkCount - Int(stream.avail_out)
                    if produced > 0 {
                        let producedBytes = UnsafeBufferPointer(
                            start: outputBaseAddress.assumingMemoryBound(to: UInt8.self),
                            count: produced
                        )
                        output.append(contentsOf: producedBytes)
                    }
                    return result
                }
            } while status == Z_OK

            return status
        }

        guard deflateResult == Z_STREAM_END else {
            throw CocoaError(.coderInvalidValue)
        }

        return output
    }

    private func writeTarString(_ value: String, to header: inout [UInt8], offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(max(0, length - 1)))
        guard !bytes.isEmpty else { return }
        header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private func writeTarOctal(_ value: Int, to header: inout [UInt8], offset: Int, length: Int) {
        let octal = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - octal.count - 1)) + octal
        writeTarString(padded, to: &header, offset: offset, length: length)
    }

    private func writeTarChecksum(_ value: Int, to header: inout [UInt8], offset: Int, length: Int) {
        let octal = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - octal.count - 2)) + octal
        let bytes = Array(padded.utf8.prefix(max(0, length - 2)))
        if !bytes.isEmpty {
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        header[offset + max(0, length - 2)] = 0
        header[offset + max(0, length - 1)] = 32
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10),
        condition: @escaping () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    @MainActor
    private func makeHostedTextView() -> (window: UIWindow, textView: TypstTextView) {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = UIViewController()
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        let textView = TypstTextView()
        textView.frame = viewController.view.bounds
        viewController.view.addSubview(textView)
        return (window, textView)
    }

}

private func isImageKind(_ kind: FileKind?) -> Bool {
    switch kind {
    case .image, .vector, .pdf:
        return true
    case .directory, .typ, .text, .bibliography, .data, .configuration, .font, .archive, .other, .none:
        return false
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

private final class CompileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var blockers: [String: DispatchSemaphore] = [:]
    private var activeCount = 0
    private var maxActiveCount = 0

    var startedSources: [String] {
        lock.withLock { started }
    }

    var maxConcurrent: Int {
        lock.withLock { maxActiveCount }
    }

    func block(_ source: String) {
        lock.withLock {
            blockers[source] = DispatchSemaphore(value: 0)
        }
    }

    func release(_ source: String) {
        let blocker = lock.withLock { blockers.removeValue(forKey: source) }
        blocker?.signal()
    }

    func compile(source: String) -> Result<TypstPreviewArtifact, TypstBridgeError> {
        let blocker = lock.withLock { () -> DispatchSemaphore? in
            started.append(source)
            activeCount += 1
            maxActiveCount = max(maxActiveCount, activeCount)
            return blockers[source]
        }

        blocker?.wait()

        lock.withLock {
            activeCount -= 1
        }
        return .success(makePreviewArtifact(pdfData: Data(source.utf8)))
    }
}

private extension Data {
    mutating func appendU16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendU32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
