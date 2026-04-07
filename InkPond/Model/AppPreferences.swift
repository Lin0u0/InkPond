import Foundation

enum StorageMode: String {
    case local
    case iCloud
}

enum SyncContentCategory {
    case projects
    case appFonts
    case localPackages
    case snippets

    nonisolated var directoryName: String {
        return switch self {
        case .projects: ""
        case .appFonts: "AppFonts"
        case .localPackages: "LocalPackages"
        case .snippets: "Snippets"
        }
    }

    nonisolated var localRootURL: URL? {
        return switch self {
        case .projects: ExposedAuxiliaryDirectory.localDocumentsURL
        case .appFonts: FontManager.localAppFontsRootURL
        case .localPackages: TypstBridge.localPackagesRootURL
        case .snippets: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent(AppIdentity.snippetStoreDirectoryName, isDirectory: true)
        }
    }
}

enum AppPreferences {
    nonisolated static let storageModeKey = "storageMode"
    nonisolated static let syncFontsKey = "syncAppFontsInICloud"
    nonisolated static let syncPackagesKey = "syncLocalPackagesInICloud"
    nonisolated static let syncSnippetsKey = "syncSnippetsInICloud"

    nonisolated static var syncProjects: Bool {
        getProjectStorageMode == StorageMode.iCloud
    }
    
    nonisolated static var getProjectStorageMode: StorageMode {
        StorageMode(rawValue: UserDefaults.standard.string(forKey: storageModeKey) ?? StorageMode.local.rawValue)!
    }
    nonisolated static func setProjectStorageMode(mode: StorageMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageModeKey)
    }
    
    nonisolated static func GetSyncState(for category: SyncContentCategory) -> Bool {
        return switch category {
        case .projects: syncProjects
        case .appFonts: fontPreferenceEnabled
        case .localPackages: packagePreferenceEnabled
        case .snippets: snippetPreferenceEnabled
        }
    }

    nonisolated static func SetSyncState(_ enabled: Bool, for category: SyncContentCategory) {
        switch category {
        case .projects: setProjectStorageMode(mode: enabled ? .iCloud : .local)
        case .appFonts: enableFontSyncPreference(enabled: enabled)
        case .localPackages: enablePackageSyncPreference(enabled: enabled)
        case .snippets: enableSnippetSyncPreference(enabled: enabled)
        }
    }
    

    nonisolated static var fontPreferenceEnabled: Bool {
        bool(forKey: syncFontsKey, default: false)
    }
    nonisolated static func enableFontSyncPreference(enabled:Bool) {
        UserDefaults.standard.set(enabled, forKey: syncFontsKey)
    }
    
    
    nonisolated static var packagePreferenceEnabled: Bool {
        bool(forKey: syncPackagesKey, default: false)
    }
    nonisolated static func enablePackageSyncPreference(enabled:Bool) {
        UserDefaults.standard.set(enabled, forKey: syncPackagesKey)
    }

    nonisolated static var snippetPreferenceEnabled: Bool {
        bool(forKey: syncSnippetsKey, default: false)
    }
    nonisolated static func enableSnippetSyncPreference(enabled:Bool) {
        UserDefaults.standard.set(enabled, forKey: syncSnippetsKey)
    }

    nonisolated static var syncFonts: Bool {
        syncProjects && fontPreferenceEnabled
    }
    nonisolated static var syncPackages: Bool {
        syncProjects && packagePreferenceEnabled
    }
    nonisolated static var syncSnippets: Bool {
        syncProjects && snippetPreferenceEnabled
    }

    nonisolated private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
