//
//  StorageManager.swift
//  InkPond
//

import Foundation
import Network
import os

enum StorageMode: String {
    case local
    case iCloud
}

enum SyncContentCategory {
    case appFonts
    case localPackages
    case snippets

    nonisolated var directoryName: String {
        switch self {
        case .appFonts:
            return "AppFonts"
        case .localPackages:
            return "LocalPackages"
        case .snippets:
            return "Snippets"
        }
    }

    nonisolated var localRootURL: URL? {
        switch self {
        case .appFonts:
            return FontManager.localAppFontsRootURL
        case .localPackages:
            return TypstBridge.localPackagesRootURL
        case .snippets:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent(AppIdentity.snippetStoreDirectoryName, isDirectory: true)
        }
    }
}

@Observable
final class StorageManager {
    private static let storageKey = StorageSyncPreferences.storageModeKey
    private static let syncFontsKey = StorageSyncPreferences.syncFontsKey
    private static let syncPackagesKey = StorageSyncPreferences.syncPackagesKey
    private static let syncSnippetsKey = StorageSyncPreferences.syncSnippetsKey

    private(set) var mode: StorageMode
    private(set) var iCloudAvailable: Bool = false
    private(set) var isMigrating: Bool = false
    private(set) var migrationError: String?
    /// Migration progress (0.0–1.0) for UI feedback.
    private(set) var migrationProgress: Double = 0
    private(set) var syncFontsInICloud: Bool
    private(set) var syncPackagesInICloud: Bool
    private(set) var syncSnippetsInICloud: Bool

    /// Project IDs that failed during the last migration attempt.
    /// Non-empty means the migration partially succeeded and can be retried.
    private(set) var failedProjectIDs: [String] = []

    /// Whether a partial migration can be retried.
    var canRetryMigration: Bool { !failedProjectIDs.isEmpty && !isMigrating }

    /// The ubiquity container URL, if iCloud is available.
    private(set) var ubiquityURL: URL?

