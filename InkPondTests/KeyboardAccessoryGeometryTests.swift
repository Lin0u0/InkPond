import CoreGraphics
import XCTest
import UIKit
@testable import InkPond

final class KeyboardAccessoryGeometryTests: XCTestCase {
    private func solve(_ regions: [CGRect], width: CGFloat = 669, bottom: CGFloat = 455.667, scale: CGFloat = 3) -> KeyboardAccessoryGeometry.Solution? {
        KeyboardAccessoryGeometry.solve(width: width, bottom: bottom, regions: regions, scale: scale)
    }
    func testNoRegions() { XCTAssertEqual(solve([])?.padding, 0) }
    func testHorizontalSample() {
        let result = solve([CGRect(x: 0, y: 435.5, width: 669, height: 80)])!
        XCTAssertEqual(result.padding, 40 / 3, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(455.667 - 8 - result.padding, 434.5)
    }
    func testBottomAnchorStability() {
        let first = solve([CGRect(x: 0, y: 435.5, width: 669, height: 80)])!
        let second = solve([CGRect(x: 0, y: 435.5 + first.padding, width: 669, height: 80)], bottom: 455.667 + first.padding)!
        XCTAssertEqual(first.padding, second.padding)
    }
    func testFarInactiveGeometryDoesNotMove() { XCTAssertEqual(solve([CGRect(x: 0, y: 800, width: 669, height: 80)])?.padding, 0) }
    func testAsymmetricExpandedEdges() {
        let result = solve([CGRect(x: 210, y: -1000, width: 80, height: 2000)])!
        XCTAssertEqual(result.span.minX, 291)
        XCTAssertEqual(result.span.width, 378)
    }
    func testMultipleRegions() {
        let result = solve([CGRect(x: 100, y: -1000, width: 20, height: 2000), CGRect(x: 400, y: -1000, width: 20, height: 2000)])!
        XCTAssertEqual(result.span, CGRect(x: 121, y: 0, width: 278, height: 60))
    }
    func testFractionalPixelRoundsUp() {
        XCTAssertEqual(solve([CGRect(x: 0, y: 435.5, width: 669, height: 80)], scale: 2)?.padding, 13.5)
    }
    func testRotatedVerticalRegion() {
        let result = solve([CGRect(x: 300, y: -1000, width: 40, height: 2000)])!
        XCTAssertEqual(result.padding, 0)
        XCTAssertEqual(result.span.minX, 341)
    }
    func testNarrowSafeSegmentRetainsTargetWidth() {
        let result = solve([CGRect(x: 46, y: -100, width: 200, height: 1000)], width: 100)!
        XCTAssertEqual(result.span.width, 45)
    }
    func testInvalidDimensionsDefer() {
        XCTAssertNil(solve([], width: 0))
        XCTAssertNil(solve([], bottom: .nan))
        XCTAssertNil(solve([], scale: 0))
        XCTAssertNil(solve([.null]))
    }
    func testNonzeroOriginTranslation() {
        let a = solve([CGRect(x: 0, y: 435.5, width: 669, height: 80)])!
        let b = solve([CGRect(x: 0, y: 535.5, width: 669, height: 80)], bottom: 555.667)!
        XCTAssertEqual(a, b)
    }
    func testFullHeightInfeasibleIsExplicit() {
        XCTAssertNil(KeyboardAccessoryGeometry.solve(width: 100, bottom: 60,
            regions: [CGRect(x: 0, y: -100, width: 100, height: 1000)], scale: 3, availableTop: -100))
    }
    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    func testViewValidInfeasibleValidRestoresInteraction() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let scene = NSObject()
        let valid = KeyboardAccessoryGeometry.Solution(padding: 0, span: CGRect(x: 0, y: 0, width: 400, height: 60))
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: valid)
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertFalse(buttons(in: content).isEmpty)
        XCTAssertFalse(content.isHidden)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: nil)
        XCTAssertTrue(content.isHidden)
        XCTAssertFalse(content.isUserInteractionEnabled)
        XCTAssertTrue(content.accessibilityElementsHidden)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: valid)
        XCTAssertFalse(content.isHidden)
        XCTAssertTrue(content.isUserInteractionEnabled)
        XCTAssertFalse(content.accessibilityElementsHidden)
    }

    func testAdaptedNarrowTargetCornersAreHittable() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        let scene = NSObject()
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true,
            result: .init(padding: 0, span: CGRect(x: 0, y: 0, width: 45, height: 60)))
        accessory.layoutIfNeeded()
        let first = buttons(in: accessory).first!
        XCTAssertGreaterThanOrEqual(first.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(first.bounds.height, 44)
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 43.5, y: 0.5),
                      CGPoint(x: 0.5, y: 43.5), CGPoint(x: 43.5, y: 43.5)] {
            XCTAssertTrue(accessory.hitTest(first.convert(point, to: accessory), with: nil) === first)
        }
    }

    func testSceneChangeRestoresRealOrdinaryLayout() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        accessory.layoutIfNeeded()
        let originalButtons = buttons(in: accessory)
        let originalFrames = originalButtons.map(\.frame)
        let originalParents = originalButtons.map { $0.superview }
        let firstScene = NSObject(), ordinaryScene = NSObject()
        let solution = KeyboardAccessoryGeometry.Solution(padding: 0, span: CGRect(x: 0, y: 0, width: 400, height: 60))
        accessory.applyValidatedGeometry(sceneIdentity: firstScene, hasDivision: true, result: solution)
        accessory.layoutIfNeeded()
        for button in buttons(in: accessory) {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
        accessory.applyValidatedGeometry(sceneIdentity: firstScene, hasDivision: false, result: solution)
        accessory.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(originalButtons[0].bounds.height, 44)
        accessory.applyValidatedGeometry(sceneIdentity: ordinaryScene, hasDivision: false, result: solution)
        accessory.layoutIfNeeded()
        XCTAssertEqual(accessory.intrinsicContentSize.height, 60)
        XCTAssertEqual(accessory.autoresizingMask, [.flexibleWidth])
        for (index, button) in originalButtons.enumerated() {
            XCTAssertEqual(button.frame, originalFrames[index])
            XCTAssertTrue(button.superview === originalParents[index])
        }
    }

    func testNativeInputViewSelfSizingAndOrdinaryRestore() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 669, height: 60)
        XCTAssertFalse(accessory.allowsSelfSizing)
        XCTAssertTrue(accessory.translatesAutoresizingMaskIntoConstraints)
        let adaptedScene = NSObject(), ordinaryScene = NSObject()
        var preferredSizes: [CGSize] = []
        accessory.onPreferredAccessorySizeChanged = { preferredSizes.append($0) }
        let protected = KeyboardAccessoryGeometry.Solution(padding: 40 / 3,
            span: CGRect(x: 0, y: 0, width: 669, height: 60))
        accessory.applyValidatedGeometry(sceneIdentity: adaptedScene, hasDivision: true, result: protected)
        XCTAssertTrue(accessory.allowsSelfSizing)
        XCTAssertFalse(accessory.translatesAutoresizingMaskIntoConstraints)
        let width = accessory.constraints.first { $0.identifier == "KeyboardAccessory.adaptedWidth" }!
        XCTAssertTrue(width.isActive)
        XCTAssertEqual(width.constant, 669)
        let height = accessory.constraints.first { $0.identifier == "KeyboardAccessory.adaptedHeight" }!
        XCTAssertTrue(height.isActive)
        XCTAssertEqual(height.constant, 60 + 40 / 3, accuracy: 0.0001)
        let target = CGSize(width: 669, height: 60)
        XCTAssertEqual(accessory.systemLayoutSizeFitting(target).height, 60 + 40 / 3, accuracy: 0.0001)
        XCTAssertEqual(accessory.systemLayoutSizeFitting(target,
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height,
            60 + 40 / 3, accuracy: 0.0001)
        XCTAssertEqual(accessory.intrinsicContentSize.height, 60 + 40 / 3, accuracy: 0.0001)
        XCTAssertEqual(accessory.sizeThatFits(target).height, 60 + 40 / 3, accuracy: 0.0001)
        accessory.applyValidatedGeometry(sceneIdentity: adaptedScene, hasDivision: true,
            result: .init(padding: 20, span: protected.span))
        XCTAssertTrue(height.isActive)
        XCTAssertEqual(height.constant, 80)
        XCTAssertEqual(preferredSizes.last?.height, 80)
        XCTAssertEqual(accessory.systemLayoutSizeFitting(target).height, 80)
        accessory.applyValidatedGeometry(sceneIdentity: ordinaryScene, hasDivision: false,
            result: .init(padding: 0, span: protected.span))
        XCTAssertFalse(height.isActive)
        XCTAssertFalse(width.isActive)
        XCTAssertTrue(accessory.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(accessory.autoresizingMask, [.flexibleWidth])
        XCTAssertEqual(preferredSizes.last?.height, 60)
        XCTAssertFalse(accessory.constraints.contains { $0.identifier == "KeyboardAccessory.adaptedHeight" && $0.isActive })
        XCTAssertFalse(accessory.allowsSelfSizing)
        XCTAssertEqual(accessory.intrinsicContentSize.height, 60)
        XCTAssertEqual(accessory.sizeThatFits(target).height, 60)
    }

    func testRealizedTargetsValidateVisibleClippingAndMinimumSize() {
        let target = CGRect(x: 0, y: 8, width: 44, height: 44)
        let fold = CGRect(x: 0, y: 39.833, width: 669, height: 80)
        XCTAssertFalse(KeyboardAccessoryView.realizedTargetsAreSafe([(target, target)], protectedRegions: [fold]))
        XCTAssertFalse(KeyboardAccessoryView.realizedTargetsAreSafe([(target, CGRect(x: 0, y: 8, width: 44, height: 20))], protectedRegions: [fold]))
        XCTAssertFalse(KeyboardAccessoryView.realizedTargetsAreSafe([(CGRect(x: 0, y: 8, width: 36, height: 44), target)], protectedRegions: []))
        XCTAssertFalse(KeyboardAccessoryView.realizedTargetsAreSafe([], protectedRegions: []))
    }

    func testUnrealizedHostFailsClosedThenSafeRealizedHostRestores() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 669, height: 60)
        let scene = NSObject()
        let solution = KeyboardAccessoryGeometry.Solution(padding: 40 / 3,
            span: CGRect(x: 0, y: 0, width: 669, height: 60))
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: solution,
            protectedRegions: [CGRect(x: 0, y: 39.833, width: 669, height: 80)])
        accessory.layoutIfNeeded()
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertTrue(content.isHidden)
        XCTAssertFalse(content.isUserInteractionEnabled)
        XCTAssertTrue(content.accessibilityElementsHidden)
        XCTAssertEqual(accessory.systemLayoutSizeFitting(accessory.bounds.size).height, 60 + 40 / 3, accuracy: 0.0001)
        // Emulate the supported native host accepting the requested height and
        // moving its top upward while its bottom remains anchored.
        accessory.frame = CGRect(x: 0, y: -40 / 3, width: 669, height: 60 + 40 / 3)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: solution,
            protectedRegions: [CGRect(x: 0, y: 39.833 + 40 / 3, width: 669, height: 80)])
        accessory.layoutIfNeeded()
        XCTAssertFalse(content.isHidden)
        XCTAssertTrue(content.isUserInteractionEnabled)
        XCTAssertFalse(content.accessibilityElementsHidden)
        // Height alone is insufficient: moving the host downward remains unsafe.
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: solution,
            protectedRegions: [CGRect(x: 0, y: 39.833, width: 669, height: 80)])
        XCTAssertTrue(content.isHidden)
    }

    func testPreparedDivisionControllerIsHiddenUntilUsableNativeWidth() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        let scene = NSObject()
        accessory.prepareControllerHosting(sceneIdentity: scene, owningWidth: 669)
        XCTAssertFalse(accessory.translatesAutoresizingMaskIntoConstraints)
        let width = accessory.constraints.first { $0.identifier == "KeyboardAccessory.adaptedWidth" }!
        let height = accessory.constraints.first { $0.identifier == "KeyboardAccessory.adaptedHeight" }!
        XCTAssertTrue(width.isActive)
        XCTAssertTrue(height.isActive)
        XCTAssertEqual(width.constant, 669)
        XCTAssertEqual(height.constant, 60)
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertTrue(content.isHidden)
        XCTAssertFalse(content.isUserInteractionEnabled)
        XCTAssertTrue(content.accessibilityElementsHidden)
        XCTAssertEqual(accessory.systemLayoutSizeFitting(CGSize(width: 0, height: 60)).width, 669)
        accessory.layoutIfNeeded()
        XCTAssertTrue(content.isHidden)
        accessory.frame = CGRect(x: 0, y: 0, width: 669, height: 60)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true,
            result: .init(padding: 0, span: CGRect(x: 0, y: 0, width: 669, height: 60)),
            protectedRegions: [])
        accessory.layoutIfNeeded()
        XCTAssertFalse(content.isHidden)
        for button in buttons(in: accessory) {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
    }

    func testPartialScrollEdgeIsNoninteractiveThenRestoresWhenFullyVisible() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        accessory.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        let scene = NSObject()
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true,
            result: .init(padding: 0, span: CGRect(x: 0, y: 0, width: 100, height: 60)), protectedRegions: [])
        accessory.layoutIfNeeded()
        let first = buttons(in: accessory).first!
        let scroll = first.superview!.superview as! UIScrollView
        scroll.contentOffset = CGPoint(x: 10, y: 0)
        accessory.scrollViewDidScroll(scroll)
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertFalse(content.isHidden)
        XCTAssertFalse(first.isUserInteractionEnabled)
        XCTAssertTrue(first.accessibilityElementsHidden)
        XCTAssertFalse(first.isAccessibilityElement)
        scroll.contentOffset = .zero
        accessory.scrollViewDidScroll(scroll)
        XCTAssertTrue(first.isUserInteractionEnabled)
        XCTAssertFalse(first.accessibilityElementsHidden)
        XCTAssertTrue(first.isAccessibilityElement)
        accessory.applyValidatedGeometry(sceneIdentity: NSObject(), hasDivision: false,
            result: .init(padding: 0, span: CGRect(x: 0, y: 0, width: 100, height: 60)))
        XCTAssertTrue(first.isUserInteractionEnabled)
        XCTAssertFalse(first.accessibilityElementsHidden)
    }

    func testNativeAncestorHitHeightFailsClosedEvenWithoutVisualClipping() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        let nativeHost = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        nativeHost.clipsToBounds = false
        nativeHost.addSubview(accessory)
        accessory.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        let scene = NSObject()
        let solution = KeyboardAccessoryGeometry.Solution(padding: 0, span: CGRect(x: 0, y: 0, width: 100, height: 60))
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: solution, protectedRegions: [])
        accessory.layoutIfNeeded()
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertTrue(content.isHidden)
        XCTAssertFalse(content.isUserInteractionEnabled)
        nativeHost.bounds.size.height = 60
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: solution, protectedRegions: [])
        accessory.layoutIfNeeded()
        XCTAssertFalse(content.isHidden)
    }

    func testWidthOnlyRotationUpdatesNativePreferenceBeforeGeometryRecovers() {
        let editor = UITextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        let scene = NSObject()
        accessory.prepareControllerHosting(sceneIdentity: scene, owningWidth: 400)
        let controller = UIInputViewController()
        controller.inputView = accessory
        controller.preferredContentSize = CGSize(width: 400, height: 60)
        var notifications = 0
        accessory.onPreferredAccessorySizeChanged = {
            notifications += 1
            controller.preferredContentSize = $0
        }
        // Host still has its pre-rotation width; fail-closed geometry must not
        // prevent the controller requesting the new owning width.
        accessory.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        accessory.updateControllerHostingWidth(700)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true, result: nil, protectedRegions: [])
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 700, height: 60))
        XCTAssertEqual(accessory.constraints.first { $0.identifier == "KeyboardAccessory.adaptedWidth" }?.constant, 700)
        let content = accessory.subviews.first { !buttons(in: $0).isEmpty }!
        XCTAssertTrue(content.isHidden)
        accessory.updateControllerHostingWidth(700)
        XCTAssertEqual(notifications, 1, "Stable samples must not create a layout feedback loop")
        accessory.updateControllerHostingWidth(.nan)
        XCTAssertEqual(notifications, 1)
        accessory.frame = CGRect(x: 0, y: 0, width: 700, height: 60)
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true,
            result: .init(padding: 0, span: CGRect(x: 0, y: 0, width: 700, height: 60)), protectedRegions: [])
        accessory.layoutIfNeeded()
        XCTAssertFalse(content.isHidden)
        XCTAssertTrue(content.isUserInteractionEnabled)
        // A subsequent height request sees the old realized width again.
        accessory.frame.size.width = 400
        // A subsequent height request must not restore stale realized width.
        accessory.applyValidatedGeometry(sceneIdentity: scene, hasDivision: true,
            result: .init(padding: 10, span: CGRect(x: 0, y: 0, width: 700, height: 60)))
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 700, height: 70))
        accessory.updateControllerHostingWidth(400)
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 400, height: 70))
        XCTAssertEqual(editor.text, "")
    }

    func testVerticalDivisionWithinNativeExtentUsesSideSpanWithoutExtraHeight() {
        for region in [CGRect(x: 170, y: -500, width: 60, height: 1000),
                       CGRect(x: 470, y: -500, width: 60, height: 1000)] {
            let solution = KeyboardAccessoryGeometry.solve(width: 700, bottom: 60,
                regions: [region], scale: 3, availableTop: 0)
            XCTAssertNotNil(solution)
            XCTAssertEqual(solution?.padding, 0)
            if let solution {
                let targetBand = CGRect(x: solution.span.minX, y: 8, width: solution.span.width, height: 44)
                XCTAssertFalse(targetBand.intersects(region))
            }
        }
    }

    func testDiagnosticHintContinuesAfterHistoryEviction() {
        let editor = TypstTextView()
        let accessory = KeyboardAccessoryView(textView: editor)
        for index in 0..<140 {
            accessory.recordGeometryDiagnostic("sample unique-\(index)")
        }
        accessory.recordGeometryDiagnostic("sample current-owner-bounds")
        accessory.recordGeometryDiagnostic("realized current-native-targets")
        let hint = editor.accessoryGeometryDiagnosticHint ?? ""
        XCTAssertTrue(hint.contains("records=128/128"))
        XCTAssertTrue(hint.contains("SAMPLE: sample current-owner-bounds"))
        XCTAssertTrue(hint.contains("REALIZED: realized current-native-targets"))
        XCTAssertTrue(editor.accessibilityHint?.contains("REALIZED: realized current-native-targets") == true)
        // Re-admitting the evicted oldest record still updates the latest sample.
        accessory.recordGeometryDiagnostic("sample unique-0")
        XCTAssertTrue(editor.accessoryGeometryDiagnosticHint?.contains("SAMPLE: sample unique-0") == true)
        XCTAssertTrue(editor.accessoryGeometryDiagnosticHint?.contains("records=128/128") == true)
    }

    func testDiagnosticHintSurvivesOrdinaryEditorHintUpdates() {
        let editor = TypstTextView()
        editor.accessibilityHint = "Ordinary hint"
        XCTAssertNil(editor.accessoryGeometryDiagnosticHint)
        XCTAssertEqual(editor.accessibilityHint, "Ordinary hint")
        editor.accessoryGeometryDiagnosticHint = "Geometry sample"
        editor.accessibilityHint = "Updated ordinary hint"
        XCTAssertEqual(editor.accessibilityHint, "Geometry sample")
        editor.accessoryGeometryDiagnosticHint = nil
        XCTAssertEqual(editor.accessibilityHint, "Updated ordinary hint")
    }

}
