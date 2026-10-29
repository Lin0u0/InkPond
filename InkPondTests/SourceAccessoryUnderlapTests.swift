import XCTest
@testable import InkPond

final class SourceAccessoryUnderlapTests: XCTestCase {
    func testUnknownAndStickyDivisionSceneFailClosed() {
        let first = NSObject()
        let second = NSObject()
        var policy = SourceAccessoryScenePolicy()
        XCTAssertFalse(policy.allowsUnderlap)
        policy.observe(scene: first, divisionCapable: false, capabilityResolved: true)
        XCTAssertTrue(policy.allowsUnderlap)
        policy.observe(scene: first, divisionCapable: true)
        policy.observe(scene: first, divisionCapable: false)
        XCTAssertFalse(policy.allowsUnderlap)
        policy.observe(scene: second, divisionCapable: false, capabilityResolved: true)
        XCTAssertTrue(policy.allowsUnderlap)
    }

    func testExtensionIsActualAccessoryGapOnly() {
        let window = CGRect(x: 0, y: 0, width: 390, height: 844)
        let accessory = CGRect(x: 0, y: 513, width: 390, height: 60)
        XCTAssertEqual(SourceAccessoryScenePolicy.extensionHeight(safeBottom: 513, accessory: accessory, window: window), 60)
        XCTAssertEqual(SourceAccessoryScenePolicy.extensionHeight(safeBottom: 450, accessory: accessory, window: window), 0)
        XCTAssertEqual(SourceAccessoryScenePolicy.extensionHeight(safeBottom: .nan, accessory: accessory, window: window), 0)
        XCTAssertEqual(SourceAccessoryScenePolicy.extensionHeight(safeBottom: 513, accessory: .zero, window: window), 0)
    }
    @MainActor
    func testDivisionRegistrySurvivesPolicyReplacementWithoutRetainingScene() {
        let registry = SourceAccessorySceneRegistry()
        weak var weakScene: NSObject?
        var replacement = SourceAccessoryScenePolicy()
        autoreleasepool {
            let scene = NSObject()
            weakScene = scene
            var original = SourceAccessoryScenePolicy()
            original.observe(scene: scene, divisionCapable:
                registry.observe(scene: scene, divisionCapable: true))
            replacement.observe(scene: scene, divisionCapable:
                registry.observe(scene: scene, divisionCapable: false))
            XCTAssertFalse(replacement.allowsUnderlap)
        }
        XCTAssertNil(weakScene)
        XCTAssertNil(replacement.scene)
        XCTAssertFalse(replacement.allowsUnderlap)
        let ordinary = NSObject()
        replacement.observe(scene: ordinary, divisionCapable:
            registry.observe(scene: ordinary, divisionCapable: false, capabilityResolved: true),
            capabilityResolved: registry.isResolved(scene: ordinary))
        XCTAssertTrue(replacement.allowsUnderlap)
    }

    func testInsetResetAfterExtentShrinksWithoutKeyboardNotification() {
        let expanded = SourceAccessoryInsetPolicy.insets(extent: 60, previouslyExtended: false,
            viewBottom: 573, keyboardTop: 513, padding: 12)
        XCTAssertEqual(expanded?.content, 72)
        XCTAssertEqual(expanded?.indicator, 60)
        let restored = SourceAccessoryInsetPolicy.insets(extent: 0, previouslyExtended: true,
            viewBottom: 513, keyboardTop: 513, padding: 12)
        XCTAssertEqual(restored?.content, 0)
        XCTAssertEqual(restored?.indicator, 0)
        XCTAssertNil(SourceAccessoryInsetPolicy.insets(extent: 0, previouslyExtended: false,
            viewBottom: 573, keyboardTop: 513, padding: 12))
    }
    func testPolicyBecomesUnknownWhenSceneDeallocates() {
        var policy = SourceAccessoryScenePolicy()
        autoreleasepool {
            let scene = NSObject()
            policy.observe(scene: scene, divisionCapable: false, capabilityResolved: true)
            XCTAssertTrue(policy.allowsUnderlap)
            XCTAssertNotNil(policy.scene)
        }
        XCTAssertNil(policy.scene)
        XCTAssertFalse(policy.allowsUnderlap)
    }
    @MainActor
    func testEmptyDivisionIsUnknownUntilValidatedInitialCapabilityUpdate() {
        let registry = SourceAccessorySceneRegistry()
        let scene = NSObject()
        var policy = SourceAccessoryScenePolicy()
        func observe(_ resolved: Bool, hingePresent: Bool) {
            let sticky = registry.observe(scene: scene, divisionCapable: hingePresent,
                                          capabilityResolved: resolved)
            policy.observe(scene: scene, divisionCapable: sticky,
                           capabilityResolved: registry.isResolved(scene: scene))
        }
        observe(false, hingePresent: false)
        XCTAssertFalse(policy.allowsUnderlap, "Empty division query is not proof of ordinary capability")
        XCTAssertFalse(policy.capabilityResolved)
        observe(true, hingePresent: false)
        XCTAssertTrue(policy.allowsUnderlap, "Validated attached initial nil can resolve ordinary")
        observe(true, hingePresent: true)
        observe(true, hingePresent: false)
        XCTAssertFalse(policy.allowsUnderlap, "Later nil cannot erase positive hinge capability")
        var replacement = SourceAccessoryScenePolicy()
        replacement.observe(scene: scene, divisionCapable:
            registry.observe(scene: scene, divisionCapable: false),
            capabilityResolved: registry.isResolved(scene: scene))
        XCTAssertFalse(replacement.allowsUnderlap)
    }

    @MainActor
    func testFreshClosedHingeExcludesBeforeOrdinaryResolution() {
        let registry = SourceAccessorySceneRegistry()
        let scene = NSObject()
        var policy = SourceAccessoryScenePolicy()
        policy.observe(scene: scene, divisionCapable: false)
        XCTAssertFalse(policy.allowsUnderlap)
        let sticky = registry.observe(scene: scene, divisionCapable: true, capabilityResolved: true)
        policy.observe(scene: scene, divisionCapable: sticky,
                       capabilityResolved: registry.isResolved(scene: scene))
        XCTAssertTrue(policy.divisionCapable)
        XCTAssertFalse(policy.allowsUnderlap)
        let newScene = NSObject()
        policy.observe(scene: newScene, divisionCapable: false)
        XCTAssertFalse(policy.capabilityResolved)
        XCTAssertFalse(policy.allowsUnderlap)
    }
}
