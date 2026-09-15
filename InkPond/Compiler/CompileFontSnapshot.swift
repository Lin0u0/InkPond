import CryptoKit
import Foundation

/// Rust caches extra font faces and preview worlds by path, not file contents.
/// Give custom font bytes an immutable identity before consulting either cache.
enum CompileFontSnapshot {
    nonisolated private static let lock = NSLock()
    nonisolated private static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("CompileFontSnapshots-v1", isDirectory: true)

    nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func prepare(paths: [String]) throws -> [String] {
        try CoreTextFontMaterializer.materializePlannedFonts(in: paths).map { path in
            // Always read the input, even if its old snapshot exists. A deleted or
            // unreadable project/app font must fail rather than reuse old output.
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if CoreTextFontMaterializer.ownsMaterializedPath(path) {
                return path
            }
            return try snapshot(data: data)
        }
    }

    nonisolated private static func snapshot(data: Data) throws -> String {
        // Full SHA-256, no lossy filename sanitization, timestamps or path-only keys.
        // Rust identifies the container from bytes, so the extension is immaterial.
        let destination = directory.appendingPathComponent(fingerprint(data) + ".font")
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Never overwrite a published identity with different bytes (including
            // externally damaged snapshots or an unexpected digest collision).
            guard try Data(contentsOf: destination) == data else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            try data.write(to: destination, options: .atomic)
        }
        return destination.path
    }
}
