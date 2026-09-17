#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import InkPond

@Suite(.serialized)
@MainActor
struct EditorAssetTransactionTests {
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func files(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { $0.contains("image-") }.sorted()
    }

    @Test func importCommitsUniqueBytesAndOneUndoStep() async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let destination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 7), for: "main.typ"))
            await editor.importImage(from: .rawData(png(), suggestedFileName: "keep.png"), destination: destination).value
            let paths = files(h.root)
            #expect(paths.count == 1)
            let path = try #require(paths.first)
            #expect(editor.editorText.contains(path))
            #expect(UIImage(data: try Data(contentsOf: h.root.appendingPathComponent(path))) != nil)
            let history = destination.session.editorUndoHistory
            history.canReplay = { true }
            #expect(history.canUndo)
            history.undo()
            #expect(editor.editorText == "initial")
            #expect(!history.canUndo)
            history.redo()
            #expect(editor.editorText.contains(path))
            #expect(files(h.root) == paths) // Redo references original bytes, never duplicates them.
        }
    }

    @Test(arguments: [false, true], [false, true])
    func overlappingAssetTasksCompleteSecondFirstWithOneUndoStep(firstIsRichPaste: Bool, secondIsRichPaste: Bool) async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let firstEntered = AssetGate(), firstRelease = AssetGate()
            let secondEntered = AssetGate(), secondRelease = AssetGate()
            var firstDestination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 7), for: "main.typ"))
            var secondDestination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 7), for: "main.typ"))
            #expect(firstDestination.session === secondDestination.session)
            #expect(firstDestination.revision == secondDestination.revision)
            let bytes = png()
            firstDestination.loadDataForTesting = { _ in
                await firstEntered.open(); await firstRelease.wait(); return bytes
            }
            secondDestination.loadDataForTesting = { _ in
                await secondEntered.open(); await secondRelease.wait(); return bytes
            }

            let firstTask = firstIsRichPaste
                ? editor.handleRichPaste([.text("stale-prefix"), .imageData(bytes, suggestedFileName: "same.png"), .text("stale-suffix")], destination: firstDestination)
                : editor.importImage(from: .rawData(bytes, suggestedFileName: "same.png"), destination: firstDestination)
            await firstEntered.wait()
            let secondTask = secondIsRichPaste
                ? editor.handleRichPaste([.text("accepted-prefix"), .imageData(bytes, suggestedFileName: "same.png"), .text("accepted-suffix")], destination: secondDestination)
                : editor.importImage(from: .rawData(bytes, suggestedFileName: "same.png"), destination: secondDestination)
            await secondEntered.wait()
            #expect(editor.editorText == "initial")
            #expect(files(h.root).isEmpty)
            #expect(!firstDestination.session.editorUndoHistory.canUndo)

            // Both real operations captured the same revision; only the second may commit.
            await secondRelease.open(); await secondTask.value
            let acceptedText = editor.editorText
            let acceptedPaths = files(h.root)
            let acceptedBytes = acceptedPaths.compactMap { try? Data(contentsOf: h.root.appendingPathComponent($0)) }
            let acceptedToast = editor.imageImportToast
            #expect(acceptedText != "initial")
            #expect(acceptedPaths.count == 1)
            #expect(editor.imageImportError == nil)
            if secondIsRichPaste {
                #expect(acceptedText.hasPrefix("accepted-prefix"))
                #expect(acceptedText.hasSuffix("accepted-suffix"))
            }

            await firstRelease.open(); await firstTask.value
            #expect(editor.editorText == acceptedText)
            #expect(files(h.root) == acceptedPaths)
            #expect(editor.imageImportError == nil)
            // The real 1.8s toast dismissal may run while parallel tests yield.
            // A stale completion may not replace it with another request's toast.
            #expect(editor.imageImportToast == nil || editor.imageImportToast == acceptedToast)
            let path = try #require(acceptedPaths.first)
            let installedBytes = try Data(contentsOf: h.root.appendingPathComponent(path))
            let originalBytes = try #require(acceptedBytes.first)
            #expect(installedBytes == originalBytes)
            #expect(UIImage(data: installedBytes) != nil)
            #expect(acceptedText.components(separatedBy: path).count == 2)
            #expect(!acceptedText.contains("stale-prefix"))
            #expect(!acceptedText.contains("stale-suffix"))

            let history = firstDestination.session.editorUndoHistory
            history.canReplay = { true }
            #expect(history.canUndo)
            history.undo()
            #expect(editor.editorText == "initial")
            #expect(!history.canUndo)
            history.redo()
            #expect(editor.editorText == acceptedText)
            #expect(files(h.root) == acceptedPaths)
            #expect(try Data(contentsOf: h.root.appendingPathComponent(path)) == installedBytes)
        }
    }

    @Test func richPasteSwitchCommitsToOriginWithoutWrongToast() async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let entered = AssetGate(), release = AssetGate()
            var destination = try #require(editor.captureAssetDestination(at: NSRange(location: 7, length: 0), for: "main.typ"))
            let bytes = png()
            destination.loadDataForTesting = { _ in
                await entered.open(); await release.wait(); return bytes
            }
            let origin = destination.session
            let task = editor.handleRichPaste([.text("prefix"), .imageData(bytes, suggestedFileName: "x.png"), .text("suffix")], destination: destination)
            await entered.wait()
            #expect(editor.loadFile(named: "B.typ"))
            let other = editor.documentSession
            await release.open(); await task.value
            #expect(origin.editorText.hasPrefix("initialprefix"))
            #expect(origin.editorText.hasSuffix("suffix"))
            #expect(other.editorText == "B on disk")
            #expect(!other.editorUndoHistory.canUndo)
            #expect(origin.editorUndoHistory.canUndo)
            #expect(editor.imageImportToast == nil)
            #expect(editor.imageImportError == nil)
            #expect(files(h.root).count == 1)
        }
    }

    @Test(arguments: ["revision", "cancel", "load", "attachment", "failure", "staleFailure"])
    func suspendedImportRejectsObsoleteOrFailedWork(reason: String) async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let entered = AssetGate(), release = AssetGate()
            var destination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 0), for: "main.typ"))
            let bytes = png()
            destination.loadDataForTesting = { _ in
                await entered.open(); await release.wait()
                if reason == "failure" || reason == "staleFailure" { throw CocoaError(.fileReadNoSuchFile) }
                return bytes
            }
            let task = editor.importImage(from: .rawData(bytes, suggestedFileName: nil), destination: destination)
            await entered.wait()
            switch reason {
            case "revision", "staleFailure": editor.editorText = "new revision"
            case "cancel": task.cancel()
            case "load": editor.fileLoadToken = UUID()
            case "attachment":
                editor.closeEditorOnDisappear()
                await editor.projectCloseTask?.value
                let reopened = try AssetEditorHost(document: h.document, root: h.root)
                await reopened.mount()
                #expect(reopened.editor!.editorText == "initial")
                reopened.unmount()
            default: break
            }
            await release.open(); await task.value
            #expect(files(h.root).isEmpty)
            #expect(editor.editorText == (["revision", "staleFailure"].contains(reason) ? "new revision" : "initial"))
            #expect(!destination.session.editorUndoHistory.canUndo)
            #expect(editor.imageImportToast == nil)
            #expect((editor.imageImportError != nil) == (reason == "failure"))
        }
    }

    @Test func failedSecondInstallRollsBackOnlyOwnedBytes() async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let destination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 0), for: "main.typ"))
            let transaction = EditorAssetTransaction(destination: destination)
            let first = transaction.append(data: png(), extension: "png")
            let second = transaction.append(data: png(), extension: "png")
            transaction.append(text: "must not insert")
            let collision = h.root.appendingPathComponent(second)
            try FileManager.default.createDirectory(at: collision.deletingLastPathComponent(), withIntermediateDirectories: true)
            let preserved = Data("preexisting bytes".utf8)
            try preserved.write(to: collision)
            do {
                try transaction.commit()
                Issue.record("Exclusive install unexpectedly replaced an existing file")
            } catch { }
            #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent(first).path))
            #expect(try Data(contentsOf: collision) == preserved)
            #expect(editor.editorText == "initial")
            #expect(!destination.session.editorUndoHistory.canUndo)
        }
    }

    @Test func richPasteReadFailureLeavesNoPartialAssetsOrText() async throws {
        try await withAssetEditor { h in
            let editor = h.editor!
            let destination = try #require(editor.captureAssetDestination(at: NSRange(location: 0, length: 7), for: "main.typ"))
            let preserved = h.root.appendingPathComponent("keep.png")
            let bytes = png()
            try bytes.write(to: preserved)
            await editor.handleRichPaste([.text("before"), .imageData(bytes, suggestedFileName: "keep.png"), .imageData(Data(), suggestedFileName: "invalid.png")], destination: destination).value
            #expect(editor.editorText == "initial")
            #expect(files(h.root).isEmpty)
            #expect(try Data(contentsOf: preserved) == bytes)
            #expect(!destination.session.editorUndoHistory.canUndo)
            #expect(editor.imageImportError != nil)
            #expect(editor.imageImportToast == nil)
        }
    }
}

