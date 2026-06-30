//
//  MetricKitDiagnosticsSubscriber.swift
//  InkPond
//

import Foundation
import MetricKit

final class MetricKitDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitDiagnosticsSubscriber()

    private var isStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        MXMetricManager.shared.add(self)
        isStarted = true
        Diagnostics.record(.appLifecycle, "metrickit.subscriber_started")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        Diagnostics.record(
            .appLifecycle,
            "metrickit.metric_payloads_received",
            metadata: ["payloadCount": String(payloads.count)]
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let summaries = payloads.flatMap(Self.summaries(for:))
        Diagnostics.storage.appendMetricSummaries(summaries)
        Diagnostics.record(
            .appLifecycle,
            "metrickit.diagnostic_payloads_received",
            metadata: [
                "payloadCount": String(payloads.count),
                "summaryCount": String(summaries.count)
            ]
        )
    }

    func logStoredDiagnosticsAtLaunch() {
        let summaries = Diagnostics.storage.recentMetricSummaries()
        guard !summaries.isEmpty else { return }
        let latest = summaries[0]
        Diagnostics.record(
            .appLifecycle,
            "metrickit.last_diagnostic_available",
            level: .warning,
            metadata: [
                "kind": latest.kind,
                "appVersion": latest.appVersion ?? "unknown",
                "detail": latest.detail
            ]
        )
    }

    private static func summaries(for payload: MXDiagnosticPayload) -> [MetricDiagnosticSummary] {
        var summaries: [MetricDiagnosticSummary] = []
        let timestamp = payload.timeStampEnd

        for diagnostic in payload.crashDiagnostics ?? [] {
            summaries.append(MetricDiagnosticSummary(
                id: UUID().uuidString,
                timestamp: timestamp,
                kind: "crash",
                appVersion: diagnostic.applicationVersion,
                detail: crashDetail(diagnostic)
            ))
        }

        for diagnostic in payload.hangDiagnostics ?? [] {
            summaries.append(MetricDiagnosticSummary(
                id: UUID().uuidString,
                timestamp: timestamp,
                kind: "hang",
                appVersion: diagnostic.applicationVersion,
                detail: "duration=\(seconds(diagnostic.hangDuration))s"
            ))
        }

        for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
            summaries.append(MetricDiagnosticSummary(
                id: UUID().uuidString,
                timestamp: timestamp,
                kind: "disk_write",
                appVersion: diagnostic.applicationVersion,
                detail: "bytesWritten=\(bytes(diagnostic.totalWritesCaused))"
            ))
        }

        for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
            summaries.append(MetricDiagnosticSummary(
                id: UUID().uuidString,
                timestamp: timestamp,
                kind: "cpu",
                appVersion: diagnostic.applicationVersion,
                detail: "cpuTime=\(seconds(diagnostic.totalCPUTime))s sampled=\(seconds(diagnostic.totalSampledTime))s"
            ))
        }

        if #available(iOS 16.0, *) {
            for diagnostic in payload.appLaunchDiagnostics ?? [] {
                summaries.append(MetricDiagnosticSummary(
                    id: UUID().uuidString,
                    timestamp: timestamp,
                    kind: "launch",
                    appVersion: diagnostic.applicationVersion,
                    detail: "duration=\(seconds(diagnostic.launchDuration))s"
                ))
            }
        }

        return summaries
    }

    private static func crashDetail(_ diagnostic: MXCrashDiagnostic) -> String {
        var fields: [String] = []
        if let terminationReason = diagnostic.terminationReason, !terminationReason.isEmpty {
            fields.append("termination=\(String(terminationReason.prefix(80)))")
        }
        if let exceptionType = diagnostic.exceptionType {
            fields.append("exceptionType=\(exceptionType)")
        }
        if let signal = diagnostic.signal {
            fields.append("signal=\(signal)")
        }
        if #available(iOS 17.0, *),
           let exceptionName = diagnostic.exceptionReason?.exceptionName,
           !exceptionName.isEmpty {
            fields.append("exception=\(String(exceptionName.prefix(80)))")
        }
        return fields.isEmpty ? "no_detail" : fields.joined(separator: " ")
    }

    private static func seconds(_ measurement: Measurement<UnitDuration>) -> String {
        let value = measurement.converted(to: .seconds).value
        return String(format: "%.3f", value)
    }

    private static func bytes(_ measurement: Measurement<UnitInformationStorage>) -> String {
        let value = measurement.converted(to: .bytes).value
        return String(Int64(value.rounded()))
    }
}
