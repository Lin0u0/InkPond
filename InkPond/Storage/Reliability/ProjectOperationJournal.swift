import Foundation
#if canImport(Darwin)
import Darwin
#endif

nonisolated enum ProjectOperationState: String, Codable, Sendable {
    case prepared
    case applied
    case committed
}

nonisolated struct ProjectOperationJournalEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let schemaVersion: Int
    let snapshot: DocumentSnapshot
    let stagedRelativePath: String
    var state: ProjectOperationState

    init(id: UUID = UUID(), snapshot: DocumentSnapshot, stagedRelativePath: String, state: ProjectOperationState = .prepared) {
        self.id = id
        self.schemaVersion = 1
        self.snapshot = snapshot
        self.stagedRelativePath = stagedRelativePath
        self.state = state
    }
}

actor ProjectOperationJournal {
    private let journalURL: URL
    private var entries: [ProjectOperationJournalEntry]

    init(rootURL: URL) throws {
        let directory = rootURL.appendingPathComponent(".inkpond", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = try ProjectPathPolicy(rootURL: rootURL).resolve(".inkpond/journal-v1.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            entries = try JSONDecoder().decode([ProjectOperationJournalEntry].self, from: Data(contentsOf: journalURL))
            if let unsupported = entries.first(where: { $0.schemaVersion != 1 }) {
                throw ProjectOperationJournalError.unsupportedSchemaVersion(unsupported.schemaVersion)
            }
            guard entries.allSatisfy({ $0.stagedRelativePath.hasPrefix(".inkpond/staging/") }) else {
                throw ProjectOperationJournalError.invalidEntry
            }
        } else {
            entries = []
        }
    }

    func prepare(_ entry: ProjectOperationJournalEntry) throws {
        var next = entries
        next.append(entry)
        try persist(next)
        entries = next
    }

    func transition(id: UUID, to state: ProjectOperationState) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ProjectOperationJournalError.entryNotFound(id)
        }
        let current = entries[index].state
        guard (current == .prepared && state == .applied) || (current == .applied && state == .committed) else {
            throw ProjectOperationJournalError.invalidTransition(from: current, to: state)
        }
        var next = entries
        next[index].state = state
        try persist(next)
        entries = next
    }

    func discard(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ProjectOperationJournalError.entryNotFound(id)
        }
        var next = entries
        next.remove(at: index)
        try persist(next)
        entries = next
    }

    func discardCommitted(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .committed else {
            throw ProjectOperationJournalError.entryNotFound(id)
        }
        try discard(id: id)
    }

    func compactCommitted() throws {
        let next = entries.filter { $0.state != .committed }
        guard next.count != entries.count else { return }
        try persist(next)
        entries = next
    }

    func pendingEntries() -> [ProjectOperationJournalEntry] {
        entries.filter { $0.state != .committed }
    }

    func committedEntries() -> [ProjectOperationJournalEntry] {
        entries.filter { $0.state == .committed }
    }

    private func persist(_ entries: [ProjectOperationJournalEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: journalURL, options: [.atomic])
#if canImport(Darwin)
        try synchronize(journalURL)
        try synchronize(journalURL.deletingLastPathComponent())
#endif
    }

#if canImport(Darwin)
    private func synchronize(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
#endif
}

nonisolated enum ProjectOperationJournalError: Error, Equatable {
    case entryNotFound(UUID)
    case unsupportedSchemaVersion(Int)
    case invalidTransition(from: ProjectOperationState, to: ProjectOperationState)
    case invalidEntry
}
