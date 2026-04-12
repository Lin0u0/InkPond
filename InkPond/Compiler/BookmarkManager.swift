import Foundation
import os

enum BookmarkManager {
    private static let bookmarksDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bookmarks", isDirectory: true)
    }()

    /// Tracks resolved URLs and their access reference counts.
    private static let _lock = OSAllocatedUnfairLock<[String: (url: URL, refCount: Int)]>(initialState: [:])

    static func hasBookmark(projectID: String) -> Bool {
        if _lock.withLock({ $0[projectID] }) != nil { return true }
        let fileURL = bookmarksDirectory.appendingPathComponent("\(projectID).bookmark")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func saveBookmark(for url: URL, projectID: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: bookmarksDirectory.path) {
            try fm.createDirectory(at: bookmarksDirectory, withIntermediateDirectories: true)
        }

        let bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let fileURL = bookmarksDirectory.appendingPathComponent("\(projectID).bookmark")
        try bookmarkData.write(to: fileURL)
    }

    /// Resolves and starts security-scoped access for a bookmark.
    /// Each call increments a reference count — callers must balance with `stopAccessing(_:)`.
    static func loadBookmark(projectID: String) -> URL? {
        // If already resolved, increment ref count and return cached URL.
        if let entry = _lock.withLock({ state -> (url: URL, refCount: Int)? in
            guard var entry = state[projectID] else { return nil }
            entry.refCount += 1
            state[projectID] = entry
            return entry
        }) {
            return entry.url
        }

        let fileURL = bookmarksDirectory.appendingPathComponent("\(projectID).bookmark")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        var isStale = false
        guard let resolvedURL = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }

        if isStale {
            // Re-save refreshed bookmark data so it stays valid.
            if let refreshedData = try? resolvedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? refreshedData.write(to: fileURL)
                os_log(.info, "BookmarkManager: refreshed stale bookmark for %{public}@", projectID)
            }
        }

        if resolvedURL.startAccessingSecurityScopedResource() {
            _lock.withLock { $0[projectID] = (url: resolvedURL, refCount: 1) }
            return resolvedURL
        }
        return nil
    }

    /// Decrements the reference count for a bookmark's security-scoped access.
    /// When the count reaches zero, `stopAccessingSecurityScopedResource()` is called.
    static func stopAccessing(_ projectID: String) {
        _lock.withLock { state in
            guard var entry = state[projectID] else { return }
            entry.refCount -= 1
            if entry.refCount <= 0 {
                entry.url.stopAccessingSecurityScopedResource()
                state.removeValue(forKey: projectID)
            } else {
                state[projectID] = entry
            }
        }
    }

    static func removeBookmark(projectID: String) {
        _lock.withLock { state in
            if let entry = state[projectID] {
                entry.url.stopAccessingSecurityScopedResource()
                state.removeValue(forKey: projectID)
            }
        }
        let fileURL = bookmarksDirectory.appendingPathComponent("\(projectID).bookmark")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
