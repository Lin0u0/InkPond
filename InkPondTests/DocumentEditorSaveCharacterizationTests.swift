#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import InkPond

// M2-A production-path regressions, first executed against unchanged main behavior.
// No fake save state machine: every operation uses mounted editor State.
@Suite(.serialized)
@MainActor
struct DocumentEditorSaveCharacterizationTests {
    @Test func delayedOldAutosaveCannotOverwriteFlush() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let entered = SaveCheckpoint()
            let release = SaveCheckpoint()
            defer { Task { await release.open() } }
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(before: { request in
                await requests.append(request)
                if request.data == Data("old autosave".utf8) {
                    await entered.open()
                    await release.wait()
                }
            })
            editor.editorText = "old autosave"
            editor.scheduleSave(content: editor.editorText, for: "main.typ")
            let oldTask = editor.saveTask
            await entered.wait()
            editor.editorText = "new flush"
            #expect(await editor.flushPendingSave())
            #expect(try h.disk() == "new flush")
            await release.open()
            await oldTask?.value
            #expect(try h.disk() == "new flush") // Real registry cancellation must reject the delayed old request.
            #expect(editor.editorText == "new flush")
            #expect(editor.lastPersistedText == "new flush")
            #expect((editor.editorText != editor.lastPersistedText) == false)
            expectReceipt(editor, host: h, content: "new flush")
            requests.expect(h, paths: ["main.typ", "main.typ"], contents: ["old autosave", "new flush"])
        }
    }

    @Test func typingAfterDiskBeforeFlushAcknowledgementStaysDirty() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let written = SaveCheckpoint()
            let ack = SaveCheckpoint()
            defer { Task { await ack.open() } }
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(after: { request in
                await requests.append(request)
                await written.open()
                await ack.wait()
            })
            editor.editorText = "captured A"
            let flush = Task { await editor.flushPendingSave() }
            await written.wait()
            #expect(try h.disk() == "captured A")
            editor.editorText = "typed during flush"
            await ack.open()
            #expect(await flush.value == false) // A close/export guard must not accept newer unsaved edits.
            #expect(try h.disk() == "captured A")
            #expect(editor.lastPersistedText == "captured A")
            #expect(editor.editorText != editor.lastPersistedText)
            expectReceipt(editor, host: h, content: "captured A")
            requests.expect(h, paths: ["main.typ"], contents: ["captured A"])
        }
    }

    @Test func immediateSaveAcknowledgementMustNotMutateDifferentLoadedFile() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let written = SaveCheckpoint()
            let ack = SaveCheckpoint()
            defer { Task { await ack.open() } }
            let requests = SaveRequests()
            let originalLoadToken = editor.fileLoadToken
            let lifecycle = editor.projectLifecycleGeneration
            let session = editor.documentOpenSessionID
            await editor.backgroundFileWriter.setCheckpoints(after: { request in
                await requests.append(request)
                await written.open()
                await ack.wait()
            })
            editor.editorText = "captured A"
            let save = Task { await editor.persistCurrentFileImmediately(content: editor.editorText) }
            await written.wait()
            #expect(try h.disk() == "captured A")
            // Deliberate load-boundary mutation, not a replacement save implementation.
            editor.currentFileName = "B.typ"
            editor.editorText = "B on disk"
            editor.lastPersistedText = "B on disk"
            editor.fileLoadToken = UUID()
            let loadedBToken = editor.fileLoadToken
            await ack.open()
            #expect(await save.value)
            #expect(try h.disk() == "captured A")
            #expect(try h.disk("B.typ") == "B on disk")
            #expect(editor.currentFileName == "B.typ")
            #expect(editor.editorText == "B on disk")
            #expect(editor.lastPersistedText == "B on disk")
            #expect((editor.editorText != editor.lastPersistedText) == false)
            #expect(loadedBToken != originalLoadToken)
            #expect(editor.lastSaveReceipt == nil)
            #expect(editor.fileLoadToken == loadedBToken)
            #expect(editor.projectLifecycleGeneration == lifecycle)
            #expect(editor.documentOpenSessionID == session)
            requests.expect(h, paths: ["main.typ"], contents: ["captured A"])
        }
    }

    @Test func cancellationAfterWriteReturnsActualDiskOutcome() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let written = SaveCheckpoint()
            let ack = SaveCheckpoint()
            defer { Task { await ack.open() } }
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(after: { request in
                await requests.append(request)
                await written.open()
                await ack.wait() // Intentionally non-cancellation-aware: disk already committed.
            })
            editor.editorText = "committed despite cancellation"
            let save = Task { await editor.persistCurrentFileImmediately(content: editor.editorText) }
            await written.wait()
            #expect(try h.disk() == editor.editorText)
            save.cancel()
            await ack.open()
            #expect(await save.value)
            #expect(try h.disk() == "committed despite cancellation")
            #expect(editor.lastPersistedText == editor.editorText)
            #expect((editor.editorText != editor.lastPersistedText) == false)
            #expect(editor.fileSaveError == nil)
            expectReceipt(editor, host: h, content: "committed despite cancellation")
            requests.expect(h, paths: ["main.typ"], contents: ["committed despite cancellation"])
        }
    }

    @Test func revertingDuringCommittedAutosaveMustNotLeaveDiskDifferentButClean() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let written = SaveCheckpoint()
            let ack = SaveCheckpoint()
            defer { Task { await ack.open() } }
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(after: { request in
                await requests.append(request)
                if request.data == Data("transient edit".utf8) {
                    await written.open()
                    await ack.wait()
                }
            })
            editor.editorText = "transient edit"
            editor.scheduleSave(content: editor.editorText, for: "main.typ")
            let old = editor.saveTask
            await written.wait()
            #expect(try h.disk() == "transient edit")
            editor.editorText = "initial"
            editor.scheduleSave(content: editor.editorText, for: "main.typ")
            let revert = editor.saveTask
            await ack.open()
            await old?.value
            await revert?.value
            #expect(try h.disk() == "initial")
            #expect(editor.editorText == "initial")
            #expect(editor.lastPersistedText == "initial")
            #expect(editor.editorText == editor.lastPersistedText)
            requests.expect(h, paths: ["main.typ", "main.typ"], contents: ["transient edit", "initial"])
        }
    }

    @Test func failedFlushPreservesDirtyTextAndCanRetry() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(before: { request in
                await requests.append(request)
                throw CocoaError(.fileWriteOutOfSpace)
            })
            editor.editorText = "retry me"
            #expect(await editor.flushPendingSave() == false)
            #expect(try h.disk() == "initial")
            #expect(editor.lastPersistedText == "initial")
            #expect(editor.editorText != editor.lastPersistedText)
            #expect(editor.fileSaveError != nil)
            await editor.backgroundFileWriter.setCheckpoints(before: { request in await requests.append(request) })
            #expect(await editor.flushPendingSave())
            #expect(try h.disk() == "retry me")
            #expect((editor.editorText != editor.lastPersistedText) == false)
            requests.expect(h, paths: ["main.typ", "main.typ"], contents: ["retry me", "retry me"])
        }
    }

    @Test func failedDisappearCloseMustKeepWritableLeaseForRetry() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(before: { request in
                await requests.append(request)
                throw CocoaError(.fileWriteOutOfSpace)
            })
            editor.editorText = "unsaved close"
            editor.closeEditorOnDisappear() // Exact action used by production .onDisappear.
            let close = editor.projectCloseTask
            await close?.value
            #expect(try h.disk() == "initial")
            #expect(editor.editorText == "unsaved close")
            #expect(editor.editorText != editor.lastPersistedText)
            #expect(editor.fileSaveError != nil)
            #expect(editor.projectWritableLease != nil)
            await editor.backgroundFileWriter.setCheckpoints(before: { request in await requests.append(request) })
            #expect(await editor.flushPendingSave())
            #expect(try h.disk() == "unsaved close")
            #expect((editor.editorText != editor.lastPersistedText) == false)
            requests.expect(h, paths: ["main.typ", "main.typ"], contents: ["unsaved close", "unsaved close"])
        }
    }

    @Test func failedCloseDraftSurvivesUnmountAndIsRetriedByFreshEditor() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            await old.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            old.editorText = "retained after view destruction"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            h.unmount()
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let editor = fresh.editor!
            #expect(editor.restoreFailedCloseIfAvailable())
            #expect(editor.editorText == "retained after view destruction")
            #expect(editor.lastPersistedText == "initial")
            #expect(editor.editorText != editor.lastPersistedText)
            #expect(try h.disk() == "initial")
            #expect(editor.projectWritableLease != nil)
            #expect(editor.restoreFailedCloseIfAvailable() == false)
            #expect(await editor.flushPendingSave())
            #expect(try h.disk() == "retained after view destruction")
            #expect(editor.editorText == editor.lastPersistedText)
            #expect(editor.lastSaveReceipt?.projectID == h.document.stableProjectID)
            #expect(editor.lastSaveReceipt?.fileName == "main.typ")
            #expect(editor.lastSaveReceipt?.loadToken == editor.fileLoadToken)
            #expect(editor.lastSaveReceipt?.lifecycle == editor.projectLifecycleGeneration)
            #expect(editor.lastSaveReceipt?.sequence == editor.saveGeneration)
        }
    }

    @Test func revertedFailedCloseMustRewriteEqualBaselineAfterLateAutosaveAcknowledgement() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let written = SaveCheckpoint()
            let acknowledge = SaveCheckpoint()
            defer { Task { await acknowledge.open() } }
            await old.backgroundFileWriter.setCheckpoints(before: { request in
                if request.data == Data("initial".utf8) { throw CocoaError(.fileWriteOutOfSpace) }
            }, after: { request in
                if request.data == Data("transient before close".utf8) {
                    await written.open()
                    await acknowledge.wait()
                }
            })
            old.editorText = "transient before close"
            old.scheduleSave(content: old.editorText, for: "main.typ")
            let autosave = old.saveTask
            await written.wait()
            #expect(try h.disk() == "transient before close")
            old.editorText = "initial"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            #expect(old.fileSaveError != nil)
            #expect(old.lastPersistedText == "initial")
            #expect(old.lastSaveReceipt == nil)
            // The value-type retained draft already exists before this old receipt arrives.
            await acknowledge.open()
            await autosave?.value
            #expect(old.recoveryWriteSequenceFloor != nil)
            #expect(try h.disk() == "transient before close")
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount(usingLifecycle: true)
            await fresh.finishAppearance()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.editorText == "initial")
            #expect(recovered.lastSaveReceipt == nil)
            // Equal baseline strings must not authorize close while actual bytes differ.
            let requests = SaveRequests()
            await recovered.backgroundFileWriter.setCheckpoints(before: { request in await requests.append(request) })
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "initial")
            #expect(recovered.editorText == recovered.lastPersistedText)
            requests.expect(h, paths: ["main.typ"], contents: ["initial"])
            expectReceipt(recovered, host: h, content: "initial")
        }
    }

    @Test func receiptFromBeforeFailedCloseCannotActAfterTransfer() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let written = SaveCheckpoint()
            let acknowledge = SaveCheckpoint()
            defer { Task { await acknowledge.open() } }
            await old.backgroundFileWriter.setCheckpoints(before: { request in
                if request.data == Data("draft".utf8) { throw CocoaError(.fileWriteOutOfSpace) }
            }, after: { _ in
                await written.open()
                await acknowledge.wait()
            })
            // A real committed write whose receipt will look clean to the origin.
            let earlier = Task { await old.persistCurrentFileImmediately(content: "initial", forceWrite: true) }
            await written.wait()
            old.editorText = "draft"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            #expect(old.recoveryWriteSequenceFloor != nil)
            #expect(old.fileSaveError != nil)

            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            #expect(recovered.editorText == "draft")
            #expect(old.projectWritableLease == nil)
            #expect(old.lastSaveReceipt == nil)
            // Deliver the actual writer completion only after exclusive handoff.
            await acknowledge.open()
            #expect(await earlier.value) // Committed bytes remain a truthful outcome.
            #expect(old.lastSaveReceipt == nil)
            #expect(recovered.recoveryWriteSequenceFloor != nil)
            #expect(recovered.lastSaveReceipt == nil)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "draft")
            #expect(recovered.recoveryWriteSequenceFloor == nil)
            expectReceipt(recovered, host: h, content: "draft")
        }
    }

    @Test func recoveredLeaseMustExcludeOriginalViewOnReappearanceAndClose() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            await old.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            old.editorText = "transferred draft"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            #expect(try h.disk() == "initial")
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount(usingLifecycle: true)
            await fresh.finishAppearance()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.editorText == "transferred draft")
            #expect(recovered.editorText != recovered.lastPersistedText)
            #expect(recovered.projectWritableLease != nil)
            #expect(recovered.lastSaveReceipt == nil)
            old.openEditorOnAppear() // Retained SwiftUI State reappears after the store was taken.
            await old.projectLeaseTask?.value
            #expect(old.projectWritableLease == nil)
            await old.backgroundFileWriter.setCheckpoints()
            old.editorText = "stale owner's write"
            #expect(await old.flushPendingSave() == false)
            #expect(try h.disk() == "initial")
            #expect(old.editorText != old.lastPersistedText)
            #expect(old.lastSaveReceipt == nil)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "transferred draft")
            #expect(recovered.editorText == recovered.lastPersistedText)
            expectReceipt(recovered, host: h, content: "transferred draft")
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            #expect(try h.disk() == "transferred draft")
            // Closing the obsolete view must not release the recovered editor's authority.
            switch await ProjectWritableLeaseCoordinator.shared.open(projectID: h.document.stableProjectID) {
            case .readOnly: break
            case .writable(let unexpected):
                Issue.record("Old view close released the recovered editor's exclusive lease")
                await unexpected.release()
            }
            #expect(recovered.editorText == recovered.lastPersistedText)
            expectReceipt(recovered, host: h, content: "transferred draft")
        }
    }

    @Test func freshAppearanceBeforeCloseFailureMustReceiveLaterDraftWithoutReappearing() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let closing = SaveCheckpoint()
            let failClose = SaveCheckpoint()
            defer { Task { await failClose.open() } }
            await old.backgroundFileWriter.setCheckpoints(before: { _ in
                await closing.open()
                await failClose.wait()
                throw CocoaError(.fileWriteOutOfSpace)
            })
            old.editorText = "draft published after fresh appearance"
            old.closeEditorOnDisappear()
            let close = old.projectCloseTask
            await closing.wait()
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount(usingLifecycle: true)
            await fresh.finishAppearance()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.projectWritableLease == nil)
            #expect(try h.disk() == "initial")
            #expect(recovered.lastSaveReceipt == nil)
            await failClose.open()
            await close?.value // Failure publication completed; no manual restore or second appearance.
            await fresh.finishAppearance()
            #expect(recovered.editorText == "draft published after fresh appearance")
            #expect(recovered.editorText != recovered.lastPersistedText)
            #expect(recovered.projectWritableLease != nil)
            #expect(try h.disk() == "initial")
            #expect(recovered.lastSaveReceipt == nil)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "draft published after fresh appearance")
            #expect(recovered.editorText == recovered.lastPersistedText)
            expectReceipt(recovered, host: h, content: "draft published after fresh appearance")
        }
    }

    @Test func delayedAcknowledgementCannotReplaceNewerReceipt() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let written = SaveCheckpoint()
            let ack = SaveCheckpoint()
            defer { Task { await ack.open() } }
            await editor.backgroundFileWriter.setCheckpoints(after: { request in
                if request.data == Data("first".utf8) {
                    await written.open()
                    await ack.wait()
                }
            })
            editor.editorText = "first"
            let first = Task { await editor.persistCurrentFileImmediately(content: editor.editorText) }
            await written.wait()
            editor.editorText = "second"
            #expect(await editor.persistCurrentFileImmediately(content: editor.editorText))
            let latest = editor.lastSaveReceipt?.sequence
            #expect(try h.disk() == "second")
            await ack.open()
            #expect(await first.value)
            #expect(try h.disk() == "second")
            #expect(editor.lastPersistedText == "second")
            #expect(editor.editorText == editor.lastPersistedText)
            #expect(editor.lastSaveReceipt?.sequence == latest)
            #expect(editor.lastSaveReceipt?.content == "second")
            #expect(editor.lastSaveReceipt?.projectID == h.document.stableProjectID)
            #expect(editor.lastSaveReceipt?.fileName == "main.typ")
            #expect(editor.lastSaveReceipt?.loadToken == editor.fileLoadToken)
        }
    }

    @Test func secondMountedWindowCannotWriteWithoutLease() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let second = try SaveEditorHost(document: h.document, root: h.root)
            await second.mount()
            let editor = second.editor!
            let requests = SaveRequests()
            await editor.backgroundFileWriter.setCheckpoints(before: { request in await requests.append(request) })
            let access = await ProjectWritableLeaseCoordinator.shared.open(projectID: h.document.stableProjectID)
            switch access {
            case .readOnly: break
            case .writable(let unexpected):
                Issue.record("Second window unexpectedly obtained writable lease")
                await unexpected.release()
            }
            editor.editorText = "second window"
            #expect(await editor.flushPendingSave() == false)
            #expect(try h.disk() == "initial")
            #expect(editor.lastPersistedText == "initial")
            #expect(editor.editorText != editor.lastPersistedText)
            #expect(editor.fileSaveError != nil)
            #expect(h.editor!.projectWritableLease != nil)
            requests.expect(h, paths: [], contents: [])
            second.unmount()
        }
    }
}

