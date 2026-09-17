import Foundation

/// Values captured at intent, before any suspension. `textOverlays` must include
/// every authoritative session buffer (including a dirty imported .typ file).
/// These URLs are capture inputs ONLY, never worker inputs.
nonisolated struct OperationSnapshotInput: Sendable {
    var projectID: String
    var title: String
    var entryFileName: String
    var source: String
    var projectRoot: URL?
    var fontPaths: [String]
    var textOverlays: [String: String] = [:]
    var settings: [String: String] = [:]
    var frozenUnixSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    var localPackagesRoot: URL? = TypstBridge.localPackagesDirectoryURL
    var packageCacheRoot: URL? = TypstBridge.packageCacheDirectoryURL
}

nonisolated struct SnapshotCaptureLimits: Sendable {
    // Initial logical capture and total staged payload are separate budgets.
    // Physical budget includes the capture plus native sealed copies/package blobs;
    // temporary read buffers and bounded manifest metadata are not payload bytes.
    var maximumPhysicalBytes = 512 * 1024 * 1024
    var maximumPhysicalEntries = 16_384
    var maximumBytes = 256 * 1024 * 1024
    var maximumFileBytes = 64 * 1024 * 1024
    var maximumEntries = 10_000
    var maximumPackages = 256
    var maximumFonts = 256
    var maximumDepth = 64
    var maximumSeconds: TimeInterval = 15
}

nonisolated enum SnapshotCaptureError: Error, LocalizedError {
    case limitExceeded
    case unsupportedInput
    case inputChanged

    var errorDescription: String? {
        // Reuse localized storage errors until dedicated snapshot copy is localized.
        switch self {
        case .limitExceeded: return CocoaError(.fileReadTooLarge).localizedDescription
        case .unsupportedInput: return CocoaError(.fileReadUnsupportedScheme).localizedDescription
        case .inputChanged: return CocoaError(.fileReadUnknown).localizedDescription
        }
    }
}

