import Foundation
import os

actor ProjectWritableLeaseCoordinator {
    static let shared = ProjectWritableLeaseCoordinator()
    private var owners: [ProjectID: UUID] = [:]

    func acquire(projectID: ProjectID, ownerID: UUID = UUID()) throws -> ProjectWritableLease {
        guard owners[projectID] == nil else {
            throw ProjectWritableLeaseError.alreadyHeld(projectID)
        }
        owners[projectID] = ownerID
        return ProjectWritableLease(projectID: projectID, ownerID: ownerID) { [weak self] projectID, ownerID in
            await self?.release(projectID: projectID, ownerID: ownerID)
        }
    }

    func open(projectID: ProjectID, ownerID: UUID = UUID()) -> ProjectAccessLease {
        guard owners[projectID] == nil else { return .readOnly }
        owners[projectID] = ownerID
        return .writable(ProjectWritableLease(projectID: projectID, ownerID: ownerID) { [weak self] projectID, ownerID in
            await self?.release(projectID: projectID, ownerID: ownerID)
        })
    }

    func transfer(_ lease: ProjectWritableLease, to ownerID: UUID = UUID()) throws -> ProjectWritableLease {
        guard owners[lease.projectID] == lease.ownerID else {
            throw ProjectWritableLeaseError.notCurrentOwner(lease.projectID)
        }
        lease.invalidateForTransfer()
        owners[lease.projectID] = ownerID
        return ProjectWritableLease(projectID: lease.projectID, ownerID: ownerID) { [weak self] projectID, ownerID in
            await self?.release(projectID: projectID, ownerID: ownerID)
        }
    }

    private func release(projectID: ProjectID, ownerID: UUID) {
        guard owners[projectID] == ownerID else { return }
        owners.removeValue(forKey: projectID)
    }
}

final class ProjectWritableLease: @unchecked Sendable {
    let projectID: ProjectID
    fileprivate let ownerID: UUID
    private let releaseAction: @Sendable (ProjectID, UUID) async -> Void
    private let released = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(
        projectID: ProjectID,
        ownerID: UUID,
        releaseAction: @escaping @Sendable (ProjectID, UUID) async -> Void
    ) {
        self.projectID = projectID
        self.ownerID = ownerID
        self.releaseAction = releaseAction
    }

    func release() async {
        let shouldRelease = released.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if shouldRelease { await releaseAction(projectID, ownerID) }
    }

    fileprivate func invalidateForTransfer() {
        released.withLock { $0 = true }
    }

    deinit {
        let shouldRelease = released.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if shouldRelease {
            let projectID = projectID
            let ownerID = ownerID
            let action = releaseAction
            Task { await action(projectID, ownerID) }
        }
    }
}

nonisolated enum ProjectWritableLeaseError: Error, Equatable {
    case alreadyHeld(ProjectID)
    case notCurrentOwner(ProjectID)
}

nonisolated enum ProjectAccessLease: Sendable {
    case writable(ProjectWritableLease)
    case readOnly
}
