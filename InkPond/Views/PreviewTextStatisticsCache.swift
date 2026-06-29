//
//  PreviewTextStatisticsCache.swift
//  InkPond
//

import CryptoKit
import Foundation
import os

struct PreviewTextStatistics: Equatable, Sendable {
    nonisolated let signature: String
    nonisolated let wordCount: Int
    nonisolated let characterCount: Int
}

enum PreviewTextStatisticsCache {
    private struct State: Sendable {
        var entries: [String: PreviewTextStatistics] = [:]
        var order: [String] = []
    }

    nonisolated private static let maxEntries = 16
    nonisolated private static let lock = OSAllocatedUnfairLock<State>(initialState: State())

    nonisolated static func signature(for text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(data.count):\(digest)"
    }

    nonisolated static func cachedStatistics(forSignature signature: String) -> PreviewTextStatistics? {
        lock.withLock { state in
            state.entries[signature]
        }
    }

    nonisolated static func statistics(for text: String, signature: String? = nil) -> PreviewTextStatistics {
        let resolvedSignature = signature ?? self.signature(for: text)
        if let cached = cachedStatistics(forSignature: resolvedSignature) {
            return cached
        }

        let statistics = PreviewTextStatistics(
            signature: resolvedSignature,
            wordCount: text.previewWordCount,
            characterCount: text.previewCharacterCount
        )
        store(statistics)
        return statistics
    }

    nonisolated private static func store(_ statistics: PreviewTextStatistics) {
        lock.withLock { state in
            state.entries[statistics.signature] = statistics
            state.order.removeAll { $0 == statistics.signature }
            state.order.append(statistics.signature)

            while state.order.count > maxEntries {
                let evictedSignature = state.order.removeFirst()
                state.entries.removeValue(forKey: evictedSignature)
            }
        }
    }
}
