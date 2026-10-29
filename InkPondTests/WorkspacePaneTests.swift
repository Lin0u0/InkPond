import SwiftUI
import Testing
@testable import InkPond

@MainActor
struct WorkspacePaneTests {
    @Test func previewInteractionWinsOverPreviouslySelectedEditor() {
        #expect(WorkspacePane.collapseSelection(lastInteraction: .preview, currentSelection: 0) == 1)
    }

    @Test func typingAfterPreviewRetainsEditor() {
        #expect(WorkspacePane.collapseSelection(lastInteraction: .editor, currentSelection: 1) == 0)
    }

    @Test func noInteractionPreservesExplicitSinglePaneSelection() {
        for selection in [0, 1] {
            #expect(WorkspacePane.collapseSelection(lastInteraction: nil, currentSelection: selection) == selection)
        }
    }

    @Test func typingRecordsInteractionButProgrammaticUpdatesDoNot() {
        var interactionCount = 0
        let editor = EditorView(
            text: .constant("source"),
            insertionRequest: .constant(nil),
            findRequested: .constant(false),
            viewState: .constant(EditorViewState()),
            cursorJumpOffset: .constant(nil),
            onUserInteraction: { interactionCount += 1 }
        )
        let coordinator = editor.makeCoordinator()
        let textView = TypstTextView()
        textView.text = "source"
        coordinator.performProgrammaticUpdate {
            coordinator.textViewDidChange(textView)
        }
        #expect(interactionCount == 0)
        coordinator.textViewDidChange(textView)
        #expect(interactionCount == 1)
        // Source-map cursor moves must not steal preference from preview.
        coordinator.performProgrammaticUpdate {
            coordinator.textViewDidChangeSelection(textView)
        }
        #expect(interactionCount == 1)
    }

