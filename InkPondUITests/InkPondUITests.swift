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
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        app?.terminate()

        let app = XCUIApplication()
        app.launchArguments += [
            "UITEST_SKIP_ONBOARDING",
            "UITEST_IN_MEMORY_STORE",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        if seedDocument {
            app.launchArguments.append("UITEST_SEED_SAMPLE_DOCUMENT")
        }
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
    func testSplitWorkspaceExposesEditorPreviewAndHandleWhenWideEnough() throws {
        let app = launchApp(seedDocument: true)
        openSeededDocumentIfNeeded(in: app)

        let splitHandle = app.otherElements["editor.split-handle"]
        if !splitHandle.waitForExistence(timeout: 3) {
            throw XCTSkip("Split workspace is not visible at this simulator size.")
        }

        XCTAssertTrue(app.textViews["editor.text-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["editor.preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["editor.mode-picker"].exists)
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
            .matching(NSPredicate(format: "identifier == %@", "editor.preview.stats"))
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
