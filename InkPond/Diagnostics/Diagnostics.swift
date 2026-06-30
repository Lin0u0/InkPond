//
//  Diagnostics.swift
//  InkPond
//

import CryptoKit
import Darwin
import Foundation
import OSLog

enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case documentOpen = "DocumentOpen"
    case iCloud = "ICloud"
    case storage = "Storage"
    case cache = "Cache"
    case compiler = "Compiler"
    case importExport = "ImportExport"
    case appLifecycle = "AppLifecycle"
}

enum DiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct DiagnosticSession: Equatable, Sendable {
    nonisolated let id: String
    nonisolated let category: DiagnosticCategory
    nonisolated let startedAt: Date
}

struct DiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
    nonisolated let id: String
    nonisolated let timestamp: Date
    nonisolated let category: DiagnosticCategory
    nonisolated let level: DiagnosticLevel
    nonisolated let name: String
    nonisolated let sessionID: String?
    nonisolated let metadata: [String: String]
}

struct MetricDiagnosticSummary: Codable, Identifiable, Equatable, Sendable {
    nonisolated let id: String
    nonisolated let timestamp: Date
    nonisolated let kind: String
    nonisolated let appVersion: String?
    nonisolated let detail: String
}

struct StorageCapacitySnapshot: Codable, Equatable, Sendable {
    nonisolated let checkedAt: Date
    nonisolated let importantAvailableBytes: Int64?
    nonisolated let availableBytes: Int64?
    nonisolated let totalBytes: Int64?

    nonisolated var bestAvailableBytes: Int64? {
        importantAvailableBytes ?? availableBytes
    }

    nonisolated var freePercent: Double? {
        guard let totalBytes, totalBytes > 0, let bestAvailableBytes else { return nil }
        return Double(bestAvailableBytes) / Double(totalBytes)
    }

    nonisolated static func current(for url: URL? = nil) -> StorageCapacitySnapshot {
        let fallbackURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let targetURL = url ?? fallbackURL
        let values = try? targetURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ])

        return StorageCapacitySnapshot(
            checkedAt: Date(),
            importantAvailableBytes: values?.volumeAvailableCapacityForImportantUsage,
            availableBytes: values?.volumeAvailableCapacity.map(Int64.init),
            totalBytes: values?.volumeTotalCapacity.map(Int64.init)
        )
    }
}

enum StoragePressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case insufficient
    case unknown
}

struct StoragePressureAssessment: Equatable, Sendable {
    nonisolated let snapshot: StorageCapacitySnapshot
    nonisolated let requiredBytes: Int64?
    nonisolated let level: StoragePressureLevel
}

struct BetaDiagnosticsSnapshot: Equatable, Sendable {
    nonisolated let generatedAt: Date
    nonisolated let appVersion: String
    nonisolated let buildNumber: String
    nonisolated let distribution: String
    nonisolated let storage: StorageCapacitySnapshot
    nonisolated let storageMode: String
    nonisolated let iCloudSummary: String
    nonisolated let lastDocumentOpenSessionID: String?
    nonisolated let recentEvents: [DiagnosticEvent]
    nonisolated let recentMetricSummaries: [MetricDiagnosticSummary]

    nonisolated var feedbackSummary: String {
        var lines: [String] = [
            "InkPond Beta Diagnostics",
            "Generated: \(Self.isoString(generatedAt))",
            "Version: \(appVersion) (\(buildNumber))",
            "Distribution: \(distribution)",
            "Storage mode: \(storageMode)",
            "Available storage: \(Self.formattedBytes(storage.bestAvailableBytes))",
            "iCloud: \(iCloudSummary)",
            "Last document-open session: \(lastDocumentOpenSessionID ?? "none")"
        ]

        if !recentMetricSummaries.isEmpty {
            lines.append("Recent MetricKit diagnostics:")
            for summary in recentMetricSummaries.prefix(5) {
                lines.append("- \(Self.isoString(summary.timestamp)) \(summary.kind): \(summary.detail)")
            }
        }

        if !recentEvents.isEmpty {
            lines.append("Recent events:")
            for event in recentEvents.prefix(12) {
                let session = event.sessionID.map { " session=\($0)" } ?? ""
                let metadata = event.metadata.isEmpty
                    ? ""
                    : " " + event.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                lines.append("- \(Self.isoString(event.timestamp)) \(event.category.rawValue).\(event.name)\(session)\(metadata)")
            }
        }

        return lines.joined(separator: "\n")
    }

