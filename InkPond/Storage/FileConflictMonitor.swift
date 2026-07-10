//
//  FileConflictMonitor.swift
//  InkPond
//
//  Monitors a file for iCloud version conflicts using NSFilePresenter
//  and NSFileVersion. Replaces the unreliable modificationDate-based
//  conflict detection.
//

import Foundation
import os.log

/// Information about an unresolved iCloud conflict version.
struct ConflictVersionInfo: Identifiable {
    let id = UUID()
    let modificationDate: Date?
    let localizedDeviceName: String?
    let fileVersion: NSFileVersion
}

/// Monitors a single file for iCloud version conflicts.
///
/// Usage:
/// 1. Call `startMonitoring(url:)` when a file is opened for editing.
/// 2. Observe `hasConflict` to show a conflict resolution UI.
/// 3. Call `resolveKeepingCurrent()` or `resolveKeepingVersion(_:)` to resolve.
/// 4. Call `stopMonitoring()` when done editing.
@MainActor
final class FileConflictMonitor: NSObject, NSFilePresenter {

    /// Whether there are unresolved conflict versions for the monitored file.
    private(set) var hasConflict: Bool = false

    /// The unresolved conflict versions, if any.
    private(set) var conflictVersions: [ConflictVersionInfo] = []

    /// Callback invoked on the main actor when a conflict is first detected.
    var onConflictDetected: (() -> Void)?

    /// Callback invoked when the presented file changed without an unresolved conflict.
    var onPresentedItemChanged: (() -> Void)?

    /// The file being monitored.
    private(set) var monitoredURL: URL?

    // MARK: - NSFilePresenter

    nonisolated var presentedItemURL: URL? {
        _presentedItemURLLock.withLock { $0 }
    }

    nonisolated let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.inkpond.FileConflictMonitor"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// Thread-safe storage for presentedItemURL (required by NSFilePresenter).
    private let _presentedItemURLLock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Debounce task for coalescing rapid `presentedItemDidChange` calls.
    private var changeDebounceTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func startMonitoring(url: URL) {
        stopMonitoring(clearCallbacks: false)

        let standardized = url.standardizedFileURL
        _presentedItemURLLock.withLock { $0 = standardized }
        monitoredURL = standardized

        NSFileCoordinator.addFilePresenter(self)

        // Check for any pre-existing unresolved conflicts.
        refreshConflictState()
    }

    func stopMonitoring() {
        stopMonitoring(clearCallbacks: true)
    }

    private func stopMonitoring(clearCallbacks: Bool) {
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        if clearCallbacks {
            onConflictDetected = nil
            onPresentedItemChanged = nil
        }

        guard monitoredURL != nil else { return }

        NSFileCoordinator.removeFilePresenter(self)
        _presentedItemURLLock.withLock { $0 = nil }
        monitoredURL = nil
        hasConflict = false
        conflictVersions = []
    }

    // MARK: - NSFilePresenter callbacks

    /// Called when the file gains a new version (e.g. iCloud delivers a
    /// conflict version from another device).
    nonisolated func presentedItemDidGain(_ version: NSFileVersion) {
        if version.isConflict {
            Task { @MainActor [weak self] in
                self?.refreshConflictState()
            }
        }
    }

    /// Called when a conflict version is resolved externally.
    nonisolated func presentedItemDidResolveConflict(_ version: NSFileVersion) {
        Task { @MainActor [weak self] in
            self?.refreshConflictState()
        }
    }

    /// Called when the file content changes on disk (e.g. iCloud sync).
    /// Debounced to avoid redundant main-actor work during rapid syncs.
    nonisolated func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            self?.scheduleConflictCheck()
        }
    }

    // MARK: - Conflict state

    /// Coalesces rapid change notifications into a single conflict check.
    private func scheduleConflictCheck() {
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.refreshConflictState()
            if self?.hasConflict == false {
                self?.onPresentedItemChanged?()
            }
        }
    }

    /// Re-reads the unresolved conflict versions from NSFileVersion.
    func refreshConflictState() {
        guard let url = monitoredURL else {
            hasConflict = false
            conflictVersions = []
            return
        }

        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        let infos = versions.map { version in
            ConflictVersionInfo(
                modificationDate: version.modificationDate,
                localizedDeviceName: version.localizedNameOfSavingComputer,
                fileVersion: version
            )
        }

        let hadConflict = hasConflict
        conflictVersions = infos
        hasConflict = !infos.isEmpty

        if hasConflict && !hadConflict {
            os_log(.info, "FileConflictMonitor: conflict detected for %{public}@",
                   url.lastPathComponent)
            onConflictDetected?()
        }

        if !hasConflict && hadConflict {
            os_log(.info, "FileConflictMonitor: conflicts resolved for %{public}@",
                   url.lastPathComponent)
        }
    }

    // MARK: - Resolution

    func data(for info: ConflictVersionInfo) throws -> Data {
        try Data(contentsOf: info.fileVersion.url)
    }

    /// Keep the current version on disk. All conflict versions are discarded.
    func resolveKeepingCurrent() throws {
        guard let url = monitoredURL else { return }

        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in versions {
            version.isResolved = true
        }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)

        refreshConflictState()
    }

    deinit {
        // Safety net — caller should always call stopMonitoring() first.
        // Read the URL under lock to avoid racing with stopMonitoring().
        let wasMonitoring = _presentedItemURLLock.withLock { url -> Bool in
            let active = url != nil
            url = nil
            return active
        }
        if wasMonitoring {
            // removeFilePresenter is thread-safe and can be called from deinit.
            NSFileCoordinator.removeFilePresenter(self)
        }
    }
}