private actor AssetGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class AssetEditorHost {
    let document: InkPondDocument
    let root: URL
    let container: ModelContainer
    let fonts: AppFontLibrary
    var editor: DocumentEditorView?
    var controller: UIViewController?
    var window: UIWindow?
    var disappearance: CheckedContinuation<Void, Never>?

    init(document: InkPondDocument, root: URL) throws {
        self.document = document
        self.root = root
        container = try ModelContainer(for: InkPondDocument.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        fonts = AppFontLibrary(rootURL: root.appendingPathComponent("test-fonts"))
    }

    func mount(usingLifecycle: Bool = false, usingDisappearance: Bool = false) async {
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var view = DocumentEditorView(document: document)
            view.saveTestUsesLifecycle = usingLifecycle
            view.saveTestUsesDisappearance = usingDisappearance
            view.saveTestDidDisappear = { [weak self] in
                self?.disappearance?.resume()
                self?.disappearance = nil
            }
            view.saveTestDebounce = {} // No wall-clock delay; writer gates control ordering.
            view.saveTestProbe = { [weak self] mounted in
                guard let self, self.editor == nil else { return }
                self.editor = mounted
                if !usingLifecycle {
                    mounted.currentFileName = "main.typ"
                    mounted.editorText = "initial"
                    mounted.lastPersistedText = "initial"
                    mounted.activateTab(relativePath: "main.typ", kind: ProjectFileManager.fileKind(for: "main.typ", imageDirectoryName: document.imageDirectoryName))
                    mounted.documentOpenSessionID = UUID().uuidString
                }
                ready.resume()
            }
            let host = UIHostingController(rootView: view
                .modelContainer(container)
                .environment(fonts)
                .environment(ThemeManager())
                .environment(EditorFontSettings()))
            controller = host
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            self.window = window
            window.rootViewController = host
            window.isHidden = false
            host.view.layoutIfNeeded()
        }
    }

    // Wait for production appearance work, not an arbitrary run-loop delay.
    func finishAppearance() async {
        await editor?.projectLeaseTask?.value
    }

    func disk(_ path: String = "main.typ") throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// UIKit appearance removal drives the same SwiftUI onDisappear action as production.
    func detach() async {
        await withCheckedContinuation { continuation in
            disappearance = continuation
            controller?.beginAppearanceTransition(false, animated: false)
            controller?.endAppearanceTransition()
            window?.isHidden = true
            window?.rootViewController = nil
        }
        controller = nil
        window = nil
        editor = nil
    }

    func unmount() {
        // Appearance-enabled hosts start real ancillary services; stop those without
        // introducing an extra close/handoff into the ordering under test.
        editor?.stopObservingFailedClose()
        editor?.projectLeaseTask?.cancel()
        editor?.fontFamilyRefreshTask?.cancel()
        editor?.positionRestoreDismissTask?.cancel()
        editor?.positionSyncTask?.cancel()
        editor?.previewStatsTask?.cancel()
        editor?.stopConflictMonitoring()
        editor?.compiler.cancel()
        window?.isHidden = true
        window?.rootViewController = nil
        controller = nil
        window = nil
        editor = nil
    }
}