    nonisolated static func current(storageMode: String, iCloudSummary: String) -> BetaDiagnosticsSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info["CFBundleVersion"] as? String ?? "unknown"
        return BetaDiagnosticsSnapshot(
            generatedAt: Date(),
            appVersion: appVersion,
            buildNumber: buildNumber,
            distribution: AppDistribution.currentLabel,
            storage: StorageCapacitySnapshot.current(),
            storageMode: storageMode,
            iCloudSummary: iCloudSummary,
            lastDocumentOpenSessionID: Diagnostics.storage.lastDocumentOpenSessionID(),
            recentEvents: Array(Diagnostics.storage.recentEvents().prefix(30)),
            recentMetricSummaries: Array(Diagnostics.storage.recentMetricSummaries().prefix(10))
        )
    }

    nonisolated static func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct DiagnosticsStorage {
    nonisolated static let defaultRecentEventLimit = 100
    nonisolated static let defaultMetricSummaryLimit = 40

    nonisolated private static let recentEventsKey = "diagnostics.recentEvents.v1"
    nonisolated private static let metricSummariesKey = "diagnostics.metricSummaries.v1"
    nonisolated private static let lastDocumentOpenSessionKey = "diagnostics.lastDocumentOpenSessionID.v1"
    nonisolated private static let storageLock = OSAllocatedUnfairLock<Void>(initialState: ())

    let defaults: UserDefaults

    nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated func appendEvent(_ event: DiagnosticEvent, limit: Int = Self.defaultRecentEventLimit) {
        Self.storageLock.withLock {
            var events = decodeEvents(forKey: Self.recentEventsKey)
            events.insert(event, at: 0)
            events = Array(events.prefix(limit))
            encode(events, forKey: Self.recentEventsKey)
        }
    }

    nonisolated func recentEvents() -> [DiagnosticEvent] {
        Self.storageLock.withLock {
            decodeEvents(forKey: Self.recentEventsKey)
        }
    }

    nonisolated func appendMetricSummaries(
        _ summaries: [MetricDiagnosticSummary],
        limit: Int = Self.defaultMetricSummaryLimit
    ) {
        guard !summaries.isEmpty else { return }
        Self.storageLock.withLock {
            var existing = decodeMetricSummaries(forKey: Self.metricSummariesKey)
            existing.insert(contentsOf: summaries, at: 0)
            existing = Array(existing.prefix(limit))
            encode(existing, forKey: Self.metricSummariesKey)
        }
    }

    nonisolated func recentMetricSummaries() -> [MetricDiagnosticSummary] {
        Self.storageLock.withLock {
            decodeMetricSummaries(forKey: Self.metricSummariesKey)
        }
    }

    nonisolated func setLastDocumentOpenSessionID(_ id: String) {
        Self.storageLock.withLock {
            defaults.set(id, forKey: Self.lastDocumentOpenSessionKey)
        }
    }

    nonisolated func lastDocumentOpenSessionID() -> String? {
        Self.storageLock.withLock {
            defaults.string(forKey: Self.lastDocumentOpenSessionKey)
        }
    }

    nonisolated func clear() {
        Self.storageLock.withLock {
            defaults.removeObject(forKey: Self.recentEventsKey)
            defaults.removeObject(forKey: Self.metricSummariesKey)
            defaults.removeObject(forKey: Self.lastDocumentOpenSessionKey)
        }
    }

    nonisolated private func encode<T: Encodable>(_ value: T, forKey key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    nonisolated private func decodeEvents(forKey key: String) -> [DiagnosticEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DiagnosticEvent].self, from: data)) ?? []
    }

    nonisolated private func decodeMetricSummaries(forKey key: String) -> [MetricDiagnosticSummary] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MetricDiagnosticSummary].self, from: data)) ?? []
    }
}

