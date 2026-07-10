//
//  CloudItemAvailability.swift
//  InkPond
//

import Foundation
import os.log

struct CloudDownloadPreparationResult: Equatable, Sendable {
    let downloadedItemCount: Int

    var didDownloadItems: Bool {
        downloadedItemCount > 0
    }
}

nonisolated enum CloudItemAvailability {
    @discardableResult
    static func requestDownloads(at url: URL) throws -> Int {
        let pendingItems = try pendingUbiquitousItems(at: url)
        Diagnostics.record(
            .iCloud,
            "download_request.pending",
            metadata: [
                "rootHash": Diagnostics.hashIdentifier(url.standardizedFileURL.path),
                "pendingCount": String(pendingItems.count)
            ]
        )

        guard !pendingItems.isEmpty else { return 0 }

        let fileManager = FileManager.default
        var requestedCount = 0
        for itemURL in pendingItems {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: itemURL)
                requestedCount += 1
            } catch {
                Diagnostics.record(
                    .iCloud,
                    "download_request.failed",
                    level: .error,
                    metadata: Diagnostics.errorMetadata(error)
                )
                os_log(
                    .error,
                    "CloudItemAvailability: failed to request download for %{public}@: %{public}@",
                    itemURL.lastPathComponent,
                    error.localizedDescription
                )
            }
        }

        Diagnostics.record(
            .iCloud,
            "download_request.finished",
            metadata: ["requestedCount": String(requestedCount)]
        )
        return requestedCount
    }

    static func prepareForAccess(at url: URL, timeout: TimeInterval = 120) throws -> CloudDownloadPreparationResult {
        let pendingItems = try pendingUbiquitousItems(at: url)
        Diagnostics.record(
            .iCloud,
            "prepare_for_access.pending",
            metadata: [
                "rootHash": Diagnostics.hashIdentifier(url.standardizedFileURL.path),
                "pendingCount": String(pendingItems.count),
                "timeoutSeconds": String(Int(timeout))
            ]
        )
        guard !pendingItems.isEmpty else {
            return CloudDownloadPreparationResult(downloadedItemCount: 0)
        }

        let fileManager = FileManager.default
        for itemURL in pendingItems {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: itemURL)
            } catch {
                Diagnostics.record(
                    .iCloud,
                    "prepare_for_access.download_request_failed",
                    level: .error,
                    metadata: Diagnostics.errorMetadata(error)
                )
                os_log(
                    .error,
                    "CloudItemAvailability: failed to start download for %{public}@: %{public}@",
                    itemURL.lastPathComponent,
                    error.localizedDescription
                )
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var remaining = pendingItems

        while Date() < deadline {
            remaining = remaining.filter { itemURL in
                guard let values = try? itemURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else {
                    return true
                }
                return values.ubiquitousItemDownloadingStatus != .current
            }

            if remaining.isEmpty {
                Diagnostics.record(
                    .iCloud,
                    "prepare_for_access.success",
                    metadata: ["downloadedCount": String(pendingItems.count)]
                )
                return CloudDownloadPreparationResult(downloadedItemCount: pendingItems.count)
            }

            Thread.sleep(forTimeInterval: 0.35)
        }

        Diagnostics.record(
            .iCloud,
            "prepare_for_access.timeout",
            level: .error,
            metadata: [
                "pendingCount": String(pendingItems.count),
                "remainingCount": String(remaining.count)
            ]
        )
        throw StorageManager.MigrationError.downloadTimeout
    }

    private static func pendingUbiquitousItems(at url: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        var pending: [URL] = []

        if try isPendingUbiquitousItem(at: url) {
            pending.append(url)
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey
                ],
                options: [.skipsHiddenFiles]
              ) else {
            return deduplicated(pending)
        }

        for case let itemURL as URL in enumerator {
            if try isPendingUbiquitousItem(at: itemURL) {
                pending.append(itemURL)
            }
        }

        return deduplicated(pending)
    }

    private static func isPendingUbiquitousItem(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        Array(Set(urls)).sorted { $0.path < $1.path }
    }
}
