import Foundation

nonisolated struct ProjectPathPolicy: Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\")
        else {
            throw ProjectPathPolicyError.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectPathPolicyError.invalidRelativePath(relativePath)
        }

        let candidate = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ProjectPathPolicyError.outsideProjectRoot(relativePath)
        }

        let fileManager = FileManager.default
        if (try? fileManager.destinationOfSymbolicLink(atPath: rootURL.path)) != nil {
            throw ProjectPathPolicyError.symbolicLinkAncestor(rootURL.path)
        }

        var ancestor = rootURL
        for component in components {
            ancestor.appendPathComponent(component, isDirectory: true)
            if (try? fileManager.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw ProjectPathPolicyError.symbolicLinkAncestor(ancestor.path)
            }
        }
        return candidate
    }
}

nonisolated enum ProjectPathPolicyError: Error, Equatable {
    case invalidRelativePath(String)
    case outsideProjectRoot(String)
    case symbolicLinkAncestor(String)
}
