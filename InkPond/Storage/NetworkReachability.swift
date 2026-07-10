//
//  NetworkReachability.swift
//  InkPond
//

import Foundation
import Network
import os.log

/// Lightweight wrapper around NWPathMonitor for checking network availability
/// before iCloud operations.
@Observable
final class NetworkReachability {
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.inkpond.network-reachability")

    private(set) var isConnected: Bool = true
    private(set) var isExpensive: Bool = false
    private(set) var isConstrained: Bool = false

    /// Human-readable description of the current network state.
    var statusDescription: String {
        if !isConnected {
            return L10n.tr("network.status.disconnected")
        }
        if isConstrained {
            return L10n.tr("network.status.constrained")
        }
        if isExpensive {
            return L10n.tr("network.status.expensive")
        }
        return L10n.tr("network.status.connected")
    }

    func start() {
        guard monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        pathMonitor.start(queue: monitorQueue)
        monitor = pathMonitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// An asynchronous stream of network reachability changes. The monitor is
    /// cancelled as soon as the consumer releases the stream.
    nonisolated static func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.inkpond.reachability-stream")
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

    /// Async one-shot snapshot. This intentionally avoids blocking MainActor
    /// or a cooperative executor with a semaphore.
    nonisolated static func currentlyReachable() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = updates().makeAsyncIterator()
                return await iterator.next() ?? false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