enum AppDistribution {
    nonisolated static var currentLabel: String {
        if isTestFlight {
            return "TestFlight"
        }
        if isForcedBetaDiagnostics {
            return "Beta diagnostics override"
        }
        return "App Store or development"
    }

    nonisolated static var isBetaDiagnosticsAvailable: Bool {
        isTestFlight || isForcedBetaDiagnostics
    }

    nonisolated static var isTestFlight: Bool {
        isTestFlightReceiptURL(Bundle.main.appStoreReceiptURL)
    }

    nonisolated static var isForcedBetaDiagnostics: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("INKPOND_FORCE_BETA_DIAGNOSTICS")
            || processInfo.environment["INKPOND_FORCE_BETA_DIAGNOSTICS"] == "1"
    }

    nonisolated static func isTestFlightReceiptURL(_ url: URL?) -> Bool {
        url?.lastPathComponent == "sandboxReceipt"
    }
}

enum Diagnostics {
    nonisolated static let storage = DiagnosticsStorage()

    nonisolated private static let documentOpenLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.documentOpen.rawValue)
    nonisolated private static let iCloudLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.iCloud.rawValue)
    nonisolated private static let storageLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.storage.rawValue)
    nonisolated private static let cacheLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.cache.rawValue)
    nonisolated private static let compilerLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.compiler.rawValue)
    nonisolated private static let importExportLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.importExport.rawValue)
    nonisolated private static let appLifecycleLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.appLifecycle.rawValue)

    nonisolated private static let documentOpenSignposter = OSSignposter(logger: documentOpenLogger)
    nonisolated private static let iCloudSignposter = OSSignposter(logger: iCloudLogger)
    nonisolated private static let storageSignposter = OSSignposter(logger: storageLogger)
    nonisolated private static let cacheSignposter = OSSignposter(logger: cacheLogger)
    nonisolated private static let compilerSignposter = OSSignposter(logger: compilerLogger)
    nonisolated private static let importExportSignposter = OSSignposter(logger: importExportLogger)
    nonisolated private static let appLifecycleSignposter = OSSignposter(logger: appLifecycleLogger)

    nonisolated private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "InkPond"
    }

    @discardableResult
    nonisolated static func startSession(
        category: DiagnosticCategory,
        metadata: [String: String] = [:]
    ) -> DiagnosticSession {
        let session = DiagnosticSession(
            id: shortSessionID(),
            category: category,
            startedAt: Date()
        )
        if category == .documentOpen {
            storage.setLastDocumentOpenSessionID(session.id)
        }
        record(category, "session.start", sessionID: session.id, metadata: metadata)
        return session
    }

    nonisolated static func record(
        _ category: DiagnosticCategory,
        _ name: String,
        level: DiagnosticLevel = .info,
        sessionID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let sanitized = sanitizedMetadata(metadata)
        let event = DiagnosticEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            category: category,
            level: level,
            name: name,
            sessionID: sessionID,
            metadata: sanitized
        )
        storage.appendEvent(event)

        let metadataSummary = sanitized
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let sessionSummary = sessionID.map { " session=\($0)" } ?? ""
        let message = "\(name)\(sessionSummary) \(metadataSummary)"

        switch level {
        case .debug:
            logger(for: category).debug("\(message, privacy: .public)")
        case .info:
            logger(for: category).info("\(message, privacy: .public)")
        case .warning:
            logger(for: category).warning("\(message, privacy: .public)")
        case .error:
            logger(for: category).error("\(message, privacy: .public)")
        }
    }

    nonisolated static func recordStorageSnapshot(reason: String, url: URL? = nil) {
        let snapshot = StorageCapacitySnapshot.current(for: url)
        var metadata: [String: String] = [
            "reason": reason,
            "availableBytes": snapshot.bestAvailableBytes.map(String.init) ?? "unknown"
        ]
        if let totalBytes = snapshot.totalBytes {
            metadata["totalBytes"] = String(totalBytes)
        }
        if let freePercent = snapshot.freePercent {
            metadata["freePercent"] = String(format: "%.4f", freePercent)
        }
        record(.storage, "capacity.snapshot", metadata: metadata)
    }

    nonisolated static func storagePressureAssessment(
        requiredBytes: Int64? = nil,
        snapshot: StorageCapacitySnapshot = .current()
    ) -> StoragePressureAssessment {
        let level: StoragePressureLevel
        if let availableBytes = snapshot.bestAvailableBytes {
            if let requiredBytes, availableBytes < requiredBytes {
                level = .insufficient
            } else if availableBytes < 512 * 1024 * 1024 {
                level = .critical
            } else if availableBytes < 2 * 1024 * 1024 * 1024 {
                level = .warning
            } else {
                level = .normal
            }
        } else {
            level = .unknown
        }
        return StoragePressureAssessment(
            snapshot: snapshot,
            requiredBytes: requiredBytes,
            level: level
        )
    }

    nonisolated static func recordStoragePressure(
        reason: String,
        requiredBytes: Int64? = nil,
        url: URL? = nil
    ) {
        let assessment = storagePressureAssessment(
            requiredBytes: requiredBytes,
            snapshot: StorageCapacitySnapshot.current(for: url)
        )
        var metadata: [String: String] = [
            "reason": reason,
            "level": assessment.level.rawValue,
            "availableBytes": assessment.snapshot.bestAvailableBytes.map(String.init) ?? "unknown"
        ]
        if let requiredBytes {
            metadata["requiredBytes"] = String(requiredBytes)
        }
        if let totalBytes = assessment.snapshot.totalBytes {
            metadata["totalBytes"] = String(totalBytes)
        }
        let level: DiagnosticLevel
        switch assessment.level {
        case .normal:
            level = .info
        case .warning, .unknown:
            level = .warning
        case .critical, .insufficient:
            level = .error
        }
        record(.storage, "capacity.pressure", level: level, metadata: metadata)
    }

    nonisolated static func errorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        let isOutOfSpace = (nsError.domain == NSCocoaErrorDomain
            && CocoaError.Code(rawValue: nsError.code) == .fileWriteOutOfSpace)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
        return [
            "errorDomain": nsError.domain,
            "errorCode": String(nsError.code),
            "isOutOfSpace": String(isOutOfSpace)
        ]
    }

    nonisolated static func hashIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func beginInterval(
        _ name: StaticString,
        category: DiagnosticCategory
    ) -> OSSignpostIntervalState {
        signposter(for: category).beginInterval(name)
    }

    nonisolated static func endInterval(
        _ name: StaticString,
        category: DiagnosticCategory,
        _ state: OSSignpostIntervalState
    ) {
        signposter(for: category).endInterval(name, state)
    }

    nonisolated static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in metadata {
            let safeKey = String(key.prefix(64)).filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
            let safeValue = value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            sanitized[safeKey] = String(safeValue.prefix(160))
        }
        return sanitized
    }

    nonisolated private static func shortSessionID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

    nonisolated private static func logger(for category: DiagnosticCategory) -> Logger {
        switch category {
        case .documentOpen: documentOpenLogger
        case .iCloud: iCloudLogger
        case .storage: storageLogger
        case .cache: cacheLogger
        case .compiler: compilerLogger
        case .importExport: importExportLogger
        case .appLifecycle: appLifecycleLogger
        }
    }

    nonisolated private static func signposter(for category: DiagnosticCategory) -> OSSignposter {
        switch category {
        case .documentOpen: documentOpenSignposter
        case .iCloud: iCloudSignposter
        case .storage: storageSignposter
        case .cache: cacheSignposter
        case .compiler: compilerSignposter
        case .importExport: importExportSignposter
        case .appLifecycle: appLifecycleSignposter
        }
    }
}
