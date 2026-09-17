import Darwin
#if DEBUG
import SwiftUI
import SwiftData
import Testing
import UIKit
@testable import InkPond

/// Real EditorView factory/update/dismantle paths and real TextKit views, plus
/// a fully hosted DocumentEditorView production-startup regression. Factory tests
/// substitute only the deferred restoration queue, drained explicitly.
@Suite(.serialized)
@MainActor
struct DocumentEditorStateTests {
    // Production queues may retain the model beyond UIKit teardown (as the app's
    // store does). Keep this test store alive for the process, not just the test.
    private static var hostedModelContainers: [ModelContainer] = []
    @Test func inactiveRepresentationCannotStealHistoryAndCurrentOwnerRepairsLostAttachment() {
        let h = EditorStateFixture(text: "seed")
        let a = h.session("a.typ"), b = h.session("b.typ")
        let old = h.mount(a)
        let current = h.mount(b)
        let attachment = b.editorUndoHistory.attachmentID
        // An outgoing representation still has a valid document attachment,
        // but its session is no longer the active text owner.
        h.editor(a).updateTextView(old.view, coordinator: old.coordinator)
        #expect(b.editorUndoHistory.attachmentID == attachment)
        #expect(old.view.undoManager == nil)
        old.view.insertText("stale")
        #expect(a.editorText == "seed")

        // Reproduce the historical failure directly: unchanged text/token hid
        // a lost UUID, leaving the visible view's mutation gate closed forever.
        b.editorUndoHistory.attachmentID = UUID()
        #expect(current.view.undoManager == nil)
        h.editor(b).updateTextView(current.view, coordinator: current.coordinator)
        #expect(current.view.undoManager === b.editorUndoHistory)
        current.view.selectedRange = NSRange(location: 4, length: 0)
        current.view.insertText("!")
        #expect(b.editorText == "seed!")
        current.view.deleteBackward()
        #expect(b.editorText == "seed")
        current.view.undoManager?.undo()
        #expect(b.editorText == "seed!")
    }

    @Test func bootstrapWaitsForProductionOwnershipAndInactiveMountCannotAttach() {
        let h = EditorStateFixture(text: "seed")
        let a = h.session("a.typ")
        let bootstrap = MountedStateEditor(editor: h.editor(a)) // deliberately not activated
        #expect(a.editorUndoHistory.attachmentID == nil)
        #expect(bootstrap.view.undoManager == nil)
        bootstrap.view.insertText("rejected")
        #expect(a.editorText == "seed")
        h.activate(a)
        h.editor(a).updateTextView(bootstrap.view, coordinator: bootstrap.coordinator)
        #expect(bootstrap.view.undoManager === a.editorUndoHistory)
        #expect(bootstrap.view.text == "seed")
        let attachment = a.editorUndoHistory.attachmentID
        var inactiveEditor = h.editor(a)
        inactiveEditor.acceptsCallbacks = { false }
        let inactive = MountedStateEditor(editor: inactiveEditor)
        #expect(a.editorUndoHistory.attachmentID == attachment)
        #expect(inactive.view.undoManager == nil)
        EditorView.dismantleUIView(inactive.view, coordinator: inactive.coordinator)
        #expect(bootstrap.view.undoManager === a.editorUndoHistory)
    }

    @Test func revokedAttachmentStillCapturesOutgoingFindWithoutAcceptingEdits() {
        let h = EditorStateFixture(text: "seed")
        let a = h.session("a.typ")
        let m = h.mount(a)
        m.view.findInteraction?.searchText = "MainMarker"
        m.view.findInteraction?.replacementText = "Replacement"
        h.workspace.attachmentID = nil // production close/transfer precedes dismantle
        m.view.insertText("stale")
        #expect(a.editorText == "seed")
        EditorView.dismantleUIView(m.view, coordinator: m.coordinator)
        #expect(a.findState.query == "MainMarker")
        #expect(a.findState.replacement == "Replacement")
        h.workspace.attachmentID = h.attachment.id
        let restored = h.mount(a)
        #expect(restored.view.findInteraction?.searchText == "MainMarker")
        #expect(restored.view.findInteraction?.replacementText == "Replacement")
    }

