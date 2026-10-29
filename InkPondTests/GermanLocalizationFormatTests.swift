import XCTest
@testable import InkPond

final class GermanLocalizationFormatTests: XCTestCase {
    /// Resolve the compiled German resource explicitly without changing process language.
    func testGermanSplitAccessibilityPercentFormatting() throws {
        let germanURL = try XCTUnwrap(Bundle.main.url(forResource: "de", withExtension: "lproj"))
        let germanBundle = try XCTUnwrap(Bundle(url: germanURL))
        let format = germanBundle.localizedString(
            forKey: "a11y.editor.split.value_format", value: nil, table: "Localizable"
        )
        XCTAssertEqual(format, "Editor %1$d%%, Vorschau %2$d%%")
        XCTAssertEqual(String(format: format, 35, 65), "Editor 35%, Vorschau 65%")
    }

    func testProductionSplitAccessibilityPercentFormattingInCurrentLocale() {
        let value = L10n.a11yEditorSplitValue(editorPercent: 35, previewPercent: 65)
        XCTAssertTrue(value.contains("35%"), value)
        XCTAssertTrue(value.contains("65%"), value)
    }
}