/// A private directory lease. The detached worker must own this value through
/// the *return* of FFI, not merely until the UI task is cancelled.
nonisolated final class OperationSnapshot: Sendable {
    let id: UUID
    let projectID: String
    let title: String
    let entryFileName: String
    let source: String
    let settings: [String: String]
    let rootURL: URL
    let projectRoot: URL
    let fontPaths: [String]
    let preparation: SnapshotPreparationInputs
    let limits: SnapshotCaptureLimits
    let frozenUnixSeconds: Int64
    let capturedBytes: Int
    let capturedEntries: Int
    let captureSeconds: TimeInterval

    private init(input: OperationSnapshotInput, id: UUID, root: URL, fonts: [String], capture: Capture) {
        self.id = id
        projectID = input.projectID
        title = input.title
        entryFileName = input.entryFileName
        source = input.source
        settings = input.settings
        rootURL = root
        projectRoot = root.appendingPathComponent("project", isDirectory: true)
        preparation = SnapshotPreparationInputs(localPackagesRoot: input.localPackagesRoot, packageCacheRoot: input.packageCacheRoot)
        limits = capture.limits
        frozenUnixSeconds = input.frozenUnixSeconds
        fontPaths = fonts
        capturedBytes = capture.bytes
        capturedEntries = capture.entries
        captureSeconds = ProcessInfo.processInfo.systemUptime - capture.started
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }

    // Per-invocation test seam: no global hook or mutable shared capture state.
    enum CaptureCheckpoint: Sendable { case projectCopied, inputsVerified }

    /// Capture completion is NOT compile acceptance; native preparation must seal it.
    /// This is optimistic validation, not a lock shared with application writers.
    /// Each file is checked around its read; directories and files are checked again
    /// after ALL live reads, before applying the intent-time session overlays.
    /// A changed observation rejects without retry. Writes before a file's first
    /// observation may be included; writes after validation can instead succeed
    /// with the complete older copy. Workers never reread originals.
    /// Overlays intentionally supersede disk saves.
    /// This is NOT an atomic provider snapshot: metadata-preserving/ABA mutations
    /// and multi-file application transactions are not covered by these stamps.
    /// No hard links, symlinks, lazy clones, or live project/font fallbacks are retained.
    static func capture(_ input: OperationSnapshotInput, limits: SnapshotCaptureLimits = .init(), stagingParent: URL = FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                        checkpoint: (@Sendable (CaptureCheckpoint) throws -> Void)? = nil) throws -> OperationSnapshot {
        let id = UUID()
        let root = stagingParent.appendingPathComponent("inkpond-snapshot-\(id.uuidString)", isDirectory: true)
        let capture = Capture(limits: limits)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let project = root.appendingPathComponent("project", isDirectory: true)
            try capture.tree(input.projectRoot, to: project)
            try checkpoint?(.projectCopied)
            guard input.fontPaths.count <= limits.maximumFonts else { throw SnapshotCaptureError.limitExceeded }
            let fontsDirectory = root.appendingPathComponent("fonts", isDirectory: true)
            try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: false)
            var fonts: [String] = []
            for (index, path) in input.fontPaths.enumerated() {
                try capture.check()
                let materialized = try CoreTextFontMaterializer.materializeSnapshotFont(at: path)
                try capture.check()
                let origin = URL(fileURLWithPath: materialized)
                let destination = fontsDirectory.appendingPathComponent("\(index).\(origin.pathExtension)")
                try capture.file(origin, to: destination)
                fonts.append(destination.path)
            }
            // Verify originals BEFORE overlays replace their captured representations.
            try capture.verify()
            try checkpoint?(.inputsVerified)
            for (relative, text) in input.textOverlays {
                let destination = try safeURL(relative, under: project)
                try capture.consume(text.utf8.count)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: destination, options: .atomic)
            }
            try capture.consume(input.source.utf8.count)
            try capture.check()
            let snapshot = OperationSnapshot(input: input, id: id, root: root, fonts: fonts, capture: capture)
            Diagnostics.record(.compiler, "snapshot.capture.completed", metadata: [
                "bytes": String(snapshot.capturedBytes), "entries": String(snapshot.capturedEntries),
                "elapsedMs": String(Int(snapshot.captureSeconds * 1000))
            ])
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func safeURL(_ relative: String, under root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SnapshotCaptureError.unsupportedInput
        }
        return root.appendingPathComponent(relative)
    }

    nonisolated private final class Capture {
        let limits: SnapshotCaptureLimits
        let started = ProcessInfo.processInfo.systemUptime
        var bytes = 0
        var entries = 0
        var observations: [(URL, Stamp)] = []
        var missingRoots: [URL] = []

        init(limits: SnapshotCaptureLimits) { self.limits = limits }

        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started <= limits.maximumSeconds else {
                throw SnapshotCaptureError.limitExceeded
            }
        }

        func consume(_ count: Int) throws {
            try check()
            guard count >= 0, count <= limits.maximumFileBytes, bytes <= limits.maximumBytes - count, bytes <= limits.maximumPhysicalBytes - count,
                  entries < limits.maximumEntries, entries < limits.maximumPhysicalEntries else { throw SnapshotCaptureError.limitExceeded }
            bytes += count
            entries += 1
        }

        func tree(_ origin: URL?, to destination: URL, allowMissing: Bool = false, depth: Int = 0) throws {
            try check()
            guard depth <= limits.maximumDepth else { throw SnapshotCaptureError.limitExceeded }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let origin else { return }
            let stamp: Stamp
            do { stamp = try Stamp(origin) }
            catch let error as CocoaError where allowMissing && error.code == .fileReadNoSuchFile {
                missingRoots.append(origin)
                return
            }
            guard stamp.type == .typeDirectory else { throw SnapshotCaptureError.unsupportedInput }
            try consume(0)
            observations.append((origin, stamp))
            // Incremental enumeration bounds work even for huge directories.
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: origin, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw CocoaError(.fileReadUnknown) }
            for case let child as URL in enumerator {
                try check()
                let childStamp = try Stamp(child)
                let target = destination.appendingPathComponent(child.lastPathComponent)
                if childStamp.type == .typeDirectory {
                    try tree(child, to: target, depth: depth + 1)
                } else {
                    try file(child, to: target)
                }
            }
            if let enumerationError { throw enumerationError }
            guard try Stamp(origin) == stamp else { throw SnapshotCaptureError.inputChanged }
        }

        func file(_ origin: URL, to destination: URL) throws {
            let before = try Stamp(origin)
            guard before.type == .typeRegular else { throw SnapshotCaptureError.unsupportedInput }
            guard before.size <= limits.maximumFileBytes else { throw SnapshotCaptureError.limitExceeded }
            try consume(before.size)
            let handle = try FileHandle(forReadingFrom: origin)
            defer { try? handle.close() }
            var data = Data()
            while true {
                try check()
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                guard data.count <= before.size - chunk.count else { throw SnapshotCaptureError.inputChanged }
                data.append(chunk)
            }
            guard data.count == before.size, try Stamp(origin) == before else { throw SnapshotCaptureError.inputChanged }
            try data.write(to: destination, options: .atomic)
            observations.append((origin, before))
        }

        func verify() throws {
            for (url, stamp) in observations {
                try check()
                guard try Stamp(url) == stamp else { throw SnapshotCaptureError.inputChanged }
            }
            for url in missingRoots {
                try check()
                do {
                    _ = try Stamp(url)
                    throw SnapshotCaptureError.inputChanged
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
            }
        }
    }

    nonisolated private struct Stamp: Equatable {
        let type: FileAttributeType
        let size: Int
        let modified: Date?
        let created: Date?
        let inode: UInt64
        let device: UInt64

        init(_ url: URL) throws {
            guard url.isFileURL else { throw SnapshotCaptureError.unsupportedInput }
            // Do not canonicalize caller paths: doing so would hide a symlink
            // in a project/font parent. Only the OS-owned /var and /tmp aliases
            // are trusted (Foundation commonly returns these on Apple systems).
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    #if canImport(Darwin)
                    guard parent.path == "/var" || parent.path == "/tmp" else {
                        throw SnapshotCaptureError.unsupportedInput
                    }
                    #else
                    throw SnapshotCaptureError.unsupportedInput
                    #endif
                }
                parent = parent.deletingLastPathComponent()
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            type = attributes[.type] as? FileAttributeType ?? .typeUnknown
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            modified = attributes[.modificationDate] as? Date
            created = attributes[.creationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
}

/// Live package roots are usable only while discovering dependencies, never by final compile.
nonisolated struct SnapshotPreparationInputs: Sendable {
    let localPackagesRoot: URL?
    let packageCacheRoot: URL?
}

/// Native preparation is the only production constructor. Immutable manifest bytes
/// and the strong capture lease travel together through physical FFI completion.
nonisolated struct SealedCompileSnapshot: Sendable {
    let capture: OperationSnapshot
    let manifest: Data
    var rootURL: URL { capture.rootURL }

    fileprivate init(capture: OperationSnapshot, manifest: Data) {
        self.capture = capture
        self.manifest = manifest
    }

    static func prepare(_ capture: OperationSnapshot) throws -> SealedCompileSnapshot {
        defer { withExtendedLifetime(capture) {} }
        try Task.checkCancellation()
        let manifest = try TypstBridge.prepareSnapshot(capture).get()
        try Task.checkCancellation()
        return SealedCompileSnapshot(capture: capture, manifest: manifest)
    }
}
