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
        XCTAssertTrue(waitForElement(app.buttons["settings.import-zip"]))
        XCTAssertTrue(waitForElement(app.buttons["settings.fonts"], revealWithSwipes: 2))
        XCTAssertTrue(waitForElement(app.buttons["settings.cache"], revealWithSwipes: 2))
    }

    @MainActor
    func testSeededDocumentExposesEditorPrimaryControls() throws {
        let app = launchApp(seedDocument: true)

        if !app.buttons["editor.share"].waitForExistence(timeout: 3) {
            let seededRow = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "document-list.row.")
            ).firstMatch
            XCTAssertTrue(seededRow.waitForExistence(timeout: 5))
            seededRow.tap()
        }

        XCTAssertTrue(app.buttons["editor.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.more-menu"].exists)
        XCTAssertTrue(app.segmentedControls["editor.mode-picker"].exists || app.otherElements["editor.preview"].exists)
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

        let preview = openPreview(in: app)

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

        let preview = openPreview(in: app)

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

    private func openPreview(in app: XCUIApplication) -> XCUIElement {
        let preview = app.otherElements["editor.preview"]
        if preview.waitForExistence(timeout: 2) {
            return preview
        }

        let modePicker = app.segmentedControls["editor.mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        tapPreviewSegment(in: modePicker)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        return preview
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
