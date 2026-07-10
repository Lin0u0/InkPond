import Foundation

nonisolated struct OperationProgress: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing
        case staging
        case verifying
        case applying
        case committing
        case recovering
        case completed
    }

    let phase: Phase
    let completedUnitCount: Int
    let totalUnitCount: Int

    var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
    }
}
