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
    @Test func appearanceWaitsForDrainAndInstallsFreshLease() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let old = editor.workspace
            let entered = SaveCheckpoint()
            let resume = SaveCheckpoint()
            old.beforeFinalClose = {
                await entered.open()
                await resume.wait()
            }
            editor.closeEditorOnDisappear()
            await entered.wait()
            editor.openEditorOnAppear()
            let appearance = editor.projectLeaseTask
            await resume.open()
            await appearance?.value
            #expect(editor.hasSessionAttachment)
            #expect(editor.workspace !== old)
            #expect(editor.projectWritableLease != nil)
            #expect(editor.projectAccessResolved)
        }
    }

    @Test func sameStateReappearancePreservesExplicitlyEmptyTabs() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            editor.restoreProjectEditorStateIfNeeded()
            for tab in editor.openTabs { await editor.closeProjectTab(tab) }
            editor.closeEditorOnDisappear()
            await editor.workspace.closeTask?.value
            editor.openEditorOnAppear()
            await editor.projectLeaseTask?.value
            #expect(editor.openTabs.isEmpty)
            #expect(editor.activeTabPath == nil)
        }
    }

    @Test func readOnlySameStateReappearancePreservesEmptyTabs() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            editor.closeEditorOnDisappear()
            await editor.workspace.closeTask?.value
            let blocker = try await ProjectWritableLeaseCoordinator.shared.acquire(projectID: h.document.stableProjectID)
            editor.openEditorOnAppear()
            await editor.projectLeaseTask?.value
            #expect(editor.projectWritableLease == nil)
            for tab in editor.openTabs { await editor.closeProjectTab(tab) }
            editor.closeEditorOnDisappear()
            editor.openEditorOnAppear()
            await editor.projectLeaseTask?.value
            #expect(editor.openTabs.isEmpty)
            #expect(editor.activeTabPath == nil)
            #expect(editor.projectWritableLease == nil)
            await blocker.release()
        }
    }

    @Test func readOnlyClosePreservesSharedAccessUntilLastWorkspace() async throws {
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".typ")
        try Data("read only".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = InkPondDocument(title: "shared access")
        document.projectID = id
        try ExternalTypFileSessionStore.register(url: url, projectID: id)
        let writer = WorkspaceSession(document: document)
        let reader = WorkspaceSession(document: document)
        writer.retainExternalAccess()
        reader.retainExternalAccess()
        let session = DocumentSession(document: document, context: reader)
        let attachment = DocumentSessionAttachment(session: session)
        reader.retain(session)
        reader.close(session: session, presentation: .init(entrySource: "", tabs: [], activePath: nil))
        #expect(!attachment.isValid)
        #expect(reader.sessions.isEmpty)
        #expect(ExternalTypFileSessionStore.contains(projectID: id))
        writer.releaseExternalAccess()
        #expect(!ExternalTypFileSessionStore.contains(projectID: id))
    }

    @Test func evictedSessionRejectsCapturedTextBinding() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let attachment = editor.sessionAttachment
            let session = editor.documentSession
            editor.activateTab(relativePath: "main.typ", kind: .typ)
            #expect(attachment.acceptsTextMutation(for: session))
            #expect(await editor.workspace.closeTab("main.typ"))
            #expect(!attachment.acceptsTextMutation(for: session))
            #expect(editor.loadFile(named: "main.typ"))
            #expect(editor.documentSession !== session)
            #expect(editor.workspace.sessions["main.typ"] === editor.documentSession)
            #expect(attachment.acceptsTextMutation(for: editor.documentSession))
            #expect(!attachment.acceptsTextMutation(for: session))
        }
    }

    @Test func inactiveCloseFailureSurfacesThroughActiveDraft() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let a = editor.documentSession
            #expect(editor.loadFile(named: "B.typ"))
            let b = editor.documentSession
            #expect(await b.persistCurrentFileImmediately(content: b.editorText, forceWrite: true))
            #expect(!b.isDirty)
            #expect(b.lastSaveReceipt?.content == "B on disk")
            #expect(try h.disk("B.typ") == "B on disk")
            let bSequence = b.lastSaveReceipt?.sequence
            a.editorText = "inactive unsaved draft"
            await a.backgroundFileWriter.setCheckpoints(before: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            editor.closeEditorOnDisappear()
            await editor.workspace.closeTask?.value
            #expect(a.isDirty)
            // Failed project close intentionally fences the presentation session
            // for recovery, even when its own disk write succeeded. B's content
            // and acknowledged receipt must remain unaffected by A's failure.
            #expect(b.editorText == b.lastPersistedText)
            #expect(b.lastSaveReceipt?.content == "B on disk")
            #expect(b.lastSaveReceipt?.sequence == bSequence)
            #expect(try h.disk("B.typ") == "B on disk")
            #expect(b.recoveryWriteSequenceFloor == b.saveGeneration)
            #expect(b.isDirty)
            #expect(editor.restoreFailedCloseIfAvailable())
            #expect(editor.documentSession === b)
            #expect(editor.fileSaveError != nil)
            await a.backgroundFileWriter.setCheckpoints(before: nil, after: nil)
        }
    }

    @Test func workspaceResourceCapabilitiesUseRealKinds() {
        let workspace = WorkspaceSession(document: InkPondDocument(title: "resource commands"))
        for kind: FileKind in [.image, .vector, .pdf, .font, .archive, .other] {
            workspace.activate(relativePath: "resource", kind: kind)
            #expect(!workspace.allowsTextCommands)
            #expect(workspace.activeTextSession == nil)
        }
        workspace.activate(relativePath: "text.typ", kind: .typ)
        #expect(workspace.allowsTextCommands)
    }

    @Test func workspaceCloseDoesNotResurrectTextBehindResource() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let workspace = editor.workspace
            workspace.activate(relativePath: "main.typ", kind: .typ)
            let text = workspace.activeTab!
            workspace.activate(relativePath: "photo.png", kind: .image)
            #expect(workspace.activeTextSession == nil)
            #expect(!workspace.allowsTextCommands)
            await editor.closeProjectTab(text)
            #expect(workspace.activeTabPath == "photo.png")
            #expect(workspace.sessions[text.relativePath] == nil)
            await editor.closeProjectTab(workspace.activeTab!)
            await editor.closeProjectTab(text)
            #expect(workspace.openTabs.isEmpty)
            #expect(workspace.activeTabPath == nil)
            #expect(!editor.activeTabIsTextEditable)
        }
    }

    @Test func workspaceRepeatedCloseIsBoundedAndReleasesRealLease() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let workspace = editor.workspace
            // This fixture seeds main's buffer without running appearance. Open
            // its real tab before asserting that closing all tabs evicts it.
            #expect(editor.loadFile(named: "main.typ"))
            for _ in 0..<12 {
                #expect(editor.loadFile(named: "B.typ"))
                await editor.closeProjectTab(workspace.activeTab!)
                #expect(workspace.sessions.count <= 1)
            }
            for tab in workspace.openTabs { await editor.closeProjectTab(tab) }
            #expect(workspace.sessions.isEmpty)
            editor.closeEditorOnDisappear()
            await workspace.closeTask?.value
            #expect(!DocumentSessionRegistry.shared.hasRetainedSession(for: h.document.stableProjectID))
            let lease = try await ProjectWritableLeaseCoordinator.shared.acquire(projectID: h.document.stableProjectID)
            await lease.release()
        }
    }

    @Test func workspaceFailedTabCloseRetainsDraftAndRetries() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let session = editor.documentSession
            editor.activateTab(relativePath: "main.typ", kind: .typ)
            let tab = editor.workspace.activeTab!
            session.editorText = "retry tab close"
            await session.backgroundFileWriter.setCheckpoints(before: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            await editor.closeProjectTab(tab)
            #expect(editor.workspace.activeTab == tab)
            #expect(session.isDirty)
            #expect(editor.workspace.projectWritableLease != nil)
            await session.backgroundFileWriter.setCheckpoints(before: nil, after: nil)
            await editor.closeProjectTab(tab)
            #expect(editor.workspace.openTabs.isEmpty)
            #expect(try h.disk() == "retry tab close")
        }
    }

    @Test func cleanSiblingAcknowledgementPreservesFailedProjectRecovery() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let a = editor.documentSession
            #expect(await editor.openFileIfPossible(named: "B.typ"))
            let b = editor.documentSession
            #expect(await editor.openFileIfPossible(named: "main.typ"))
            a.editorText = "failed A draft"
            await a.backgroundFileWriter.setCheckpoints(before: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            editor.closeEditorOnDisappear()
            await a.closeTask?.value
            #expect(a.isDirty)

            // A late successful sibling write must not erase the project handoff.
            #expect(await b.persistCurrentFileImmediately(content: b.editorText, forceWrite: true))
            #expect(!b.isDirty)
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            #expect(recovered.documentSession === a)
            #expect(recovered.editorText == "failed A draft")
            #expect(recovered.documentSession.context.sessions["B.typ"] === b)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "failed A draft")
        }
    }

    @Test func pausedConflictCommitPreservesLoadIdentityAcrossTabRoundTrip() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let a = editor.documentSession
            let token = a.fileLoadToken
            let written = SaveCheckpoint()
            let resume = SaveCheckpoint()
            defer { Task { await resume.open() } }
            await a.backgroundFileWriter.setCheckpoints(after: { _ in
                await written.open()
                await resume.wait()
            })
            a.editorText = "conflict local across tabs"
            let resolution = Task { await a.resolveConflictKeepLocal() }
            await written.wait()
            #expect(a.savesInFlight == 1)
            // Exercise the production retained-session activation without adding
            // another write that would mask the pending conflict acknowledgement.
            #expect(editor.loadFile(named: "B.typ"))
            #expect(editor.loadFile(named: "main.typ"))
            #expect(editor.documentSession === a)
            #expect(a.fileLoadToken == token)
            await resume.open()
            await resolution.value
            #expect(a.savesInFlight == 0)
            #expect(a.lastSaveReceipt?.loadToken == token)
            #expect(!a.isDirty)
            #expect(a.fileSaveError == nil)
            #expect(try h.disk() == a.editorText)
        }
    }

    @Test func staleConflictContinuationCannotAcknowledgeAfterHandoff() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let session = old.documentSession
            let written = SaveCheckpoint()
            let resume = SaveCheckpoint()
            defer { Task { await resume.open() } }
            await session.backgroundFileWriter.setCheckpoints(before: { request in
                if request.data == Data("retained draft".utf8) {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }, after: { _ in
                await written.open()
                await resume.wait()
            })
            old.editorText = "conflict local"
            let resolution = Task { await session.resolveConflictKeepLocal() }
            await written.wait()
            old.editorText = "retained draft"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            let token = recovered.fileLoadToken
            let error = recovered.fileSaveError
            await resume.open()
            await resolution.value
            #expect(recovered.fileLoadToken == token)
            #expect(recovered.editorText == "retained draft")
            #expect(recovered.lastSaveReceipt == nil)
            #expect(recovered.recoveryWriteSequenceFloor != nil)
            #expect(recovered.fileSaveError == error)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "retained draft")
        }
    }

    @Test func terminalCloseRejectsLateAttachmentMutation() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let session = editor.documentSession
            editor.editorText = "committed before close"
            let entered = SaveCheckpoint()
            let release = SaveCheckpoint()
            session.context.beforeFinalClose = {
                await entered.open()
                await release.wait()
            }
            editor.closeEditorOnDisappear()
            let close = session.closeTask
            await entered.wait()
            editor.editorText = "late callback must be rejected"
            #expect(session.editorText == "committed before close")
            #expect(!editor.hasSessionAttachment)
            #expect(!(await editor.flushPendingSave()))
            await release.open()
            await close?.value
            #expect(!session.isDirty)
            #expect(try h.disk() == "committed before close")
            #expect(!DocumentSessionRegistry.shared.hasRetainedSession(for: h.document.stableProjectID))
        }
    }

    @Test func aToBToARetainsDurableTextAndNewLoadIdentity() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let firstToken = editor.fileLoadToken
            editor.editorText = "A revision"
            #expect(await editor.openFileIfPossible(named: "B.typ"))
            editor.editorText = "B revision"
            #expect(await editor.openFileIfPossible(named: "main.typ"))
            #expect(editor.editorText == "A revision")
            #expect(editor.fileLoadToken != firstToken)
            #expect(!editor.documentSession.isDirty)
            #expect(try h.disk() == "A revision")
            #expect(try h.disk("B.typ") == "B revision")
        }
    }

    @Test func textTabsRetainIndependentSessionIdentityAndRevision() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let a = editor.documentSession
            editor.editorText = "A retained"
            #expect(await editor.openFileIfPossible(named: "B.typ"))
            let b = editor.documentSession
            #expect(a !== b)
            #expect(a.currentFileName == "main.typ")
            #expect(b.currentFileName == "B.typ")
            let revisionA = a.editRevision
            let receiptA = a.lastSaveReceipt?.sequence
            editor.editorText = "B retained"
            #expect(a.editorText == "A retained")
            #expect(a.editRevision == revisionA)
            #expect(await editor.openFileIfPossible(named: "main.typ"))
            #expect(editor.documentSession === a)
            #expect(a.lastSaveReceipt?.sequence == receiptA)
            #expect(b.editorText == "B retained")
            #expect(await editor.openFileIfPossible(named: "B.typ"))
            #expect(editor.documentSession === b)
        }
    }

    @Test func failedCloseRecoveryRetainsBothTextTabSessions() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let a = old.documentSession
            old.editorText = "saved A"
            #expect(await old.openFileIfPossible(named: "B.typ"))
            let b = old.documentSession
            old.editorText = "failed B"
            await b.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            #expect(recovered.documentSession === b)
            #expect(recovered.editorText == "failed B")
            #expect(await recovered.openFileIfPossible(named: "main.typ"))
            #expect(recovered.documentSession === a)
            #expect(recovered.editorText == "saved A")
            #expect(await recovered.openFileIfPossible(named: "B.typ"))
            #expect(recovered.documentSession === b)
            #expect(try h.disk("B.typ") == "failed B")
        }
    }

    @Test func transferredAttachmentCannotMutateSaveOrCloseRecoveredSession() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            await old.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            old.editorText = "retained draft"
            old.closeEditorOnDisappear()
            await old.projectCloseTask?.value
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            #expect(!old.hasSessionAttachment)
            let retainedTabs = recovered.openTabs
            let retainedPath = recovered.activeTabPath
            let retainedMode = recovered.selectedTab
            old.openTabs = []
            old.activeTabPath = "stale.png"
            old.selectedTab = retainedMode == 0 ? 1 : 0
            old.activateTab(relativePath: "stale.png", kind: .image)
            for tab in retainedTabs { await old.closeProjectTab(tab) }
            #expect(recovered.openTabs == retainedTabs)
            #expect(recovered.activeTabPath == retainedPath)
            #expect(recovered.selectedTab == retainedMode)
            old.editorText = "stale mutation"
            old.scheduleSave(content: "stale scheduled save", for: "main.typ")
            #expect(await old.flushPendingSave() == false)
            #expect(await old.persistCurrentFileImmediately(content: "stale immediate") == false)
            old.closeEditorOnDisappear()
            #expect(recovered.editorText == "retained draft")
            #expect(recovered.projectWritableLease != nil)
            #expect(recovered.projectCloseTask == nil)
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "retained draft")
        }
    }

    @Test func backgroundRetriesFailedCloseWithoutMountedView() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            let session = editor.documentSession
            await session.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            editor.editorText = "detached background retry"
            editor.closeEditorOnDisappear()
            await session.closeTask?.value
            h.unmount()
            await session.backgroundFileWriter.setCheckpoints(before: nil, after: nil)
            await DocumentSessionRegistry.shared.flushForBackground()
            #expect(try h.disk() == "detached background retry")
            #expect(session.projectWritableLease == nil)
            #expect(!DocumentSessionRegistry.shared.hasRetainedSession(for: h.document.stableProjectID))
        }
    }

    @Test func backgroundFlushUsesRetainedSessionAndRealDisk() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let editor = h.editor!
            editor.editorText = "background revision"
            await DocumentSessionRegistry.shared.flushForBackground()
            #expect(try h.disk() == "background revision")
            #expect(!editor.documentSession.isDirty)
            expectReceipt(editor, host: h, content: "background revision")
        }
    }

    @Test func mountedDisappearanceFailureAndRemountRetainSession() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let original = h.editor!
            // Transfer the already acquired lease into an appearance-enabled host.
            await original.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            original.editorText = "lifecycle draft"
            original.closeEditorOnDisappear()
            await original.projectCloseTask?.value
            let mounted = try SaveEditorHost(document: h.document, root: h.root)
            await mounted.mount(usingLifecycle: true, usingDisappearance: true)
            await mounted.finishAppearance()
            let editor = mounted.editor!
            let session = editor.documentSession
            await editor.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            editor.editorText = "actual detached draft"
            await mounted.detach()
            await session.closeTask?.value
            #expect(session.isDirty)
            #expect(try h.disk() == "initial")
            let reopened = try SaveEditorHost(document: h.document, root: h.root)
            await reopened.mount(usingLifecycle: true, usingDisappearance: true)
            await reopened.finishAppearance()
            let recovered = reopened.editor!
            #expect(recovered.documentSession === session)
            #expect(recovered.editorText == "actual detached draft")
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "actual detached draft")
            let count = DocumentSessionRegistry.shared.retainedSessionCount
            await reopened.detach()
            await session.closeTask?.value
            #expect(DocumentSessionRegistry.shared.retainedSessionCount == count - 1)
            // Reopen through production loading, never a draft or in-memory baseline.
            let durable = try SaveEditorHost(document: h.document, root: h.root)
            await durable.mount(usingLifecycle: true, usingDisappearance: true)
            await durable.finishAppearance()
            #expect(durable.editor!.editorText == "actual detached draft")
            let durableSession = durable.editor!.documentSession
            await durable.detach()
            await durableSession.closeTask?.value
            #expect(DocumentSessionRegistry.shared.retainedSessionCount == count - 1)
            #expect(try h.disk() == "actual detached draft")
        }
    }

    @Test func mountedPendingCloseHandsOffFailureWithoutSecondAppearance() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let initial = h.editor!
            await initial.backgroundFileWriter.setCheckpoints(before: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            initial.editorText = "seed draft"
            initial.closeEditorOnDisappear()
            await initial.projectCloseTask?.value
            let old = try SaveEditorHost(document: h.document, root: h.root)
            await old.mount(usingLifecycle: true, usingDisappearance: true)
            await old.finishAppearance()
            let session = old.editor!.documentSession
            let entered = SaveCheckpoint()
            let release = SaveCheckpoint()
            defer { Task { await release.open() } }
            await session.backgroundFileWriter.setCheckpoints(before: { _ in
                await entered.open()
                await release.wait()
                throw CocoaError(.fileWriteOutOfSpace)
            })
            session.editorText = "pending detached draft"
            await old.detach()
            let closing = session.closeTask
            await entered.wait()
            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount(usingLifecycle: true, usingDisappearance: true)
            await fresh.finishAppearance()
            #expect(fresh.editor!.projectWritableLease == nil)
            await release.open()
            await closing?.value
            await fresh.finishAppearance()
            #expect(fresh.editor!.documentSession === session)
            #expect(fresh.editor!.editorText == "pending detached draft")
            #expect(await fresh.editor!.flushPendingSave())
            #expect(try h.disk() == "pending detached draft")
            await fresh.detach()
            await session.closeTask?.value
        }
    }

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

    @Test func immediateSavePausedBeforeRegistryCannotOverwriteNewWindowAfterFailedCloseTransfer() async throws {
        try await withEditor { (h: SaveEditorHost) async throws in
            let old = h.editor!
            let entered = SaveCheckpoint()
            let release = SaveCheckpoint()
            defer { Task { await release.open() } }
            let requests = SaveRequests()
            await old.backgroundFileWriter.setCheckpoints(before: { request in
                await requests.append(request)
                if request.data == Data("old immediate".utf8) {
                    await entered.open()
                    await release.wait() // The real registry has not seen this request yet.
                } else if request.data == Data("failed close draft".utf8) {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            })
            old.editorText = "old immediate"
            // Keep this immediate task independent of saveTask: transfer must not
            // pass merely because the autosave cancellation path rejects it.
            let earlier = Task { await old.persistCurrentFileImmediately(content: "old immediate") }
            await entered.wait()
            #expect(old.saveTask == nil)
            #expect(try h.disk() == "initial")
            old.editorText = "failed close draft"
            old.closeEditorOnDisappear()
            let close = old.projectCloseTask
            await close?.value
            #expect(old.fileSaveError != nil)
            #expect(old.recoveryWriteSequenceFloor != nil)
            #expect(old.projectWritableLease != nil)
            #expect(old.editorText != old.lastPersistedText)
            #expect(try h.disk() == "initial")

            let fresh = try SaveEditorHost(document: h.document, root: h.root)
            await fresh.mount()
            defer { fresh.unmount() }
            let recovered = fresh.editor!
            #expect(recovered.restoreFailedCloseIfAvailable())
            #expect(recovered.editorText == "failed close draft")
            #expect(recovered.lastPersistedText == "initial")
            #expect(recovered.editorText != recovered.lastPersistedText)
            #expect(recovered.projectWritableLease != nil)
            #expect(old.projectWritableLease == nil)
            #expect(old.lastSaveReceipt == nil)
            await recovered.backgroundFileWriter.setCheckpoints(before: { request in
                await requests.append(request)
            })
            recovered.editorText = "new window write"
            #expect(await recovered.flushPendingSave())
            #expect(try h.disk() == "new window write")
            #expect(recovered.lastPersistedText == "new window write")
            #expect(recovered.editorText == recovered.lastPersistedText)
            #expect(recovered.recoveryWriteSequenceFloor == nil)
            #expect(recovered.fileSaveError == nil)
            expectReceipt(recovered, host: h, content: "new window write")
            let receipt = try #require(recovered.lastSaveReceipt)

            // Only now may the old immediate request reach the actual registry.
            await release.open()
            #expect(await earlier.value == false) // Revoked request must fail admission, not silently commit.
            let finalBytes = try h.disk()
            #expect(finalBytes == "new window write")
            #expect(recovered.editorText == "new window write")
            #expect(recovered.lastPersistedText == "new window write")
            #expect(recovered.editorText == recovered.lastPersistedText)
            #expect((recovered.editorText != recovered.lastPersistedText) == (recovered.editorText != finalBytes))
            #expect(recovered.recoveryWriteSequenceFloor == nil)
            #expect(recovered.fileSaveError == nil)
            #expect(old.lastSaveReceipt == nil)
            #expect(recovered.lastSaveReceipt?.projectID == receipt.projectID)
            #expect(recovered.lastSaveReceipt?.fileName == receipt.fileName)
            #expect(recovered.lastSaveReceipt?.lifecycle == receipt.lifecycle)
            #expect(recovered.lastSaveReceipt?.loadToken == receipt.loadToken)
            #expect(recovered.lastSaveReceipt?.sequence == receipt.sequence)
            #expect(recovered.lastSaveReceipt?.content == receipt.content)
            expectReceipt(recovered, host: h, content: "new window write")
            requests.expect(h, paths: ["main.typ", "main.typ", "main.typ"],
                            contents: ["old immediate", "failed close draft", "new window write"])
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
    if let session = host.editor?.documentSession {
        DocumentSessionRegistry.shared.release(session)
    }
    host.unmount()
    if let failure { throw failure }
}
#endif
