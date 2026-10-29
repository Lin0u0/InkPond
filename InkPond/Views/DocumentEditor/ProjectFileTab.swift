//
//  ProjectFileTab.swift
//  InkPond
//

import Foundation

struct ProjectFileTab: Identifiable, Hashable {
    let relativePath: String
    let displayName: String
    let kind: FileKind

    var id: String { relativePath }

    func distinctDisplayName(in tabs: [ProjectFileTab], preservingFilenameTail: Bool = false) -> String {
        let components = relativePath.split(separator: "/")
        let peers = tabs.filter {
            $0.relativePath != relativePath
                && ($0.relativePath as NSString).lastPathComponent == displayName
        }
        guard !peers.isEmpty else {
            guard preservingFilenameTail else { return displayName }
            // Resolve collisions against the actual global output, including literal
            // ellipses in original names. Each pass consumes prefix context, so this
            // is bounded by the total number of filename graphemes.
            let names = Array(Set(tabs.map(\.displayName) + [displayName])).sorted()
            let tails = names.map { name in
                ProjectFileTab(relativePath: name, displayName: name, kind: kind)
                    .tailDisplayName(in: tabs)
            }
            var prefixCounts = Array(repeating: 0, count: names.count)
            var candidates = tails
            let budget = names.reduce(0) { $0 + $1.count } + 1
            for _ in 0..<budget {
                let collisions = candidates.indices.filter { index in
                    candidates.indices.contains { $0 != index && candidates[$0] == candidates[index] }
                }
                if collisions.isEmpty { break }
                for index in collisions {
                    prefixCounts[index] = min(prefixCounts[index] + 1, names[index].count)
                    candidates[index] = prefixCounts[index] == names[index].count
                        ? names[index]
                        : String(names[index].prefix(prefixCounts[index])) + tails[index]
                }
            }
            // Original names are unique by construction; this final fallback also
            // handles a literal name colliding with a fully expanded candidate.
            if Set(candidates).count != candidates.count { candidates = names }
            return candidates[names.firstIndex(of: displayName)!]
        }
        for count in 2...max(components.count, 2) {
            let suffix = components.suffix(count).joined(separator: "/")
            if peers.allSatisfy({ $0.relativePath.split(separator: "/").suffix(count).joined(separator: "/") != suffix }) {
                return suffix
            }
        }
        return relativePath
    }
    private func tailDisplayName(in tabs: [ProjectFileTab]) -> String {
        // Work in graphemes and never trim the extension or the entire stem.
        let name = Array(displayName)
        let stemCount = ((displayName as NSString).deletingPathExtension).count
        let sharedPrefixCount = tabs
            .filter { $0.relativePath != relativePath && $0.displayName != displayName }
            .map { zip(name, Array($0.displayName)).prefix { $0.0 == $0.1 }.count }
            .max() ?? 0
        let trimCount = min(max(0, sharedPrefixCount - 1), max(0, stemCount - 1))
        guard trimCount > 0 else { return displayName }
        return "…" + String(name.dropFirst(trimCount))
    }

}