// One-shot latching continuation: waits work whether arrival precedes or follows wait.
private actor SaveCheckpoint {
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
private final class SaveRequests {
    var values: [ProjectReliabilityWriteRequest] = []
    func append(_ request: ProjectReliabilityWriteRequest) { values.append(request) }
    func expect(_ host: SaveEditorHost, paths: [String], contents: [String]) {
        #expect(values.map(\.relativePath) == paths)
        #expect(values.map(\.data) == contents.map { Data($0.utf8) })
        for request in values {
            #expect(request.projectID == host.document.stableProjectID)
            #expect(request.rootURL.standardizedFileURL == host.root.standardizedFileURL)
            #expect(request.entryRelativePath == "main.typ")
        }
    }
}

@MainActor
private final class SaveEditorHost {
    let document: InkPondDocument
    let root: URL
    let container: ModelContainer
    let fonts: AppFontLibrary
    var editor: DocumentEditorView?
    var controller: UIViewController?
    var window: UIWindow?

    init(document: InkPondDocument, root: URL) throws {
        self.document = document
        self.root = root
        container = try ModelContainer(for: InkPondDocument.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        fonts = AppFontLibrary(rootURL: root.appendingPathComponent("test-fonts"))
    }

    func mount(usingLifecycle: Bool = false) async {
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var view = DocumentEditorView(document: document)
            view.saveTestUsesLifecycle = usingLifecycle
            view.saveTestDebounce = {} // No wall-clock delay; writer gates control ordering.
            view.saveTestProbe = { [weak self] mounted in
                guard let self, self.editor == nil else { return }
                self.editor = mounted
                if !usingLifecycle {
                    mounted.currentFileName = "main.typ"
                    mounted.editorText = "initial"
                    mounted.lastPersistedText = "initial"
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
private func expectReceipt(_ editor: DocumentEditorView, host: SaveEditorHost, content: String) {
    #expect(editor.lastSaveReceipt?.projectID == host.document.stableProjectID)
    #expect(editor.lastSaveReceipt?.fileName == "main.typ")
    #expect(editor.lastSaveReceipt?.loadToken == editor.fileLoadToken)
    #expect(editor.lastSaveReceipt?.lifecycle == editor.projectLifecycleGeneration)
    #expect(editor.lastSaveReceipt?.sequence == editor.saveGeneration)
    #expect(editor.lastSaveReceipt?.content == content)
}

@MainActor
private func withEditor(_ body: @MainActor (SaveEditorHost) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("M2A-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let document = InkPondDocument(title: "M2-A save characterization")
    document.projectID = "M2A-\(UUID().uuidString)"
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
    let host = try SaveEditorHost(document: document, root: root)
    await host.mount()
    let lease = try await ProjectWritableLeaseCoordinator.shared.acquire(projectID: document.stableProjectID)
    host.editor!.projectWritableLease = lease
    host.editor!.projectAccessResolved = true
    var failure: Error?
    do { try await body(host) } catch { failure = error }
    host.editor?.saveTask?.cancel()
    await host.editor?.saveTask?.value
    await host.editor?.projectCloseTask?.value
    await ProjectReliabilityWriterRegistry.shared.close(projectID: document.stableProjectID, rootURL: root)
    EditorFailedCloseStore.shared.remove(for: document.stableProjectID, lease: lease)
    await lease.release()
    host.unmount()
    if let failure { throw failure }
}
#endif
