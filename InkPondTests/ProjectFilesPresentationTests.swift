import SwiftUI
import XCTest
@testable import InkPond

@MainActor
final class ProjectFilesPresentationTests: XCTestCase {
    func testExistingFitBoundaryAndSizeClass() {
        for width: CGFloat in [0, 572, 669, 698, 812.99] {
            XCTAssertFalse(ProjectFilesPresentation.canShowSidebar(sizeClass: .regular, availableWidth: width))
        }
        for width: CGFloat in [813, 951, 1200] {
            XCTAssertTrue(ProjectFilesPresentation.canShowSidebar(sizeClass: .regular, availableWidth: width))
            XCTAssertFalse(ProjectFilesPresentation.canShowSidebar(sizeClass: .compact, availableWidth: width))
        }
    }

    func testWideToggleCanHideAndReopenWithoutModal() {
        var visible = true
        var modal = false
        ProjectFilesPresentation.activate(canShowSidebar: true, sidebarVisible: &visible, modalPresented: &modal)
        XCTAssertFalse(visible)
        XCTAssertFalse(modal)
        ProjectFilesPresentation.activate(canShowSidebar: true, sidebarVisible: &visible, modalPresented: &modal)
        XCTAssertTrue(visible)
        XCTAssertFalse(modal)
    }

    func testNarrowModalAndRotationPreserveSidebarPreference() {
        for initialVisible in [true, false] {
            var visible = initialVisible
            var modal = false
            ProjectFilesPresentation.activate(canShowSidebar: false, sidebarVisible: &visible, modalPresented: &modal)
            XCTAssertTrue(modal)
            XCTAssertEqual(visible, initialVisible)
            ProjectFilesPresentation.reconcile(canShowSidebar: false, modalPresented: &modal)
            XCTAssertTrue(modal)
            ProjectFilesPresentation.reconcile(canShowSidebar: true, modalPresented: &modal)
            XCTAssertFalse(modal)
            XCTAssertEqual(visible, initialVisible)
            ProjectFilesPresentation.reconcile(canShowSidebar: false, modalPresented: &modal)
            XCTAssertFalse(modal)
        }
    }
}
