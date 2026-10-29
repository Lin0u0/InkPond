import XCTest
import SwiftUI
@testable import InkPond

final class EditorToolbarLayoutTests: XCTestCase {
    func testCompactSceneAlwaysPrioritizesTitle() {
        XCTAssertTrue(EditorToolbarLayout.isCompact(sizeClass: .compact, containerWidth: 0))
        XCTAssertTrue(EditorToolbarLayout.isCompact(sizeClass: .compact, containerWidth: 900))
    }

    func testNarrowRegularWindowUsesCompactToolbar() {
        XCTAssertTrue(EditorToolbarLayout.isCompact(sizeClass: .regular, containerWidth: 571))
        XCTAssertTrue(EditorToolbarLayout.isCompact(sizeClass: nil, containerWidth: 500))
    }

    func testWideWorkspaceKeepsExistingToolbar() {
        XCTAssertFalse(EditorToolbarLayout.isCompact(sizeClass: .regular, containerWidth: 572))
        XCTAssertFalse(EditorToolbarLayout.isCompact(sizeClass: .regular, containerWidth: 1200))
        XCTAssertFalse(EditorToolbarLayout.isCompact(sizeClass: .regular, containerWidth: 0))
    }
}