@MainActor
private func withAssetEditor(_ body: @MainActor (AssetEditorHost) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("M2D-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let document = InkPondDocument(title: "M2-A save characterization")
    document.projectID = "M2D-\(UUID().uuidString)"
    document.entryFileName = "main.typ"
    let metadata = try ProjectReliabilityPaths.privateMetadataRoot(projectID: document.stableProjectID)
    defer {
        BookmarkManager.stopAccessing(document.projectID)
        BookmarkManager.removeBookmark(projectID: document.projectID)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: metadata)
    }
    try Data("initial".utf8).write(to: root.appendingPathComponent("main.typ"))
    try Data("B on disk".utf8).write(to: root.appendingPathComponent("B.typ"))
    try BookmarkManager.saveBookmark(for: root, projectID: document.projectID)
    let host = try AssetEditorHost(document: document, root: root)
    await host.mount()
    let lease = try await ProjectWritableLeaseCoordinator.shared.acquire(projectID: document.stableProjectID)
    host.editor!.projectWritableLease = lease
    host.editor!.projectAccessResolved = true
    var failure: Error?
    do { try await body(host) } catch { failure = error }
    let sessions = host.editor.map { Array($0.workspace.sessions.values) } ?? []
    for session in sessions { session.saveTask?.cancel() }
    for session in sessions { await session.saveTask?.value }
    host.editor?.toastDismissTask?.cancel()
    await host.editor?.projectCloseTask?.value
    await ProjectReliabilityWriterRegistry.shared.close(projectID: document.stableProjectID, rootURL: root)
    EditorFailedCloseStore.shared.remove(for: document.stableProjectID, lease: lease)
    await lease.release()
    for session in sessions { DocumentSessionRegistry.shared.release(session) }
    host.unmount()
    if let failure { throw failure }
}
#endif
