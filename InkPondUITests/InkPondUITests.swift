//
//  InkPondUITests.swift
//  InkPondUITests
//
//  Created by Lin Qidi on 2026/3/2.
//

import XCTest
import UIKit

final class InkPondUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchApp(
        seedDocument: Bool = false,
        inMemoryStore: Bool = true,
        environment: [String: String] = [:],
        arguments: [String] = []
    ) -> XCUIApplication {
        app?.terminate()

        let app = XCUIApplication()
        app.launchArguments += [
            "UITEST_SKIP_ONBOARDING",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        if inMemoryStore {
            app.launchArguments.append("UITEST_IN_MEMORY_STORE")
        }
        if seedDocument {
            app.launchArguments.append("UITEST_SEED_SAMPLE_DOCUMENT")
        }
        app.launchArguments += arguments
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        self.app = app
        return app
    }

    private func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        revealWithSwipes: Int = 0
    ) -> Bool {
        if element.waitForExistence(timeout: timeout) {
            return true
        }

        for _ in 0..<revealWithSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }

        return element.exists
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        if app?.state == .runningForeground {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app?.terminate()
        app = nil
    }

    @MainActor
    func testExample() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["document-list.settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["document-list.sort"].exists)
        XCTAssertTrue(app.buttons["document-list.add"].exists)
    }

    @MainActor
    func testFirstCreatedDocumentAcceptsTypingSymbolsAndSnippetAfterReopen() throws {
        // Exercise the real on-disk store: iOS 17's in-memory Core Data store can
        // throw "No eligible connection available" during first insertion/save.
        let app = launchApp(inMemoryStore: false)
        let add = app.buttons["document-list.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let editor = app.textViews["editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.isEnabled, "New project must acquire the writable lease")
        // Tap well inside the text area, away from the top close control.
        let insertionPoint = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.65))
        let close = app.buttons["editor.close-project"]
        XCTAssertFalse(close.frame.contains(insertionPoint.screenPoint), "Editor tap overlaps close button")
        insertionPoint.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 4) else {
            XCTFail("First-created editor did not expose a keyboard. UI: \(app.debugDescription)")
            return
        }
        for key in ["a", "b", "c"] {
            let button = app.keyboards.keys[key]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "Keyboard key \(key) is missing")
            button.tap()
        }
        XCTAssertTrue(waitForEditor(editor, containing: "abc"))

        let symbol = app.buttons["Insert asterisk"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 5))
        symbol.tap()
        XCTAssertTrue(waitForEditor(editor, containing: "abc*"))

        let snippet = app.buttons["Insert snippet"]
        XCTAssertTrue(snippet.waitForExistence(timeout: 5))
        snippet.tap()
        let basic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Basic Document")).firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 5))
        basic.tap()
        XCTAssertTrue(waitForEditor(editor, containing: "#set page(paper: \"a4\")"))

        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "project-home.card.")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEditor(editor, containing: "abc*"))
        XCTAssertTrue(waitForEditor(editor, containing: "#set page(paper: \"a4\")"))
    }

    private func waitForEditor(_ editor: XCUIElement, containing text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text),
            object: editor
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor
    func testSettingsScreenExposesPrimaryEntries() throws {
        let app = launchApp()

        app.buttons["document-list.settings"].tap()

        XCTAssertTrue(waitForElement(app.buttons["settings.done"]))
        XCTAssertTrue(waitForElement(app.buttons["settings.import-zip"], revealWithSwipes: 2))
        XCTAssertTrue(waitForElement(app.buttons["settings.fonts"], revealWithSwipes: 2))
        XCTAssertTrue(waitForElement(app.buttons["settings.cache"], revealWithSwipes: 2))
    }

    @MainActor
    func testSeededDocumentExposesEditorPrimaryControls() throws {
        let app = launchApp(seedDocument: true)

        openSeededDocumentIfNeeded(in: app)

        XCTAssertTrue(waitForEditorShell(in: app, timeout: 5))
        XCTAssertTrue(app.buttons["editor.more-menu"].exists)
        XCTAssertTrue(
            app.segmentedControls["editor.mode-picker"].exists
                || app.otherElements["editor.preview"].exists
                || app.textViews["editor.text-view"].exists
        )
    }

    @MainActor
    func testCompactSwipeSwitchesBetweenEditorAndPreview() throws {
        let app = launchApp(seedDocument: true)
        openSeededDocumentIfNeeded(in: app)

        let modePicker = app.segmentedControls["editor.mode-picker"]
        if !modePicker.waitForExistence(timeout: 3) {
            throw XCTSkip("Compact mode picker is not visible on this simulator.")
        }

        let preview = app.otherElements["editor.preview"]
        app.swipeLeft()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        app.swipeRight()
        XCTAssertTrue(app.textViews["editor.text-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForNonExistence(preview, timeout: 5))
    }

    @MainActor
    func testCompactPreviewSurfaceSwipeReturnsToEditor() throws {
        let app = launchApp(
            seedDocument: true,
            environment: ["UITEST_START_IN_PREVIEW": "1"]
        )
        openSeededDocumentIfNeeded(in: app)

        let modePicker = app.segmentedControls["editor.mode-picker"]
        if !modePicker.waitForExistence(timeout: 3) {
            throw XCTSkip("Compact mode picker is not visible on this simulator.")
        }

        let preview = openPreview(in: app, requireRenderedPDF: true)

        preview.swipeRight()
        XCTAssertTrue(app.textViews["editor.text-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForNonExistence(preview, timeout: 5))
    }

    @MainActor
    func testUnavailableDocumentRowDoesNotOpenEditor() throws {
        let app = launchApp(environment: ["UITEST_SEED_STALE_DOCUMENT": "1"])
        let staleRow = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                "project-home.card.ui-test-stale-",
                "document-list.row.ui-test-stale-"
            )
        ).firstMatch

        XCTAssertTrue(staleRow.waitForExistence(timeout: 5))
        staleRow.tap()

        let alert = app.alerts["Project Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["editor.text-view"].exists)
        XCTAssertFalse(app.otherElements["editor.preview"].exists)

        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["document-list.add"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChinesePreviewShowsVisibleInk() throws {
        let app = launchApp(
            seedDocument: true,
            environment: [
                "UITEST_START_IN_PREVIEW": "1",
                "UITEST_SAMPLE_CONTENT": "= 标题\n\n这里是中文预览测试。\n\n第二段也只包含中文字符。"
            ]
        )

        let preview = openPreview(in: app, requireRenderedPDF: true)

        let darkPixels = waitForVisibleInk(in: preview)
        XCTAssertGreaterThan(
            darkPixels,
            4000,
            "Expected visible preview ink, got only \(darkPixels) dark pixels"
        )
    }

    @MainActor
    func testEmojiPreviewShowsVisibleInk() throws {
        let app = launchApp(
            seedDocument: true,
            environment: [
                "UITEST_START_IN_PREVIEW": "1",
                "UITEST_SAMPLE_CONTENT": """
                #set page(width: 120pt, height: 120pt, margin: 12pt)
                #set text(size: 72pt)
                😀
                """
            ]
        )

        let preview = openPreview(in: app, requireRenderedPDF: true)

        let darkPixels = waitForVisibleInk(in: preview, minimumVisiblePixels: 1000)
        XCTAssertGreaterThan(
            darkPixels,
            1000,
            "Expected visible emoji preview ink, got only \(darkPixels) dark pixels"
        )
    }

    private func workspaceFile(_ index: Int) -> String {
        String(format: "workspace-verification-long-similar-chapter-%02d.typ", index)
    }

    @MainActor
    private func launchWorkspace(arguments: [String] = []) -> XCUIApplication {
        let app = launchApp(seedDocument: true, inMemoryStore: false, environment: [
            "UITEST_WORKSPACE_FIXTURE": "1"
        ], arguments: arguments)
        XCTAssertTrue(app.textViews["editor.text-view"].waitForExistence(timeout: 15))
        return app
    }

    private func workspaceTab(_ index: Int) -> XCUIElement {
        app.buttons["project-workspace.tab.\(workspaceFile(index))"]
    }

    private func assertActiveTab(_ index: Int) {
        let tab = workspaceTab(index)
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: tab)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Active tab must be scrolled into view after the Files sheet dismisses")
        XCTAssertEqual(tab.value as? String, "Selected", "Active tab must expose selected state")
        XCTAssertEqual(tab.label, workspaceFile(index), "Tab must expose its full relative path")
        XCTAssertGreaterThanOrEqual(tab.frame.width, 44, "Tab selection needs its own 44pt hit area")
        XCTAssertGreaterThanOrEqual(tab.frame.height, 44, "Tab selection needs its own 44pt hit area")
        let strip = app.scrollViews["project-workspace.tab-strip"]
        let close = app.buttons["project-workspace.close-tab.\(workspaceFile(index))"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "Tab strip must expose its actual viewport")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Selected tab needs a separate close button")
        // Hittable alone accepts a button with only a few points visible.
        // Allow only sub-point rounding, not a partially clipped control.
        let epsilon: CGFloat = 0.5
        let fullyVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard strip.exists, tab.exists, close.exists else { return false }
            let viewport = strip.frame.insetBy(dx: -epsilon, dy: -epsilon)
            return viewport.contains(tab.frame) && viewport.contains(close.frame)
        }, object: strip)
        let containmentResult = XCTWaiter.wait(for: [fullyVisible], timeout: 5)
        if containmentResult != .completed {
            let geometry = "strip=\(strip.frame) tab=\(tab.frame) close=\(close.frame)"
            let diagnostic = XCTAttachment(string: geometry + "\n" + app.debugDescription)
            diagnostic.name = "workspace-tab-\(index)-containment-failure"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertEqual(containmentResult, .completed,
                       "Selected tab and its close button must be fully inside the tab-strip viewport")
        let viewport = strip.frame.insetBy(dx: -epsilon, dy: -epsilon)
        XCTAssertTrue(viewport.contains(tab.frame), "Entire selected button must be visible")
        XCTAssertTrue(viewport.contains(close.frame), "Entire close button must be visible")
        XCTAssertTrue(close.isHittable, "Close must remain independently accessible")
        XCTAssertGreaterThanOrEqual(close.frame.width + epsilon, 44, "Close needs its own 44pt hit area")
        XCTAssertGreaterThanOrEqual(close.frame.height + epsilon, 44, "Close needs its own 44pt hit area")
        let overlap = tab.frame.intersection(close.frame)
        XCTAssertTrue(overlap.isNull || overlap.width <= epsilon || overlap.height <= epsilon,
                      "Select and close hit areas must not overlap")
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-\(index)"))
    }

    private func openWorkspaceFile(_ index: Int, scrollDiagnostics: Bool = false, requireOverflowMovement: Bool = false, captureVisibleSheet: Bool = false) {
        let tree = app.descendants(matching: .any)["project-file-tree"]
        // The presented browser and the workspace sidebar can both expose the
        // same file. Target the browser tree this helper opens and scrolls, not
        // the independently retained project-workspace.file-tree-sidebar.
        let row = tree.buttons["project-files.row.\(workspaceFile(index))"]
        if !tree.exists || tree.frame.intersection(app.windows.firstMatch.frame).isEmpty {
            let toggle = app.buttons["project-workspace.file-tree-toggle"]
            if toggle.exists {
                toggle.tap()
            } else {
                // Compact toolbar presents the actual Project Files sheet, not
                // the regular-width sidebar toggle.
                let files = app.buttons.matching(NSPredicate(
                    format: "identifier == %@ OR label == %@",
                    "editor.project-files", "Project Files"
                )).firstMatch
                if !files.exists || !files.isHittable {
                    let more = app.buttons["editor.more-menu"]
                    if more.exists && more.isHittable {
                        // Compact scenes deliberately keep Files in the app's
                        // More control, including its confined division panel.
                        more.tap()
                    } else {
                        // Retain the legacy native overflow path for a scene
                        // whose visible toolbar has no app-owned More control.
                        let overflow = app.buttons["BottomOverflowBarButtonItem"]
                        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
                        XCTAssertTrue(overflow.isHittable)
                        overflow.tap()
                    }
                }
                XCTAssertTrue(files.waitForExistence(timeout: 5))
                XCTAssertTrue(files.isHittable)
                files.tap()
            }
        }
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        // Lazy rows may not exist until scrolled into view; hittability alone
        // also admits partially clipped rows whose center is outside the tree.
        let browserNavigationBar = app.navigationBars["Project Files"]
        func visibleTreeFrame() -> CGRect {
            var viewport = tree.frame.intersection(app.windows.firstMatch.frame)
            if browserNavigationBar.exists {
                let navigationFrame = browserNavigationBar.frame
                if viewport.intersects(navigationFrame) {
                    let top = min(viewport.maxY, max(viewport.minY, navigationFrame.maxY))
                    viewport = CGRect(x: viewport.minX, y: top,
                                      width: viewport.width, height: viewport.maxY - top)
                }
            }
            return viewport
        }
        func rowIsFullyVisible() -> Bool {
            guard row.exists && row.isHittable else { return false }
            let viewport = visibleTreeFrame()
            let frame = row.frame
            return !viewport.isEmpty && !frame.isEmpty
                && viewport.insetBy(dx: -1, dy: -1).contains(frame)
                && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let probe = tree
        func captureScrollProbe(_ phase: String) {
            guard scrollDiagnostics else { return }
            let snapshot = "\(phase): \((probe.value as? String ?? ""))"
            print(snapshot)
            let attachment = XCTAttachment(string: snapshot)
            attachment.name = "project-files-scroll-\(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if scrollDiagnostics {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (probe.value as? String ?? "").contains("scroll[0]")
            }, object: tree)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                           "Probe must find the tree's enclosing UIScrollView")
        }
        captureScrollProbe("before-scroll")
        // Require a real offscreen target, not merely a successful tap in the
        // taller experimental sheet. An absent lazy row is also offscreen.
        let initialViewport = visibleTreeFrame()
        let initiallyOffscreen = !row.exists || row.frame.intersection(initialViewport).isEmpty
        let movementAnchor = tree.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "project-files.row.workspace-verification-long-similar-chapter-"
        )).allElementsBoundByIndex.first {
            !$0.frame.intersection(initialViewport).isEmpty
        }
        let initialAnchorFrame = movementAnchor?.frame
        var dragCount = 0
        var contentMoved = false
        if requireOverflowMovement {
            XCTAssertTrue(initiallyOffscreen, "Far fixture must start entirely offscreen even in the large sheet")
            XCTAssertNotNil(initialAnchorFrame, "Need a visible content anchor to prove scrolling")
        }
        for attempt in 0..<8 {
            if rowIsFullyVisible() { break }
            let viewport = visibleTreeFrame()
            let visibleIdentifiers = tree.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@",
                "project-files.row.workspace-verification-long-similar-chapter-"
            )).allElementsBoundByIndex.filter {
                !$0.frame.intersection(viewport).isEmpty
            }.map { $0.identifier }
            let targetPrecedesVisibleRows = visibleIdentifiers.min().map {
                "project-files.row.\(workspaceFile(index))" < $0
            } ?? false
            // Keep both endpoints in content: the tree AX frame can include
            // the sheet's navigation bar, where generic swipes do not scroll.
            guard !viewport.isEmpty else { break }
            let content = viewport.insetBy(dx: min(16, viewport.width / 4),
                                          dy: min(16, viewport.height / 4))
            let scrollDown = (row.exists && row.frame.minY < viewport.minY)
                || (!row.exists && targetPrecedesVisibleRows)
            let overflow = row.exists
                ? (scrollDown ? viewport.minY - row.frame.minY : row.frame.maxY - viewport.maxY)
                : content.height * 0.6
            let distance = min(content.height * 0.65, max(content.height * 0.4, overflow + 12))
            let startY = scrollDown ? content.minY + content.height * 0.1 : content.maxY - content.height * 0.1
            let endY = scrollDown ? startY + distance : startY - distance
            let origin = tree.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: content.midX - tree.frame.minX, dy: startY - tree.frame.minY))
            let end = origin.withOffset(CGVector(dx: content.midX - tree.frame.minX, dy: endY - tree.frame.minY))
            print("Scrolling workspace file \(index): row=\(row.exists ? row.frame : .zero) viewport=\(viewport) distance=\(distance) down=\(scrollDown)")
            captureScrollProbe("before-drag-\(attempt)")
            start.press(forDuration: 0.05, thenDragTo: end)
            dragCount += 1
            if let anchor = movementAnchor, let initial = initialAnchorFrame, anchor.exists {
                // Relative to the viewport: sheet translation alone cannot
                // satisfy this evidence of content movement.
                let relativeBefore = initial.minY - initialViewport.minY
                let relativeAfter = anchor.frame.minY - visibleTreeFrame().minY
                contentMoved = contentMoved || abs(relativeAfter - relativeBefore) > 10
            }
            captureScrollProbe("after-drag-\(attempt)")
        }
        print("Opening workspace file \(index): exists=\(row.exists) row=\(row.frame) tree=\(tree.frame) visibleTree=\(visibleTreeFrame()) center=\(CGPoint(x: row.frame.midX, y: row.frame.midY))")
        if !rowIsFullyVisible() {
            captureWorkspaceDiagnostics("workspace-file-\(index)-visibility-failure")
        }
        captureScrollProbe("before-row-assertions")
        if requireOverflowMovement {
            XCTAssertGreaterThan(dragCount, 0, "Far fixture must require a real content drag")
            XCTAssertTrue(contentMoved, "Visible content must move relative to the viewport, not just resize the sheet")
        }
        XCTAssertTrue(row.exists)
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(rowIsFullyVisible(), "Entire file row and its center must be inside the visible tree")
        let wasPresentedSheet = browserNavigationBar.exists
        if captureVisibleSheet {
            // Capture only after the full-row/center/hittability checks and
            // before the real tap dismisses Files. Includes Done, the current
            // selection, and the validated target/end row in the same image.
            let size = app.launchArguments.contains("UICTContentSizeCategoryAccessibilityXXXL") ? "maxAX" : "normal"
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "project-files-\(size)-sheet-file-\(index)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if wasPresentedSheet {
            let dismissed = waitForNonExistence(browserNavigationBar, timeout: 5)
            if !dismissed {
                captureWorkspaceDiagnostics("workspace-file-\(index)-sheet-dismissal-failure")
            }
            XCTAssertTrue(dismissed,
                          "Files sheet must dismiss before checking the revealed tab")
        }
        assertActiveTab(index)
    }

    @MainActor
    func testProjectFilesLargestAccessibilityScrollProbe() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = originalOrientation }
        _ = launchWorkspace(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-UITestFileScrollDiagnostics"
        ])
        // Same Files presentation, full-row containment, open, and active-tab
        // assertions as the existing regression path; no alternate opening path.
        openWorkspaceFile(6, scrollDiagnostics: true)
        openWorkspaceFile(7, scrollDiagnostics: true)
        // The existing fixture has eight files (not fifteen). Use its farthest
        // row and fail if this device can show it without genuine overflow.
        openWorkspaceFile(8, scrollDiagnostics: true, requireOverflowMovement: true)
    }

    @MainActor
    func testProjectFilesLargestAccessibilityRealScrollRegression() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = originalOrientation }
        // Deliberately omit the opt-in probe: verify the shipping interaction
        // with the same strict geometry and real-gesture overflow assertions.
        _ = launchWorkspace(arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openWorkspaceFile(6)
        openWorkspaceFile(7)
        openWorkspaceFile(8, requireOverflowMovement: true)
    }

    @MainActor
    func testProjectFilesSheetVisualEvidence() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = originalOrientation }
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            _ = launchWorkspace(arguments: [
                "-editorThemeID", "system", "-AppleInterfaceStyle", "Light",
                "-UIPreferredContentSizeCategoryName", category
            ])
            openWorkspaceFile(6, captureVisibleSheet: true)
            openWorkspaceFile(7, captureVisibleSheet: true)
            openWorkspaceFile(8,
                              requireOverflowMovement: category == "UICTContentSizeCategoryAccessibilityXXXL",
                              captureVisibleSheet: true)
        }
    }

    @MainActor
    func testWorkspaceOneTabAndMultipagePreview() throws {
        let app = launchWorkspace()
        // Both size classes deliberately hide the strip for a single tab.
        XCTAssertFalse(workspaceTab(1).exists)
        XCTAssertFalse(workspaceTab(2).exists)
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-1"))
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "Deterministic page 3"))
        captureWorkspaceDiagnostics("before-preview")
        let preview = openPreview(in: app, requireRenderedPDF: true)
        captureWorkspaceDiagnostics("artifact-ready", preview: preview)
        // Artifact readiness and the 3-pages counter do NOT prove painted SVG.
        // Require dark glyph pixels on a white page inside the body, excluding
        // all chrome/status overlays, and more than one occupied text row.
        let painted = waitForPaintedWorkspaceBody(preview)
        captureWorkspaceDiagnostics("after-paint-wait", preview: preview)
        XCTAssertTrue(painted, "Artifact exists but page body has no visible text; inspect body crop and hierarchy")
        XCTAssertEqual(app.descendants(matching: .any)["editor.preview.rendered"].value as? String,
                       "3 pages", "Fixture must compile to three pages in either size class")
    }

    @MainActor
    func testWorkspacePDFExportPresentsShareSheet() throws {
        let app = launchWorkspace()
        let preview = openPreview(in: app, requireRenderedPDF: true)
        XCTAssertTrue(waitForPaintedWorkspaceBody(preview))
        XCTAssertEqual(app.descendants(matching: .any)["editor.preview.rendered"].value as? String, "3 pages")
        tapWorkspaceAction("Share PDF", in: app)
        // UIActivityViewController's real destination, not the app's share button.
        let activitySheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(activitySheet.waitForExistence(timeout: 30))
        let saveToFiles = activitySheet.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 30), "PDF export must present the system activity sheet")
        let pdf = activitySheet.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] %@", "PDF"
        )).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5), "Share sheet must identify a PDF payload")
        captureWorkspaceDiagnostics("workspace-pdf-share-sheet")
    }

    @MainActor
    func testWorkspaceSlideshowNavigatesThreePagesAndCloses() throws {
        let app = launchWorkspace()
        let preview = openPreview(in: app, requireRenderedPDF: true)
        XCTAssertTrue(waitForPaintedWorkspaceBody(preview))
        tapWorkspaceAction("Slideshow", in: app)
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 10))
        captureWorkspaceDiagnostics("workspace-slide-1")
        // Query leaf controls by semantic ID: the presenting editor remains
        // in the AX tree behind the full-screen cover on both size classes.
        func control(_ identifier: String) throws -> XCUIElement {
            let controls = app.buttons.matching(identifier: identifier)
            XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(controls.count, 1, "Expected exactly one slideshow control: \(identifier)")
            return try XCTUnwrap(controls.allElementsBoundByIndex.first)
        }
        let deck = app.otherElements["slideshow.deck"]
        XCTAssertTrue(deck.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPaintedWorkspaceBody(deck))
        let firstPageInk = workspaceBodySample(deck).fingerprint
        let previous = try control("slideshow.previous")
        XCTAssertFalse(previous.isEnabled)
        try control("slideshow.next").tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForPaintedWorkspaceBody(deck, differentFrom: firstPageInk))
        let secondPageInk = workspaceBodySample(deck).fingerprint
        captureWorkspaceDiagnostics("workspace-slide-2")
        try control("slideshow.next").tap()
        XCTAssertTrue(app.staticTexts["3 / 3"].waitForExistence(timeout: 5))
        XCTAssertFalse(try control("slideshow.next").isEnabled)
        XCTAssertTrue(waitForPaintedWorkspaceBody(deck, differentFrom: secondPageInk))
        captureWorkspaceDiagnostics("workspace-slide-3")
        try control("slideshow.previous").tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 5))
        try control("slideshow.close").tap()
        XCTAssertTrue(waitForNonExistence(app.staticTexts["2 / 3"], timeout: 5))
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        captureWorkspaceDiagnostics("workspace-slideshow-closed", preview: preview)
    }

    private func tapWorkspaceAction(_ label: String, in app: XCUIApplication) {
        let action = app.buttons[label]
        if !action.exists || !action.isHittable {
            let menu = app.buttons["editor.more-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isEnabled)
        action.tap()
    }

    @MainActor
    func testWorkspaceTwoTabsSwitchAndClose() throws {
        _ = launchWorkspace()
        openWorkspaceFile(2)
        XCTAssertTrue(workspaceTab(1).exists)
        XCTAssertTrue(workspaceTab(2).exists)
        XCTAssertFalse(workspaceTab(3).exists)
        workspaceTab(1).tap()
        assertActiveTab(1)
        workspaceTab(2).tap()
        assertActiveTab(2)
        let close = app.buttons["project-workspace.close-tab.\(workspaceFile(2))"]
        XCTAssertTrue(close.isHittable, "Tab close must remain independently accessible")
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertTrue(waitForNonExistence(workspaceTab(2), timeout: 5))
        XCTAssertFalse(workspaceTab(1).exists, "Last remaining tab strip is intentionally hidden")
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-1"))
    }

    @MainActor
    func testNativeTabsAppearanceAccessibilityMatrix() throws {
        assertNativeTabsAppearance(cases: [
            ("native-tabs-light", ["-editorThemeID", "system", "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]),
            ("native-tabs-dark", ["-editorThemeID", "system", "-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]),
            ("native-tabs-custom-latte", ["-editorThemeID", "latte", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]),
            ("native-tabs-custom-mocha", ["-editorThemeID", "mocha", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]),
            ("native-tabs-largest-AX", ["-editorThemeID", "system", "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ])
    }

    @MainActor
    func testNativeTabsLargestAccessibilityRegression() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = originalOrientation }
        assertNativeTabsAppearance(cases: [
            ("native-tabs-light", ["-editorThemeID", "system", "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]),
            ("native-tabs-largest-AX", ["-editorThemeID", "system", "-AppleInterfaceStyle", "Light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ])
    }

    @MainActor
    private func assertNativeTabsAppearance(cases: [(String, [String])]) {
        var standardHeight: CGFloat = 0
        for (name, arguments) in cases {
            _ = launchWorkspace(arguments: arguments)
            XCTAssertFalse(app.scrollViews["project-workspace.tab-strip"].exists,
                           "One file must not leave an empty rail")
            for index in 2...8 { openWorkspaceFile(index) }
            assertActiveTab(8) // full viewport containment, separate 44pt targets
            let height = app.scrollViews["project-workspace.tab-strip"].frame.height
            if name == "native-tabs-light" { standardHeight = height }
            if name == "native-tabs-largest-AX" {
                XCTAssertGreaterThan(height, standardHeight + 20,
                                     "The actual rail must grow: a silently ignored size override cannot pass")
            }
            captureWorkspaceDiagnostics(name)
            openWorkspaceFile(1)
            assertActiveTab(1)
            captureWorkspaceDiagnostics(name + "-first-active")
            for index in (2...8).reversed() {
                openWorkspaceFile(index)
                assertActiveTab(index)
                app.buttons["project-workspace.close-tab.\(workspaceFile(index))"].tap()
                XCTAssertTrue(waitForNonExistence(workspaceTab(index), timeout: 5))
            }
            XCTAssertTrue(waitForNonExistence(app.scrollViews["project-workspace.tab-strip"], timeout: 5),
                          "Closing to one file must remove the complete rail immediately")
            XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-1"))
        }
    }

    @MainActor
    func testWorkspaceEightTabsKeepActiveVisible() throws {
        _ = launchWorkspace()
        for index in 2...8 { openWorkspaceFile(index) }
        for index in 1...8 {
            XCTAssertTrue(workspaceTab(index).exists, "Expected eight open tabs")
        }
        assertActiveTab(8)
        // Re-select via the real file tree: tab strip must reveal the active
        // first and last file even when the other long names overflow.
        openWorkspaceFile(1)
        assertActiveTab(1)
        openWorkspaceFile(8)
        assertActiveTab(8)
        XCTAssertTrue(app.buttons["project-workspace.close-tab.\(workspaceFile(8))"].isHittable)
    }

    @MainActor
    func testWorkspaceEightTabsAllowManualScrollWithoutSnapback() throws {
        let app = launchWorkspace()
        for index in 2...8 { openWorkspaceFile(index) }
        assertActiveTab(8)
        let selected = workspaceTab(8)
        let strip = app.scrollViews["project-workspace.tab-strip"]
        let viewport = strip.frame.intersection(app.windows.firstMatch.frame)
        let initialX = selected.frame.minX
        // The strip's AX frame can include top chrome. Use the actual tab row.
        let y = selected.frame.midY
        let endX = viewport.maxX - 8
        var dragTab = selected
        var startX = max(viewport.minX + 8, selected.frame.minX + 8)
        if endX - startX < 80 {
            // A narrow viewport may leave too little travel on tab 8. Start
            // inside the visible selection area of tab 7, never its close button.
            dragTab = workspaceTab(7)
            startX = max(viewport.minX + 8, dragTab.frame.minX + 8)
        }
        let startPoint = CGPoint(x: startX, y: y)
        XCTAssertTrue(dragTab.frame.contains(startPoint))
        XCTAssertTrue(viewport.contains(startPoint))
        XCTAssertGreaterThanOrEqual(endX - startX, 30)
        for index in 1...8 {
            XCTAssertFalse(app.buttons["project-workspace.close-tab.\(workspaceFile(index))"].frame.contains(startPoint),
                           "Manual scroll must not begin on a close control")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: startX, dy: y))
        let end = origin.withOffset(CGVector(dx: endX, dy: y))
        // A native drag on the button must be handled by its parent scroll view.
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertGreaterThanOrEqual(selected.frame.minX - initialX, 30,
                                    "Rightward manual scrolling must move the tabs, even on iPad")
        XCTAssertEqual(selected.value as? String, "Selected")
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-8"))
        captureWorkspaceDiagnostics("eight-tabs-manual-scroll-moved")
        let snapback = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(selected.frame.minX - initialX) < 30
        }, object: selected)
        snapback.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [snapback], timeout: 2), .completed,
                       "Selected tab must not snap back after a manual scroll")
        XCTAssertGreaterThanOrEqual(selected.frame.minX - initialX, 30)
        XCTAssertEqual(selected.value as? String, "Selected")
        XCTAssertTrue(waitForEditor(app.textViews["editor.text-view"], containing: "fixture-file-8"))
    }

    @MainActor
    func testWorkspaceEightTabsKeyboardTypingPreservedAcrossSwitchAndReopen() throws {
        let app = launchWorkspace()
        for index in 2...8 { openWorkspaceFile(index) }
        assertActiveTab(8)
        let editor = app.textViews["editor.text-view"]
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.04)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        captureWorkspaceDiagnostics("eight-tabs-keyboard-before-input")
        let marker = "eighttypingmarker"
        XCTAssertFalse((editor.value as? String ?? "").contains(marker))
        XCTAssertTrue(tapWorkspaceKeyboardMarker(marker, in: app))
        XCTAssertTrue(waitForEditor(editor, containing: marker))
        captureWorkspaceDiagnostics("eight-tabs-keyboard-after-input")
        openWorkspaceFile(7)
        assertActiveTab(7)
        openWorkspaceFile(8)
        assertActiveTab(8)
        XCTAssertTrue(waitForEditor(editor, containing: marker))
        captureWorkspaceDiagnostics("eight-tabs-keyboard-after-switch")
        let close = app.buttons["editor.close-project"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        // launchApp terminates the old application and updates self.app, which
        // openWorkspaceFile/workspaceTab use. Do not reuse the old editor query.
        let reopened = launchApp(inMemoryStore: false)
        let card = reopened.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND identifier BEGINSWITH %@",
            "UI Workspace Multipage Fixture", "project-home.card."
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let reopenedEditor = reopened.textViews["editor.text-view"]
        XCTAssertTrue(reopenedEditor.waitForExistence(timeout: 10))
        if !(reopenedEditor.value as? String ?? "").contains("fixture-file-8") {
            openWorkspaceFile(8)
        }
        XCTAssertTrue(waitForEditor(reopenedEditor, containing: "fixture-file-8"))
        XCTAssertTrue(waitForEditor(reopenedEditor, containing: marker))
        captureWorkspaceDiagnostics("eight-tabs-keyboard-disk-reopen")
    }

    @MainActor
    func testWorkspaceKeyboardTypingPreservedAcrossSwitchAndReopen() throws {
        let app = launchWorkspace()
        let editor = app.textViews["editor.text-view"]
        // Hit the first source line, not the gutter or the center of a long
        // wrapped document. Tap only once: a second tap can open the text
        // selection menu and interfere with XCTest's AX focus snapshot.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.04)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        captureWorkspaceDiagnostics("keyboard-before-input")
        // Tap real software-keyboard keys instead of typeText: on this simulator
        // XCTest's AX text-focus preflight fails even with the keyboard visible.
        // Key taps still require a real first responder and exercise normal input.
        let marker = "typedpreservationmarker"
        XCTAssertFalse((editor.value as? String ?? "").contains(marker))
        guard tapWorkspaceKeyboardMarker(marker, in: app) else { return }
        captureWorkspaceDiagnostics("keyboard-after-input")
        XCTAssertTrue(waitForEditor(editor, containing: "typedpreservationmarker"))
        openWorkspaceFile(2)
        openWorkspaceFile(1)
        XCTAssertTrue(waitForEditor(editor, containing: "typedpreservationmarker"))
        app.buttons["editor.close-project"].tap()
        // No seed on relaunch: this must read the disk store and saved source.
        let reopened = launchApp(inMemoryStore: false)
        let card = reopened.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND identifier BEGINSWITH %@",
            "UI Workspace Multipage Fixture", "project-home.card."
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(waitForEditor(reopened.textViews["editor.text-view"], containing: "typedpreservationmarker"))
    }

    private func tapWorkspaceKeyboardMarker(_ marker: String, in app: XCUIApplication) -> Bool {
        for character in marker {
            let key = app.keys[String(character)].firstMatch
            guard key.waitForExistence(timeout: 5), key.isHittable else {
                captureWorkspaceDiagnostics("keyboard-key-unavailable-\(character)")
                XCTFail("Expected hittable software keyboard key: \(character)")
                return false
            }
            key.tap()
        }
        return true
    }

    private func workspaceBodyRect(_ preview: XCUIElement) -> CGRect {
        // Intersect the actual surface with screen space. Exclude top chrome,
        // edge/shadow pixels, and bottom 140pt (statistics/status overlays).
        let visible = preview.frame.intersection(app.frame)
        return CGRect(x: visible.minX + 24, y: visible.minY + 40,
                      width: max(0, visible.width - 48), height: max(0, visible.height - 180))
    }

    private func captureWorkspaceDiagnostics(_ stage: String, preview: XCUIElement? = nil) {
        var geometry = "screen=\(app.frame)"
        if let preview { geometry += " preview=\(preview.frame) body=\(workspaceBodyRect(preview))" }
        let text = XCTAttachment(string: geometry + "\n" + app.debugDescription)
        text.name = stage + "-hierarchy-geometry"
        text.lifetime = .keepAlways
        add(text)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = stage
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func workspaceBodySample(_ preview: XCUIElement) -> (ink: Int, white: Int, rows: Int, fingerprint: UInt64) {
        guard let image = UIImage(data: XCUIScreen.main.screenshot().pngRepresentation)?.cgImage else {
            return (0, 0, 0, 0)
        }
        // Screenshot PNG scale is not guaranteed to equal UIImage.scale.
        let screen = app.frame
        let body = workspaceBodyRect(preview)
        let rect = CGRect(x: body.minX * CGFloat(image.width) / screen.width,
                          y: body.minY * CGFloat(image.height) / screen.height,
                          width: body.width * CGFloat(image.width) / screen.width,
                          height: body.height * CGFloat(image.height) / screen.height).integral
        guard rect.width > 0, rect.height > 0, let crop = image.cropping(to: rect) else { return (0, 0, 0, 0) }
        // Normalize bitmap layout instead of guessing the PNG's channel order.
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return (0, 0, 0, 0) }
        var ink = 0, white = 0, rows = 0
        var fingerprint: UInt64 = 14695981039346656037
        for y in 0..<height {
            var rowInk = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                // Count glyph ink only beside page-white pixels. Black slideshow
                // letterboxing must never satisfy the painted-content assertion.
                let neighbor = (y * width + min(x + 8, width - 1)) * 4
                let leftNeighbor = (y * width + max(x - 8, 0)) * 4
                if bytes[i] < 120 && bytes[i + 1] < 120 && bytes[i + 2] < 120
                    && bytes[neighbor] > 250 && bytes[neighbor + 1] > 250 && bytes[neighbor + 2] > 250
                    && bytes[leftNeighbor] > 250 && bytes[leftNeighbor + 1] > 250 && bytes[leftNeighbor + 2] > 250 {
                    ink += 1; rowInk += 1
                    fingerprint = (fingerprint ^ UInt64(y * width + x)) &* 1099511628211
                }
                if bytes[i] > 250 && bytes[i + 1] > 250 && bytes[i + 2] > 250 { white += 1 }
            }
            if rowInk >= 8 { rows += 1 }
        }
        return (ink, white, rows, fingerprint)
    }

    private func waitForPaintedWorkspaceBody(_ preview: XCUIElement, differentFrom previousInk: UInt64? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        var sample = (ink: 0, white: 0, rows: 0, fingerprint: UInt64(0))
        var lastPaintedFingerprint: UInt64?
        while Date() < deadline {
            sample = workspaceBodySample(preview)
            if sample.ink > 500 && sample.white > 10000 && sample.rows > 20
                && (previousInk == nil || sample.fingerprint != previousInk) {
                // Require a settled body, not a transient animated slide frame.
                if lastPaintedFingerprint == sample.fingerprint { return true }
                lastPaintedFingerprint = sample.fingerprint
            } else {
                lastPaintedFingerprint = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let diagnostic = XCTAttachment(string: "body ink=\(sample.ink) white=\(sample.white) occupiedRows=\(sample.rows)")
        diagnostic.name = "body-paint-failure"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        return false
    }

    private func waitForVisibleInk(
        in preview: XCUIElement,
        minimumVisiblePixels: Int = 4000,
        timeout: TimeInterval = 5
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var bestCount = 0

        while Date() < deadline {
            bestCount = max(bestCount, darkPixelCount(in: preview))
            if bestCount > minimumVisiblePixels {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return bestCount
    }

    private func openPreview(
        in app: XCUIApplication,
        requireRenderedPDF: Bool = false
    ) -> XCUIElement {
        let preview = app.otherElements["editor.preview"]
        if preview.waitForExistence(timeout: 2) {
            if requireRenderedPDF {
                XCTAssertTrue(waitForRenderedPreview(in: app))
            }
            return preview
        }

        let compactToggle = app.buttons["editor.mode-picker"]
        if compactToggle.exists {
            compactToggle.tap()
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
            if requireRenderedPDF { XCTAssertTrue(waitForRenderedPreview(in: app)) }
            return preview
        }
        let modePicker = app.segmentedControls["editor.mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        app.swipeLeft()
        if preview.waitForExistence(timeout: 5) {
            if requireRenderedPDF {
                XCTAssertTrue(waitForRenderedPreview(in: app))
            }
            return preview
        }

        tapPreviewSegment(in: modePicker)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        if requireRenderedPDF {
            XCTAssertTrue(waitForRenderedPreview(in: app))
        }
        return preview
    }

    private func openSeededDocumentIfNeeded(in app: XCUIApplication) {
        if waitForEditorShell(in: app, timeout: 10) {
            return
        }

        let seededRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "document-list.row.")
        ).firstMatch
        XCTAssertTrue(seededRow.waitForExistence(timeout: 5))
        seededRow.tap()
        XCTAssertTrue(waitForEditorShell(in: app, timeout: 10))
    }

    private func waitForEditorShell(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.textViews["editor.text-view"].exists
                || app.segmentedControls["editor.mode-picker"].exists
                || app.buttons["editor.more-menu"].exists
                || app.otherElements["editor.preview"].exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func waitForRenderedPreview(in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let renderedMarker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "editor.preview.rendered"))
            .firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if renderedMarker.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return renderedMarker.exists
    }

    private func tapPreviewSegment(in modePicker: XCUIElement) {
        modePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
    }

    private func darkPixelCount(in element: XCUIElement) -> Int {
        let screenshot = XCUIScreen.main.screenshot()
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage else {
            return 0
        }

        let scale = image.scale
        let frame = element.frame
        let cropRect = CGRect(
            x: frame.origin.x * scale,
            y: frame.origin.y * scale,
            width: frame.size.width * scale,
            height: frame.size.height * scale
        ).integral

        guard let cropped = cgImage.cropping(to: cropRect),
              let provider = cropped.dataProvider,
              let data = provider.data else {
            return 0
        }

        let bytes = CFDataGetBytePtr(data)!
        let bytesPerRow = cropped.bytesPerRow
        let bytesPerPixel = cropped.bitsPerPixel / 8
        var count = 0

        for y in 0..<cropped.height {
            let rowStart = y * bytesPerRow
            for x in 0..<cropped.width {
                let offset = rowStart + x * bytesPerPixel
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if red < 245 || green < 245 || blue < 245 {
                    count += 1
                }
            }
        }

        return count
    }
}
