import CoreGraphics
import Foundation

/// Fail closed until the owning window has been validated. Division capability
/// includes inactive regions and remains sticky for the lifetime of that scene.
struct SourceAccessoryScenePolicy {
    private weak var sceneOwner: AnyObject?
    var scene: ObjectIdentifier? { sceneOwner.map(ObjectIdentifier.init) }
    private(set) var divisionCapable = false
    private(set) var capabilityResolved = false

    mutating func observe(scene: AnyObject, divisionCapable: Bool, capabilityResolved: Bool = false) {
        if sceneOwner !== scene {
            sceneOwner = scene
            self.divisionCapable = divisionCapable
            self.capabilityResolved = capabilityResolved || divisionCapable
        } else {
            self.divisionCapable = self.divisionCapable || divisionCapable
            self.capabilityResolved = self.capabilityResolved || capabilityResolved || divisionCapable
        }
    }

    var allowsUnderlap: Bool { scene != nil && capabilityResolved && !divisionCapable }

    static func extensionHeight(safeBottom: CGFloat, accessory: CGRect, window: CGRect) -> CGFloat {
        guard safeBottom.isFinite, !accessory.isNull, !accessory.isEmpty,
              accessory.minY.isFinite, accessory.maxY.isFinite,
              window.contains(CGPoint(x: accessory.midX, y: accessory.midY)),
              abs(safeBottom - accessory.minY) <= 2 else { return 0 }
        return max(0, min(accessory.maxY, window.maxY) - max(safeBottom, accessory.minY))
    }
}

/// Weak object identity prevents a replaced text view from forgetting an owning
/// scene's division capability, without extending the lifetime of that scene.
@MainActor
final class SourceAccessorySceneRegistry {
    static let shared = SourceAccessorySceneRegistry()
    private let divisionScenes = NSHashTable<AnyObject>.weakObjects()
    private let resolvedScenes = NSHashTable<AnyObject>.weakObjects()

    func observe(scene: AnyObject, divisionCapable: Bool, capabilityResolved: Bool = false) -> Bool {
        if divisionCapable { divisionScenes.add(scene) }
        if capabilityResolved || divisionCapable { resolvedScenes.add(scene) }
        return divisionScenes.contains(scene)
    }

    func isResolved(scene: AnyObject) -> Bool { resolvedScenes.contains(scene) }
}

struct SourceAccessoryInsetPolicy {
    /// Nil preserves the untouched native/Duo path. A previously extended view
    /// gets one final recomputation after shrinking, even without a notification.
    static func insets(extent: CGFloat, previouslyExtended: Bool, viewBottom: CGFloat,
                       keyboardTop: CGFloat, padding: CGFloat) -> (content: CGFloat, indicator: CGFloat)? {
        guard extent > 0 || previouslyExtended else { return nil }
        let overlap = max(0, viewBottom - keyboardTop)
        return (overlap > 0 ? overlap + padding : 0, overlap)
    }
}
