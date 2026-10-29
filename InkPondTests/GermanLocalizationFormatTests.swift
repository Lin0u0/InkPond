import XCTest
@testable import InkPond

final class GermanLocalizationFormatTests: XCTestCase {
    /// Run with -testLanguage de -testRegion DE so the actual L10n path uses German.
    func testGermanSplitAccessibilityPercentFormatting() {
        XCTAssertEqual(L10n.tr("a11y.editor.split.value_format"), "Editor %1$d%%, Vorschau %2$d%%")
        XCTAssertEqual(
            L10n.a11yEditorSplitValue(editorPercent: 35, previewPercent: 65),
            "Editor 35%, Vorschau 65%"
        )
    }
}
