import Foundation
#if canImport(Darwin)
import Darwin
#endif

nonisolated enum DurableFileSynchronization {
    static func synchronizeFileAndParent(_ url: URL) throws {
#if canImport(Darwin)
        try synchronize(url)
        try synchronize(url.deletingLastPathComponent())
#endif
    }

    static func synchronizeParent(of url: URL) throws {
#if canImport(Darwin)
        try synchronize(url.deletingLastPathComponent())
#endif
    }

#if canImport(Darwin)
    private static func synchronize(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
#endif
}
