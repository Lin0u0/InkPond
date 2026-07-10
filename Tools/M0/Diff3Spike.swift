import Foundation

struct MergeConflict: Equatable {
    let baseLineRange: Range<Int>
    let local: String
    let base: String
    let remote: String
}

struct MergeResult: Equatable {
    let text: String
    let conflicts: [MergeConflict]
}

enum Diff3 {
    static func merge(base: String, local: String, remote: String) -> MergeResult {
        let baseLines = splitLines(base)
        let localChanges = diff(from: baseLines, to: splitLines(local))
        let remoteChanges = diff(from: baseLines, to: splitLines(remote))
        let groups = changeGroups(local: localChanges, remote: remoteChanges)

        var output = ""
        var conflicts: [MergeConflict] = []
        var cursor = 0

        for group in groups {
            output += baseLines[cursor..<group.start].joined()

            let baseText = baseLines[group.start..<group.end].joined()
            let localText = applying(
                group.changes.filter { $0.side == .local }.map(\.change),
                to: baseLines,
                in: group.start..<group.end
            )
            let remoteText = applying(
                group.changes.filter { $0.side == .remote }.map(\.change),
                to: baseLines,
                in: group.start..<group.end
            )
            let hasLocalChange = group.changes.contains { $0.side == .local }
            let hasRemoteChange = group.changes.contains { $0.side == .remote }

            switch (hasLocalChange, hasRemoteChange) {
            case (true, false):
                output += localText
            case (false, true):
                output += remoteText
            case (true, true) where localText == remoteText:
                output += localText
            case (true, true) where localText == baseText:
                output += remoteText
            case (true, true) where remoteText == baseText:
                output += localText
            case (true, true):
                output += conflictText(local: localText, base: baseText, remote: remoteText)
                conflicts.append(
                    MergeConflict(
                        baseLineRange: group.start..<group.end,
                        local: localText,
                        base: baseText,
                        remote: remoteText
                    )
                )
            case (false, false):
                preconditionFailure("A change group cannot be empty")
            }

            cursor = group.end
        }

        output += baseLines[cursor...].joined()
        return MergeResult(text: output, conflicts: conflicts)
    }

    private enum Side: Int {
        case local
        case remote
    }

    private struct Change {
        let start: Int
        let end: Int
        let replacement: [String]
    }

    private struct SidedChange {
        let side: Side
        let change: Change
    }

    private struct ChangeGroup {
        var start: Int
        var end: Int
        var changes: [SidedChange]
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lines = pieces.enumerated().map { index, piece in
            String(piece) + (index < pieces.count - 1 ? "\n" : "")
        }
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func diff(from base: [String], to changed: [String]) -> [Change] {
        var lcs = Array(
            repeating: Array(repeating: 0, count: changed.count + 1),
            count: base.count + 1
        )

        if !base.isEmpty, !changed.isEmpty {
            for baseIndex in stride(from: base.count - 1, through: 0, by: -1) {
                for changedIndex in stride(from: changed.count - 1, through: 0, by: -1) {
                    if base[baseIndex] == changed[changedIndex] {
                        lcs[baseIndex][changedIndex] = lcs[baseIndex + 1][changedIndex + 1] + 1
                    } else {
                        lcs[baseIndex][changedIndex] = max(
                            lcs[baseIndex + 1][changedIndex],
                            lcs[baseIndex][changedIndex + 1]
                        )
                    }
                }
            }
        }

        var changes: [Change] = []
        var baseIndex = 0
        var changedIndex = 0
        var pendingStart: Int?
        var pendingEnd = 0
        var replacement: [String] = []

        func flush() {
            guard let start = pendingStart else { return }
            changes.append(Change(start: start, end: pendingEnd, replacement: replacement))
            pendingStart = nil
            replacement = []
        }

        while baseIndex < base.count || changedIndex < changed.count {
            if baseIndex < base.count,
               changedIndex < changed.count,
               base[baseIndex] == changed[changedIndex] {
                flush()
                baseIndex += 1
                changedIndex += 1
            } else if baseIndex < base.count,
                      (changedIndex == changed.count
                        || lcs[baseIndex + 1][changedIndex] >= lcs[baseIndex][changedIndex + 1]) {
                if pendingStart == nil {
                    pendingStart = baseIndex
                    pendingEnd = baseIndex
                }
                baseIndex += 1
                pendingEnd = baseIndex
            } else {
                if pendingStart == nil {
                    pendingStart = baseIndex
                    pendingEnd = baseIndex
                }
                replacement.append(changed[changedIndex])
                changedIndex += 1
            }
        }
        flush()
        return changes
    }

    private static func changeGroups(local: [Change], remote: [Change]) -> [ChangeGroup] {
        let allChanges = (
            local.map { SidedChange(side: .local, change: $0) }
                + remote.map { SidedChange(side: .remote, change: $0) }
        ).sorted {
            if $0.change.start != $1.change.start {
                return $0.change.start < $1.change.start
            }
            if $0.change.end != $1.change.end {
                return $0.change.end < $1.change.end
            }
            return $0.side.rawValue < $1.side.rawValue
        }

        var groups: [ChangeGroup] = []
        for candidate in allChanges {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].changes.contains(where: {
                   $0.side != candidate.side && overlaps($0.change, candidate.change)
               }) {
                groups[lastIndex].start = min(groups[lastIndex].start, candidate.change.start)
                groups[lastIndex].end = max(groups[lastIndex].end, candidate.change.end)
                groups[lastIndex].changes.append(candidate)
            } else {
                groups.append(
                    ChangeGroup(
                        start: candidate.change.start,
                        end: candidate.change.end,
                        changes: [candidate]
                    )
                )
            }
        }
        return groups
    }

    private static func overlaps(_ lhs: Change, _ rhs: Change) -> Bool {
        if lhs.start == lhs.end {
            return rhs.start <= lhs.start && lhs.start <= rhs.end
        }
        if rhs.start == rhs.end {
            return lhs.start <= rhs.start && rhs.start <= lhs.end
        }
        return max(lhs.start, rhs.start) < min(lhs.end, rhs.end)
    }

    private static func applying(
        _ changes: [Change],
        to base: [String],
        in region: Range<Int>
    ) -> String {
        var result = ""
        var cursor = region.lowerBound
        for change in changes.sorted(by: { $0.start < $1.start }) {
            result += base[cursor..<change.start].joined()
            result += change.replacement.joined()
            cursor = change.end
        }
        result += base[cursor..<region.upperBound].joined()
        return result
    }

    private static func conflictText(local: String, base: String, remote: String) -> String {
        "<<<<<<< LOCAL\n"
            + terminated(local)
            + "||||||| BASE\n"
            + terminated(base)
            + "=======\n"
            + terminated(remote)
            + ">>>>>>> ICLOUD\n"
    }

    private static func terminated(_ text: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
    }
}
