import Foundation

nonisolated enum ProjectStorageBackendKind: String, Codable, Sendable {
    case local
    case iCloud
    case privateShadow
    case linkedExternal
    case faultInjecting
}

protocol ProjectStorageBackend: Sendable {
    var kind: ProjectStorageBackendKind { get }
    func read(_ relativePath: String) async throws -> Data
    func writeStaged(_ data: Data, at relativePath: String) async throws
    func replace(_ relativePath: String, withStaged stagedRelativePath: String) async throws
    func remove(_ relativePath: String) async throws
    func exists(_ relativePath: String) async throws -> Bool
}

actor LocalProjectStorageBackend: ProjectStorageBackend {
    nonisolated let kind: ProjectStorageBackendKind
    private let policy: ProjectPathPolicy
    private let fileManager: FileManager

    init(rootURL: URL, kind: ProjectStorageBackendKind = .local, fileManager: FileManager = .default) throws {
        guard kind != .faultInjecting else { throw ProjectStorageBackendError.invalidKind }
        self.kind = kind
        self.policy = ProjectPathPolicy(rootURL: rootURL)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func read(_ relativePath: String) throws -> Data {
        try Data(contentsOf: policy.resolve(relativePath))
    }

    func writeStaged(_ data: Data, at relativePath: String) throws {
        let url = try policy.resolve(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func replace(_ relativePath: String, withStaged stagedRelativePath: String) throws {
        let destination = try policy.resolve(relativePath)
        let staged = try policy.resolve(stagedRelativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        try DurableFileSynchronization.synchronizeFileAndParent(destination)
    }

    func remove(_ relativePath: String) throws {
        let url = try policy.resolve(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func exists(_ relativePath: String) throws -> Bool {
        fileManager.fileExists(atPath: try policy.resolve(relativePath).path)
    }
}

actor CoordinatedProjectStorageBackend: ProjectStorageBackend {
    nonisolated let kind: ProjectStorageBackendKind
    private let policy: ProjectPathPolicy
    private let securityScopeLease: SecurityScopeLease?

    init(rootURL: URL, kind: ProjectStorageBackendKind, securityScopeLease: SecurityScopeLease? = nil) throws {
        guard kind == .iCloud || kind == .linkedExternal else {
            throw ProjectStorageBackendError.invalidKind
        }
        self.kind = kind
        self.policy = ProjectPathPolicy(rootURL: rootURL)
        self.securityScopeLease = securityScopeLease
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func read(_ relativePath: String) throws -> Data {
        try CloudFileCoordinator.readData(from: policy.resolve(relativePath))
    }

    func writeStaged(_ data: Data, at relativePath: String) throws {
        let url = try policy.resolve(relativePath)
        try CloudFileCoordinator.createDirectory(at: url.deletingLastPathComponent())
        try CloudFileCoordinator.writeData(data, to: url)
    }

    func replace(_ relativePath: String, withStaged stagedRelativePath: String) throws {
        try CloudFileCoordinator.replaceItemAtomically(
            from: policy.resolve(stagedRelativePath),
            to: policy.resolve(relativePath)
        )
        try DurableFileSynchronization.synchronizeFileAndParent(policy.resolve(relativePath))
    }

    func remove(_ relativePath: String) throws {
        let url = try policy.resolve(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try CloudFileCoordinator.removeItem(at: url)
    }

    func exists(_ relativePath: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try policy.resolve(relativePath).path)
    }
}

actor ExternalSingleFileProjectStorageBackend: ProjectStorageBackend {
    nonisolated let kind: ProjectStorageBackendKind = .linkedExternal
    private let targetFileURL: URL
    private let targetFileName: String
    private let stagingPolicy: ProjectPathPolicy
    private let securityScopeLease: SecurityScopeLease?

    init(targetFileURL: URL, stagingRootURL: URL) throws {
        self.targetFileURL = targetFileURL.standardizedFileURL
        self.targetFileName = targetFileURL.lastPathComponent
        self.stagingPolicy = ProjectPathPolicy(rootURL: stagingRootURL)
        self.securityScopeLease = SecurityScopeLease.accessing(targetFileURL)
        try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
    }

    func read(_ relativePath: String) throws -> Data {
        if relativePath == targetFileName {
            return try CloudFileCoordinator.readData(from: targetFileURL)
        }
        return try Data(contentsOf: stagingURL(relativePath))
    }

    func writeStaged(_ data: Data, at relativePath: String) throws {
        let url = try stagingURL(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func replace(_ relativePath: String, withStaged stagedRelativePath: String) throws {
        guard relativePath == targetFileName else { throw ProjectStorageBackendError.invalidExternalPath }
        let stagedURL = try stagingURL(stagedRelativePath)
        let data = try Data(contentsOf: stagedURL)
        try CloudFileCoordinator.writeData(data, to: targetFileURL, atomically: true)
        try DurableFileSynchronization.synchronizeFileAndParent(targetFileURL)
        try FileManager.default.removeItem(at: stagedURL)
    }

    func remove(_ relativePath: String) throws {
        if relativePath == targetFileName {
            try CloudFileCoordinator.removeItem(at: targetFileURL)
        } else {
            let url = try stagingURL(relativePath)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func exists(_ relativePath: String) throws -> Bool {
        if relativePath == targetFileName { return FileManager.default.fileExists(atPath: targetFileURL.path) }
        return FileManager.default.fileExists(atPath: try stagingURL(relativePath).path)
    }

    private func stagingURL(_ relativePath: String) throws -> URL {
        guard relativePath.hasPrefix(".inkpond/staging/") else {
            throw ProjectStorageBackendError.invalidExternalPath
        }
        return try stagingPolicy.resolve(relativePath)
    }
}

nonisolated enum ProjectStorageBackendFactory {
    static func make(
        kind: ProjectStorageBackendKind,
        rootURL: URL,
        securityScopeLease: SecurityScopeLease? = nil
    ) throws -> any ProjectStorageBackend {
        switch kind {
        case .local, .privateShadow:
            return try LocalProjectStorageBackend(rootURL: rootURL, kind: kind)
        case .iCloud, .linkedExternal:
            return try CoordinatedProjectStorageBackend(
                rootURL: rootURL,
                kind: kind,
                securityScopeLease: securityScopeLease
            )
        case .faultInjecting:
            throw ProjectStorageBackendError.invalidKind
        }
    }
}

nonisolated enum InjectedStorageFault: Sendable {
    case none
    case corruptStagedRead
    case failStagedWrite
    case failReplace
    case diskFull
    case permissionLoss
    case coordinationFailure
}

actor FaultInjectingProjectStorageBackend: ProjectStorageBackend {
    nonisolated let kind: ProjectStorageBackendKind = .faultInjecting
    private let base: any ProjectStorageBackend
    private let fault: InjectedStorageFault

    init(base: any ProjectStorageBackend, fault: InjectedStorageFault) {
        self.base = base
        self.fault = fault
    }

    func read(_ relativePath: String) async throws -> Data {
        if fault == .coordinationFailure {
            throw ProjectStorageBackendError.coordinationFailed
        }
        let data = try await base.read(relativePath)
        if fault == .corruptStagedRead, relativePath.hasPrefix(".inkpond/staging/") {
            return data + Data([0])
        }
        return data
    }

    func writeStaged(_ data: Data, at relativePath: String) async throws {
        if fault == .failStagedWrite { throw ProjectStorageBackendError.injectedFailure }
        if fault == .diskFull { throw ProjectStorageBackendError.diskFull }
        try await base.writeStaged(data, at: relativePath)
    }

    func replace(_ relativePath: String, withStaged stagedRelativePath: String) async throws {
        if fault == .failReplace { throw ProjectStorageBackendError.injectedFailure }
        if fault == .permissionLoss { throw ProjectStorageBackendError.permissionDenied }
        try await base.replace(relativePath, withStaged: stagedRelativePath)
    }

    func remove(_ relativePath: String) async throws { try await base.remove(relativePath) }
    func exists(_ relativePath: String) async throws -> Bool { try await base.exists(relativePath) }
}

nonisolated enum ProjectStorageBackendError: Error, Equatable, Sendable {
    case invalidKind
    case injectedFailure
    case diskFull
    case permissionDenied
    case coordinationFailed
    case invalidExternalPath
}
