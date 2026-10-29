import XCTest
import UIKit
import SwiftUI
@testable import InkPond

final class EditorCommandPresentationTests: XCTestCase {
    func testLargestSafeRegionBothFoldAxesAndCameraWithBoundary() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        for fold in [CGRect(x: 435, y: 0, width: 30, height: 700),
                     CGRect(x: 0, y: 280, width: 900, height: 30)] {
            let obstacles = [fold, CGRect(x: 20, y: 20, width: 70, height: 60)]
            let actual = EditorCommandGeometry.usable(in: bounds, excluding: obstacles)
            XCTAssertTrue(bounds.insetBy(dx: 20, dy: 20).contains(actual))
            XCTAssertGreaterThan(actual.width * actual.height, 0)
            for obstacle in obstacles {
                let overlap = actual.intersection(obstacle.insetBy(dx: -20, dy: -20))
                XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
            }
        }
        XCTAssertEqual(EditorCommandGeometry.usable(in: bounds, excluding: []), bounds.insetBy(dx: 20, dy: 20))
        XCTAssertEqual(EditorCommandGeometry.usable(in: CGRect(x: 0, y: 0, width: 30, height: 30), excluding: []), .zero)
    }

    func testKeyboardReflowRetainsUsableSnippetPresentation() {
        let full = EditorCommandGeometry(bounds: CGRect(x: 0, y: 0, width: 600, height: 700),
                                         region: CGRect(x: 20, y: 20, width: 560, height: 660), needsPanel: true)
        let keyboard = EditorCommandGeometry(bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
                                             region: CGRect(x: 20, y: 20, width: 560, height: 360), needsPanel: true)
        let minimum = EditorCommandHeader.minimumSize(title: "Insert Snippet…", done: "Done", width: 560,
                                                       category: .large)
        XCTAssertNotEqual(full, keyboard)
        // Full-geometry inequality must not dismiss search; both layouts can
        // still expose a complete native header and a complete result row.
        XCTAssertTrue(full.canPresent(minimumSize: minimum))
        XCTAssertTrue(keyboard.canPresent(minimumSize: minimum))
        XCTAssertGreaterThanOrEqual(keyboard.region.height - (minimum.height - 44), 44)
    }

    func testMeasuredSourceSlotReflowDoesNotSubtractSafeInsetsAgain() {
        let division = CGRect(x: 194.5, y: -82, width: 80, height: 669)
        for height: CGFloat in [587, 323, 300] {
            let slot = CGRect(x: 0, y: 0, width: 307, height: height)
            let region = EditorCommandGeometry.usable(in: slot, excluding: [division])
            XCTAssertEqual(region, CGRect(x: 20, y: 20, width: 154.5, height: height - 40))
            XCTAssertTrue(EditorCommandGeometry(bounds: slot, region: region, needsPanel: true)
                .canPresent(minimumSize: CGSize(width: 128, height: 111)))
            XCTAssertEqual(EditorCommandGeometry.usable(in: slot, excluding: []),
                           CGRect(x: 20, y: 20, width: 267, height: height - 40))
        }
        let tiny = CGRect(x: 0, y: 0, width: 307, height: 140)
        let region = EditorCommandGeometry.usable(in: tiny, excluding: [division])
        XCTAssertEqual(region, CGRect(x: 20, y: 20, width: 154.5, height: 100))
        XCTAssertFalse(EditorCommandGeometry(bounds: tiny, region: region, needsPanel: true)
            .canPresent(minimumSize: CGSize(width: 128, height: 111)))
    }

    func testTinyRegionAndDynamicTypeHeaderCannotBlockEditor() {
        let title = "Insert Symbol…"
        let normal = EditorCommandHeader.minimumSize(title: title, done: "Done", width: 240, category: .large)
        let accessible = EditorCommandHeader.minimumSize(title: title, done: "Done", width: 240,
                                                         category: .accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(accessible.height, normal.height)
        let tiny = EditorCommandGeometry(bounds: .zero, region: CGRect(x: 20, y: 20, width: 240, height: 43),
                                         needsPanel: true)
        XCTAssertFalse(tiny.canPresent(minimumSize: normal))
        let normalOnly = EditorCommandGeometry(bounds: .zero,
                                               region: CGRect(x: 20, y: 20, width: 240, height: normal.height),
                                               needsPanel: true)
        XCTAssertTrue(normalOnly.canPresent(minimumSize: normal))
        XCTAssertFalse(normalOnly.canPresent(minimumSize: accessible))
        let narrow = EditorCommandGeometry(bounds: .zero, region: CGRect(x: 20, y: 20, width: 43, height: 700),
                                           needsPanel: true)
        XCTAssertFalse(narrow.canPresent(minimumSize: normal))
        XCTAssertGreaterThanOrEqual(normal.height, 89)
        XCTAssertGreaterThanOrEqual(accessible.height, 89)
    }

    func testStackedAccessibleHeaderFitsNarrowSafeColumnWithoutShrinking() {
        let size = EditorCommandHeader.minimumSize(title: "More actions", done: "Done", width: 154.5,
                                                   category: .accessibilityExtraExtraExtraLarge)
        XCTAssertLessThanOrEqual(size.width, 154.5)
        XCTAssertLessThan(size.height, 547)
        XCTAssertGreaterThanOrEqual(size.height, 44 + 44 + 1)
    }

    func testPendingOpenUsesLiveBufferAndSelectionNotCapturedAnchorAgain() {
        let anchor = EditorCommandAnchor(projectID: "p", fileName: "a", loadToken: UUID(),
                                         selection: NSRange(location: 5, length: 0), restoreFocus: true)
        let pending = EditorCommandPendingOpen(anchor: anchor, source: "original")
        // Resigning focus is not an insertion-anchor change.
        let resigned = EditorCommandAnchor(projectID: anchor.projectID, fileName: anchor.fileName,
            loadToken: anchor.loadToken, selection: anchor.selection, restoreFocus: false)
        XCTAssertTrue(pending.isCurrent(current: resigned, source: "original"))
        XCTAssertFalse(pending.isCurrent(current: resigned, source: "competing edit"))
        let moved = EditorCommandAnchor(projectID: anchor.projectID, fileName: anchor.fileName,
            loadToken: anchor.loadToken, selection: NSRange(location: 6, length: 0), restoreFocus: false)
        XCTAssertFalse(pending.isCurrent(current: moved, source: "original"))
        let reloaded = EditorCommandAnchor(projectID: anchor.projectID, fileName: anchor.fileName,
            loadToken: UUID(), selection: anchor.selection, restoreFocus: false)
        XCTAssertFalse(pending.isCurrent(current: reloaded, source: "original"))
    }

    func testPendingOpenWithoutSoftwareKeyboardDoesNotRequireAnotherHideOrZeroSafeInset() {
        let anchor = EditorCommandAnchor(projectID: "p", fileName: "a", loadToken: UUID(),
                                         selection: NSRange(location: 5, length: 0), restoreFocus: true)
        let pending = EditorCommandPendingOpen(anchor: anchor, source: "original")
        var geometry = EditorCommandGeometry(bounds: .zero,
            region: CGRect(x: 20, y: 20, width: 154.5, height: 260), needsPanel: true)
        geometry.safeInsets.bottom = 34 // A non-keyboard safe inset is not a transition.
        XCTAssertTrue(pending.canOpen(current: anchor, source: "original", keyboardTransitionInFlight: false,
            geometry: geometry, minimum: EditorCommandRecovery.minimumSize))
        XCTAssertFalse(pending.canOpen(current: anchor, source: "original", keyboardTransitionInFlight: true,
            geometry: geometry, minimum: EditorCommandRecovery.minimumSize))
        XCTAssertFalse(pending.canOpen(current: anchor, source: "edited", keyboardTransitionInFlight: false,
            geometry: geometry, minimum: EditorCommandRecovery.minimumSize))
        XCTAssertFalse(pending.canOpen(current: anchor, source: "original", keyboardTransitionInFlight: false,
            geometry: nil, minimum: EditorCommandRecovery.minimumSize))
    }

    func testDesign1217RecoveryOnlyWhenFullHeaderDoesNotFit() {
        let full = CGSize(width: 153, height: 297)
        XCTAssertTrue(EditorCommandRecovery.isNeeded(region: CGSize(width: 154.5, height: 260), fullHeaderMinimum: full))
        XCTAssertFalse(EditorCommandRecovery.isNeeded(region: CGSize(width: 154.5, height: 547), fullHeaderMinimum: full))
        XCTAssertFalse(EditorCommandRecovery.isNeeded(region: full, fullHeaderMinimum: full))
        XCTAssertEqual(EditorCommandRecovery.minimumSize.width, 8 + 44 + 8 + 44 + 8)
        XCTAssertEqual(EditorCommandRecovery.minimumSize.height, 44 + 1 + 44)
    }

    func testDesign1227NarrowMaxAXRetainsCompactHeaderAfterKeyboardDismissal() {
        let full = CGSize(width: 153, height: 359)
        for height in [CGFloat(283), CGFloat(547)] {
            XCTAssertTrue(EditorCommandRecovery.isNeeded(region: CGSize(width: 154.5, height: height),
                fullHeaderMinimum: full, category: .accessibilityExtraExtraExtraLarge))
        }
        XCTAssertFalse(EditorCommandRecovery.isNeeded(region: CGSize(width: 154.5, height: 547),
            fullHeaderMinimum: CGSize(width: 128, height: 111), category: .large))
        XCTAssertFalse(EditorCommandRecovery.isNeeded(region: CGSize(width: 1024, height: 547),
            fullHeaderMinimum: full, category: .accessibilityExtraExtraExtraLarge))
    }

    func testUnknownUndersizeLatchesNonmodalEvenWhenGeometryRecovers() {
        var safety = EditorCommandSessionSafety()
        safety.observe(region: CGSize(width: 154.5, height: 260))
        XCTAssertFalse(safety.awaitingExplicitResume)
        // Zero may be transient: do not interpret this as a stable-layout
        // verdict or close the mounted browser. The nonmodal latch is safe.
        safety.observe(region: .zero)
        XCTAssertTrue(safety.awaitingExplicitResume)
        safety.observe(region: CGSize(width: 154.5, height: 547))
        XCTAssertTrue(safety.awaitingExplicitResume)
        XCTAssertTrue(safety.resumeExplicitly(region: CGSize(width: 154.5, height: 547)))
        XCTAssertFalse(safety.awaitingExplicitResume)
    }

    func testUnknownInsufficientRecoveryCannotResumeUntilExplicitMoreFits() {
        var safety = EditorCommandSessionSafety()
        safety.observe(region: CGSize(width: 100, height: 40))
        XCTAssertTrue(safety.awaitingExplicitResume)
        XCTAssertFalse(safety.resumeExplicitly(region: CGSize(width: 100, height: 40)))
        XCTAssertTrue(safety.awaitingExplicitResume)
        safety.observe(region: EditorCommandRecovery.minimumSize)
        XCTAssertTrue(safety.awaitingExplicitResume)
        XCTAssertTrue(safety.resumeExplicitly(region: EditorCommandRecovery.minimumSize))
        XCTAssertFalse(safety.awaitingExplicitResume)
    }

    func testDiagnosticRingRetainsLastSixAfterCloseWithoutDuplicates() {
        var samples: [String] = []
        for index in 0..<8 {
            samples = EditorCommandDiagnosticRing.appending("geometry-\(index)", to: samples)
        }
        XCTAssertEqual(samples, ["geometry-2", "geometry-3", "geometry-4", "geometry-5", "geometry-6", "geometry-7"])
        samples = EditorCommandDiagnosticRing.appending("close", to: samples)
        XCTAssertEqual(samples.count, 6)
        XCTAssertEqual(samples.last, "close")
        XCTAssertEqual(EditorCommandDiagnosticRing.appending("close", to: samples), samples)
    }

    @MainActor
    func testNativePresentationAccessibilityExclusionRestoresWithoutMutatingDocument() {
        let view = TypstTextView()
        view.text = "unchanged"
        view.selectedRange = NSRange(location: 2, length: 3)
        view.isEditable = true
        EditorView.applyAccessibilityPresentationExclusion(true, to: view)
        XCTAssertFalse(view.isAccessibilityElement)
        XCTAssertTrue(view.accessibilityElementsHidden)
        XCTAssertEqual(view.text, "unchanged")
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertTrue(view.isEditable)
        EditorView.applyAccessibilityPresentationExclusion(false, to: view)
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertFalse(view.accessibilityElementsHidden)
        XCTAssertEqual(view.text, "unchanged")
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertTrue(view.isEditable)
    }

    func testAnchorRejectsSwitchAwayAndBackAndReadOnly() {
        let token = UUID()
        let anchor = EditorCommandAnchor(projectID: "project", fileName: "main.typ", loadToken: token,
                                         selection: NSRange(location: 3, length: 2), restoreFocus: true)
        XCTAssertTrue(anchor.matches(projectID: "project", fileName: "main.typ", loadToken: token, writable: true))
        XCTAssertFalse(anchor.matches(projectID: "other", fileName: "main.typ", loadToken: token, writable: true))
        XCTAssertFalse(anchor.matches(projectID: "project", fileName: "other.typ", loadToken: token, writable: true))
        XCTAssertFalse(anchor.matches(projectID: "project", fileName: "main.typ", loadToken: UUID(), writable: true))
        XCTAssertFalse(anchor.matches(projectID: "project", fileName: "main.typ", loadToken: token, writable: false))
    }

    func testExactOrderedSymbolsIncludingTwoSpaceIndent() {
        XCTAssertEqual(EditorCommandSymbol.all.map(\.literal), ["⇥", "#", "$", "=", "*", "_", "{", "}", "[", "]", "(", ")", "<", ">", "@", "/"])
        XCTAssertEqual(EditorCommandSymbol.all.first?.insertion, "  ")
        XCTAssertEqual(EditorCommandSymbol.all.last?.insertion, "/")
        for symbol in EditorCommandSymbol.all { XCTAssertTrue(symbol.title.contains(symbol.literal)) }
    }

    func testApprovedLocalizedInsertionNames() throws {
        for (language, expected) in [
            ("en", ["Insert Symbol…", "Insert Snippet…", "Insert Image…"]),
            ("zh-Hans", ["插入符号…", "插入片段…", "插入图片…"]),
            ("zh-Hant-HK", ["插入符號…", "插入片段…", "插入圖片…"]),
            ("zh-Hant-TW", ["插入符號…", "插入片段…", "插入圖片…"])
        ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let actual = ["editor.command.insert_symbol", "editor.command.insert_snippet", "editor.command.insert_image"]
                .map { bundle.localizedString(forKey: $0, value: nil, table: "Localizable") }
            XCTAssertEqual(actual, expected)
        }
    }

    @MainActor
    func testNativeInsertionReplacesSelectionAndUndoRedoRestoreActualTextAndCaret() {
        let view = TypstTextView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        view.becomeFirstResponder()
        defer { view.resignFirstResponder(); window.isHidden = true }
        view.isEditable = true
        view.text = "abcdef"
        view.selectedRange = NSRange(location: 2, length: 2)
        let manager = try! XCTUnwrap(view.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        EditorUndoReplacement.register(in: view, range: NSRange(location: 2, length: 1),
                                       replacement: "cd", selection: view.selectedRange)
        view.textStorage.replaceCharacters(in: view.selectedRange, with: "#")
        view.selectedRange = NSRange(location: 3, length: 0)
        manager.endUndoGrouping()
        let commands = EditorCommandTarget()
        commands.register(view)
        commands.refresh()
        XCTAssertEqual(view.text, "ab#ef")
        XCTAssertTrue(commands.canUndo)
        commands.undo()
        XCTAssertEqual(view.text, "abcdef")
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 2))
        XCTAssertTrue(commands.canRedo)
        commands.redo()
        XCTAssertEqual(view.text, "ab#ef")
        XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
        view.isEditable = false
        commands.refresh()
        XCTAssertFalse(commands.canUndo)
        XCTAssertFalse(commands.canRedo)
        commands.undo()
        XCTAssertEqual(view.text, "ab#ef")
        XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 0))
    }

    @MainActor
    func testQueuedInsertionUsesExistingCoordinatorAndSnippetCursorOffset() {
        let buffer = CommandTestBuffer()
        let token = UUID()
        let request = EditorInsertionRequest(text: "hello", targetRange: NSRange(location: 1, length: 2),
                                             targetFileName: "main.typ", targetLoadToken: token, cursorOffset: 2)
        let editor = EditorView(text: Binding(get: { buffer.text }, set: { buffer.text = $0 }),
                                insertionRequest: .constant(nil), findRequested: .constant(false),
                                viewState: Binding(get: { buffer.state }, set: { buffer.state = $0 }),
                                cursorJumpOffset: .constant(nil), fileLoadToken: token)
        let coordinator = editor.makeCoordinator()
        let view = TypstTextView()
        view.text = buffer.text
        view.isEditable = true
        coordinator.textView = view
        coordinator.insertText(request)
        XCTAssertEqual(buffer.text, "ahellodef")
        XCTAssertEqual(view.text, "ahellodef")
        XCTAssertEqual(buffer.state.selectedLocation, 3)
        XCTAssertEqual(buffer.state.selectedLength, 0)
    }
}

@MainActor
private final class CommandTestBuffer {
    var text = "abcdef"
    var state = EditorViewState()
}