    /// Cached flag for cross-actor reads. Updated whenever mode or iCloudAvailable changes.
    /// Protected by a lock for thread-safe access from any actor context.
    @ObservationIgnored
    private let _isUsingiCloudLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? StorageMode.local.rawValue
        self.mode = StorageMode(rawValue: raw) ?? .local
        self.syncFontsInICloud = StorageSyncPreferences.fontPreferenceEnabled
        self.syncPackagesInICloud = StorageSyncPreferences.packagePreferenceEnabled
        self.syncSnippetsInICloud = StorageSyncPreferences.snippetPreferenceEnabled
        // Perform initial availability check. url(forUbiquityContainerIdentifier:)
        // may trigger a first-time container setup, so keep it synchronous at launch
        // to ensure the URL is ready before any file operations.
        let url = FileManager.default.url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)
        self.ubiquityURL = url
        self.iCloudAvailable = url != nil
        let initialUsingiCloud = self.mode == .iCloud && self.iCloudAvailable
        self._isUsingiCloudLock.withLock { $0 = initialUsingiCloud }
    }

    /// The active documents base URL, depending on current storage mode.
    var activeDocumentsURL: URL {
        if mode == .iCloud, let ubiquityDocuments = ubiquityDocumentsURL {
            return ubiquityDocuments
        }
        return localDocumentsURL
    }

    /// The documents directory that can be safely enumerated for sync/monitoring.
    /// Returns `nil` while iCloud mode is selected but the ubiquity container is unavailable.
    var syncDocumentsURL: URL? {
        switch mode {
        case .local:
            return localDocumentsURL
        case .iCloud:
            return ubiquityDocumentsURL
        }
    }

    var localDocumentsURL: URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("DocumentDirectory unavailable")
        }
        return docs
    }

    var ubiquityDocumentsURL: URL? {
        ubiquityURL?.appendingPathComponent("Documents", isDirectory: true)
    }

    func refreshICloudAvailability() {
        let url = FileManager.default.url(forUbiquityContainerIdentifier: AppIdentity.iCloudContainerIdentifier)
        self.ubiquityURL = url
        self.iCloudAvailable = url != nil
        syncCachedFlag()
    }

    func setSyncFontsInICloud(_ enabled: Bool) async {
        await setAuxiliarySync(enabled, for: .appFonts)
    }

    func setSyncPackagesInICloud(_ enabled: Bool) async {
        await setAuxiliarySync(enabled, for: .localPackages)
    }

    func setSyncSnippetsInICloud(_ enabled: Bool) async {
        await setAuxiliarySync(enabled, for: .snippets)
    }

    func setMode(_ newMode: StorageMode, documents: [InkPondProject]) async {
        guard newMode != mode else { return }
        guard !isMigrating else { return }

        // Verify network connectivity before attempting migration
        guard NetworkReachability.currentlyReachable() else {
            migrationError = L10n.tr("icloud.error.no_network")
            return
        }

        if newMode == .iCloud {
            refreshICloudAvailability()
            guard iCloudAvailable, let iCloudDocs = ubiquityDocumentsURL else {
                migrationError = L10n.tr("icloud.error.unavailable")
                return
            }
            // Verify URLs are distinct
            guard iCloudDocs.standardizedFileURL != localDocumentsURL.standardizedFileURL else {
                migrationError = L10n.tr("icloud.error.unavailable")
                return
            }
        } else {
            // Switching to local: iCloud container must still be reachable to copy files out.
            guard let iCloudDocs = ubiquityDocumentsURL,
                  iCloudDocs.standardizedFileURL != localDocumentsURL.standardizedFileURL else {
                migrationError = L10n.tr("icloud.error.unavailable")
                return
            }
        }

        isMigrating = true
        migrationError = nil
        migrationProgress = 0

        let sourceBase: URL
        let destBase: URL

        if newMode == .iCloud {
            sourceBase = localDocumentsURL
            destBase = ubiquityDocumentsURL!
        } else {
            sourceBase = ubiquityDocumentsURL!
            destBase = localDocumentsURL
        }

        let projectIDs = documents.map(\.projectID)
        let toiCloud = newMode == .iCloud
        let syncFontsInICloud = self.syncFontsInICloud
        let syncPackagesInICloud = self.syncPackagesInICloud
        let syncSnippetsInICloud = self.syncSnippetsInICloud
        let appFontsDirectoryName = SyncContentCategory.appFonts.directoryName
        let appFontsLocalRootURL = SyncContentCategory.appFonts.localRootURL
        let localPackagesDirectoryName = SyncContentCategory.localPackages.directoryName
        let localPackagesRootURL = SyncContentCategory.localPackages.localRootURL
        let snippetsDirectoryName = SyncContentCategory.snippets.directoryName
        let snippetsLocalRootURL = SyncContentCategory.snippets.localRootURL

        do {
            let failures = try await Task.detached {
                let failed = self.migrateFiles(
                    projectIDs: projectIDs,
                    from: sourceBase,
                    to: destBase,
                    toiCloud: toiCloud
                    ) { progress in
                        Task { @MainActor in
                            self.migrationProgress = progress
                        }
                    }
                if syncFontsInICloud, let localFontsRoot = appFontsLocalRootURL {
                    try self.migrateAuxiliaryDirectory(
                        named: appFontsDirectoryName,
                        from: toiCloud ? localFontsRoot : sourceBase,
                        to: toiCloud ? destBase : localFontsRoot,
                        sourceIsICloud: !toiCloud,
                        destinationIsICloud: toiCloud
                    )
                }

                if syncPackagesInICloud, let localPackagesRoot = localPackagesRootURL {
                    try self.migrateAuxiliaryDirectory(
                        named: localPackagesDirectoryName,
                        from: toiCloud ? localPackagesRoot : sourceBase,
                        to: toiCloud ? destBase : localPackagesRoot,
                        sourceIsICloud: !toiCloud,
                        destinationIsICloud: toiCloud
                    )
                }

                if syncSnippetsInICloud, let snippetsRoot = snippetsLocalRootURL {
                    try self.migrateAuxiliaryDirectory(
                        named: snippetsDirectoryName,
                        from: toiCloud ? snippetsRoot : sourceBase,
                        to: toiCloud ? destBase : snippetsRoot,
                        sourceIsICloud: !toiCloud,
                        destinationIsICloud: toiCloud
                    )
                }
                return failed
            }.value

            // Switch mode even with partial failures — successfully migrated projects
            // are already at the destination. Failed ones can be retried.
            mode = newMode
            syncCachedFlag()
            UserDefaults.standard.set(newMode.rawValue, forKey: Self.storageKey)
            failedProjectIDs = failures

            if failures.isEmpty {
                os_log(.info, "StorageManager: switched to %{public}@", newMode.rawValue)
            } else {
                let failedList = failures.joined(separator: ", ")
                migrationError = L10n.format("icloud.error.partial_migration", failures.count)
                os_log(.error, "StorageManager: partial migration, failed projects: %{public}@", failedList)
            }
        } catch {
            migrationError = error.localizedDescription
            os_log(.error, "StorageManager: migration failed: %{public}@", error.localizedDescription)
        }

        isMigrating = false
    }

    /// Retry migrating projects that failed during the last migration attempt.
    func retryFailedMigration(documents: [InkPondProject]) async {
        guard !failedProjectIDs.isEmpty else { return }
        guard !isMigrating else { return }

        guard NetworkReachability.currentlyReachable() else {
            migrationError = L10n.tr("icloud.error.no_network")
            return
        }

        refreshICloudAvailability()
        guard iCloudAvailable, let iCloudDocs = ubiquityDocumentsURL,
              iCloudDocs.standardizedFileURL != localDocumentsURL.standardizedFileURL else {
            migrationError = L10n.tr("icloud.error.unavailable")
            return
        }

        isMigrating = true
        migrationError = nil
        migrationProgress = 0

        let sourceBase: URL
        let destBase: URL
        let toiCloud = mode == .iCloud

        if toiCloud {
            sourceBase = localDocumentsURL
            destBase = iCloudDocs
        } else {
            sourceBase = iCloudDocs
            destBase = localDocumentsURL
        }

        let retryIDs = failedProjectIDs

        let failures = await Task.detached {
            self.migrateFiles(
                projectIDs: retryIDs,
                from: sourceBase,
                to: destBase,
                toiCloud: toiCloud
            ) { progress in
                Task { @MainActor in
                    self.migrationProgress = progress
                }
            }
        }.value

        failedProjectIDs = failures
        if failures.isEmpty {
            migrationError = nil
            os_log(.info, "StorageManager: retry migration succeeded")
        } else {
            migrationError = L10n.format("icloud.error.partial_migration", failures.count)
            os_log(.error, "StorageManager: retry still has %d failed projects", failures.count)
        }

        isMigrating = false
    }

    /// Returns true if iCloud mode is active and available.
    /// Nonisolated so it can be read from any actor context (e.g. BackgroundDocumentFileWriter).
    nonisolated var isUsingiCloud: Bool {
        _isUsingiCloudLock.withLock { $0 }
    }

    /// Call after changing mode or iCloudAvailable to update the cross-actor cache.
    private func syncCachedFlag() {
        let value = mode == .iCloud && iCloudAvailable
        _isUsingiCloudLock.withLock { $0 = value }
    }

    private func setAuxiliarySync(_ enabled: Bool, for category: SyncContentCategory) async {
        guard !isMigrating else { return }
        guard auxiliarySyncState(for: category) != enabled else { return }

        guard mode == .iCloud else {
            persistAuxiliarySync(enabled, for: category)
            return
        }

        guard NetworkReachability.currentlyReachable() else {
            migrationError = L10n.tr("icloud.error.no_network")
            return
        }

        refreshICloudAvailability()
        guard iCloudAvailable, let iCloudDocumentsURL = ubiquityDocumentsURL else {
            migrationError = L10n.tr("icloud.error.unavailable")
            return
        }
        let directoryName = category.directoryName
        guard let localRootURL = category.localRootURL else { return }

        isMigrating = true
        migrationError = nil
        migrationProgress = 0.1

        do {
            try await Task.detached {
                try self.migrateAuxiliaryDirectory(
                    named: directoryName,
                    from: enabled ? localRootURL : iCloudDocumentsURL,
                    to: enabled ? iCloudDocumentsURL : localRootURL,
                    sourceIsICloud: !enabled,
                    destinationIsICloud: enabled
                )
            }.value

            migrationProgress = 1
            persistAuxiliarySync(enabled, for: category)
        } catch {
            migrationError = error.localizedDescription
            os_log(.error, "StorageManager: auxiliary migration failed: %{public}@", error.localizedDescription)
        }

        isMigrating = false
    }

    private func auxiliarySyncState(for category: SyncContentCategory) -> Bool {
        switch category {
        case .appFonts:
            return syncFontsInICloud
        case .localPackages:
            return syncPackagesInICloud
        case .snippets:
            return syncSnippetsInICloud
        }
    }

    private func persistAuxiliarySync(_ enabled: Bool, for category: SyncContentCategory) {
        switch category {
        case .appFonts:
            syncFontsInICloud = enabled
            UserDefaults.standard.set(enabled, forKey: Self.syncFontsKey)
        case .localPackages:
            syncPackagesInICloud = enabled
            UserDefaults.standard.set(enabled, forKey: Self.syncPackagesKey)
        case .snippets:
            syncSnippetsInICloud = enabled
            UserDefaults.standard.set(enabled, forKey: Self.syncSnippetsKey)
        }
    }

    // MARK: - Migration

    /// Migrates project directories, collecting failures instead of aborting.
    /// Returns the list of project IDs that failed to migrate.
    private nonisolated func migrateFiles(
        projectIDs: [String],
        from sourceBase: URL,
        to destBase: URL,
        toiCloud: Bool,
        onProgress: @Sendable (Double) -> Void
    ) -> [String] {
        let fm = FileManager.default

        // Ensure destination base exists
        do {
            if !fm.fileExists(atPath: destBase.path) {
                try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
            }
        } catch {
            os_log(.error, "StorageManager: cannot create destination: %{public}@", error.localizedDescription)
            return projectIDs
        }

        // When migrating FROM iCloud, attempt download for each project individually
        // so that a single download failure doesn't block the rest.

        let coordinator = NSFileCoordinator()
        let total = projectIDs.count
        var completed = 0
        var failedIDs: [String] = []

        for projectID in projectIDs {
            let sourceDir = sourceBase.appendingPathComponent(projectID, isDirectory: true)
            let destDir = destBase.appendingPathComponent(projectID, isDirectory: true)

            guard fm.fileExists(atPath: sourceDir.path) else {
                completed += 1
                onProgress(Double(completed) / Double(max(total, 1)))
                continue
            }

            do {
                // Download from iCloud if needed
                if !toiCloud {
                    try ensureDownloaded(directory: sourceDir)
                }

                // Copy using NSFileCoordinator
                var coordinationError: NSError?
                var copyError: Error?

                coordinator.coordinate(
                    readingItemAt: sourceDir, options: [],
                    writingItemAt: destDir, options: .forReplacing,
                    error: &coordinationError
                ) { coordinatedSource, coordinatedDest in
                    do {
                        if fm.fileExists(atPath: coordinatedDest.path) {
                            try fm.removeItem(at: coordinatedDest)
                        }
                        try fm.copyItem(at: coordinatedSource, to: coordinatedDest)
                    } catch {
                        copyError = error
                    }
                }

                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }

                // Verify the copy
                guard fm.fileExists(atPath: destDir.path) else {
                    throw MigrationError.verificationFailed(projectID)
                }

                // Clean up source after successful copy & verification
                do {
                    try removeMigratedSourceDirectory(at: sourceDir, isICloud: !toiCloud)
                } catch {
                    os_log(.error, "StorageManager: cleanup failed for %{public}@: %{public}@",
                           projectID, error.localizedDescription)
                }

                os_log(.info, "StorageManager: migrated project %{public}@", projectID)
            } catch {
                failedIDs.append(projectID)
                os_log(.error, "StorageManager: failed to migrate %{public}@: %{public}@",
                       projectID, error.localizedDescription)
            }

            completed += 1
            onProgress(Double(completed) / Double(max(total, 1)))
        }

        return failedIDs
    }

    /// Recursively triggers download of all files in an iCloud directory and waits
    /// until they are available locally (up to a timeout).
    private nonisolated func ensureDownloaded(directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var filesToDownload: [URL] = []

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .ubiquitousItemDownloadingStatusKey
            ])
            guard values?.isRegularFile == true else { continue }

            let status = values?.ubiquitousItemDownloadingStatus
            if status != .current {
                try fm.startDownloadingUbiquitousItem(at: fileURL)
                filesToDownload.append(fileURL)
            }
        }

        guard !filesToDownload.isEmpty else { return }

        // Poll until all files are downloaded (timeout: 120s)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let remaining = filesToDownload.filter { url in
                let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return values?.ubiquitousItemDownloadingStatus != .current
            }
            if remaining.isEmpty { return }
            filesToDownload = remaining
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Timeout — throw so the user knows migration couldn't complete
        throw MigrationError.downloadTimeout
    }

    private nonisolated func migrateAuxiliaryDirectory(
        named directoryName: String,
        from sourceRoot: URL,
        to destinationRoot: URL,
        sourceIsICloud: Bool,
        destinationIsICloud: Bool
    ) throws {
        let fm = FileManager.default
        let sourceDir = sourceRoot.appendingPathComponent(directoryName, isDirectory: true)
        let destinationDir = destinationRoot.appendingPathComponent(directoryName, isDirectory: true)

        guard fm.fileExists(atPath: sourceDir.path) else { return }

        if sourceIsICloud {
            try ensureDownloaded(directory: sourceDir)
        }

        if !fm.fileExists(atPath: destinationRoot.path) {
            if destinationIsICloud {
                try CloudFileCoordinator.createDirectory(at: destinationRoot)
            } else {
                try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            }
        }

        if fm.fileExists(atPath: destinationDir.path) {
            if destinationIsICloud {
                try CloudFileCoordinator.removeItem(at: destinationDir)
            } else {
                try fm.removeItem(at: destinationDir)
            }
        }

        if sourceIsICloud || destinationIsICloud {
            try CloudFileCoordinator.copyItem(from: sourceDir, to: destinationDir)
        } else {
            try fm.copyItem(at: sourceDir, to: destinationDir)
        }

        try removeMigratedSourceDirectory(at: sourceDir, isICloud: sourceIsICloud)
    }

    private nonisolated func removeMigratedSourceDirectory(at sourceDir: URL, isICloud: Bool) throws {
        if isICloud {
            try CloudFileCoordinator.removeItem(at: sourceDir)
        } else {
            try FileManager.default.removeItem(at: sourceDir)
        }
    }

    enum MigrationError: LocalizedError {
        case iCloudUnavailable
        case verificationFailed(String)
        case downloadTimeout

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable:
                return L10n.tr("icloud.error.unavailable")
            case .verificationFailed(let projectID):
                return L10n.format("icloud.error.verification_failed", projectID)
            case .downloadTimeout:
                return L10n.tr("icloud.error.download_timeout")
            }
        }
    }
}