    @Test func previewThenHardwareCaretNavigationRetainsEditorOnCollapse() {
        var lastInteraction: WorkspacePane? = .preview
        let editor = EditorView(
            text: .constant("source"),
            insertionRequest: .constant(nil),
            findRequested: .constant(false),
            viewState: .constant(EditorViewState(selectedLocation: 2)),
            cursorJumpOffset: .constant(nil),
            onUserInteraction: { lastInteraction = .editor }
        )
        let coordinator = editor.makeCoordinator()
        let textView = TypstTextView()
        textView.text = "source"
        // Restoring the editor after layout, including a deferred UIKit callback,
        // must leave the last preview touch as the collapse preference.
        coordinator.restoreViewStateIfNeeded(in: textView)
        coordinator.textViewDidChangeSelection(textView)
        #expect(lastInteraction == .preview)
        // Preview-to-source jumps use this same tracked setter. Repeated/deferred
        // notifications at the programmatic range must never count as input.
        coordinator.setProgrammaticSelection(NSRange(location: 3, length: 0), in: textView)
        coordinator.textViewDidChangeSelection(textView)
        coordinator.textViewDidChangeSelection(textView)
        #expect(WorkspacePane.collapseSelection(lastInteraction: lastInteraction, currentSelection: 0) == 1)
        // A hardware arrow moves only the selection, not the source text.
        textView.selectedRange = NSRange(location: 4, length: 0)
        coordinator.textViewDidChangeSelection(textView)
        #expect(lastInteraction == .editor)
        #expect(WorkspacePane.collapseSelection(lastInteraction: lastInteraction, currentSelection: 1) == 0)
        #expect(textView.text == "source")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test func accessibilityTabNamesKeepDistinguishingChapterTail() {
        let tabs = ["workspace-verification-long-similar-chapter-07.typ",
                    "workspace-verification-long-similar-chapter-08.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        #expect(tabs[0].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "…07.typ")
        #expect(tabs[1].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "…08.typ")
        #expect(tabs[0].distinctDisplayName(in: tabs) == tabs[0].displayName)
    }

    @Test func duplicateTabNamesUseShortestDistinguishingDirectory() {
        let tabs = ["draft/chapters/main.typ", "final/chapters/main.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: "main.typ", kind: .typ)
        }
        #expect(tabs[0].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "draft/chapters/main.typ")
        #expect(tabs[1].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "final/chapters/main.typ")
        let shorter = ["draft/main.typ", "final/main.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: "main.typ", kind: .typ)
        }
        #expect(shorter[0].distinctDisplayName(in: shorter, preservingFilenameTail: true) == "draft/main.typ")
        #expect(shorter[1].distinctDisplayName(in: shorter, preservingFilenameTail: true) == "final/main.typ")
    }

    @Test func ordinaryTabNamesRemainUnchanged() {
        let tabs = ["main.typ", "notes.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        for tab in tabs {
            #expect(tab.distinctDisplayName(in: tabs, preservingFilenameTail: true) == tab.displayName)
            #expect(tab.distinctDisplayName(in: tabs) == tab.displayName)
        }
        #expect(tabs[0].distinctDisplayName(in: [tabs[0]], preservingFilenameTail: true) == "main.typ")
    }

    @Test func accessibilityTabNamesPreserveUnicodeGraphemes() {
        let tabs = ["章节-👩🏽‍💻-07.typ", "章节-👩🏽‍💻-08.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        #expect(tabs[0].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "…07.typ")
        #expect(tabs[1].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "…08.typ")
        let emoji = ["章节-👩🏽‍💻.typ", "章节-👨🏽‍💻.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        #expect(emoji[0].distinctDisplayName(in: emoji, preservingFilenameTail: true) == "…-👩🏽‍💻.typ")
        #expect(emoji[1].distinctDisplayName(in: emoji, preservingFilenameTail: true) == "…-👨🏽‍💻.typ")
    }

    @Test func accessibilityTabNamesNeverTrimExtensionOrEntireStem() {
        let tabs = ["a.typ", "a.typ.backup"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        #expect(tabs[0].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "a.typ")
        #expect(tabs[1].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "…p.backup")
    }

    @Test func accessibilityTabNamesDisambiguateCollidingFilenameFamilies() {
        let tabs = ["chapter-07.typ", "chapter-08.typ", "appendix-07.typ", "appendix-08.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        let labels = tabs.map { $0.distinctDisplayName(in: tabs, preservingFilenameTail: true) }
        #expect(labels == ["c…07.typ", "c…08.typ", "a…07.typ", "a…08.typ"])
        #expect(Set(labels).count == tabs.count)
    }

    @Test func longDuplicateBasenamesRetainDirectoryAndCompleteFilename() {
        let filename = "workspace-verification-long-similar-chapter-07.typ"
        let tabs = ["draft/chapters/", "final/chapters/"].map {
            ProjectFileTab(relativePath: $0 + filename, displayName: filename, kind: .typ)
        }
        #expect(tabs[0].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "draft/chapters/" + filename)
        #expect(tabs[1].distinctDisplayName(in: tabs, preservingFilenameTail: true) == "final/chapters/" + filename)
    }

    @Test func accessibilityTabNamesResolveLiteralEllipsisCollision() {
        let tabs = ["chapter-07.typ", "chapter-08.typ", "appendix-07.typ", "appendix-08.typ", "c…07.typ"].map {
            ProjectFileTab(relativePath: $0, displayName: $0, kind: .typ)
        }
        let labels = tabs.map { $0.distinctDisplayName(in: tabs, preservingFilenameTail: true) }
        #expect(Set(labels).count == tabs.count)
        #expect(labels.allSatisfy { $0.hasSuffix(".typ") })
        // Ordering of the open tabs must not change the resolved labels.
        let reversed = Array(tabs.reversed())
        #expect(tabs.map { $0.distinctDisplayName(in: reversed, preservingFilenameTail: true) } == labels)
    }

}
