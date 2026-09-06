import Foundation
import os

final class SecurityScopeLease: @unchecked Sendable {
    let url: URL
    private let stopAccess: @Sendable () -> Void
    private let released = OSAllocatedUnfairLock(initialState: false)

    init?(
        url: URL,
        startAccess: @Sendable () -> Bool = { false },
        stopAccess: @escaping @Sendable () -> Void = {}
    ) {
        guard startAccess() else { return nil }
        self.url = url
        self.stopAccess = stopAccess
    }

    func release() {
        let shouldStop = released.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if shouldStop { stopAccess() }
    }

    deinit { release() }

    static func accessing(_ url: URL) -> SecurityScopeLease? {
        SecurityScopeLease(
            url: url,
            startAccess: { url.startAccessingSecurityScopedResource() },
            stopAccess: { url.stopAccessingSecurityScopedResource() }
        )
    }
}
