//
//  CloudFileCoordinator.swift
//  InkPond
//

import Foundation
import os.log

/// Provides NSFileCoordinator-wrapped file operations for iCloud Documents.
/// All coordinated operations run synchronously within the coordination block
/// to ensure atomicity, as required by the NSFileCoordinator contract.
///
/// Marked nonisolated to allow usage from any actor context (MainActor,
/// BackgroundDocumentFileWriter, Task.detached, etc.).
nonisolated enum CloudFileCoordinator {
    // MARK: - Read

    static func readData(from url: URL) throws -> Data {
        let interval = Diagnostics.beginInterval("icloud.coordinated_read", category: .iCloud)
        let startedAt = Date()
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var readData: Data?
        var readError: Error?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                readData = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            var metadata = Diagnostics.errorMetadata(coordinationError)
            metadata["elapsedMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            Diagnostics.record(.iCloud, "coordinated_read.coordination_failure", level: .error, metadata: metadata)
            Diagnostics.endInterval("icloud.coordinated_read", category: .iCloud, interval)
            throw coordinationError
        }
        if let readError {
            var metadata = Diagnostics.errorMetadata(readError)
            metadata["elapsedMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            Diagnostics.record(.iCloud, "coordinated_read.read_failure", level: .error, metadata: metadata)
            Diagnostics.endInterval("icloud.coordinated_read", category: .iCloud, interval)
            throw readError
        }
        guard let data = readData else {
            Diagnostics.record(
                .iCloud,
                "coordinated_read.empty_result",
                level: .error,
                metadata: ["elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))]
            )
            Diagnostics.endInterval("icloud.coordinated_read", category: .iCloud, interval)
            throw CocoaError(.fileReadUnknown)
        }
        Diagnostics.record(
            .iCloud,
            "coordinated_read.success",
            metadata: [
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "byteCount": String(data.count)
            ]
        )
        Diagnostics.endInterval("icloud.coordinated_read", category: .iCloud, interval)
        return data
    }

    static func readString(from url: URL, encoding: String.Encoding = .utf8) throws -> String {
        let data = try readData(from: url)
        guard let string = String(data: data, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    // MARK: - Write

    static func writeData(_ data: Data, to url: URL, atomically: Bool = true) throws {
        let interval = Diagnostics.beginInterval("icloud.coordinated_write", category: .iCloud)
        let startedAt = Date()
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: atomically ? .atomic : [])
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            var metadata = Diagnostics.errorMetadata(coordinationError)
            metadata["elapsedMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            metadata["byteCount"] = String(data.count)
            Diagnostics.record(.iCloud, "coordinated_write.coordination_failure", level: .error, metadata: metadata)
            Diagnostics.endInterval("icloud.coordinated_write", category: .iCloud, interval)
            throw coordinationError
        }
        if let writeError {
            var metadata = Diagnostics.errorMetadata(writeError)
            metadata["elapsedMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            metadata["byteCount"] = String(data.count)
            Diagnostics.record(.iCloud, "coordinated_write.write_failure", level: .error, metadata: metadata)
            Diagnostics.endInterval("icloud.coordinated_write", category: .iCloud, interval)
            throw writeError
        }
        Diagnostics.record(
            .iCloud,
            "coordinated_write.success",
            metadata: [
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "byteCount": String(data.count)
            ]
        )
        Diagnostics.endInterval("icloud.coordinated_write", category: .iCloud, interval)
    }

    static func writeString(_ string: String, to url: URL, encoding: String.Encoding = .utf8) throws {
        guard let data = string.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeData(data, to: url)
    }

    // MARK: - Copy

    static func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL, options: [],
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: coordinatedDestination.path) {
                    // Back up existing destination so we can restore it if the copy fails.
                    let backupURL = coordinatedDestination.deletingLastPathComponent()
                        .appendingPathComponent(".backup-\(UUID().uuidString)-\(coordinatedDestination.lastPathComponent)")
                    do {
                        try fm.moveItem(at: coordinatedDestination, to: backupURL)
                    } catch {
                        // If backup fails, fall back to the old remove-then-copy behaviour.
                        try fm.removeItem(at: coordinatedDestination)
                        try fm.copyItem(at: coordinatedSource, to: coordinatedDestination)
                        return
                    }
                    do {
                        try fm.copyItem(at: coordinatedSource, to: coordinatedDestination)
                        // Copy succeeded — remove backup.
                        try? fm.removeItem(at: backupURL)
                    } catch {
                        // Copy failed — restore from backup.
                        try? fm.moveItem(at: backupURL, to: coordinatedDestination)
                        throw error
                    }
                } else {
                    try fm.copyItem(at: coordinatedSource, to: coordinatedDestination)
                }
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    // MARK: - Move

    static func moveItem(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var moveError: Error?

        coordinator.coordinate(
            writingItemAt: sourceURL, options: .forMoving,
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: coordinatedDestination.path) {
                    try fm.removeItem(at: coordinatedDestination)
                }
                try fm.moveItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                moveError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    /// Atomically install a verified staged file while coordinating both URLs.
    /// Unlike `moveItem`, this preserves the existing destination if replacement fails.
    static func replaceItemAtomically(from stagedURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var replaceError: Error?

        coordinator.coordinate(
            writingItemAt: stagedURL, options: .forMoving,
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedStage, coordinatedDestination in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: coordinatedDestination.path) {
                    _ = try fm.replaceItemAt(coordinatedDestination, withItemAt: coordinatedStage)
                } else {
                    try fm.moveItem(at: coordinatedStage, to: coordinatedDestination)
                }
            } catch {
                replaceError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let replaceError { throw replaceError }
    }

    // MARK: - Delete

    static func removeItem(at url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var deleteError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                deleteError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }

    // MARK: - Directory

    static func createDirectory(at url: URL, withIntermediateDirectories: Bool = true) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var createError: Error?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(
                    at: coordinatedURL,
                    withIntermediateDirectories: withIntermediateDirectories
                )
            } catch {
                createError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let createError { throw createError }
    }
}