    @Test func hostedDocumentEditorProductionAppearanceAcceptsTypingDeleteAndPaste() async throws {
        let document = InkPondDocument(title: "Hosted editor regression")
        try ProjectFileManager.createProjectRoot(for: document)
        let root = ProjectFileManager.projectDirectory(for: document)
        let seed = "MainMarker"
        try seed.write(to: ProjectFileManager.entryFileURL(for: document), atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: InkPondDocument.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Self.hostedModelContainers.append(container)
        container.mainContext.insert(document)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        // No saveTestProbe, injected attachment, preactivation, or EditorView factory:
        // the full production onAppear acquires access and loads the active session.
        let host = UIHostingController(rootView: DocumentEditorView(document: document)
            .modelContainer(container)
            .environment(AppFontLibrary(rootURL: root.appendingPathComponent("test-fonts")))
            .environment(ThemeManager())
            .environment(EditorFontSettings()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        func textViews(in view: UIView) -> [TypstTextView] {
            (view as? TypstTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        // Bounded readiness, not a preactivated fixture or fixed startup delay.
        var editor: TypstTextView?
        for _ in 0..<200 {
            window.layoutIfNeeded()
            editor = textViews(in: host.view).first { $0.window != nil && $0.isEditable && $0.text == seed }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let view = try #require(editor)
        let coordinator = try #require(view.delegate as? EditorView.Coordinator)
        let active = try #require(coordinator.parent.session)
        #expect(active.context.activeTextSession === active)
        #expect(view.undoManager === active.editorUndoHistory)
        _ = view.becomeFirstResponder()
        view.selectedRange = NSRange(location: seed.utf16.count, length: 0)
        view.insertText("!")
        #expect(view.text == seed + "!" && active.editorText == seed + "!")
        view.deleteBackward()
        #expect(view.text == seed && active.editorText == seed)
        let pasteboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = pasteboard }
        UIPasteboard.general.string = " pasted"
        view.paste(nil) // keep the production rich-paste callback installed
        for _ in 0..<100 {
            if active.editorText == seed + " pasted", view.text == seed + " pasted" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.text == seed + " pasted")
        #expect(active.editorText == seed + " pasted")
        view.undoManager?.undo()
        #expect(view.text == seed && active.editorText == seed)
        view.undoManager?.redo()
        #expect(view.text == seed + " pasted")
        #expect(active.editorText == seed + " pasted")
        // Trigger the real disappearance before removing this test's project.
        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        await active.context.closeTask?.value
        active.saveTask?.cancel()
        active.stopConflictMonitoring()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func snapshotHistoryBalancesRegistrationAndRejectsReplaySideEffects() {
        let h = EditorStateFixture(text: "before")
        let session = h.session("a.typ")
        let history = session.editorUndoHistory
        let before = EditorUndoSnapshot(text: "before", selection: NSRange(location: 1, length: 2))
        let after = EditorUndoSnapshot(text: "after", selection: NSRange(location: 5, length: 0))
        let foreignTarget = NSObject()
        var foreignActionRan = false
        var replayCount = 0
        history.canReplay = { true }
        history.didReplay = {
            replayCount += 1
            #expect(!history.isUndoRegistrationEnabled)
            history.registerUndo(withTarget: foreignTarget) { _ in foreignActionRan = true }
        }
        defer { history.didReplay = nil }
        session.editorText = after.text
        history.record(before: before, after: after)
        #expect(history.groupingLevel == 0)
        #expect(!history.isUndoRegistrationEnabled)
        for _ in 0..<3 {
            #expect(history.canUndo && !history.canRedo)
            history.undo()
            #expect(session.editorText == before.text)
            #expect(session.editorViewState.selectedLocation == 1)
            #expect(session.editorViewState.selectedLength == 2)
            #expect(!history.canUndo && history.canRedo)
            #expect(history.groupingLevel == 0 && !history.isUndoRegistrationEnabled)
            history.redo()
            #expect(session.editorText == after.text)
            #expect(session.editorViewState.selectedLocation == 5)
            #expect(session.editorViewState.selectedLength == 0)
            #expect(history.groupingLevel == 0 && !history.isUndoRegistrationEnabled)
        }
        #expect(replayCount == 6 && !foreignActionRan)
        history.resetHistory()
        #expect(!history.canUndo && !history.canRedo)
        #expect(!history.isUndoRegistrationEnabled)
    }

    @Test func equalTextSwitchRestoresIdentitySelectionFindAndUndo() {
        let h = EditorStateFixture(text: "same text")
        let a = h.session("a.typ")
        let b = h.session("b.typ")
        a.editorViewState = .init(selectedLocation: 1, selectedLength: 2)
        b.editorViewState = .init(selectedLocation: 7)
        b.findState = .init(query: "B", replacement: "BB")
        let mounted = h.mount(a)
        mounted.view.findInteraction?.searchText = "A"
        mounted.view.findInteraction?.replacementText = "AA"
        #expect(mounted.view.selectedRange == NSRange(location: 1, length: 2))
        h.activate(b)
        h.editor(b).updateTextView(mounted.view, coordinator: mounted.coordinator)
        mounted.drain()
        #expect(mounted.view.text == "same text")
        #expect(mounted.view.selectedRange == NSRange(location: 7, length: 0))
        #expect(mounted.view.findInteraction?.searchText == "B")
        #expect(a.findState.query == "A")
        #expect(a.findState.replacement == "AA")
        #expect(mounted.view.undoManager === b.editorUndoHistory)
        h.activate(a)
        h.editor(a).updateTextView(mounted.view, coordinator: mounted.coordinator)
        mounted.drain()
        #expect(mounted.view.selectedRange == NSRange(location: 1, length: 2))
        #expect(mounted.view.findInteraction?.searchText == "A")
        #expect(mounted.view.undoManager === a.editorUndoHistory)
        #expect(!a.isDirty && !b.isDirty)
    }

    @Test func presentedFindDismissSwitchAndRestoreKeepsQueriesPerFile() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let h = EditorStateFixture(text: "MainMarker SecondMarker")
        let a = h.session("main.typ"), b = h.session("second.typ")
        let m = h.mount(a)
        controller.view.addSubview(m.view)
        m.view.frame = controller.view.bounds
        window.makeKeyAndVisible()
        defer {
            EditorView.dismantleUIView(m.view, coordinator: m.coordinator)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        // Let UIKit complete real navigator/keyboard presentation, not just
        // assert the properties on an unattached UITextView.
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
        }
        func expectFields(query: String, replacement: String) throws {
            let interaction = try #require(m.view.findInteraction)
            #expect(interaction.isFindNavigatorVisible)
            #expect(interaction.searchText == query)
            #expect(interaction.replacementText == replacement)
            // UIKit does not expose the navigator's private search-field view
            // as part of this window on every runtime. Assert its public model
            // with the real navigator presented; visible text is also verified
            // separately on the shared Simulator, not inferred from this test.
        }
        m.view.presentFind(showingReplace: true)
        try await settle()
        let interaction = try #require(m.view.findInteraction)
        interaction.searchText = "MainMarker"
        interaction.replacementText = "MainReplacement"
        interaction.dismissFindNavigator() // Done's public UIKit lifecycle
        try await settle()
        h.activate(b)
        h.editor(b).updateTextView(m.view, coordinator: m.coordinator)
        m.drain()
        m.view.presentFind(showingReplace: true)
        try await settle()
        try expectFields(query: "", replacement: "")
        interaction.searchText = "SecondMarker"
        interaction.replacementText = "SecondReplacement"
        interaction.dismissFindNavigator()
        try await settle()
        m.view.presentFind(showingReplace: true)
        try await settle()
        try expectFields(query: "SecondMarker", replacement: "SecondReplacement")
        // Switch with Find still visible; returning to B must auto-present B,
        // while returning to the dismissed A requires an explicit presentation.
        h.activate(a)
        h.editor(a).updateTextView(m.view, coordinator: m.coordinator)
        m.drain()
        try await settle()
        m.view.presentFind(showingReplace: true)
        try await settle()
        try expectFields(query: "MainMarker", replacement: "MainReplacement")
        h.activate(b)
        h.editor(b).updateTextView(m.view, coordinator: m.coordinator)
        m.drain()
        try await settle()
        try expectFields(query: "SecondMarker", replacement: "SecondReplacement")
    }

    @Test func realTypingAutopairDeleteReplaceCompletionAndInsertionUndoRedo() {
        let h = EditorStateFixture(text: "")
        let a = h.session("a.typ")
        let m = h.mount(a)
        func roundTrip(_ edit: () -> Void) {
            let before = a.editorText
            edit()
            let after = a.editorText
            #expect(after != before)
            #expect(m.view.text == after)
            #expect(a.editorUndoHistory.canUndo)
            m.view.undoManager?.undo()
            #expect(a.editorText == before)
            #expect(m.view.text == before)
            m.view.undoManager?.redo()
            #expect(a.editorText == after)
            #expect(m.view.text == after)
            m.drain()
        }
        roundTrip { m.view.insertText("hello") }
        roundTrip { m.view.insertText("(") }
        #expect(a.editorText == "hello()")
        roundTrip { m.view.deleteBackward() }
        #expect(a.editorText == "hello")
        roundTrip {
            m.view.selectedRange = NSRange(location: 0, length: 5)
            m.view.replace(m.view.selectedTextRange!, withText: "replacement")
        }
        roundTrip {
            m.coordinator.insertText(.init(text: "#tex", targetRange: NSRange(location: 0, length: a.editorText.utf16.count), targetFileName: "a.typ"))
        }
        roundTrip {
            m.view.updateCompletion()
            m.view.acceptCompletion(.init(label: "text", insertText: "text()", kind: .function, detail: nil))
        }
        #expect(a.editorText == "#text()")
        // Plain UIKit paste uses the same UITextInput replacement route. Rich
        // document paste uses EditorInsertionRequest after asset processing.
        m.view.onRichPaste = nil
        let items = UIPasteboard.general.items
        defer { UIPasteboard.general.items = items }
        UIPasteboard.general.string = "pasted"
        roundTrip { m.view.paste(nil) }
        roundTrip {
            m.coordinator.insertText(.init(text: "rich paste", targetRange: m.view.selectedRange, targetFileName: "a.typ"))
        }
    }

    @Test(arguments: [false, true])
    func chineseMarkedTextCommitsAsOneUndoTransaction(replacingSelection: Bool) throws {
        let original = "标题😀：旧文字。"
        let h = EditorStateFixture(text: original)
        let a = h.session("a.typ")
        let m = h.mount(a)
        defer { EditorView.dismantleUIView(m.view, coordinator: m.coordinator) }
        let selection = replacingSelection
            ? (original as NSString).range(of: "旧文字")
            : NSRange(location: original.utf16.count, length: 0)
        m.view.selectedRange = selection
        m.coordinator.textViewDidChangeSelection(m.view)

        // Exercise UITextInput's actual marked range, not a fake markedTextRange
        // override or insertText("中文"). Explicit delegate delivery makes this
        // deterministic even when UIKit omits/duplicates programmatic callbacks.
        for candidate in ["n", "ni", "nihao", "你好"] {
            m.view.setMarkedText(candidate,
                                 selectedRange: NSRange(location: candidate.utf16.count, length: 0))
            let marked = try #require(m.view.markedTextRange)
            #expect(m.view.text(in: marked) == candidate)
            m.coordinator.textViewDidChange(m.view)
            m.coordinator.textViewDidChangeSelection(m.view)
        }
        m.view.unmarkText()
        #expect(m.view.markedTextRange == nil)
        m.coordinator.textViewDidChange(m.view)
        m.coordinator.textViewDidChangeSelection(m.view)
        let committed = (original as NSString).replacingCharacters(in: selection, with: "你好")
        let committedSelection = NSRange(location: selection.location + 2, length: 0)
        #expect(a.editorText == committed && m.view.text == committed)
        #expect(m.view.selectedRange == committedSelection)
        #expect(a.editorUndoHistory.canUndo)
        for _ in 0..<3 {
            m.view.undoManager?.undo()
            #expect(a.editorText == original && m.view.text == original)
            #expect(m.view.selectedRange == selection)
            #expect(!a.editorUndoHistory.canUndo && a.editorUndoHistory.canRedo)
            m.view.undoManager?.redo()
            #expect(a.editorText == committed && m.view.text == committed)
            #expect(m.view.selectedRange == committedSelection)
            #expect(a.editorUndoHistory.canUndo && !a.editorUndoHistory.canRedo)
            #expect(m.view.markedTextRange == nil)
            #expect(!a.editorUndoHistory.isUndoRegistrationEnabled)
        }
    }

    @Test func longDocumentsKeepIndependentHistoryAcrossRepeatedSwitchAndReplay() {
        // ~100 KB UTF-8 / 4,000 lines per file. Separate insertText calls are
        // separate committed transactions, with no run-loop typing coalescing.
        // Peak RSS is process-wide (other tests share the host), not an isolated
        // allocation benchmark. Report it alongside the functional workload.
        func peakRSS() -> Int64 {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
            return Int64(usage.ru_maxrss)
        }
        let rssBefore = peakRSS()
        defer { print("[M2UndoMemory] two 4000-line documents, 80 edits/file, full undo/redo; peakRSSBytes before=\(rssBefore) after=\(peakRSS())") }
        let base = String(repeating: "段落😀 long document text\n", count: 4_000)
        let h = EditorStateFixture(text: base)
        let a = h.session("a.typ"), b = h.session("b.typ")
        let m = h.mount(a)
        defer { EditorView.dismantleUIView(m.view, coordinator: m.coordinator) }
        let editsPerFile = 80
        var suffixes = ["", ""]
        func activate(_ session: DocumentSession) {
            h.activate(session)
            h.editor(session).updateTextView(m.view, coordinator: m.coordinator)
            m.drain()
            #expect(m.view.undoManager === session.editorUndoHistory)
            #expect(m.view.text == session.editorText)
        }
        for batch in 0..<8 {
            for (index, session) in [a, b].enumerated() {
                activate(session)
                m.view.selectedRange = NSRange(location: session.editorText.utf16.count, length: 0)
                m.coordinator.textViewDidChangeSelection(m.view)
                for edit in 0..<10 {
                    let token = "\(index):\(batch * 10 + edit);"
                    m.view.insertText(token)
                    suffixes[index] += token
                    #expect(session.editorText == base + suffixes[index])
                    #expect(session.editorUndoHistory.groupingLevel == 0)
                    #expect(!session.editorUndoHistory.isUndoRegistrationEnabled)
                }
            }
        }
        for (index, session) in [a, b].enumerated() {
            activate(session)
            let other = index == 0 ? b : a
            let otherText = other.editorText
            // A manager retained by an inactive tab must not target this view.
            other.editorUndoHistory.undo()
            #expect(other.editorText == otherText)
            #expect(session.editorText == base + suffixes[index])
            for remaining in stride(from: editsPerFile - 1, through: 0, by: -1) {
                #expect(session.editorUndoHistory.canUndo)
                session.editorUndoHistory.undo()
                let expectedSuffix = (0..<remaining).map { "\(index):\($0);" }.joined()
                #expect(session.editorText == base + expectedSuffix)
                #expect(m.view.text == session.editorText)
                #expect(m.view.selectedRange == NSRange(location: session.editorText.utf16.count, length: 0))
                #expect(other.editorText == otherText)
            }
            #expect(!session.editorUndoHistory.canUndo && session.editorUndoHistory.canRedo)
            #expect(!session.isDirty)
            // Detach/re-attach with the entire history on the redo stack.
            activate(other)
            activate(session)
            for count in 1...editsPerFile {
                #expect(session.editorUndoHistory.canRedo)
                session.editorUndoHistory.redo()
                let expectedSuffix = (0..<count).map { "\(index):\($0);" }.joined()
                #expect(session.editorText == base + expectedSuffix)
                #expect(m.view.text == session.editorText)
                #expect(m.view.selectedRange == NSRange(location: session.editorText.utf16.count, length: 0))
                #expect(other.editorText == otherText)
            }
            #expect(!session.editorUndoHistory.canRedo && session.editorUndoHistory.canUndo)
            #expect(session.editorUndoHistory.groupingLevel == 0)
            #expect(!session.editorUndoHistory.isUndoRegistrationEnabled)
        }
    }

    @Test func recreationKeepsHistoryButDepartedViewCannotEditOrUndo() {
        let h = EditorStateFixture(text: "seed")
        let a = h.session("a.typ")
        let old = h.mount(a)
        old.view.selectedRange = NSRange(location: 4, length: 0)
        old.view.insertText("!")
        old.view.findInteraction?.searchText = "seed"
        old.view.findInteraction?.replacementText = "new"
        EditorView.dismantleUIView(old.view, coordinator: old.coordinator)
        #expect(old.view.undoManager == nil)
        let fresh = h.mount(a)
        #expect(fresh.view !== old.view)
        #expect(fresh.view.text == "seed!")
        #expect(fresh.view.selectedRange.location == 5)
        #expect(fresh.view.findInteraction?.searchText == "seed")
        old.view.insertText("stale")
        old.coordinator.textViewDidChange(old.view)
        old.drain()
        #expect(a.editorText == "seed!")
        fresh.view.undoManager?.undo()
        #expect(fresh.view.text == "seed")
        #expect(!a.isDirty)
        fresh.view.undoManager?.redo()
        #expect(fresh.view.text == "seed!")
    }

    @Test func independentHistorySurvivesSwitchAndCannotTargetOtherFile() {
        let h = EditorStateFixture(text: "")
        let a = h.session("a.typ"), b = h.session("b.typ")
        let m = h.mount(a)
        m.view.insertText("A")
        let oldManager = a.editorUndoHistory
        h.activate(b)
        h.editor(b).updateTextView(m.view, coordinator: m.coordinator)
        m.view.insertText("B")
        oldManager.undo()
        #expect(a.editorText == "A" && b.editorText == "B")
        m.view.undoManager?.undo()
        #expect(b.editorText == "" && a.editorText == "A")
        h.activate(a)
        h.editor(a).updateTextView(m.view, coordinator: m.coordinator)
        m.view.undoManager?.undo()
        #expect(a.editorText == "" && b.editorText == "")
        m.view.undoManager?.redo()
        #expect(a.editorText == "A" && b.editorText == "")
    }

    @Test func restorationClampsUTF16SelectionAndScrollWithoutPublishingText() {
        let h = EditorStateFixture(text: "a😀z")
        let a = h.session("a.typ")
        a.editorViewState = .init(selectedLocation: Int.max, selectedLength: Int.max,
                                  contentOffset: CGPoint(x: CGFloat.infinity, y: 999_999))
        let revision = a.editRevision
        let m = h.mount(a)
        m.drain()
        #expect(m.view.selectedRange == NSRange(location: 4, length: 0))
        let clamped = EditorView.Coordinator.clampedOffset(a.editorViewState.contentOffset, in: m.view)
        #expect(m.view.contentOffset == clamped)
        #expect(a.editRevision == revision)
        #expect(!a.isDirty && !a.editorUndoHistory.canUndo)
        a.editorViewState = .init(selectedLocation: -2, selectedLength: Int.max,
                                  contentOffset: CGPoint(x: -999, y: -999))
        a.fileLoadToken = UUID()
        h.editor(a).updateTextView(m.view, coordinator: m.coordinator)
        m.drain()
        #expect(m.view.selectedRange == NSRange(location: 0, length: 4))
        #expect(m.view.contentOffset.y == -m.view.adjustedContentInset.top)
        #expect(a.editRevision == revision && !a.isDirty)
    }

    @Test func pendingRestorationCancelledByNavigationSwitchAndDetach() {
        let h = EditorStateFixture(text: String(repeating: "line\n", count: 100))
        let a = h.session("a.typ"), b = h.session("b.typ")
        a.editorViewState.contentOffset.y = 400
        let m = h.mount(a, drain: false)
        let generation = m.coordinator.installationGeneration
        m.view.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        m.coordinator.captureViewState(from: m.view)
        m.drain()
        #expect(m.view.contentOffset.y == 80)
        a.fileLoadToken = UUID()
        a.editorViewState.contentOffset.y = 400
        h.editor(a).updateTextView(m.view, coordinator: m.coordinator)
        h.activate(b)
        b.editorViewState.contentOffset.y = 120
        h.editor(b).updateTextView(m.view, coordinator: m.coordinator)
        m.drain()
        #expect(m.view.contentOffset.y == 120)
        #expect(!m.coordinator.acceptsDeferredWork(generation, in: m.view))
        b.fileLoadToken = UUID()
        b.editorViewState.contentOffset.y = 300
        h.editor(b).updateTextView(m.view, coordinator: m.coordinator)
        EditorView.dismantleUIView(m.view, coordinator: m.coordinator)
        let offset = m.view.contentOffset
        m.drain()
        #expect(m.view.contentOffset == offset)
    }

    @Test func actualWorkspaceCloseReopenDropsOldHistoryAndRejectsLateCallbacks() async {
        let h = EditorStateFixture(text: "base")
        let a = h.session("a.typ")
        let old = h.mount(a)
        old.view.insertText("edit")
        old.view.undoManager?.undo() // clean, so real close needs no disk writer
        #expect(!a.isDirty && a.editorUndoHistory.canRedo)
        #expect(await h.workspace.closeTab("a.typ"))
        let reopened = h.session("a.typ")
        #expect(reopened !== a)
        let fresh = h.mount(reopened)
        a.editorUndoHistory.redo()
        old.view.insertText("late")
        old.coordinator.textViewDidChange(old.view)
        old.drain()
        #expect(reopened.editorText == "base" && a.editorText == "base")
        #expect(!fresh.view.undoManager!.canUndo && !fresh.view.undoManager!.canRedo)
        #expect(reopened.editorViewState.selectedLocation == 0)
        #expect(reopened.findState.query == nil)
    }
}

@MainActor
private final class EditorStateFixture {
    let document = InkPondDocument(title: "Editor state tests")
    let workspace: WorkspaceSession
    let attachment: DocumentSessionAttachment
    let initialText: String

    init(text: String) {
        initialText = text
        workspace = WorkspaceSession(document: document)
        attachment = DocumentSessionAttachment(session: DocumentSession(document: document, context: workspace))
    }

    func session(_ path: String) -> DocumentSession {
        let session = DocumentSession(document: document, fileName: path, context: workspace)
        session.editorText = initialText
        session.lastPersistedText = initialText
        workspace.retain(session)
        return session
    }

    func activate(_ session: DocumentSession) {
        attachment.session = session
        workspace.activate(relativePath: session.currentFileName, kind: .typ)
    }

    func editor(_ session: DocumentSession) -> EditorView {
        EditorView(text: Binding(get: { session.editorText }, set: { [attachment] in
            if attachment.acceptsTextMutation(for: session) { session.editorText = $0 }
        }), insertionRequest: .constant(nil),
        findRequested: Binding(get: { session.findRequested }, set: { session.findRequested = $0 }),
        viewState: Binding(get: { session.editorViewState }, set: { [attachment] in
            if attachment.acceptsTextMutation(for: session) { session.editorViewState = $0 }
        }), cursorJumpOffset: .constant(nil), fileLoadToken: session.fileLoadToken, session: session,
        acceptsCallbacks: { [attachment] in attachment.acceptsTextMutation(for: session) },
        attachmentIsValid: { [attachment] in attachment.isValid })
    }

    func mount(_ session: DocumentSession, drain: Bool = true) -> MountedStateEditor {
        activate(session)
        let mounted = MountedStateEditor(editor: editor(session))
        if drain { mounted.drain() }
        return mounted
    }
}

@MainActor
private final class MountedStateEditor {
    let coordinator: EditorView.Coordinator
    let view: TypstTextView
    private let queue: RestorationQueue

    init(editor: EditorView) {
        let queue = RestorationQueue()
        self.queue = queue
        coordinator = editor.makeCoordinator()
        coordinator.enqueueRestoration = { queue.work.append($0) }
        view = editor.makeTextView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        coordinator.performProgrammaticUpdate { view.layoutIfNeeded() }
    }

    func drain() { queue.drain() }
}

@MainActor
private final class RestorationQueue {
    var work: [@MainActor () -> Void] = []
    func drain() {
        let pending = work
        work.removeAll()
        for block in pending { block() }
    }
}
#endif
